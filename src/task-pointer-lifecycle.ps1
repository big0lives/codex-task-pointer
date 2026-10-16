#requires -Version 7.5
[CmdletBinding()]
param([AllowNull()][string]$StateRoot = $null)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'task-pointer-store.ps1')
$script:TPV2_MaxHookInputBytes = 65536

function Write-HookJson {
    param([System.Collections.IDictionary]$Value)
    [Console]::Out.WriteLine(($Value | ConvertTo-Json -Compress -Depth 20))
}

function Read-HookInput {
    $stream = [Console]::OpenStandardInput()
    $memory = [IO.MemoryStream]::new()
    try {
        $buffer = [byte[]]::new(4096)
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $memory.Write($buffer, 0, $read)
            if ($memory.Length -gt $script:TPV2_MaxHookInputBytes) {
                Throw-TPV2Error -Code 'HOOK_INPUT_TOO_LARGE' -Detail ([string]$memory.Length)
            }
        }
        if ($memory.Length -eq 0) { Throw-TPV2Error -Code 'HOOK_INPUT_EMPTY' }
        try { return $script:TPV2_Utf8.GetString($memory.ToArray()) }
        catch { Throw-TPV2Error -Code 'HOOK_INPUT_UTF8_INVALID' }
    }
    finally { $memory.Dispose() }
}

function Write-AdditionalContext {
    param([string]$EventName, [string]$Context)
    if ($null -eq $Context) { return }
    Write-HookJson -Value ([ordered]@{
        continue = $true
        hookSpecificOutput = [ordered]@{
            hookEventName = $EventName
            additionalContext = $Context
        }
    })
}

function Assert-Event {
    param([System.Collections.IDictionary]$Event)
    foreach ($field in @('session_id','hook_event_name')) {
        if (-not $Event.Contains($field) -or $Event[$field] -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Event[$field])) { Throw-TPV2Error -Code 'HOOK_EVENT_FIELD_INVALID' -Detail $field }
    }
    Assert-TPV2SessionId -SessionId ([string]$Event.session_id)
    $name = [string]$Event.hook_event_name
    if ($name -cnotin @('UserPromptSubmit','PreCompact','SessionStart')) { Throw-TPV2Error -Code 'HOOK_EVENT_INVALID' }
    if ($name -ceq 'PreCompact' -and [string]$Event.trigger -cnotin @('manual','auto')) { Throw-TPV2Error -Code 'HOOK_TRIGGER_INVALID' }
    if ($name -ceq 'SessionStart' -and [string]$Event.source -cnotin @('startup','resume','clear','compact')) { Throw-TPV2Error -Code 'HOOK_SOURCE_INVALID' }
}

$eventName = $null
$eventSource = $null
try {
    $raw = Read-HookInput
    if ([string]::IsNullOrWhiteSpace($raw)) { Throw-TPV2Error -Code 'HOOK_INPUT_EMPTY' }
    try { $event = $raw | ConvertFrom-Json -AsHashtable -Depth 30 -DateKind String }
    catch { Throw-TPV2Error -Code 'HOOK_INPUT_PARSE_FAILED' }
    if ($event -isnot [System.Collections.IDictionary]) { Throw-TPV2Error -Code 'HOOK_INPUT_SCHEMA_INVALID' }
    $eventName = [string]$event.hook_event_name
    $eventSource = if ($event.Contains('source')) { [string]$event.source } else { $null }
    Assert-Event -Event $event
    $root = Resolve-TPV2StateRoot -StateRoot $StateRoot
    $session = [string]$event.session_id

    switch ($eventName) {
        'UserPromptSubmit' {
            $result = Set-TPV2Dirty -StateRoot $root -SessionId $session
            # 无指针可续（首次或刚被清除）才发 bootstrap；其余一律发 CAS 基础。DIRTY 上的 no-op
            # 重标记走这里而不是 bootstrap 分支，CAS 产物在 revision 不变时逐字节相同。
            $context = if ([bool]$result.bootstrap) {
                Format-TPV2BootstrapContext -SessionId $session -Source prompt -Status ([string]$result.status) -Generation ([string]$result.generation) -Revision ([int64]$result.revision)
            } else {
                Format-TPV2CasContext -SessionId $session -Status ([string]$result.status) -Generation ([string]$result.generation) -Revision ([int64]$result.revision) -AgeSeconds ([int]$result.age_seconds) -IdenticalTextStreak ([int]$result.identical_text_streak)
            }
            Write-AdditionalContext -EventName 'UserPromptSubmit' -Context $context
        }
        'PreCompact' {
            # 当前 state 在每次 publish/prompt 时已持久化；compact 前不复制或改写状态。
            return
        }
        'SessionStart' {
            if ($eventSource -ceq 'clear') {
                $result = Clear-TPV2State -StateRoot $root -SessionId $session
                Write-AdditionalContext -EventName 'SessionStart' -Context (Format-TPV2BootstrapContext -SessionId $session -Source clear -Status CLEARED -Generation ([string]$result.generation) -Revision ([int64]$result.revision))
            }
            else {
                $context = Get-TPV2Context -StateRoot $root -SessionId $session -Source $eventSource
                if ($null -eq $context) { $context = Get-TPV2BootstrapContext -StateRoot $root -SessionId $session -Source $eventSource }
                Write-AdditionalContext -EventName 'SessionStart' -Context $context
            }
        }
    }
    exit 0
}
catch {
    $code = Get-TPV2ErrorCode $_
    if ($eventName -ceq 'UserPromptSubmit') {
        [Console]::Error.WriteLine('TASK_POINTER_V2:' + $code)
        [Console]::Out.WriteLine('{"decision":"block","reason":"TASK_POINTER_DIRTY_WRITE_FAILED"}')
        exit 2
    }
    if ($eventName -ceq 'SessionStart') {
        $stop = $eventSource -cin @('clear','compact')
        Write-HookJson -Value ([ordered]@{
            continue = -not $stop
            stopReason = if ($stop) { 'TASK_POINTER_RECOVERY_REQUIRED' } else { $null }
            systemMessage = 'UNKNOWN_RECOVERY:' + $code
        })
        exit 0
    }
    Write-HookJson -Value ([ordered]@{continue=$false;stopReason='TASK_POINTER_V2_FAILED';systemMessage='TASK_POINTER_V2:'+$code})
    exit 2
}
