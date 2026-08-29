#requires -Version 7.5

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script:Publisher = Join-Path $script:Root 'src\task-pointer-publish.ps1'
$script:Lifecycle = Join-Path $script:Root 'src\task-pointer-lifecycle.ps1'
$script:Store = Join-Path $script:Root 'src\task-pointer-store.ps1'
$script:Migration = Join-Path $script:Root 'scripts\migrate-v1-to-v3.ps1'
$script:Passed = 0
$script:Failed = 0
$script:Utf8 = [System.Text.UTF8Encoding]::new($false)
$script:TempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$script:TestRoot = Join-Path $script:TempBase ('codex-task-pointer-v2-' + [guid]::NewGuid().ToString('N'))
$script:StateRoot = Join-Path $script:TestRoot 'state'
. $script:Store

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -cne $Actual) { throw "$Message expected=<$Expected> actual=<$Actual>" }
}

function Assert-Match {
    param([string]$Pattern, [string]$Actual, [string]$Message)
    if ($Actual -cnotmatch $Pattern) { throw "$Message pattern=<$Pattern> actual=<$Actual>" }
}

function Wait-TestPath {
    param([string]$Path, [int]$TimeoutMs = 5000)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while (-not [IO.File]::Exists($Path)) {
        if ($timer.ElapsedMilliseconds -ge $TimeoutMs) { throw "timed out waiting for $Path" }
        Start-Sleep -Milliseconds 10
    }
}

function Get-TestSha256Lower {
    param([byte[]]$Bytes)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function ConvertTo-TestFlatCanonicalJson {
    param([System.Collections.IDictionary]$Value)
    $keys = [string[]]@($Value.Keys | ForEach-Object { [string]$_ })
    [Array]::Sort($keys, [StringComparer]::Ordinal)
    $ordered = [ordered]@{}
    foreach ($key in $keys) { $ordered[$key] = $Value[$key] }
    return $ordered | ConvertTo-Json -Compress -Depth 20
}

function Write-TestV1Record {
    param(
        [string]$Root,
        [string]$SessionId,
        [ValidateSet('CLEAN','DIRTY','RETIRED','TOMBSTONE')][string]$Status,
        [AllowNull()][string]$TaskId,
        [AllowNull()][string]$PointerText
    )
    $sessionKey = Get-TPV2SessionKey $SessionId
    $directory = Join-Path $Root $sessionKey
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    if ($Status -ceq 'TOMBSTONE') {
        $payload = [ordered]@{
            created_at = '2026-08-23T00:00:00Z'
            reason = 'CLEAR'
            record_type = 'active_tombstone'
            schema_version = 1
            session_id = $SessionId
            session_key = $sessionKey
            status = 'TOMBSTONE'
            turn_id = $null
        }
    }
    else {
        $pointerBytes = $script:Utf8.GetBytes($PointerText)
        $payload = [ordered]@{
            dirty_from_turn_id = if ($Status -ceq 'DIRTY') { 'turn-dirty' } else { $null }
            dirty_prompt_count = if ($Status -ceq 'DIRTY') { 1 } else { 0 }
            dirty_through_turn_id = if ($Status -ceq 'DIRTY') { 'turn-dirty' } else { $null }
            pointer_sha256 = Get-TestSha256Lower $pointerBytes
            pointer_text = $PointerText
            pointer_text_utf8_bytes = $pointerBytes.Length
            record_type = 'active_snapshot'
            schema_version = 1
            session_id = $SessionId
            session_key = $sessionKey
            status = $Status
            task_id = $TaskId
            trigger = if ($Status -ceq 'DIRTY') { 'USER_PROMPT_SUBMIT' } else { 'CREATE' }
            updated_at = '2026-08-23T00:00:00Z'
            validated_through_turn_id = if ($Status -ceq 'DIRTY') { $null } else { 'turn-clean' }
            workspace_anchor = 'D:\Work\fixture'
        }
    }
    $payloadJson = ConvertTo-TestFlatCanonicalJson $payload
    $hash = Get-TestSha256Lower $script:Utf8.GetBytes($payloadJson)
    $document = '{"payload":' + $payloadJson + ',"payload_sha256":"' + $hash + '"}' + "`n"
    [IO.File]::WriteAllText((Join-Path $directory 'active.json'), $document, $script:Utf8)
}

function Update-TestV1Payload {
    param(
        [string]$Root,
        [string]$SessionId,
        [scriptblock]$Mutation
    )
    $file = Join-Path (Join-Path $Root (Get-TPV2SessionKey $SessionId)) 'active.json'
    $document = [IO.File]::ReadAllText($file, $script:Utf8) | ConvertFrom-Json -AsHashtable -Depth 50 -DateKind String
    & $Mutation $document.payload
    $payloadJson = ConvertTo-TestFlatCanonicalJson $document.payload
    $hash = Get-TestSha256Lower $script:Utf8.GetBytes($payloadJson)
    [IO.File]::WriteAllText($file, ('{"payload":' + $payloadJson + ',"payload_sha256":"' + $hash + '"}' + "`n"), $script:Utf8)
    return $file
}

function Invoke-Case {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $script:Passed++
        Write-Host "PASS $Name"
    }
    catch {
        $script:Failed++
        Write-Host "FAIL $Name :: $($_.Exception.Message)"
    }
}

function Get-StatePath {
    param([string]$SessionId, [string]$StateRoot = $script:StateRoot)
    return Get-TPV2StatePath -StateRoot $StateRoot -SessionId $SessionId
}

function Read-State {
    param([string]$SessionId, [string]$StateRoot = $script:StateRoot)
    return Get-Content -LiteralPath (Get-StatePath -SessionId $SessionId -StateRoot $StateRoot) -Raw -Encoding utf8 |
        ConvertFrom-Json -AsHashtable -Depth 20 -DateKind String
}

function New-RequestJson {
    param(
        [string]$SessionId,
        [string]$ExpectedGeneration,
        [int64]$ExpectedRevision,
        [string]$TaskId,
        [ValidateSet('CLEAN', 'CLEARED')]
        [string]$Status,
        [AllowNull()]
        [string]$PointerText
    )
    return [ordered]@{
        schema_version = 3
        session_id = $SessionId
        expected_generation = $ExpectedGeneration
        expected_revision = $ExpectedRevision
        task_id = if ($Status -ceq 'CLEARED') { $null } else { $TaskId }
        target_status = $Status
        pointer_text = if ($Status -ceq 'CLEARED') { $null } else { $PointerText }
    } | ConvertTo-Json -Compress
}

function Invoke-Publisher {
    param(
        [string]$SessionId,
        [string]$RequestJson,
        [string]$StateRoot = $script:StateRoot,
        [string]$Fault
    )
    $oldFault = [Environment]::GetEnvironmentVariable('CODEX_TASK_POINTER_V2_FAULT')
    try {
        [Environment]::SetEnvironmentVariable('CODEX_TASK_POINTER_V2_FAULT', $Fault)
        $lines = @($RequestJson | & pwsh -NonInteractive -NoProfile -File $script:Publisher -SessionId $SessionId -StateRoot $StateRoot 2>&1)
        return [ordered]@{ ExitCode = $LASTEXITCODE; Text = ($lines -join "`n").Trim() }
    }
    finally {
        [Environment]::SetEnvironmentVariable('CODEX_TASK_POINTER_V2_FAULT', $oldFault)
    }
}

function New-Event {
    param(
        [ValidateSet('UserPromptSubmit', 'PreCompact', 'SessionStart')]
        [string]$Name,
        [string]$SessionId,
        [string]$Variant
    )
    $base = [ordered]@{
        session_id = $SessionId
        transcript_path = $null
        cwd = 'D:\Work\fixture'
        hook_event_name = $Name
        model = 'fixture-model'
    }
    if ($Name -ceq 'UserPromptSubmit') {
        $base.turn_id = 'turn-' + [guid]::NewGuid().ToString('N')
        $base.prompt = 'fixture prompt'
        $base.permission_mode = 'default'
    }
    elseif ($Name -ceq 'PreCompact') {
        $base.turn_id = 'turn-' + [guid]::NewGuid().ToString('N')
        $base.trigger = $Variant
    }
    else {
        $base.source = $Variant
        $base.permission_mode = 'default'
    }
    return $base
}

function Invoke-Lifecycle {
    param(
        [System.Collections.IDictionary]$Event,
        [string]$StateRoot = $script:StateRoot,
        [string]$Fault
    )
    $oldFault = [Environment]::GetEnvironmentVariable('CODEX_TASK_POINTER_V2_FAULT')
    try {
        [Environment]::SetEnvironmentVariable('CODEX_TASK_POINTER_V2_FAULT', $Fault)
        $json = $Event | ConvertTo-Json -Compress -Depth 20
        $lines = @($json | & pwsh -NoProfile -File $script:Lifecycle -StateRoot $StateRoot 2>&1)
        return [ordered]@{ ExitCode = $LASTEXITCODE; Text = ($lines -join "`n").Trim() }
    }
    finally {
        [Environment]::SetEnvironmentVariable('CODEX_TASK_POINTER_V2_FAULT', $oldFault)
    }
}

function Publish-Clean {
    param(
        [string]$SessionId,
        [int64]$ExpectedRevision,
        [string]$PointerText = '目标：fixture`n下一步：verify',
        [string]$TaskId = '11111111-1111-4111-8111-111111111111',
        [string]$StateRoot = $script:StateRoot
    )
    $current = Read-TPV2State -StateRoot $StateRoot -SessionId $SessionId
    $generation = Get-TPV2Generation $current
    $request = New-RequestJson -SessionId $SessionId -ExpectedGeneration $generation -ExpectedRevision $ExpectedRevision -TaskId $TaskId -Status CLEAN -PointerText $PointerText
    return Invoke-Publisher -SessionId $SessionId -RequestJson $request -StateRoot $StateRoot
}

[System.IO.Directory]::CreateDirectory($script:TestRoot) | Out-Null
try {
    Invoke-Case 'v2 store、publisher、lifecycle 与迁移器存在' {
        foreach ($path in @($script:Store, $script:Publisher, $script:Lifecycle, $script:Migration)) {
            Assert-True -Condition (Test-Path -LiteralPath $path -PathType Leaf) -Message "missing $path"
        }
    }

    Invoke-Case '首次 publish 生成单一 CLEAN state.json' {
        $session = 'session-initial'
        $result = Publish-Clean -SessionId $session -ExpectedRevision 0
        Assert-Equal 0 $result.ExitCode ('publisher exit :: ' + $result.Text)
        $receipt = $result.Text | ConvertFrom-Json -AsHashtable
        Assert-True ([bool]$receipt.ok) 'receipt ok'
        Assert-Equal 1 ([int64]$receipt.revision) 'receipt revision'
        $state = Read-State -SessionId $session
        Assert-Equal 'generation,pointer_text,revision,schema_version,session_id,status,task_id,updated_at' ((@($state.Keys) | Sort-Object) -join ',') 'state exact fields'
        Assert-Equal 3 ([int]$state.schema_version) 'schema'
        Assert-Equal $session ([string]$state.session_id) 'session readback'
        Assert-Equal ([string]$receipt.generation) ([string]$state.generation) 'generation readback'
        Assert-Equal 'CLEAN' ([string]$state.status) 'status readback'
        Assert-Equal '11111111-1111-4111-8111-111111111111' ([string]$state.task_id) 'task readback'
        Assert-Equal '目标：fixture`n下一步：verify' ([string]$state.pointer_text) 'pointer readback'
        Assert-True (Test-TPV2UtcTimestamp $state.updated_at) 'timestamp readback'
        Assert-Match '^g-[0-9a-f]{32}$' ([string]$state.generation) 'generation'
        Assert-Equal 'CLEAN' ([string]$state.status) 'status'
        Assert-Equal 1 ([int64]$state.revision) 'revision'
        $files = @(Get-ChildItem -LiteralPath (Split-Path -Parent (Get-StatePath $session)) -File)
        Assert-Equal 1 $files.Count 'single state file'
        Assert-Equal 'state.json' $files[0].Name 'state name'
    }

    Invoke-Case 'UserPromptSubmit 原子标记 DIRTY 且 stale revision 被拒绝' {
        $session = 'session-dirty'
        Assert-Equal 0 (Publish-Clean -SessionId $session -ExpectedRevision 0).ExitCode 'initial publish'
        $event = New-Event -Name UserPromptSubmit -SessionId $session
        $hook = Invoke-Lifecycle -Event $event
        Assert-Equal 0 $hook.ExitCode ('prompt hook exit :: ' + $hook.Text)
        $state = Read-State -SessionId $session
        Assert-Equal 'DIRTY' ([string]$state.status) 'dirty status'
        Assert-Equal 2 ([int64]$state.revision) 'dirty revision'
        Assert-Match 'TASK_POINTER_V2_CAS' $hook.Text 'prompt CAS context'
        Assert-Match ([regex]::Escape('GENERATION=' + [string]$state.generation)) $hook.Text 'prompt CAS generation'
        Assert-Match 'REVISION=2' $hook.Text 'prompt CAS revision'
        $stale = Publish-Clean -SessionId $session -ExpectedRevision 1
        Assert-Equal 2 $stale.ExitCode 'stale exit'
        $staleReceipt = $stale.Text | ConvertFrom-Json -AsHashtable
        Assert-Equal 'STALE_REVISION' ([string]$staleReceipt.code) 'stale code'
        Assert-Equal 2 ([int64]$staleReceipt.observed_revision) 'observed revision'
        Assert-Equal 0 (Publish-Clean -SessionId $session -ExpectedRevision 2).ExitCode 'merge publish'
        Assert-Equal 'CLEAN' ([string](Read-State $session).status) 'clean restored'
    }

    Invoke-Case '连续 prompt 只依赖 revision 且不会接受旧基础' {
        $session = 'session-multi-prompt'
        Assert-Equal 0 (Publish-Clean -SessionId $session -ExpectedRevision 0).ExitCode 'initial publish'
        1..3 | ForEach-Object {
            $promptResult = Invoke-Lifecycle -Event (New-Event -Name UserPromptSubmit -SessionId $session)
            Assert-Equal 0 $promptResult.ExitCode ("prompt $_ :: " + $promptResult.Text)
        }
        $state = Read-State $session
        Assert-Equal 4 ([int64]$state.revision) 'revision after prompts'
        Assert-Equal 'DIRTY' ([string]$state.status) 'status after prompts'
        Assert-Equal 2 (Publish-Clean -SessionId $session -ExpectedRevision 3).ExitCode 'old base rejected'
        Assert-Equal 0 (Publish-Clean -SessionId $session -ExpectedRevision 4).ExitCode 'current base accepted'
    }

    Invoke-Case 'PreCompact 保持单 state，SessionStart 注入 CLEAN 或 MERGE_FIRST' {
        $session = 'session-compact'
        Assert-Equal 0 (Publish-Clean -SessionId $session -ExpectedRevision 0 -PointerText "目标：compact`n下一步：continue").ExitCode 'initial publish'
        $before = [System.IO.File]::ReadAllBytes((Get-StatePath $session))
        $pre = Invoke-Lifecycle -Event (New-Event -Name PreCompact -SessionId $session -Variant manual)
        Assert-Equal 0 $pre.ExitCode 'precompact exit'
        $after = [System.IO.File]::ReadAllBytes((Get-StatePath $session))
        Assert-Equal ([Convert]::ToBase64String($before)) ([Convert]::ToBase64String($after)) 'PreCompact changed state'
        $start = Invoke-Lifecycle -Event (New-Event -Name SessionStart -SessionId $session -Variant compact)
        Assert-Equal 0 $start.ExitCode 'session start exit'
        Assert-Match 'RECOVERY_MODE=CONTINUE' $start.Text 'clean context'
        Assert-Equal 0 (Invoke-Lifecycle -Event (New-Event -Name UserPromptSubmit -SessionId $session)).ExitCode 'dirty mark'
        $dirtyStart = Invoke-Lifecycle -Event (New-Event -Name SessionStart -SessionId $session -Variant resume)
        Assert-Match 'RECOVERY_MODE=MERGE_FIRST' $dirtyStart.Text 'dirty context'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path (Split-Path -Parent (Get-StatePath $session)) 'compact.json'))) 'compact.json created'
    }

    Invoke-Case 'clear 写 CLEARED，重复 clear 幂等递增 revision' {
        $session = 'session-clear'
        Assert-Equal 0 (Publish-Clean -SessionId $session -ExpectedRevision 0).ExitCode 'initial publish'
        foreach ($expected in @(2, 3)) {
            $result = Invoke-Lifecycle -Event (New-Event -Name SessionStart -SessionId $session -Variant clear)
            Assert-Equal 0 $result.ExitCode ('clear exit :: ' + $result.Text)
            $state = Read-State $session
            Assert-Equal 'CLEARED' ([string]$state.status) 'cleared status'
            Assert-Equal $expected ([int64]$state.revision) 'clear revision'
            Assert-True ($null -eq $state.task_id -and $null -eq $state.pointer_text) 'cleared payload'
        }
        $resume = Invoke-Lifecycle -Event (New-Event -Name SessionStart -SessionId $session -Variant resume)
        Assert-Equal 0 $resume.ExitCode 'cleared resume exit'
        Assert-Match 'TASK_POINTER_V2_BOOTSTRAP' $resume.Text 'cleared resume bootstrap'
    }

    Invoke-Case 'absent prompt 写 CLEARED fence，其他 absent 事件只返回 bootstrap' {
        $session = 'session-absent'
        foreach ($event in @(
            (New-Event -Name UserPromptSubmit -SessionId $session),
            (New-Event -Name PreCompact -SessionId $session -Variant auto),
            (New-Event -Name SessionStart -SessionId $session -Variant startup)
        )) {
            Assert-Equal 0 (Invoke-Lifecycle -Event $event).ExitCode 'absent event exit'
        }
        $state = Read-State $session
        Assert-Equal 'CLEARED' ([string]$state.status) 'absent prompt fence status'
        Assert-Equal 1 ([int64]$state.revision) 'absent prompt fence revision'
    }

    Invoke-Case 'pointer UTF-8 byte cap 为 8192' {
        $ok = Publish-Clean -SessionId 'session-byte-ok' -ExpectedRevision 0 -PointerText ('a' * 8192)
        Assert-Equal 0 $ok.ExitCode '8192 bytes'
        $bad = Publish-Clean -SessionId 'session-byte-bad' -ExpectedRevision 0 -PointerText ('a' * 8193)
        Assert-Equal 2 $bad.ExitCode '8193 bytes'
        Assert-Match 'POINTER_TOO_LARGE' $bad.Text 'byte cap code'
    }

    Invoke-Case '写入故障保持有效 state 且 UserPromptSubmit block' {
        $session = 'session-write-fault'
        Assert-Equal 0 (Publish-Clean -SessionId $session -ExpectedRevision 0).ExitCode 'initial publish'
        $before = [System.IO.File]::ReadAllBytes((Get-StatePath $session))
        $fault = Invoke-Lifecycle -Event (New-Event -Name UserPromptSubmit -SessionId $session) -Fault BEFORE_REPLACE
        Assert-Equal 2 $fault.ExitCode 'fault exit'
        Assert-Match 'TASK_POINTER_DIRTY_WRITE_FAILED' $fault.Text 'prompt block'
        $after = [System.IO.File]::ReadAllBytes((Get-StatePath $session))
        Assert-Equal ([Convert]::ToBase64String($before)) ([Convert]::ToBase64String($after)) 'fault changed state'
    }

    Invoke-Case '损坏 state 产生 UNKNOWN_RECOVERY 且正文不进入上下文' {
        $session = 'session-corrupt'
        $statePath = Get-StatePath $session
        [System.IO.Directory]::CreateDirectory((Split-Path -Parent $statePath)) | Out-Null
        [System.IO.File]::WriteAllText($statePath, '{broken', $script:Utf8)
        $start = Invoke-Lifecycle -Event (New-Event -Name SessionStart -SessionId $session -Variant resume)
        Assert-Equal 0 $start.ExitCode 'corrupt SessionStart exit'
        Assert-Match 'UNKNOWN_RECOVERY' $start.Text 'unknown recovery warning'
        Assert-True ($start.Text -cnotmatch '下一步') 'corrupt body leaked'
    }

    Invoke-Case 'session id 路径边界拒绝 traversal' {
        $request = New-RequestJson -SessionId '..\escape' -ExpectedGeneration ABSENT -ExpectedRevision 0 -TaskId '11111111-1111-4111-8111-111111111111' -Status CLEAN -PointerText 'x'
        $result = Invoke-Publisher -SessionId '..\escape' -RequestJson $request
        Assert-Equal 2 $result.ExitCode 'traversal exit'
        Assert-Match 'SESSION_ID_INVALID' $result.Text 'traversal code'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $script:TestRoot 'escape'))) 'traversal write'
    }

    Invoke-Case 'v1 migration dry-run 与 CLEAN/DIRTY/RETIRED/TOMBSTONE 映射' {
        $v1 = Join-Path $script:TestRoot 'v1'
        $v2 = Join-Path $script:TestRoot 'migrated-v2'
        $fixtures = @(
            @{ id = 'migrate-clean'; type = 'active_snapshot'; status = 'CLEAN'; task = '11111111-1111-4111-8111-111111111111'; pointer = '中文 clean pointer' },
            @{ id = 'migrate-dirty'; type = 'active_snapshot'; status = 'DIRTY'; task = '22222222-2222-4222-8222-222222222222'; pointer = 'dirty pointer' },
            @{ id = 'migrate-retired'; type = 'active_snapshot'; status = 'RETIRED'; task = '33333333-3333-4333-8333-333333333333'; pointer = "retired pointer`n下一步：NONE" },
            @{ id = 'migrate-tombstone'; type = 'active_tombstone'; status = 'TOMBSTONE'; task = $null; pointer = $null }
        )
        foreach ($fixture in $fixtures) {
            Write-TestV1Record -Root $v1 -SessionId $fixture.id -Status $fixture.status -TaskId $fixture.task -PointerText $fixture.pointer
        }
        $dry = @(& pwsh -NoProfile -File $script:Migration -V1Root $v1 -V2Root $v2 2>&1)
        Assert-Equal 0 $LASTEXITCODE 'migration dry exit'
        Assert-True (-not (Test-Path -LiteralPath $v2)) 'dry-run wrote v2'
        Assert-Match 'invalid=0' ($dry -join "`n") 'dry-run summary'
        $apply = @(& pwsh -NoProfile -File $script:Migration -V1Root $v1 -V2Root $v2 -Apply 2>&1)
        Assert-Equal 0 $LASTEXITCODE ('migration apply exit :: ' + ($apply -join "`n"))
        Assert-Match 'migrated=4' ($apply -join "`n") 'apply summary'
        Assert-Equal 'CLEAN' ([string](Read-State -SessionId 'migrate-clean' -StateRoot $v2).status) 'clean map'
        Assert-Equal 'DIRTY' ([string](Read-State -SessionId 'migrate-dirty' -StateRoot $v2).status) 'dirty map'
        Assert-Equal 'CLEARED' ([string](Read-State -SessionId 'migrate-retired' -StateRoot $v2).status) 'retired map'
        Assert-Equal 'CLEARED' ([string](Read-State -SessionId 'migrate-tombstone' -StateRoot $v2).status) 'tombstone map'
        Assert-Equal 4 @(Get-ChildItem -LiteralPath $v1 -Recurse -Filter active.json).Count 'v1 changed'
    }

    Invoke-Case 'v1 snapshot trigger 与 DIRTY/RETIRED 关系严格绑定' {
        $validRoot = Join-Path $script:TestRoot 'v1-valid-trigger-matrix'
        $validTriggers = @('CREATE','USER_STEERING','RECOVERY_DRIFT','BATCH_NODE','GIT_CHECKPOINT','LONG_COMMAND_START','LONG_COMMAND_END','COMPLETE','REPLACE','USER_PROMPT_SUBMIT')
        for ($index = 0; $index -lt $validTriggers.Count; $index++) {
            $session = "valid-trigger-$index"
            Write-TestV1Record -Root $validRoot -SessionId $session -Status CLEAN -TaskId '11111111-1111-4111-8111-111111111111' -PointerText 'valid trigger pointer'
            [void](Update-TestV1Payload -Root $validRoot -SessionId $session -Mutation { param($payload) $payload['trigger'] = $validTriggers[$index] })
        }
        $caseSessionA = 'CaseSensitiveSession'
        $caseSessionB = 'casesensitivesession'
        Write-TestV1Record -Root $validRoot -SessionId $caseSessionA -Status CLEAN -TaskId '22222222-2222-4222-8222-222222222222' -PointerText 'case A'
        Write-TestV1Record -Root $validRoot -SessionId $caseSessionB -Status CLEAN -TaskId '33333333-3333-4333-8333-333333333333' -PointerText 'case B'
        $valid = @(& pwsh -NoProfile -File $script:Migration -V1Root $validRoot -V2Root (Join-Path $script:TestRoot 'v2-valid-trigger-matrix') 2>&1)
        Assert-Equal 0 $LASTEXITCODE ('valid trigger matrix :: ' + ($valid -join "`n"))
        Assert-Match 'scanned=12' ($valid -join "`n") 'valid trigger scan count'
        Assert-Match 'invalid=0' ($valid -join "`n") 'valid trigger invalid count'

        $invalidRoot = Join-Path $script:TestRoot 'v1-invalid-relations'
        Write-TestV1Record -Root $invalidRoot -SessionId 'dirty-wrong-trigger' -Status DIRTY -TaskId '44444444-4444-4444-8444-444444444444' -PointerText 'dirty relation'
        [void](Update-TestV1Payload -Root $invalidRoot -SessionId 'dirty-wrong-trigger' -Mutation { param($payload) $payload['trigger'] = 'CREATE' })
        Write-TestV1Record -Root $invalidRoot -SessionId 'retired-dirty-fields' -Status RETIRED -TaskId '55555555-5555-4555-8555-555555555555' -PointerText "retired`n下一步：NONE"
        [void](Update-TestV1Payload -Root $invalidRoot -SessionId 'retired-dirty-fields' -Mutation {
            param($payload)
            $payload['dirty_prompt_count'] = 1
            $payload['dirty_from_turn_id'] = 'turn-dirty'
            $payload['dirty_through_turn_id'] = 'turn-dirty'
        })
        Write-TestV1Record -Root $invalidRoot -SessionId 'retired-next-step' -Status RETIRED -TaskId '66666666-6666-4666-8666-666666666666' -PointerText "retired`n下一步：NONE"
        [void](Update-TestV1Payload -Root $invalidRoot -SessionId 'retired-next-step' -Mutation {
            param($payload)
            $pointer = 'retired without terminal next step'
            $bytes = $script:Utf8.GetBytes($pointer)
            $payload['pointer_text'] = $pointer
            $payload['pointer_text_utf8_bytes'] = $bytes.Length
            $payload['pointer_sha256'] = Get-TestSha256Lower $bytes
        })
        $invalid = @(& pwsh -NoProfile -File $script:Migration -V1Root $invalidRoot -V2Root (Join-Path $script:TestRoot 'v2-invalid-relations') 2>&1)
        Assert-Equal 2 $LASTEXITCODE ('invalid relation matrix :: ' + ($invalid -join "`n"))
        Assert-Match 'invalid=3' ($invalid -join "`n") 'invalid relation count'
    }

    Invoke-Case 'v1 JCS known vector、DateKind String 与非 canonical 输入可证伪' {
        $knownRoot = Join-Path $script:TestRoot 'v1-jcs-known'
        $session = 'jcs-known-session'
        Write-TestV1Record -Root $knownRoot -SessionId $session -Status CLEAN -TaskId '11111111-1111-4111-8111-111111111111' -PointerText 'JCS known pointer'
        $knownFile = Join-Path (Join-Path $knownRoot (Get-TPV2SessionKey $session)) 'active.json'
        $knownText = [IO.File]::ReadAllText($knownFile, $script:Utf8)
        Assert-Match '"payload_sha256":"0608ba5dbc3fc1071b2e919901d589f12df94dde25176e404b806807fd024ba2"' $knownText 'known vector hash'
        $knownParsed = $knownText | ConvertFrom-Json -AsHashtable -Depth 50 -DateKind String
        Assert-True ($knownParsed.payload.updated_at -is [string]) 'DateKind changed updated_at type'
        $knownRun = @(& pwsh -NoProfile -File $script:Migration -V1Root $knownRoot -V2Root (Join-Path $script:TestRoot 'v2-jcs-known') 2>&1)
        Assert-Equal 0 $LASTEXITCODE ('known vector migration :: ' + ($knownRun -join "`n"))

        $noncanonicalRoot = Join-Path $script:TestRoot 'v1-jcs-noncanonical'
        Write-TestV1Record -Root $noncanonicalRoot -SessionId 'jcs-noncanonical-session' -Status CLEAN -TaskId '22222222-2222-4222-8222-222222222222' -PointerText 'noncanonical pointer'
        $noncanonicalFile = Join-Path (Join-Path $noncanonicalRoot (Get-TPV2SessionKey 'jcs-noncanonical-session')) 'active.json'
        $noncanonical = [IO.File]::ReadAllText($noncanonicalFile, $script:Utf8)
        $noncanonical = $noncanonical.Replace('{"payload":{"dirty_from_turn_id":null,"dirty_prompt_count":0', '{"payload":{"dirty_prompt_count":0,"dirty_from_turn_id":null')
        [IO.File]::WriteAllText($noncanonicalFile, $noncanonical, $script:Utf8)
        $rejected = @(& pwsh -NoProfile -File $script:Migration -V1Root $noncanonicalRoot -V2Root (Join-Path $script:TestRoot 'v2-jcs-noncanonical') 2>&1)
        Assert-Equal 2 $LASTEXITCODE ('noncanonical migration :: ' + ($rejected -join "`n"))
        Assert-Match 'invalid=1' ($rejected -join "`n") 'noncanonical invalid count'
    }

    Invoke-Case '活动 v2 实现退出 Win32 journal、双文件与多层 hash' {
        $activeText = (Get-Content -LiteralPath $script:Store -Raw) + (Get-Content -LiteralPath $script:Publisher -Raw) + (Get-Content -LiteralPath $script:Lifecycle -Raw)
        foreach ($legacy in @('Add-Type', 'ReplaceFileW', 'MoveFileExW', 'pending.json', 'payload_sha256', 'pointer_sha256', 'source_active_file_sha256', 'compact.json', 'TOMBSTONE', 'RETIRED')) {
            Assert-True ($activeText -cnotmatch [regex]::Escape($legacy)) "legacy symbol remains: $legacy"
        }
    }

    Invoke-Case 'absent session 生成带 generation 的有界 bootstrap' {
        . $script:Store
        $context = Get-TPV2BootstrapContext -StateRoot $script:StateRoot -SessionId 'session-bootstrap-red' -Source startup
        Assert-Match 'TASK_POINTER_V2_BOOTSTRAP' $context 'bootstrap marker'
        Assert-Match 'GENERATION=ABSENT' $context 'absent generation'
        Assert-Match 'REVISION=0' $context 'absent revision'
        Assert-Match 'PUBLISH_CURRENT_POINTER_PATH=' $context 'publisher path'
    }

    Invoke-Case 'publisher 只从 stdin 接收 generation CAS request' {
        $session = 'session-stdin-red'
        $request = [ordered]@{
            schema_version = 3
            session_id = $session
            expected_generation = 'ABSENT'
            expected_revision = 0
            task_id = '11111111-1111-4111-8111-111111111111'
            target_status = 'CLEAN'
            pointer_text = '中文 stdin pointer'
        } | ConvertTo-Json -Compress
        $lines = @($request | & pwsh -NonInteractive -NoProfile -File $script:Publisher -SessionId $session -StateRoot $script:StateRoot 2>&1)
        Assert-Equal 0 $LASTEXITCODE ('stdin publisher :: ' + ($lines -join "`n"))
        $receipt = ($lines -join "`n") | ConvertFrom-Json -AsHashtable
        Assert-True ([bool]$receipt.ok) 'stdin receipt'
        Assert-Match '^g-[0-9a-f]{32}$' ([string]$receipt.generation) 'new generation'
        $state = Read-State -SessionId $session
        Assert-Equal 3 ([int]$state.schema_version) 'schema v3'
        Assert-Equal '中文 stdin pointer' ([string]$state.pointer_text) 'utf8 roundtrip'
    }

    Invoke-Case '损坏 state clear 重建 generation 且不复用旧 revision' {
        $session = 'session-corrupt-clear-red'
        $statePath = Get-StatePath $session
        [System.IO.Directory]::CreateDirectory((Split-Path -Parent $statePath)) | Out-Null
        [System.IO.File]::WriteAllText($statePath, '{broken', $script:Utf8)
        $clear = Invoke-Lifecycle -Event (New-Event -Name SessionStart -SessionId $session -Variant clear)
        Assert-Equal 0 $clear.ExitCode ('corrupt clear :: ' + $clear.Text)
        $state = Read-State $session
        Assert-Equal 3 ([int]$state.schema_version) 'recovered schema'
        Assert-Equal 'CLEARED' ([string]$state.status) 'recovered status'
        Assert-Match '^g-[0-9a-f]{32}$' ([string]$state.generation) 'recovered generation'
        Assert-Match 'TASK_POINTER_V2_BOOTSTRAP' $clear.Text 'clear bootstrap'
    }

    Invoke-Case 'session directory junction 不能把 state 写到 root 外' {
        $root = Join-Path $script:TestRoot 'junction-root-red'
        $outside = Join-Path $script:TestRoot 'junction-outside-red'
        [System.IO.Directory]::CreateDirectory($root) | Out-Null
        [System.IO.Directory]::CreateDirectory($outside) | Out-Null
        $junction = Join-Path $root 'junction-session'
        New-Item -ItemType Junction -Path $junction -Target $outside | Out-Null
        $rejected = $false
        try { [void](Publish-Clean -SessionId 'junction-session' -ExpectedRevision 0 -StateRoot $root) }
        catch { $rejected = (Get-TPV2ErrorCode $_) -ceq 'PATH_REPARSE_POINT' }
        Assert-True $rejected 'junction publisher must fail with PATH_REPARSE_POINT'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $outside 'state.json'))) 'outside state created'
    }

    Invoke-Case 'state.json 叶子 Junction 在原子替换前被拒绝' {
        $root = Join-Path $script:TestRoot 'state-leaf-link-root'
        $session = 'state-leaf-link-session'
        $statePath = Get-StatePath -SessionId $session -StateRoot $root
        [IO.Directory]::CreateDirectory((Split-Path -Parent $statePath)) | Out-Null
        $outsidePath = Join-Path $script:TestRoot 'state-leaf-link-target'
        [IO.Directory]::CreateDirectory($outsidePath) | Out-Null
        $markerPath = Join-Path $outsidePath 'marker.txt'
        [IO.File]::WriteAllText($markerPath, 'outside-bytes', $script:Utf8)
        New-Item -ItemType Junction -Path $statePath -Target $outsidePath | Out-Null
        $next = New-TPV2State -SessionId $session -Generation (New-TPV2Generation) -Revision 1 -Status CLEAN -TaskId '11111111-1111-4111-8111-111111111111' -PointerText 'must not replace link'
        $rejected = $false
        try { [void](Write-TPV2StateFile -StateRoot $root -SessionId $session -State $next) }
        catch { $rejected = (Get-TPV2ErrorCode $_) -cin @('PATH_REPARSE_POINT','STATE_REPARSE_POINT') }
        Assert-True $rejected 'state leaf Junction was not rejected as a reparse point'
        Assert-Equal 'outside-bytes' ([IO.File]::ReadAllText($markerPath, $script:Utf8)) 'state leaf Junction changed external target'
    }

    Invoke-Case 'v1 dry-run 拒绝 payload hash 损坏' {
        $v1 = Join-Path $script:TestRoot 'v1-invalid-hash-red'
        $v2 = Join-Path $script:TestRoot 'v2-invalid-hash-red'
        $dir = Join-Path $v1 'legacy-invalid'
        [System.IO.Directory]::CreateDirectory($dir) | Out-Null
        $payload = [ordered]@{
            record_type = 'active_snapshot'
            session_id = 'invalid-hash-session'
            status = 'CLEAN'
            task_id = '11111111-1111-4111-8111-111111111111'
            pointer_text = 'invalid hash pointer'
        }
        $document = [ordered]@{ payload = $payload; payload_sha256 = ('0' * 64) } | ConvertTo-Json -Compress -Depth 10
        [System.IO.File]::WriteAllText((Join-Path $dir 'active.json'), $document + "`n", $script:Utf8)
        $lines = @(& pwsh -NoProfile -File $script:Migration -V1Root $v1 -V2Root $v2 2>&1)
        Assert-Equal 2 $LASTEXITCODE ('invalid hash dry-run :: ' + ($lines -join "`n"))
        Assert-Match 'invalid=1' ($lines -join "`n") 'invalid hash count'
    }

    Invoke-Case 'UserPromptSubmit 为 missed-start absent session 提供 bootstrap fallback' {
        $session = 'session-prompt-bootstrap'
        $result = Invoke-Lifecycle -Event (New-Event -Name UserPromptSubmit -SessionId $session)
        Assert-Equal 0 $result.ExitCode ('prompt bootstrap :: ' + $result.Text)
        Assert-Match 'TASK_POINTER_V2_BOOTSTRAP' $result.Text 'prompt bootstrap marker'
        $state = Read-State $session
        Assert-Equal 'CLEARED' ([string]$state.status) 'prompt fence status'
        Assert-Match ([regex]::Escape('GENERATION=' + [string]$state.generation)) $result.Text 'bootstrap uses fenced generation'
    }

    Invoke-Case 'lifecycle 对真实重定向 stdin 使用严格 UTF-8' {
        $session = 'session-lifecycle-utf8'
        $event = New-Event -Name UserPromptSubmit -SessionId $session
        $event.prompt = '中文提示：恢复任务指针并继续。'
        $input = Join-Path $script:TestRoot 'lifecycle-utf8-input.json'
        $out = Join-Path $script:TestRoot 'lifecycle-utf8.out'
        $err = Join-Path $script:TestRoot 'lifecycle-utf8.err'
        [IO.File]::WriteAllText($input, ($event | ConvertTo-Json -Compress -Depth 20), $script:Utf8)
        $process = Start-Process -FilePath 'pwsh' -ArgumentList @('-NonInteractive','-NoProfile','-File',$script:Lifecycle,'-StateRoot',$script:StateRoot) -RedirectStandardInput $input -RedirectStandardOutput $out -RedirectStandardError $err -WindowStyle Hidden -PassThru
        $process.WaitForExit()
        Assert-Equal 0 $process.ExitCode ('UTF-8 lifecycle exit :: ' + [IO.File]::ReadAllText($out) + [IO.File]::ReadAllText($err))
        Assert-Equal 'CLEARED' ([string](Read-State $session).status) 'UTF-8 lifecycle state'
    }

    Invoke-Case 'absent 与 CLEARED prompt fence 使旧首发 request 稳定失效' {
        $session = 'session-prompt-publish-race'
        $oldAbsent = New-RequestJson -SessionId $session -ExpectedGeneration ABSENT -ExpectedRevision 0 -TaskId '11111111-1111-4111-8111-111111111111' -Status CLEAN -PointerText 'old absent request'
        Assert-Equal 0 (Invoke-Lifecycle -Event (New-Event -Name UserPromptSubmit -SessionId $session)).ExitCode 'absent prompt fence'
        $replayAbsent = Invoke-Publisher -SessionId $session -RequestJson $oldAbsent
        Assert-Equal 2 $replayAbsent.ExitCode 'absent old request exit'
        Assert-Match 'STALE_GENERATION' $replayAbsent.Text 'absent old request code'
        $firstFence = Read-State $session
        $oldCleared = New-RequestJson -SessionId $session -ExpectedGeneration ([string]$firstFence.generation) -ExpectedRevision ([int64]$firstFence.revision) -TaskId '22222222-2222-4222-8222-222222222222' -Status CLEAN -PointerText 'old cleared request'
        Assert-Equal 0 (Invoke-Lifecycle -Event (New-Event -Name UserPromptSubmit -SessionId $session)).ExitCode 'cleared prompt fence'
        $replayCleared = Invoke-Publisher -SessionId $session -RequestJson $oldCleared
        Assert-Equal 2 $replayCleared.ExitCode 'cleared old request exit'
        Assert-Match 'STALE_GENERATION' $replayCleared.Text 'cleared old request code'
        Assert-Equal 'CLEARED' ([string](Read-State $session).status) 'old prompt request revived pointer'
    }

    Invoke-Case 'corrupt clear 后旧 generation request 不能 ABA 复活' {
        $session = 'session-generation-aba'
        Assert-Equal 0 (Publish-Clean -SessionId $session -ExpectedRevision 0).ExitCode 'initial publish'
        $before = Read-State $session
        $old = New-RequestJson -SessionId $session -ExpectedGeneration ([string]$before.generation) -ExpectedRevision 1 -TaskId '22222222-2222-4222-8222-222222222222' -Status CLEAN -PointerText 'must not revive'
        [IO.File]::WriteAllText((Get-StatePath $session), '{broken', $script:Utf8)
        Assert-Equal 0 (Invoke-Lifecycle -Event (New-Event -Name SessionStart -SessionId $session -Variant clear)).ExitCode 'corrupt clear'
        $replay = Invoke-Publisher -SessionId $session -RequestJson $old
        Assert-Equal 2 $replay.ExitCode 'old generation replay exit'
        Assert-Match 'STALE_GENERATION' $replay.Text 'old generation replay code'
        Assert-Equal 'CLEARED' ([string](Read-State $session).status) 'old request revived state'
    }

    Invoke-Case 'clear 与 compact 恢复失败停止 continuation' {
        $session = 'session-source-fail-closed'
        Assert-Equal 0 (Publish-Clean -SessionId $session -ExpectedRevision 0).ExitCode 'initial publish'
        $path = Get-StatePath $session
        $lock = [IO.FileStream]::new($path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try { $clear = Invoke-Lifecycle -Event (New-Event -Name SessionStart -SessionId $session -Variant clear) }
        finally { $lock.Dispose() }
        Assert-Equal 0 $clear.ExitCode ('locked clear :: ' + $clear.Text)
        Assert-Match '"continue":false' $clear.Text 'locked clear fail-open'
        $compactLock = [IO.FileStream]::new($path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try { $lockedCompact = Invoke-Lifecycle -Event (New-Event -Name SessionStart -SessionId $session -Variant compact) }
        finally { $compactLock.Dispose() }
        Assert-Equal 0 $lockedCompact.ExitCode ('locked compact :: ' + $lockedCompact.Text)
        Assert-Match '"continue":false' $lockedCompact.Text 'locked compact fail-open'
        [IO.File]::WriteAllText($path, '{broken', $script:Utf8)
        $compact = Invoke-Lifecycle -Event (New-Event -Name SessionStart -SessionId $session -Variant compact)
        Assert-Equal 0 $compact.ExitCode ('corrupt compact :: ' + $compact.Text)
        Assert-Match '"continue":false' $compact.Text 'corrupt compact fail-open'
    }

    Invoke-Case 'publisher 拒绝重复字段与超限 stdin' {
        $session = 'session-input-boundary'
        $duplicate = '{"schema_version":3,"schema_version":3,"session_id":"' + $session + '","expected_generation":"ABSENT","expected_revision":0,"task_id":"11111111-1111-4111-8111-111111111111","target_status":"CLEAN","pointer_text":"x"}'
        $dup = Invoke-Publisher -SessionId $session -RequestJson $duplicate
        Assert-Equal 2 $dup.ExitCode 'duplicate input exit'
        Assert-Match 'INPUT_DUPLICATE_FIELD' $dup.Text 'duplicate input code'
        $oversize = New-RequestJson -SessionId $session -ExpectedGeneration ABSENT -ExpectedRevision 0 -TaskId '11111111-1111-4111-8111-111111111111' -Status CLEAN -PointerText ('x' * 13000)
        $large = Invoke-Publisher -SessionId $session -RequestJson $oversize
        Assert-Equal 2 $large.ExitCode 'oversize input exit'
        Assert-Match 'INPUT_TOO_LARGE' $large.Text 'oversize input code'
        $numeric = '{"schema_version":3,"session_id":123,"expected_generation":"ABSENT","expected_revision":0,"task_id":"11111111-1111-4111-8111-111111111111","target_status":"CLEAN","pointer_text":"x"}'
        $numericResult = Invoke-Publisher -SessionId '123' -RequestJson $numeric
        Assert-Equal 2 $numericResult.ExitCode 'numeric session input exit'
        Assert-Match 'INPUT_SESSION_INVALID' $numericResult.Text 'numeric session input code'
    }

    Invoke-Case '双进程同 generation/revision 恰一成功' {
        $session = 'session-concurrent-cas'
        $request = New-RequestJson -SessionId $session -ExpectedGeneration ABSENT -ExpectedRevision 0 -TaskId '11111111-1111-4111-8111-111111111111' -Status CLEAN -PointerText 'concurrent'
        $input = Join-Path $script:TestRoot 'concurrent-request.json'
        [IO.File]::WriteAllText($input, $request, $script:Utf8)
        $processes = @()
        foreach ($index in 1..2) {
            $out = Join-Path $script:TestRoot "concurrent-$index.out"
            $err = Join-Path $script:TestRoot "concurrent-$index.err"
            $args = @('-NonInteractive','-NoProfile','-File',$script:Publisher,'-SessionId',$session,'-StateRoot',$script:StateRoot)
            $processes += Start-Process -FilePath 'pwsh' -ArgumentList $args -RedirectStandardInput $input -RedirectStandardOutput $out -RedirectStandardError $err -WindowStyle Hidden -PassThru
        }
        $processes | ForEach-Object { $_.WaitForExit() }
        $codes = @($processes | ForEach-Object { $_.ExitCode } | Sort-Object)
        Assert-Equal '0,2' ($codes -join ',') 'concurrent exit codes'
        $state = Read-State $session
        Assert-Equal 1 ([int64]$state.revision) 'concurrent final revision'
        Assert-Equal 'CLEAN' ([string]$state.status) 'concurrent final status'
    }

    Invoke-Case 'prompt 与 publisher 双进程按两种锁序串行化' {
        $wrapper = Join-Path $script:TestRoot 'ordered-mutex-runner.ps1'
        $wrapperBody = @'
param(
    [string]$MutexName,
    [string]$ReadyPath,
    [string]$GoPath,
    [string]$TargetScript,
    [ValidateSet('publisher','lifecycle')][string]$TargetKind,
    [string]$SessionId,
    [string]$StateRoot
)
$mutex = [Threading.Mutex]::new($false, $MutexName)
[void]$mutex.WaitOne()
[IO.File]::WriteAllText($ReadyPath, 'ready')
$timer = [Diagnostics.Stopwatch]::StartNew()
while (-not [IO.File]::Exists($GoPath)) {
    if ($timer.ElapsedMilliseconds -ge 5000) { exit 9 }
    Start-Sleep -Milliseconds 10
}
if ($TargetKind -ceq 'publisher') { & $TargetScript -SessionId $SessionId -StateRoot $StateRoot }
else { & $TargetScript -StateRoot $StateRoot }
'@
        [IO.File]::WriteAllText($wrapper, $wrapperBody, $script:Utf8)

        foreach ($publisherFirst in @($true, $false)) {
            $label = if ($publisherFirst) { 'publisher-first' } else { 'prompt-first' }
            $session = "session-prompt-publisher-$label"
            $mutexName = 'Local\CodexTaskPointerV2-' + (Get-TPV2SessionKey $session)
            $requestPath = Join-Path $script:TestRoot "$label-request.json"
            $eventPath = Join-Path $script:TestRoot "$label-event.json"
            [IO.File]::WriteAllText($requestPath, (New-RequestJson -SessionId $session -ExpectedGeneration ABSENT -ExpectedRevision 0 -TaskId '11111111-1111-4111-8111-111111111111' -Status CLEAN -PointerText $label), $script:Utf8)
            [IO.File]::WriteAllText($eventPath, ((New-Event -Name UserPromptSubmit -SessionId $session) | ConvertTo-Json -Compress -Depth 20), $script:Utf8)
            $firstInput = if ($publisherFirst) { $requestPath } else { $eventPath }
            $secondInput = if ($publisherFirst) { $eventPath } else { $requestPath }
            $firstScript = if ($publisherFirst) { $script:Publisher } else { $script:Lifecycle }
            $secondScript = if ($publisherFirst) { $script:Lifecycle } else { $script:Publisher }
            $ready = Join-Path $script:TestRoot "$label-ready"
            $go = Join-Path $script:TestRoot "$label-go"
            $firstOut = Join-Path $script:TestRoot "$label-first.out"
            $firstErr = Join-Path $script:TestRoot "$label-first.err"
            $secondOut = Join-Path $script:TestRoot "$label-second.out"
            $secondErr = Join-Path $script:TestRoot "$label-second.err"
            $firstKind = if ($publisherFirst) { 'publisher' } else { 'lifecycle' }
            $secondKind = if ($publisherFirst) { 'lifecycle' } else { 'publisher' }
            $firstArgs = @('-NonInteractive','-NoProfile','-File',$wrapper,'-MutexName',$mutexName,'-ReadyPath',$ready,'-GoPath',$go,'-TargetScript',$firstScript,'-TargetKind',$firstKind,'-SessionId',$session,'-StateRoot',$script:StateRoot)
            $first = Start-Process -FilePath 'pwsh' -ArgumentList $firstArgs -RedirectStandardInput $firstInput -RedirectStandardOutput $firstOut -RedirectStandardError $firstErr -WindowStyle Hidden -PassThru
            Wait-TestPath -Path $ready
            $secondArgs = @('-NonInteractive','-NoProfile','-File',$secondScript)
            if ($secondKind -ceq 'publisher') { $secondArgs += @('-SessionId',$session) }
            $secondArgs += @('-StateRoot',$script:StateRoot)
            $second = Start-Process -FilePath 'pwsh' -ArgumentList $secondArgs -RedirectStandardInput $secondInput -RedirectStandardOutput $secondOut -RedirectStandardError $secondErr -WindowStyle Hidden -PassThru
            [IO.File]::WriteAllText($go, 'go', $script:Utf8)
            $first.WaitForExit()
            $second.WaitForExit()
            Assert-Equal 0 $first.ExitCode "$label first exit"
            $state = Read-State $session
            if ($publisherFirst) {
                Assert-Equal 0 $second.ExitCode 'publisher-first prompt exit'
                Assert-Equal 'DIRTY' ([string]$state.status) 'publisher-first status'
                Assert-Equal 2 ([int64]$state.revision) 'publisher-first revision'
            }
            else {
                Assert-Equal 2 $second.ExitCode 'prompt-first publisher exit'
                Assert-Match 'STALE_GENERATION' ([IO.File]::ReadAllText($secondOut)) 'prompt-first stale code'
                Assert-Equal 'CLEARED' ([string]$state.status) 'prompt-first status'
                Assert-Equal 1 ([int64]$state.revision) 'prompt-first revision'
            }
        }
    }

    Invoke-Case '独占锁写失败保持 state 且无 temp residue' {
        $session = 'session-real-lock'
        Assert-Equal 0 (Publish-Clean -SessionId $session -ExpectedRevision 0).ExitCode 'initial publish'
        $path = Get-StatePath $session
        $before = [IO.File]::ReadAllBytes($path)
        $lock = [IO.FileStream]::new($path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try { $result = Invoke-Lifecycle -Event (New-Event -Name UserPromptSubmit -SessionId $session) }
        finally { $lock.Dispose() }
        Assert-Equal 2 $result.ExitCode 'locked prompt exit'
        Assert-Match 'TASK_POINTER_DIRTY_WRITE_FAILED' $result.Text 'locked prompt block'
        Assert-Equal ([Convert]::ToBase64String($before)) ([Convert]::ToBase64String([IO.File]::ReadAllBytes($path))) 'locked state changed'
        Assert-Equal 0 @(Get-ChildItem -LiteralPath (Split-Path -Parent $path) -File -Filter '.state-*.tmp').Count 'temp residue'
    }

    Invoke-Case 'abandoned mutex 后下一 writer 可恢复' {
        $session = 'session-abandoned-mutex'
        Assert-Equal 0 (Publish-Clean -SessionId $session -ExpectedRevision 0).ExitCode 'initial publish'
        $mutexName = 'Local\CodexTaskPointerV2-' + (Get-TPV2SessionKey $session)
        $helper = Join-Path $script:TestRoot 'abandon-mutex.ps1'
        $helperBody = @'
param([string]$Name)
$mutex = [Threading.Mutex]::new($false, $Name)
[void]$mutex.WaitOne()
[Environment]::Exit(0)
'@
        [IO.File]::WriteAllText($helper, $helperBody, $script:Utf8)
        $process = Start-Process -FilePath 'pwsh' -ArgumentList @('-NonInteractive','-NoProfile','-File',$helper,'-Name',$mutexName) -WindowStyle Hidden -PassThru
        $process.WaitForExit()
        Assert-Equal 0 $process.ExitCode 'abandon helper exit'
        $result = Invoke-Lifecycle -Event (New-Event -Name UserPromptSubmit -SessionId $session)
        Assert-Equal 0 $result.ExitCode ('abandoned mutex recovery :: ' + $result.Text)
        Assert-Equal 'DIRTY' ([string](Read-State $session).status) 'abandoned mutex dirty status'
    }

    Invoke-Case 'v1 migration 拒绝 duplicate property 与 existing conflict' {
        $v1 = Join-Path $script:TestRoot 'v1-strict-negative'
        $v2 = Join-Path $script:TestRoot 'v2-strict-negative'
        $session = 'migration-conflict-session'
        Write-TestV1Record -Root $v1 -SessionId $session -Status CLEAN -TaskId '11111111-1111-4111-8111-111111111111' -PointerText 'source pointer'
        $conflict = Publish-Clean -SessionId $session -ExpectedRevision 0 -PointerText 'different pointer' -StateRoot $v2
        Assert-Equal 0 $conflict.ExitCode 'conflict seed'
        $lines = @(& pwsh -NonInteractive -NoProfile -File $script:Migration -V1Root $v1 -V2Root $v2 2>&1)
        Assert-Equal 2 $LASTEXITCODE ('existing conflict :: ' + ($lines -join "`n"))
        Assert-Match 'invalid=1' ($lines -join "`n") 'existing conflict count'

        $dupRoot = Join-Path $script:TestRoot 'v1-duplicate-property'
        Write-TestV1Record -Root $dupRoot -SessionId 'duplicate-property-session' -Status CLEAN -TaskId '22222222-2222-4222-8222-222222222222' -PointerText 'duplicate property'
        $file = Get-ChildItem -LiteralPath $dupRoot -Recurse -File -Filter active.json | Select-Object -First 1
        $raw = [IO.File]::ReadAllText($file.FullName, $script:Utf8).TrimEnd("`n")
        $match = [regex]::Match($raw, '^\{"payload":(?<payload>\{.*\}),"payload_sha256":"[0-9a-f]{64}"\}$')
        $payloadJson = $match.Groups['payload'].Value.TrimEnd('}') + ',"status":"CLEAN"}'
        $hash = Get-TestSha256Lower $script:Utf8.GetBytes($payloadJson)
        [IO.File]::WriteAllText($file.FullName, ('{"payload":' + $payloadJson + ',"payload_sha256":"' + $hash + '"}' + "`n"), $script:Utf8)
        $dup = @(& pwsh -NonInteractive -NoProfile -File $script:Migration -V1Root $dupRoot -V2Root (Join-Path $script:TestRoot 'v2-duplicate-property') 2>&1)
        Assert-Equal 2 $LASTEXITCODE ('duplicate property :: ' + ($dup -join "`n"))
        Assert-Match 'invalid=1' ($dup -join "`n") 'duplicate property count'
    }

    Invoke-Case 'legacy schema v2 原位升级且 Windows raw alias 不覆盖原 session' {
        $root = Join-Path $script:TestRoot 'legacy-v2-root'
        $session = 'LegacyCase'
        $rawDir = Join-Path $root $session
        [IO.Directory]::CreateDirectory($rawDir) | Out-Null
        $legacy = [ordered]@{schema_version=2;session_id=$session;revision=1;status='CLEAN';task_id='11111111-1111-4111-8111-111111111111';pointer_text='legacy pointer';updated_at='2026-08-23T00:00:00Z'}
        $rawPath = Join-Path $rawDir 'state.json'
        [IO.File]::WriteAllText($rawPath, (($legacy|ConvertTo-Json -Compress)+"`n"), $script:Utf8)
        $context = Get-TPV2Context -StateRoot $root -SessionId $session -Source resume
        Assert-Match 'GENERATION=LEGACY_V2' $context 'legacy generation'
        $upgrade = Invoke-Lifecycle -Event (New-Event -Name UserPromptSubmit -SessionId $session) -StateRoot $root
        Assert-Equal 0 $upgrade.ExitCode ('legacy upgrade :: ' + $upgrade.Text)
        Assert-Equal 3 ([int](Read-State -SessionId $session -StateRoot $root).schema_version) 'legacy upgraded schema'
        $beforeAlias = [IO.File]::ReadAllBytes($rawPath)

        $alias = 'LegacyCase.'
        $clearAlias = Invoke-Lifecycle -Event (New-Event -Name SessionStart -SessionId $alias -Variant clear) -StateRoot $root
        Assert-Equal 0 $clearAlias.ExitCode ('alias clear :: ' + $clearAlias.Text)
        Assert-Equal ([Convert]::ToBase64String($beforeAlias)) ([Convert]::ToBase64String([IO.File]::ReadAllBytes($rawPath))) 'alias changed legacy bytes'
        Assert-True ((Get-StatePath -SessionId $alias -StateRoot $root) -cne $rawPath) 'alias selected raw path'
        Assert-Equal 'CLEARED' ([string](Read-State -SessionId $alias -StateRoot $root).status) 'alias state status'
        Assert-Match '^s-' (Split-Path -Leaf (Split-Path -Parent (Get-StatePath -SessionId CON -StateRoot $root))) 'reserved name not encoded'
    }

    Invoke-Case 'StateRoot junction 与 malformed/invalid UTF-8 stdin 均拒绝' {
        $target = Join-Path $script:TestRoot 'state-root-target'
        $junction = Join-Path $script:TestRoot 'state-root-junction'
        [IO.Directory]::CreateDirectory($target) | Out-Null
        New-Item -ItemType Junction -Path $junction -Target $target | Out-Null
        $reparseRejected = $false
        try { [void](Get-TPV2BootstrapContext -StateRoot $junction -SessionId 'root-junction-session' -Source startup) }
        catch { $reparseRejected = (Get-TPV2ErrorCode $_) -ceq 'PATH_REPARSE_POINT' }
        Assert-True $reparseRejected 'StateRoot junction accepted'
        [IO.Directory]::Delete($junction, $false)

        $malformed = Invoke-Publisher -SessionId 'malformed-session' -RequestJson '{broken'
        Assert-Equal 2 $malformed.ExitCode 'malformed input exit'
        Assert-Match 'INPUT_PARSE_FAILED' $malformed.Text 'malformed input code'
        $input = Join-Path $script:TestRoot 'invalid-utf8.bin'; [IO.File]::WriteAllBytes($input, [byte[]]@(0xFF,0xFE,0xFD))
        $out = Join-Path $script:TestRoot 'invalid-utf8.out'; $err = Join-Path $script:TestRoot 'invalid-utf8.err'
        $process = Start-Process -FilePath 'pwsh' -ArgumentList @('-NonInteractive','-NoProfile','-File',$script:Publisher,'-SessionId','invalid-utf8-session','-StateRoot',$script:StateRoot) -RedirectStandardInput $input -RedirectStandardOutput $out -RedirectStandardError $err -WindowStyle Hidden -PassThru
        $process.WaitForExit()
        Assert-Equal 2 $process.ExitCode 'invalid utf8 exit'
        Assert-Match 'INPUT_UTF8_INVALID' ([IO.File]::ReadAllText($out)) 'invalid utf8 code'
    }

    Invoke-Case 'v1 migration 拒绝非直属 session 目录' {
        $v1 = Join-Path $script:TestRoot 'v1-nested-session'
        Write-TestV1Record -Root $v1 -SessionId 'nested-session' -Status CLEAN -TaskId '11111111-1111-4111-8111-111111111111' -PointerText 'nested'
        $sessionDir = Get-ChildItem -LiteralPath $v1 -Directory | Select-Object -First 1
        $junk = Join-Path $v1 'junk'; [IO.Directory]::CreateDirectory($junk) | Out-Null
        [IO.Directory]::Move($sessionDir.FullName, (Join-Path $junk $sessionDir.Name))
        $lines = @(& pwsh -NonInteractive -NoProfile -File $script:Migration -V1Root $v1 -V2Root (Join-Path $script:TestRoot 'v2-nested-session') 2>&1)
        Assert-Equal 2 $LASTEXITCODE ('nested session :: ' + ($lines -join "`n"))
        Assert-Match 'invalid=1' ($lines -join "`n") 'nested session count'
    }

    Invoke-Case 'state duplicate property 与非 string session_id 均进入安全诊断' {
        $session = '123'
        Assert-Equal 0 (Publish-Clean -SessionId $session -ExpectedRevision 0).ExitCode 'initial state'
        $path = Get-StatePath $session
        $raw = [IO.File]::ReadAllText($path, $script:Utf8)
        [IO.File]::WriteAllText($path, $raw.Replace('"status":"CLEAN"', '"status":"CLEAN","status":"DIRTY"'), $script:Utf8)
        $duplicate = Invoke-Lifecycle -Event (New-Event -Name SessionStart -SessionId $session -Variant resume)
        Assert-Equal 0 $duplicate.ExitCode 'duplicate state diagnostic exit'
        Assert-Match 'UNKNOWN_RECOVERY:STATE_DUPLICATE_FIELD' $duplicate.Text 'duplicate state code'
        [IO.File]::WriteAllText($path, $raw.Replace('"session_id":"123"', '"session_id":123'), $script:Utf8)
        $numeric = Invoke-Lifecycle -Event (New-Event -Name SessionStart -SessionId $session -Variant resume)
        Assert-Equal 0 $numeric.ExitCode 'numeric session diagnostic exit'
        Assert-Match 'UNKNOWN_RECOVERY:STATE_SESSION_INVALID' $numeric.Text 'numeric session code'
    }
}
finally {
    $resolved = [System.IO.Path]::GetFullPath($script:TestRoot)
    Assert-True ($resolved.StartsWith($script:TempBase, [System.StringComparison]::OrdinalIgnoreCase)) 'unsafe cleanup root'
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}

Write-Host "SUMMARY passed=$script:Passed failed=$script:Failed skipped=0 blocked=0"
if ($script:Failed -gt 0) { exit 1 }
