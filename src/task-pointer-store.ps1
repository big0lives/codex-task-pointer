#requires -Version 7.5

Set-StrictMode -Version Latest

function Get-TPV2DefaultCodexHome {
    $configured = [Environment]::GetEnvironmentVariable('CODEX_HOME')
    if ([string]::IsNullOrWhiteSpace($configured)) {
        $configured = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex'
    }
    return [System.IO.Path]::GetFullPath($configured)
}

$script:TPV2_DefaultCodexHome = Get-TPV2DefaultCodexHome
$script:TPV2_DefaultStateRoot = Join-Path $script:TPV2_DefaultCodexHome 'state\task-pointers\v2'
$script:TPV2_PublisherPath = Join-Path $PSScriptRoot 'task-pointer-publish.ps1'
$script:TPV2_Utf8 = [System.Text.UTF8Encoding]::new($false, $true)
$script:TPV2_MaxPointerBytes = 8192
$script:TPV2_MaxContextBytes = 10000
$script:TPV2_MaxStateBytes = 32768
$script:TPV2_MutexTimeoutMs = 5000

function Throw-TPV2Error {
    param([Parameter(Mandatory)][ValidatePattern('^[A-Z0-9_]+$')][string]$Code, [string]$Detail = 'UNKNOWN')
    $safe = ($Detail -replace '[\r\n\x00-\x1f]+', ' ').Trim()
    if ($safe.Length -gt 160) { $safe = $safe.Substring(0, 160) }
    throw [System.InvalidOperationException]::new("$Code|$safe")
}

function Get-TPV2ErrorCode {
    param([System.Management.Automation.ErrorRecord]$ErrorRecord)
    $message = [string]$ErrorRecord.Exception.Message
    if ($message -match '^([A-Z0-9_]+)\|') { return $Matches[1] }
    return 'TASK_POINTER_V2_FAILED'
}

function Assert-TPV2NoReparseComponents {
    param([Parameter(Mandatory)][string]$Path, [string[]]$AllowedReparseRoots = @($script:TPV2_DefaultCodexHome))
    $full = [System.IO.Path]::GetFullPath($Path)
    $volume = [System.IO.Path]::GetPathRoot($full)
    $relative = $full.Substring($volume.Length)
    $current = $volume.TrimEnd('\')
    foreach ($segment in $relative.Split('\', [System.StringSplitOptions]::RemoveEmptyEntries)) {
        $current = if ([string]::IsNullOrEmpty($current)) { $segment } else { Join-Path $current $segment }
        if (-not [System.IO.File]::Exists($current) -and -not [System.IO.Directory]::Exists($current)) { continue }
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        $allowed = @($AllowedReparseRoots | ForEach-Object { try { [System.IO.Path]::GetFullPath($_).TrimEnd('\') } catch { $null } })
        $allowedMatch = $false
        foreach ($allowedRoot in $allowed) {
            if ($null -ne $allowedRoot -and $allowedRoot.Equals($current.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) {
                $allowedMatch = $true
                break
            }
        }
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -and -not $allowedMatch) {
            Throw-TPV2Error -Code 'PATH_REPARSE_POINT' -Detail $current
        }
    }
}

function Resolve-TPV2StateRoot {
    param([AllowNull()][string]$StateRoot = $null)
    if ([string]::IsNullOrWhiteSpace($StateRoot)) { $StateRoot = $script:TPV2_DefaultStateRoot }
    try { $resolved = [System.IO.Path]::GetFullPath($StateRoot).TrimEnd('\') }
    catch { Throw-TPV2Error -Code 'STATE_ROOT_INVALID' }
    $default = [System.IO.Path]::GetFullPath($script:TPV2_DefaultStateRoot).TrimEnd('\')
    $codexHomeRoot = [System.IO.Path]::GetFullPath($script:TPV2_DefaultCodexHome).TrimEnd('\')
    $temp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $underHome = ($resolved + '\').StartsWith($codexHomeRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)
    $underTemp = ($resolved + '\').StartsWith($temp, [System.StringComparison]::OrdinalIgnoreCase)
    if (-not $resolved.Equals($default, [System.StringComparison]::OrdinalIgnoreCase) -and -not $underHome -and -not $underTemp) {
        Throw-TPV2Error -Code 'STATE_ROOT_OVERRIDE_FORBIDDEN'
    }
    Assert-TPV2NoReparseComponents -Path $resolved -AllowedReparseRoots @($script:TPV2_DefaultCodexHome)
    return $resolved
}

function Assert-TPV2SessionId {
    param([string]$SessionId)
    if ($SessionId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') { Throw-TPV2Error -Code 'SESSION_ID_INVALID' }
}

function Get-TPV2SessionKey {
    param([string]$SessionId)
    Assert-TPV2SessionId -SessionId $SessionId
    return 's-' + [System.Convert]::ToHexString($script:TPV2_Utf8.GetBytes($SessionId)).ToLowerInvariant()
}

function Get-TPV2StatePath {
    param([string]$StateRoot, [string]$SessionId)
    $root = Resolve-TPV2StateRoot -StateRoot $StateRoot
    $encodedDirectory = Join-Path $root (Get-TPV2SessionKey -SessionId $SessionId)
    $encodedPath = Join-Path $encodedDirectory 'state.json'
    $legacyDirectory = Join-Path $root $SessionId
    $legacyPath = Join-Path $legacyDirectory 'state.json'
    $legacyExact = $false
    if ([IO.Directory]::Exists($legacyDirectory)) {
        $legacyItem = Get-Item -LiteralPath $legacyDirectory -Force
        $legacyExact = [string]$legacyItem.Name -ceq $SessionId
    }
    $encodedExists = [IO.File]::Exists($encodedPath) -or [IO.Directory]::Exists($encodedDirectory)
    $legacyExists = $legacyExact -and ([IO.File]::Exists($legacyPath) -or [IO.Directory]::Exists($legacyDirectory))
    if ($encodedExists -and $legacyExists) { Throw-TPV2Error -Code 'STATE_PATH_CONFLICT' }
    $selected = if ($legacyExists) { $legacyPath } else { $encodedPath }
    $full = [System.IO.Path]::GetFullPath($selected)
    if (-not $full.StartsWith($root + '\', [System.StringComparison]::OrdinalIgnoreCase)) { Throw-TPV2Error -Code 'STATE_PATH_INVALID' }
    Assert-TPV2NoReparseComponents -Path (Split-Path -Parent $full)
    return $full
}

function Enter-TPV2Mutex {
    param([string]$SessionId)
    $mutex = [System.Threading.Mutex]::new($false, ('Local\CodexTaskPointerV2-' + (Get-TPV2SessionKey $SessionId)))
    try {
        try { $acquired = $mutex.WaitOne($script:TPV2_MutexTimeoutMs) }
        catch [System.Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { $mutex.Dispose(); Throw-TPV2Error -Code 'MUTEX_TIMEOUT' }
        return $mutex
    }
    catch { $mutex.Dispose(); throw }
}

function Exit-TPV2Mutex {
    param([System.Threading.Mutex]$Mutex)
    if ($null -eq $Mutex) { return }
    try { $Mutex.ReleaseMutex() } finally { $Mutex.Dispose() }
}

function Test-TPV2UtcTimestamp {
    param([object]$Value)
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $false }
    $parsed = [DateTimeOffset]::MinValue
    return [DateTimeOffset]::TryParseExact([string]$Value, 'yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)
}

function Assert-TPV2PointerFields {
    param([System.Collections.IDictionary]$State)
    if ([string]$State.status -ceq 'CLEARED') {
        if ($null -ne $State.task_id -or $null -ne $State.pointer_text) { Throw-TPV2Error -Code 'STATE_CLEARED_FIELDS_INVALID' }
        return
    }
    if ($State.task_id -isnot [string] -or [string]$State.task_id -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$') { Throw-TPV2Error -Code 'STATE_TASK_ID_INVALID' }
    if ($State.pointer_text -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$State.pointer_text)) { Throw-TPV2Error -Code 'STATE_POINTER_INVALID' }
    $pointer = ([string]$State.pointer_text).Replace("`r`n", "`n").Replace("`r", "`n")
    if ($pointer.Contains([char]0)) { Throw-TPV2Error -Code 'STATE_POINTER_INVALID' }
    $count = $script:TPV2_Utf8.GetByteCount($pointer)
    if ($count -gt $script:TPV2_MaxPointerBytes) { Throw-TPV2Error -Code 'POINTER_TOO_LARGE' -Detail ([string]$count) }
}

function Assert-TPV2State {
    param([System.Collections.IDictionary]$State, [string]$ExpectedSessionId)
    if ($State -isnot [System.Collections.IDictionary]) { Throw-TPV2Error -Code 'STATE_SCHEMA_INVALID' }
    if ($State.schema_version -isnot [int] -and $State.schema_version -isnot [long]) { Throw-TPV2Error -Code 'STATE_SCHEMA_INVALID' }
    $schema = [int]$State.schema_version
    $expected = if ($schema -eq 2) { @('schema_version','session_id','revision','status','task_id','pointer_text','updated_at') } elseif ($schema -eq 3) { @('schema_version','session_id','generation','revision','status','task_id','pointer_text','updated_at') } else { Throw-TPV2Error -Code 'STATE_SCHEMA_INVALID' }
    $actual = @($State.Keys | ForEach-Object { [string]$_ } | Sort-Object)
    if (($actual -join "`0") -cne (($expected | Sort-Object) -join "`0")) { Throw-TPV2Error -Code 'STATE_FIELDS_INVALID' }
    if ($State.session_id -isnot [string] -or [string]$State.session_id -cne $ExpectedSessionId) { Throw-TPV2Error -Code 'STATE_SESSION_INVALID' }
    if ($schema -eq 3 -and ($State.generation -isnot [string] -or [string]$State.generation -notmatch '^g-[0-9a-f]{32}$')) { Throw-TPV2Error -Code 'STATE_GENERATION_INVALID' }
    if ($State.revision -isnot [int] -and $State.revision -isnot [long]) { Throw-TPV2Error -Code 'STATE_REVISION_INVALID' }
    if ([int64]$State.revision -lt 1) { Throw-TPV2Error -Code 'STATE_REVISION_INVALID' }
    if ($State.status -isnot [string] -or [string]$State.status -cnotin @('CLEAN','DIRTY','CLEARED')) { Throw-TPV2Error -Code 'STATE_STATUS_INVALID' }
    if (-not (Test-TPV2UtcTimestamp $State.updated_at)) { Throw-TPV2Error -Code 'STATE_TIME_INVALID' }
    Assert-TPV2PointerFields -State $State
}

function Get-TPV2Generation {
    param([AllowNull()][System.Collections.IDictionary]$State)
    if ($null -eq $State) { return 'ABSENT' }
    if ([int]$State.schema_version -eq 2) { return 'LEGACY_V2' }
    return [string]$State.generation
}

function Read-TPV2StateFile {
    param([string]$Path, [string]$ExpectedSessionId, [switch]$AllowAbsent)
    if (-not [System.IO.File]::Exists($Path)) { if ($AllowAbsent) { return $null }; Throw-TPV2Error -Code 'STATE_MISSING' }
    Assert-TPV2NoReparseComponents -Path $Path
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Throw-TPV2Error -Code 'STATE_REPARSE_POINT' }
    if ($item.Length -gt $script:TPV2_MaxStateBytes) { Throw-TPV2Error -Code 'STATE_TOO_LARGE' }
    try { $text = [System.IO.File]::ReadAllText($Path, $script:TPV2_Utf8) } catch { Throw-TPV2Error -Code 'STATE_READ_FAILED' }
    try {
        $jsonDocument = [System.Text.Json.JsonDocument]::Parse($text)
        try {
            if ($jsonDocument.RootElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) { Throw-TPV2Error -Code 'STATE_SCHEMA_INVALID' }
            $names = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($property in $jsonDocument.RootElement.EnumerateObject()) {
                if (-not $names.Add($property.Name)) { Throw-TPV2Error -Code 'STATE_DUPLICATE_FIELD' -Detail $property.Name }
            }
        }
        finally { $jsonDocument.Dispose() }
    }
    catch [System.InvalidOperationException] { throw }
    catch { Throw-TPV2Error -Code 'STATE_PARSE_FAILED' }
    try { $state = $text | ConvertFrom-Json -AsHashtable -Depth 20 -DateKind String } catch { Throw-TPV2Error -Code 'STATE_PARSE_FAILED' }
    Assert-TPV2State -State $state -ExpectedSessionId $ExpectedSessionId
    return $state
}

function Read-TPV2State {
    param([string]$StateRoot, [string]$SessionId)
    return Read-TPV2StateFile -Path (Get-TPV2StatePath $StateRoot $SessionId) -ExpectedSessionId $SessionId -AllowAbsent
}

function Get-TPV2ComparableState { param([System.Collections.IDictionary]$State); return $State | ConvertTo-Json -Compress -Depth 20 }

function Write-TPV2StateFile {
    param([string]$StateRoot, [string]$SessionId, [System.Collections.IDictionary]$State)
    Assert-TPV2State -State $State -ExpectedSessionId $SessionId
    if ([int]$State.schema_version -ne 3) { Throw-TPV2Error -Code 'STATE_WRITE_SCHEMA_INVALID' }
    $path = Get-TPV2StatePath $StateRoot $SessionId
    $directory = Split-Path -Parent $path
    Assert-TPV2NoReparseComponents -Path (Split-Path -Parent $directory)
    [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    Assert-TPV2NoReparseComponents -Path $directory
    $temp = Join-Path $directory ('.state-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $bytes = $script:TPV2_Utf8.GetBytes((Get-TPV2ComparableState $State) + "`n")
    try {
        $stream = [System.IO.FileStream]::new($temp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough)
        try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        [void](Read-TPV2StateFile -Path $temp -ExpectedSessionId $SessionId)
        Assert-TPV2NoReparseComponents -Path $directory
        if ([Environment]::GetEnvironmentVariable('CODEX_TASK_POINTER_V2_FAULT') -ceq 'BEFORE_REPLACE') { Throw-TPV2Error -Code 'TEST_BEFORE_REPLACE' }
        $existingItem = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        if ($existingItem) {
            if (($existingItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Throw-TPV2Error -Code 'STATE_REPARSE_POINT' }
            if ($existingItem.PSIsContainer) { Throw-TPV2Error -Code 'STATE_PATH_INVALID' }
        }
        if ([IO.File]::Exists($path)) { [IO.File]::Replace($temp,$path,[Management.Automation.Language.NullString]::Value,$true) } else { [IO.File]::Move($temp,$path) }
        Assert-TPV2NoReparseComponents -Path $path
        $stored = Read-TPV2StateFile -Path $path -ExpectedSessionId $SessionId
        if ((Get-TPV2ComparableState $stored) -cne (Get-TPV2ComparableState $State)) { Throw-TPV2Error -Code 'STATE_READBACK_FAILED' }
        return $stored
    }
    finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}

function New-TPV2Generation { return 'g-' + [guid]::NewGuid().ToString('N') }

function New-TPV2State {
    param([string]$SessionId,[string]$Generation,[int64]$Revision,[ValidateSet('CLEAN','DIRTY','CLEARED')][string]$Status,[AllowNull()][object]$TaskId,[AllowNull()][object]$PointerText)
    if ($null -ne $PointerText) { $PointerText = ([string]$PointerText).Replace("`r`n","`n").Replace("`r","`n") }
    return [ordered]@{schema_version=3;session_id=$SessionId;generation=$Generation;revision=$Revision;status=$Status;task_id=$TaskId;pointer_text=$PointerText;updated_at=[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')}
}

function Publish-TPV2State {
    param([string]$StateRoot,[string]$SessionId,[string]$ExpectedGeneration,[int64]$ExpectedRevision,[AllowNull()][object]$TaskId,[ValidateSet('CLEAN','CLEARED')][string]$TargetStatus,[AllowNull()][object]$PointerText)
    $mutex = Enter-TPV2Mutex $SessionId
    try {
        $current = Read-TPV2State $StateRoot $SessionId
        $observedGeneration = Get-TPV2Generation $current
        $observedRevision = if ($null -eq $current) { 0 } else { [int64]$current.revision }
        if ($observedGeneration -cne $ExpectedGeneration) { return [ordered]@{ok=$false;code='STALE_GENERATION';observed_generation=$observedGeneration;observed_revision=$observedRevision} }
        if ($observedRevision -ne $ExpectedRevision) { return [ordered]@{ok=$false;code='STALE_REVISION';observed_generation=$observedGeneration;observed_revision=$observedRevision} }
        if ($TargetStatus -ceq 'CLEARED') { $TaskId=$null; $PointerText=$null }
        $generation = if ($null -eq $current -or [int]$current.schema_version -eq 2 -or $TargetStatus -ceq 'CLEARED') { New-TPV2Generation } else { [string]$current.generation }
        $next = New-TPV2State $SessionId $generation ($observedRevision+1) $TargetStatus $TaskId $PointerText
        [void](Write-TPV2StateFile $StateRoot $SessionId $next)
        return [ordered]@{ok=$true;schema_version=3;session_id=$SessionId;task_id=$TaskId;status=$TargetStatus;generation=$generation;revision=$observedRevision+1}
    } finally { Exit-TPV2Mutex $mutex }
}

function Set-TPV2Dirty {
    param([string]$StateRoot,[string]$SessionId)
    $mutex=Enter-TPV2Mutex $SessionId
    try {
        $current=Read-TPV2State $StateRoot $SessionId
        if ($null -eq $current -or [string]$current.status -ceq 'CLEARED') {
            $revision = if ($null -eq $current) { 1 } else { [int64]$current.revision + 1 }
            $generation = New-TPV2Generation
            $fence = New-TPV2State $SessionId $generation $revision CLEARED $null $null
            [void](Write-TPV2StateFile $StateRoot $SessionId $fence)
            return [ordered]@{ok=$true;changed=$false;fenced=$true;status='CLEARED';generation=$generation;revision=$revision}
        }
        $generation=if([int]$current.schema_version-eq2){New-TPV2Generation}else{[string]$current.generation}
        $next=New-TPV2State $SessionId $generation ([int64]$current.revision+1) DIRTY ([string]$current.task_id) ([string]$current.pointer_text)
        [void](Write-TPV2StateFile $StateRoot $SessionId $next)
        return [ordered]@{ok=$true;changed=$true;status='DIRTY';generation=$generation;revision=[int64]$next.revision}
    } finally { Exit-TPV2Mutex $mutex }
}

function Clear-TPV2State {
    param([string]$StateRoot,[string]$SessionId)
    $mutex=Enter-TPV2Mutex $SessionId
    try {
        $recovered=$false
        try { $current=Read-TPV2State $StateRoot $SessionId } catch {
            $code=Get-TPV2ErrorCode $_
            if($code -cnotin @('STATE_PARSE_FAILED','STATE_DUPLICATE_FIELD','STATE_SCHEMA_INVALID','STATE_FIELDS_INVALID','STATE_GENERATION_INVALID','STATE_REVISION_INVALID','STATE_STATUS_INVALID','STATE_TIME_INVALID','STATE_CLEARED_FIELDS_INVALID','STATE_TASK_ID_INVALID','STATE_POINTER_INVALID','POINTER_TOO_LARGE','STATE_TOO_LARGE')){throw}
            $current=$null; $recovered=$true
        }
        $revision=if($null-eq$current-or$recovered){1}else{[int64]$current.revision+1}
        $generation=New-TPV2Generation
        $next=New-TPV2State $SessionId $generation $revision CLEARED $null $null
        [void](Write-TPV2StateFile $StateRoot $SessionId $next)
        return [ordered]@{ok=$true;changed=$true;recovered=$recovered;status='CLEARED';generation=$generation;revision=$revision}
    } finally { Exit-TPV2Mutex $mutex }
}

function Get-TPV2Context {
    param([string]$StateRoot,[string]$SessionId,[string]$Source)
    $mutex=Enter-TPV2Mutex $SessionId; try{$state=Read-TPV2State $StateRoot $SessionId}finally{Exit-TPV2Mutex $mutex}
    if($null-eq$state-or[string]$state.status-ceq'CLEARED'){return $null}
    $mode=if([string]$state.status-ceq'DIRTY'){'MERGE_FIRST'}else{'CONTINUE'}
        $context=@"
[TASK_POINTER_V2]
SOURCE=$Source
STATUS=$($state.status)
RECOVERY_MODE=$mode
GENERATION=$(Get-TPV2Generation $state)
REVISION=$($state.revision)
TASK_ID=$($state.task_id)
PUBLISH_CURRENT_POINTER_SESSION_ID=$SessionId
PUBLISH_CURRENT_POINTER_PATH=$script:TPV2_PublisherPath
$($state.pointer_text)
[/TASK_POINTER_V2]
"@.TrimEnd("`r","`n").Replace("`r`n","`n")
    if($script:TPV2_Utf8.GetByteCount($context)-gt$script:TPV2_MaxContextBytes){Throw-TPV2Error -Code 'CONTEXT_TOO_LARGE'}
    return $context
}

function Format-TPV2BootstrapContext {
    param([string]$SessionId,[string]$Source,[string]$Status,[string]$Generation,[int64]$Revision)
    $context=@"
[TASK_POINTER_V2_BOOTSTRAP]
SOURCE=$Source
STATUS=$Status
GENERATION=$Generation
REVISION=$Revision
SESSION_ID=$SessionId
PUBLISH_CURRENT_POINTER_PATH=$script:TPV2_PublisherPath
PUBLISH_TRANSPORT=STDIN_JSON
REQUEST_SCHEMA=3
[/TASK_POINTER_V2_BOOTSTRAP]
"@.TrimEnd("`r","`n").Replace("`r`n","`n")
    if($script:TPV2_Utf8.GetByteCount($context)-gt$script:TPV2_MaxContextBytes){Throw-TPV2Error -Code 'CONTEXT_TOO_LARGE'}
    return $context
}

function Format-TPV2CasContext {
    param([string]$SessionId,[string]$Status,[string]$Generation,[int64]$Revision)
    return @"
[TASK_POINTER_V2_CAS]
STATUS=$Status
GENERATION=$Generation
REVISION=$Revision
SESSION_ID=$SessionId
PUBLISH_CURRENT_POINTER_PATH=$script:TPV2_PublisherPath
[/TASK_POINTER_V2_CAS]
"@.TrimEnd("`r","`n").Replace("`r`n","`n")
}

function Get-TPV2BootstrapContext {
    param([string]$StateRoot,[string]$SessionId,[string]$Source)
    $mutex=Enter-TPV2Mutex $SessionId; try{$state=Read-TPV2State $StateRoot $SessionId}finally{Exit-TPV2Mutex $mutex}
    if($null-ne$state-and[string]$state.status-cne'CLEARED'){return $null}
    $status=if($null-eq$state){'ABSENT'}else{'CLEARED'}; $generation=Get-TPV2Generation $state; $revision=if($null-eq$state){0}else{[int64]$state.revision}
    return Format-TPV2BootstrapContext -SessionId $SessionId -Source $Source -Status $status -Generation $generation -Revision $revision
}
