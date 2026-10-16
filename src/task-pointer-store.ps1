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
$script:TPV2_JournalFileName = 'journal.jsonl'
$script:TPV2_JournalVersion = 1
# 日志是诊断证据而非事实源，因此有上限；超限轮转保留末次记录（见 docs/design.md §4.4）。
$script:TPV2_MaxJournalBytes = 524288
$script:TPV2_JournalRetainRecords = 100
$script:TPV2_JournalMaxRecallEntries = 20
$script:TPV2_MaxRecallBytes = 4096
$script:TPV2_MaxReportBytes = 10000

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

function Get-TPV2JournalPath {
    param([string]$StateRoot, [string]$SessionId)
    $statePath = Get-TPV2StatePath $StateRoot $SessionId
    return Join-Path (Split-Path -Parent $statePath) $script:TPV2_JournalFileName
}

# 日志记录全 ASCII；正文永不进入日志，只留字节数与摘要。
function New-TPV2JournalRecord {
    param([string]$SessionId, [ValidateSet('PUBLISH','CLEARED')][string]$Event, [int64]$Revision, [string]$Generation, [string]$Status, [AllowNull()][object]$TaskId, [AllowNull()][object]$PointerText, [AllowNull()][object]$PreviousRevision, [AllowNull()][object]$PreviousStatus)
    $bytes = $null
    $digest = $null
    if ($null -ne $PointerText) {
        $normalized = ([string]$PointerText).Replace("`r`n", "`n").Replace("`r", "`n")
        $encoded = $script:TPV2_Utf8.GetBytes($normalized)
        $bytes = $encoded.Length
        $digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($encoded)).ToLowerInvariant()
    }
    return [ordered]@{
        journal_version = $script:TPV2_JournalVersion
        session_id = $SessionId
        event = $Event
        revision = $Revision
        generation = $Generation
        status = $Status
        task_id = $TaskId
        # 命名刻意避开 v1 双文件哈希链那两个字段名：它们属于被淘汰的 Win32 journal 时代，
        # 禁止在活动运行时里复现（tests 的 legacy symbol tripwire 会逐字拦截）。
        pointer_digest = $digest
        pointer_byte_count = $bytes
        previous_revision = $PreviousRevision
        previous_status = $PreviousStatus
        recorded_at = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
}

function Read-TPV2JournalLines {
    param([string]$Path)
    if (-not [IO.File]::Exists($Path)) { return @() }
    try { $raw = [IO.File]::ReadAllText($Path, $script:TPV2_Utf8) } catch { return @() }
    if ([string]::IsNullOrEmpty($raw)) { return @() }
    $lines = [Collections.Generic.List[string]]::new()
    foreach ($line in $raw.Split("`n")) {
        $trimmed = $line.TrimEnd("`r")
        if (-not [string]::IsNullOrWhiteSpace($trimmed)) { $lines.Add($trimmed) }
    }
    return @($lines)
}

# 只解析形状正确的记录；损坏行计入 gaps，不抛错（docs/design.md §4.3）。
function Get-TPV2Journal {
    param([string]$StateRoot, [string]$SessionId)
    $path = Get-TPV2JournalPath $StateRoot $SessionId
    $records = [Collections.Generic.List[object]]::new()
    $invalid = 0
    foreach ($line in @(Read-TPV2JournalLines $path)) {
        try { $record = $line | ConvertFrom-Json -AsHashtable -Depth 8 -DateKind String }
        catch { $invalid++; continue }
        if ($record -isnot [Collections.IDictionary]) { $invalid++; continue }
        if (-not $record.Contains('journal_version') -or -not $record.Contains('revision') -or -not $record.Contains('event')) { $invalid++; continue }
        $records.Add($record)
    }
    return [ordered]@{ path = $path; exists = [IO.File]::Exists($path); records = @($records); invalid_lines = $invalid }
}

# revision 缺口 = 有记录但编号不连续（含日志被截断/轮转后的起点）；哈希连续 = 正文连续未变。
function Get-TPV2JournalSummary {
    param([string]$StateRoot, [string]$SessionId)
    $journal = Get-TPV2Journal -StateRoot $StateRoot -SessionId $SessionId
    $records = @($journal.records)
    $latest = if ($records.Count -gt 0) { [int64]$records[-1].revision } else { 0 }
    $revisionGaps = 0
    for ($index = 1; $index -lt $records.Count; $index++) {
        if ([int64]$records[$index].revision -ne [int64]$records[$index - 1].revision + 1) { $revisionGaps++ }
    }
    $identicalRun = 1
    for ($index = $records.Count - 1; $index -ge 1; $index--) {
        $current = $records[$index]
        $previous = $records[$index - 1]
        if ([string]$current.event -cne 'PUBLISH' -or [string]$previous.event -cne 'PUBLISH') { break }
        $currentHash = if ($current.Contains('pointer_digest')) { $current.pointer_digest } else { $null }
        $previousHash = if ($previous.Contains('pointer_digest')) { $previous.pointer_digest } else { $null }
        if ([string]::IsNullOrEmpty([string]$currentHash) -or [string]$currentHash -cne [string]$previousHash) { break }
        $identicalRun++
    }
    return [ordered]@{
        entry_count = $records.Count
        latest_revision = $latest
        invalid_lines = [int]$journal.invalid_lines
        revision_gaps = $revisionGaps
        # 判定"原地踏步"需要至少两次发布都没变，单次不足以下结论。
        identical_text_streak = if ($records.Count -ge 2) { $identicalRun } else { 0 }
    }
}

# 追加失败不得影响 CAS 结果，因此永不抛出；失败以返回值表达。
function Add-TPV2JournalRecord {
    param([string]$StateRoot, [string]$SessionId, [System.Collections.IDictionary]$Record)
    $path = $null
    try {
        $path = Get-TPV2JournalPath $StateRoot $SessionId
        $line = ($Record | ConvertTo-Json -Compress -Depth 8) + "`n"
        $bytes = $script:TPV2_Utf8.GetBytes($line)
        $rotated = $false
        if ([IO.File]::Exists($path)) {
            $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if ($item.Length -gt $script:TPV2_MaxJournalBytes) {
                Invoke-TPV2JournalRotation -Path $path
                $rotated = $true
            }
        }
        $stream = [IO.FileStream]::new($path, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read, 4096, [IO.FileOptions]::WriteThrough)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        return [ordered]@{ ok = $true; code = $null; path = $path; rotated = $rotated }
    }
    catch { return [ordered]@{ ok = $false; code = 'JOURNAL_APPEND_FAILED'; path = $path; rotated = $false } }
}

function Invoke-TPV2JournalRotation {
    param([string]$Path)
    $lines = @(Read-TPV2JournalLines $Path)
    $keep = if ($lines.Count -gt $script:TPV2_JournalRetainRecords) { $lines[($lines.Count - $script:TPV2_JournalRetainRecords)..($lines.Count - 1)] } else { $lines }
    $text = if ($keep.Count -gt 0) { (($keep -join "`n") + "`n") } else { '' }
    $temp = Join-Path (Split-Path -Parent $Path) ('.journal-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temp, $text, $script:TPV2_Utf8)
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temp, $Path, [Management.Automation.Language.NullString]::Value, $true) } else { [IO.File]::Move($temp, $Path) }
    }
    finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
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

function Get-TPV2AgeSeconds {
    param([AllowNull()][object]$Timestamp)
    if ($Timestamp -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Timestamp)) { return -1 }
    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParseExact([string]$Timestamp, 'yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) { return -1 }
    $seconds = [int64]([DateTimeOffset]::UtcNow - $parsed).TotalSeconds
    if ($seconds -lt 0) { return 0 }
    return $seconds
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
        $previousStatus = if ($null -eq $current) { $null } else { [string]$current.status }
        # generation 模型用 ABSENT 表示"此前不存在"：日志沿用同一编码，不用 null 表达同一件事。
        $journal = Add-TPV2JournalRecord -StateRoot $StateRoot -SessionId $SessionId -Record (New-TPV2JournalRecord -SessionId $SessionId -Event $(if ($TargetStatus -ceq 'CLEARED') { 'CLEARED' } else { 'PUBLISH' }) -Revision ([int64]$next.revision) -Generation $generation -Status $TargetStatus -TaskId $TaskId -PointerText $PointerText -PreviousRevision ([int64]$observedRevision) -PreviousStatus $previousStatus)
        return [ordered]@{ok=$true;schema_version=3;session_id=$SessionId;task_id=$TaskId;status=$TargetStatus;generation=$generation;revision=$observedRevision+1;journal_appended=[bool]$journal.ok;journal_error=$journal.code}
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
            return [ordered]@{ok=$true;changed=$false;bootstrap=$true;fenced=$true;status='CLEARED';generation=$generation;revision=$revision}
        }
        $generation=if([int]$current.schema_version-eq2){New-TPV2Generation}else{[string]$current.generation}
        $NextTaskId = [string]$current.task_id
        $NextPointerText = [string]$current.pointer_text
        # no-op 守卫：内容已与前一次标记一致时不再写盘，也不递增 revision。"这次 prompt 又会
        # 标记 DIRTY"不构成内容变化；让 updated_at 停在真正最后一次变更上，POINTER_AGE_SECONDS
        # 才是可用的陈旧信号，revision 也才能当"指针内容版本"读（docs/design.md §4.5）。
        if ([string]$current.status -ceq 'DIRTY') {
            $summary = Get-TPV2JournalSummary -StateRoot $StateRoot -SessionId $SessionId
            return [ordered]@{ok=$true;changed=$false;bootstrap=$false;fenced=$false;status='DIRTY';generation=$generation;revision=[int64]$current.revision;age_seconds=(Get-TPV2AgeSeconds ([string]$current.updated_at));identical_text_streak=[int]$summary.identical_text_streak}
        }
        $next=New-TPV2State $SessionId $generation ([int64]$current.revision+1) DIRTY $NextTaskId $NextPointerText
        [void](Write-TPV2StateFile $StateRoot $SessionId $next)
        # 只有 CLEAN -> DIRTY 是"上一版指针尚未合并"的实质转变；DIRTY -> DIRTY 是噪声，不入日志。
        if ([string]$current.status -ceq 'CLEAN') {
            [void](Add-TPV2JournalRecord -StateRoot $StateRoot -SessionId $SessionId -Record (New-TPV2JournalRecord -SessionId $SessionId -Event 'PUBLISH' -Revision ([int64]$next.revision) -Generation $generation -Status 'DIRTY' -TaskId ([string]$current.task_id) -PointerText ([string]$current.pointer_text) -PreviousRevision ([int64]$current.revision) -PreviousStatus ([string]$current.status)))
        }
        $summary = Get-TPV2JournalSummary -StateRoot $StateRoot -SessionId $SessionId
        return [ordered]@{ok=$true;changed=$true;bootstrap=$false;fenced=$false;status='DIRTY';generation=$generation;revision=[int64]$next.revision;age_seconds=(Get-TPV2AgeSeconds ([string]$current.updated_at));identical_text_streak=[int]$summary.identical_text_streak}
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
        # 墓碑：清除前把被放弃指针的可识别信息留在日志里，避免"清空即抹除"。
        $tombstoneTaskId = if ($null -eq $current -or [string]$current.status -ceq 'CLEARED') { $null } else { [string]$current.task_id }
        $tombstoneText = if ($null -eq $current -or [string]$current.status -ceq 'CLEARED') { $null } else { [string]$current.pointer_text }
        $previousRevision = if ($null -eq $current -or $recovered) { $null } else { [int64]$current.revision }
        $generation=New-TPV2Generation
        $next=New-TPV2State $SessionId $generation $revision CLEARED $null $null
        [void](Write-TPV2StateFile $StateRoot $SessionId $next)
        [void](Add-TPV2JournalRecord -StateRoot $StateRoot -SessionId $SessionId -Record (New-TPV2JournalRecord -SessionId $SessionId -Event 'CLEARED' -Revision $revision -Generation $generation -Status 'CLEARED' -TaskId $tombstoneTaskId -PointerText $tombstoneText -PreviousRevision $previousRevision -PreviousStatus $(if ($null -eq $current -or $recovered) { $null } else { [string]$current.status })))
        return [ordered]@{ok=$true;changed=$true;recovered=$recovered;status='CLEARED';generation=$generation;revision=$revision}
    } finally { Exit-TPV2Mutex $mutex }
}

function Get-TPV2Context {
    param([string]$StateRoot,[string]$SessionId,[string]$Source)
    $mutex=Enter-TPV2Mutex $SessionId; try{$state=Read-TPV2State $StateRoot $SessionId}finally{Exit-TPV2Mutex $mutex}
    if($null-eq$state-or[string]$state.status-ceq'CLEARED'){return $null}
    $mode=if([string]$state.status-ceq'DIRTY'){'MERGE_FIRST'}else{'CONTINUE'}
    # 注入的每个字段都必须是 state 的纯函数：年龄、字节数、日志计数这类随时钟或日志变动的
    # 诊断量一律不放这里，否则 revision 未变而产物已变，会在注入点之后击穿前缀缓存
    # （docs/design.md §2.3）。诊断量另有出口：CAS 通道与 report 入口。
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

# 每轮 prompt 的 CAS 注入口。envelope 字段顺序固定、LF 规范：revision 不变时产物逐字节相同，
# 因此不会在注入点之后额外打断前缀缓存（docs/design.md §2.3）。
function Format-TPV2CasContext {
    param([string]$SessionId,[string]$Status,[string]$Generation,[int64]$Revision,[int]$AgeSeconds=-1,[int]$IdenticalTextStreak=0)
    # 同一份指针已连续发布多次且仍未更新 => 要么没有新进展，要么新进展没有被发布。
    $nextAction = if ($Status -ceq 'DIRTY' -and $AgeSeconds -ge 600) { 'REPUBLISH_THEN_CONTINUE' }
        elseif ($Status -ceq 'DIRTY' -and $IdenticalTextStreak -ge 3) { 'REPUBLISH_WITH_NEW_NEXT_STEP' }
        elseif ($Status -ceq 'DIRTY') { 'MERGE_THEN_REPUBLISH' }
        else { 'CONTINUE' }
    return @"
[TASK_POINTER_V2_CAS]
STATUS=$Status
GENERATION=$Generation
REVISION=$Revision
SESSION_ID=$SessionId
REQUEST_SCHEMA=3
POINTER_AGE_SECONDS=$AgeSeconds
JOURNAL_IDENTICAL_TEXT_STREAK=$IdenticalTextStreak
NEXT_ACTION=$nextAction
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

# 召回：列出匹配的日志记录，或取回指针正文。日志只存元数据，因此正文只可能取到
# 当前 state 的版本；请求历史 revision 的正文返回 RECALL_TEXT_UNAVAILABLE（见 docs/design.md §3）。
function Get-TPV2RecallText {
    param([string]$StateRoot,[string]$SessionId,[AllowNull()][object]$Revision=$null,[int]$Last=0,[AllowNull()][object]$TextMatch=$null,[switch]$Full)
    $journal=Get-TPV2Journal -StateRoot $StateRoot -SessionId $SessionId
    $records=@($journal.records)
    if($Revision -isnot [int] -and $Revision -isnot [long] -and -not [string]::IsNullOrWhiteSpace([string]$Revision)){
        try{$Revision=[int64]$Revision}catch{$Revision=$null}
    }
    $requested=$null
    if($Revision -is [int] -or $Revision -is [long]){
        $requested=[int64]$Revision
        $records=@($records | Where-Object { [int64]$_.revision -eq $requested })
    }
    if($Last -gt 0 -and $records.Count -gt $Last){ $records=@($records[($records.Count-$Last)..($records.Count-1)]) }
    if($records.Count -eq 0){ return 'RECALL_EMPTY' }
    $state=$null
    try{ $state=Read-TPV2State $StateRoot $SessionId }catch{ $state=$null }
    $liveText=if($null-ne$state -and -not [string]::IsNullOrWhiteSpace([string]$state.pointer_text)){[string]$state.pointer_text}else{$null}
    $liveRevision=if($null-ne$state){[int64]$state.revision}else{$null}
    if(-not [string]::IsNullOrWhiteSpace([string]$TextMatch)){
        $needle=[string]$TextMatch
        if($null-eq$liveText -or $liveText.IndexOf($needle,[StringComparison]::Ordinal) -lt 0){ return 'RECALL_EMPTY' }
    }
    if($records.Count -gt $script:TPV2_JournalMaxRecallEntries){ $records=@($records[($records.Count-$script:TPV2_JournalMaxRecallEntries)..($records.Count-1)]) }
    $lines=[Collections.Generic.List[string]]::new()
    foreach($record in $records){
        $bytes = if($record.Contains('pointer_byte_count') -and $null-ne$record.pointer_byte_count){$record.pointer_byte_count}else{'-'}
        $digest = if($record.Contains('pointer_digest') -and -not [string]::IsNullOrEmpty([string]$record.pointer_digest)){[string]$record.pointer_digest}else{'-'}
        $taskId = if($record.Contains('task_id') -and -not [string]::IsNullOrEmpty([string]$record.task_id)){[string]$record.task_id}else{'-'}
        $recorded = if($record.Contains('recorded_at')){[string]$record.recorded_at}else{'-'}
        $lines.Add(('REV={0} EVENT={1} STATUS={2} BYTES={3} SHA256={4} TASK_ID={5} RECORDED_AT={6}' -f $record.revision,$record.event,$record.status,$bytes,$digest,$taskId,$recorded))
    }
    $target = if($null-ne$requested){$requested}else{[int64]$records[-1].revision}
    if($null-eq$liveText -or $null-eq$liveRevision -or [int64]$liveRevision -ne [int64]$target){
        $lines.Add('POINTER_TEXT=RECALL_TEXT_UNAVAILABLE')
        $lines.Add('RECALL_TEXT_UNAVAILABLE_REASON=journal_stores_metadata_only')
    }
    elseif($Full){ $lines.Add('POINTER_TEXT_BEGIN'); $lines.Add($liveText); $lines.Add('POINTER_TEXT_END') }
    else{ $preview=if($liveText.Length-gt 160){$liveText.Substring(0,160)+'...'}else{$liveText}; $lines.Add('POINTER_PREVIEW='+(($preview -replace "[`r`n]+",' ').Trim())) }
    $result=$lines -join "`n"
    if($script:TPV2_Utf8.GetByteCount($result)-gt$script:TPV2_MaxRecallBytes){ Throw-TPV2Error -Code 'RECALL_TOO_LARGE' }
    return $result
}

# 只读状态面：publisher hook 是否在跑、指针多旧、日志有无缺口。
function Format-TPV2Report {
    param([string]$StateRoot,[string]$SessionId)
    $state=$null; $readError=$null
    try{ $state=Read-TPV2State $StateRoot $SessionId }catch{ $readError=Get-TPV2ErrorCode $_ }
    $summary=Get-TPV2JournalSummary -StateRoot $StateRoot -SessionId $SessionId
    $lines=[Collections.Generic.List[string]]::new()
    $lines.Add('[TASK_POINTER_V2_REPORT]')
    $lines.Add('SESSION_ID='+$SessionId)
    $lines.Add('STATE_ROOT='+(Resolve-TPV2StateRoot -StateRoot $StateRoot))
    $lines.Add('STATE_PATH='+(Get-TPV2StatePath $StateRoot $SessionId))
    $lines.Add('JOURNAL_PATH='+(Get-TPV2JournalPath $StateRoot $SessionId))
    if($null-ne$readError){ $lines.Add('STATE=UNREADABLE'); $lines.Add('STATE_ERROR='+[string]$readError) }
    elseif($null-eq$state){ $lines.Add('STATE=ABSENT') }
    else{
        $lines.Add('STATE='+[string]$state.status)
        $lines.Add('REVISION='+[string]$state.revision)
        $lines.Add('GENERATION='+(Get-TPV2Generation $state))
        $reportTaskId = if ($null -eq $state.task_id) { '-' } else { [string]$state.task_id }
        $reportPointerBytes = if ($null -eq $state.pointer_text) { 0 } else { $script:TPV2_Utf8.GetByteCount(([string]$state.pointer_text).Replace("`r`n", "`n").Replace("`r", "`n")) }
        $lines.Add('TASK_ID=' + $reportTaskId)
        $lines.Add('UPDATED_AT=' + [string]$state.updated_at)
        $lines.Add('POINTER_AGE_SECONDS=' + (Get-TPV2AgeSeconds $state.updated_at))
        $lines.Add('POINTER_BYTES=' + $reportPointerBytes)
    }
    $lines.Add('JOURNAL_ENTRIES='+[string]$summary.entry_count)
    $lines.Add('JOURNAL_LATEST_REVISION='+[string]$summary.latest_revision)
    $lines.Add('JOURNAL_INVALID_LINES='+[string]$summary.invalid_lines)
    $lines.Add('JOURNAL_REVISION_GAPS='+[string]$summary.revision_gaps)
    $lines.Add('JOURNAL_IDENTICAL_TEXT_STREAK='+[string]$summary.identical_text_streak)
    $journal=Get-TPV2Journal -StateRoot $StateRoot -SessionId $SessionId
    $records=@($journal.records)
    if($records.Count -gt 0){
        if($records.Count -gt 10){ $records=@($records[($records.Count-10)..($records.Count-1)]) }
        foreach($record in $records){
            $digest = if($record.Contains('pointer_digest') -and -not [string]::IsNullOrEmpty([string]$record.pointer_digest)){([string]$record.pointer_digest).Substring(0,12)}else{'-'}
            $taskId = if($record.Contains('task_id') -and -not [string]::IsNullOrEmpty([string]$record.task_id)){[string]$record.task_id}else{'-'}
            $lines.Add(('JOURNAL {0} REV={1} STATUS={2} TASK_ID={3} SHA={4}' -f $record.recorded_at,$record.revision,$record.status,$taskId,$digest))
        }
    }
    $lines.Add('[/TASK_POINTER_V2_REPORT]')
    $result=$lines -join "`n"
    if($script:TPV2_Utf8.GetByteCount($result)-gt$script:TPV2_MaxReportBytes){ Throw-TPV2Error -Code 'REPORT_TOO_LARGE' }
    return $result
}
