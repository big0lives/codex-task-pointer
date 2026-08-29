#requires -Version 7.5
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$V1Root,
    [Parameter(Mandatory)][string]$V2Root,
    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$storePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'src\task-pointer-store.ps1'
. $storePath

$utf8 = [System.Text.UTF8Encoding]::new($false, $true)
$jsonOptions = [System.Text.Json.JsonSerializerOptions]::new()
$jsonOptions.Encoder = [System.Text.Encodings.Web.JavaScriptEncoder]::UnsafeRelaxedJsonEscaping
$rows = @()
$invalid = @()
$sessions = [System.Collections.Generic.Dictionary[string, bool]]::new([StringComparer]::Ordinal)

function Throw-MigrationError {
    param([Parameter(Mandatory)][ValidatePattern('^[A-Z0-9_]+$')][string]$Code)
    throw [System.InvalidOperationException]::new($Code)
}

function Get-MigrationErrorCode {
    param([System.Management.Automation.ErrorRecord]$ErrorRecord)
    $message = [string]$ErrorRecord.Exception.Message
    if ($message -match '^([A-Z0-9_]+)(?:\|.*)?$') { return $Matches[1] }
    return 'MIGRATION_FAILED'
}

function Get-MigrationFullPath {
    param([Parameter(Mandatory)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { Throw-MigrationError -Code 'V1_ROOT_MISSING' }
    try { $full = [System.IO.Path]::GetFullPath($Path) }
    catch { Throw-MigrationError -Code 'V1_ROOT_INVALID' }
    if ([string]::IsNullOrWhiteSpace($full)) { Throw-MigrationError -Code 'V1_ROOT_INVALID' }
    $root = [System.IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $root.Length) { return $full.TrimEnd('\') }
    return $root
}

function Assert-MigrationNoReparseComponents {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Code = 'PATH_REPARSE_POINT'
    )
    $full = Get-MigrationFullPath -Path $Path
    try {
        $volume = [System.IO.Path]::GetPathRoot($full)
        $current = $volume
        $relative = $full.Substring($volume.Length)
        foreach ($segment in $relative.Split('\', [System.StringSplitOptions]::RemoveEmptyEntries)) {
            $current = Join-Path $current $segment
            if (-not [System.IO.File]::Exists($current) -and -not [System.IO.Directory]::Exists($current)) { continue }
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                Throw-MigrationError -Code $Code
            }
        }
    }
    catch [System.InvalidOperationException] { throw }
    catch { Throw-MigrationError -Code 'V1_SCAN_FAILED' }
}

function Resolve-MigrationV1Root {
    param([Parameter(Mandatory)][string]$Path)
    $full = Get-MigrationFullPath -Path $Path
    try { $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop }
    catch [System.Management.Automation.ItemNotFoundException] { Throw-MigrationError -Code 'V1_ROOT_MISSING' }
    catch { Throw-MigrationError -Code 'V1_ROOT_INVALID' }
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { Throw-MigrationError -Code 'PATH_REPARSE_POINT' }
    if (-not $item.PSIsContainer) { Throw-MigrationError -Code 'V1_ROOT_NOT_DIRECTORY' }
    $parent = Split-Path -Parent $full
    if (-not [string]::IsNullOrWhiteSpace($parent)) { Assert-MigrationNoReparseComponents -Path $parent }
    return $full
}

function Get-MigrationV1Files {
    param([Parameter(Mandatory)][string]$Root)
    $pending = [System.Collections.Generic.Stack[string]]::new()
    $files = [System.Collections.Generic.List[string]]::new()
    $pending.Push($Root)
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        Assert-MigrationNoReparseComponents -Path $directory
        try { $entries = @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop) }
        catch [System.InvalidOperationException] { throw }
        catch { Throw-MigrationError -Code 'V1_SCAN_FAILED' }
        foreach ($entry in $entries) {
            if (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                Throw-MigrationError -Code 'PATH_REPARSE_POINT'
            }
            $entryPath = Get-MigrationFullPath -Path ([string]$entry.FullName)
            Assert-MigrationNoReparseComponents -Path $entryPath
            if ($entry.PSIsContainer) {
                $pending.Push($entryPath)
                continue
            }
            if ([string]$entry.Name -ceq 'active.json') { [void]$files.Add($entryPath) }
        }
    }
    return @($files | Sort-Object)
}

function Write-MigrationReceipt {
    param(
        [int]$Scanned,
        [int]$Migrated,
        [int]$Existing,
        [int]$Invalid,
        [AllowNull()][string]$ErrorCode = $null
    )
    $line = "scanned=$Scanned migrated=$Migrated existing=$Existing invalid=$Invalid apply=$([bool]$Apply)"
    if (-not [string]::IsNullOrWhiteSpace($ErrorCode)) { $line += " error=$ErrorCode" }
    [Console]::Out.WriteLine($line)
}

function Get-Sha256Lower {
    param([byte[]]$Bytes)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function ConvertTo-JcsScalar {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [string]) { return [System.Text.Json.JsonSerializer]::Serialize([string]$Value, $jsonOptions) }
    if ($Value -is [bool]) { return ([string]$Value).ToLowerInvariant() }
    if ($Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or $Value -is [int64] -or $Value -is [uint64]) { return [Convert]::ToString($Value, [Globalization.CultureInfo]::InvariantCulture) }
    throw 'unsupported JCS scalar type'
}

function ConvertTo-FlatCanonicalJson {
    param([System.Collections.IDictionary]$Value)
    $keys = [string[]]@($Value.Keys | ForEach-Object { [string]$_ })
    [Array]::Sort($keys, [StringComparer]::Ordinal)
    $parts = foreach ($key in $keys) {
        ([System.Text.Json.JsonSerializer]::Serialize($key, $jsonOptions) + ':' + (ConvertTo-JcsScalar $Value[$key]))
    }
    return '{' + ($parts -join ',') + '}'
}

function Assert-ExactKeys {
    param([System.Collections.IDictionary]$Value, [string[]]$Expected)
    $actual = @($Value.Keys | ForEach-Object { [string]$_ } | Sort-Object)
    if (($actual -join "`0") -cne (($Expected | Sort-Object) -join "`0")) { throw 'fields invalid' }
}

function Assert-V1Snapshot {
    param([System.Collections.IDictionary]$Payload)
    Assert-ExactKeys $Payload @('schema_version','record_type','session_id','session_key','status','task_id','validated_through_turn_id','dirty_from_turn_id','dirty_through_turn_id','dirty_prompt_count','workspace_anchor','trigger','pointer_text','pointer_text_utf8_bytes','pointer_sha256','updated_at')
    if ($Payload.schema_version -isnot [int] -and $Payload.schema_version -isnot [long]) { throw 'schema type' }
    if ([int]$Payload.schema_version -ne 1 -or [string]$Payload.record_type -cne 'active_snapshot') { throw 'snapshot identity' }
    if ([string]$Payload.status -cnotin @('CLEAN','DIRTY','RETIRED')) { throw 'snapshot status' }
    if ($Payload.task_id -isnot [string] -or [string]$Payload.task_id -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$') { throw 'task id' }
    if ($Payload.pointer_text -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Payload.pointer_text)) { throw 'pointer' }
    $pointerBytes = $utf8.GetBytes([string]$Payload.pointer_text)
    if ($Payload.pointer_text_utf8_bytes -isnot [int] -and $Payload.pointer_text_utf8_bytes -isnot [long]) { throw 'pointer bytes type' }
    if ([int64]$Payload.pointer_text_utf8_bytes -ne $pointerBytes.Length) { throw 'pointer bytes' }
    if ([string]$Payload.pointer_sha256 -cne (Get-Sha256Lower $pointerBytes)) { throw 'pointer hash' }
    if ($Payload.dirty_prompt_count -isnot [int] -and $Payload.dirty_prompt_count -isnot [long]) { throw 'dirty count type' }
    $count = [int64]$Payload.dirty_prompt_count
    if ([string]$Payload.status -cne 'DIRTY' -and ($count -ne 0 -or $null -ne $Payload.dirty_from_turn_id -or $null -ne $Payload.dirty_through_turn_id)) { throw 'clean/retired dirty relation' }
    if ([string]$Payload.status -ceq 'DIRTY' -and ($count -lt 1 -or $Payload.dirty_from_turn_id -isnot [string] -or $Payload.dirty_through_turn_id -isnot [string] -or [string]$Payload.trigger -cne 'USER_PROMPT_SUBMIT')) { throw 'dirty relation' }
    foreach ($field in @('validated_through_turn_id','dirty_from_turn_id','dirty_through_turn_id')) { if ($null -ne $Payload[$field] -and $Payload[$field] -isnot [string]) { throw 'turn field type' } }
    if ($Payload.workspace_anchor -isnot [string] -or -not [IO.Path]::IsPathFullyQualified([string]$Payload.workspace_anchor)) { throw 'workspace anchor' }
    if ($Payload.trigger -isnot [string] -or [string]$Payload.trigger -cnotin @('CREATE','USER_STEERING','RECOVERY_DRIFT','BATCH_NODE','GIT_CHECKPOINT','LONG_COMMAND_START','LONG_COMMAND_END','COMPLETE','REPLACE','USER_PROMPT_SUBMIT')) { throw 'trigger' }
    if ($Payload.updated_at -isnot [string] -or -not (Test-TPV2UtcTimestamp $Payload.updated_at)) { throw 'updated time' }
    if ([string]$Payload.status -ceq 'RETIRED' -and [string]$Payload.pointer_text -cnotmatch '(?m)^下一步：NONE$') { throw 'retired next step' }
}

function Assert-V1Tombstone {
    param([System.Collections.IDictionary]$Payload)
    Assert-ExactKeys $Payload @('schema_version','record_type','session_id','session_key','status','reason','turn_id','created_at')
    if ($Payload.schema_version -isnot [int] -and $Payload.schema_version -isnot [long]) { throw 'schema type' }
    if ([int]$Payload.schema_version -ne 1 -or [string]$Payload.record_type -cne 'active_tombstone' -or [string]$Payload.status -cne 'TOMBSTONE') { throw 'tombstone identity' }
    if ($Payload.reason -isnot [string] -or [string]$Payload.reason -cnotin @('CLEAR','NO_ACTIVE')) { throw 'tombstone reason' }
    if ($null -ne $Payload.turn_id -and $Payload.turn_id -isnot [string]) { throw 'tombstone turn' }
    if ($Payload.created_at -isnot [string] -or -not (Test-TPV2UtcTimestamp $Payload.created_at)) { throw 'created time' }
}

try {
    $v1 = Resolve-MigrationV1Root -Path $V1Root
    $v2 = Resolve-TPV2StateRoot -StateRoot $V2Root
    $v1Files = @(Get-MigrationV1Files -Root $v1)
}
catch {
    Write-MigrationReceipt -Scanned 0 -Migrated 0 -Existing 0 -Invalid 1 -ErrorCode (Get-MigrationErrorCode -ErrorRecord $_)
    exit 2
}

foreach ($filePath in $v1Files) {
    try {
        Assert-MigrationNoReparseComponents -Path $filePath
        if ([IO.Path]::GetFullPath((Split-Path -Parent (Split-Path -Parent $filePath))).TrimEnd('\') -cne $v1) { throw 'active record is not a direct session child' }
        $bytes = [IO.File]::ReadAllBytes($filePath)
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { throw 'bom' }
        $text = $utf8.GetString($bytes)
        if ($text.EndsWith("`n")) { $text = $text.Substring(0, $text.Length - 1) }
        if ($text.Contains("`r") -or $text.Contains("`n")) { throw 'noncanonical line ending' }
        $match = [regex]::Match($text, '^\{"payload":(?<payload>\{.*\}),"payload_sha256":"(?<hash>[0-9a-f]{64})"\}$', [Text.RegularExpressions.RegexOptions]::Singleline)
        if (-not $match.Success) { throw 'envelope shape' }
        $payloadJson = $match.Groups['payload'].Value
        $declaredHash = $match.Groups['hash'].Value
        try { $document = $text | ConvertFrom-Json -AsHashtable -Depth 50 -DateKind String } catch { throw 'json parse' }
        Assert-ExactKeys $document @('payload','payload_sha256')
        if ($document.payload -isnot [System.Collections.IDictionary]) { throw 'payload missing' }
        $payload = $document.payload
        $canonicalPayload = ConvertTo-FlatCanonicalJson $payload
        if ($canonicalPayload -cne $payloadJson) { throw 'payload noncanonical or duplicate property' }
        $canonicalEnvelope = '{"payload":' + $canonicalPayload + ',"payload_sha256":"' + $declaredHash + '"}'
        if ($canonicalEnvelope -cne $text) { throw 'envelope noncanonical' }
        if ((Get-Sha256Lower $utf8.GetBytes($canonicalPayload)) -cne $declaredHash) { throw 'payload hash' }

        $session = [string]$payload.session_id
        Assert-TPV2SessionId -SessionId $session
        $sessionKey = Get-TPV2SessionKey $session
        if ([string]$payload.session_key -cne $sessionKey -or (Split-Path -Leaf (Split-Path -Parent $filePath)) -cne $sessionKey) { throw 'session key' }
        if ($sessions.ContainsKey($session)) { throw 'duplicate session' }
        $sessions[$session] = $true

        if ([string]$payload.record_type -ceq 'active_snapshot') {
            Assert-V1Snapshot $payload
            if ([string]$payload.status -cin @('CLEAN','DIRTY')) { $targetStatus=[string]$payload.status; $taskId=[string]$payload.task_id; $pointer=[string]$payload.pointer_text }
            else { $targetStatus='CLEARED'; $taskId=$null; $pointer=$null }
        }
        elseif ([string]$payload.record_type -ceq 'active_tombstone') { Assert-V1Tombstone $payload; $targetStatus='CLEARED'; $taskId=$null; $pointer=$null }
        else { throw 'record type' }

        Assert-TPV2PointerFields -State ([ordered]@{status=$targetStatus;task_id=$taskId;pointer_text=$pointer})

        $current = Read-TPV2State -StateRoot $v2 -SessionId $session
        if ($null -ne $current) {
            if ([string]$current.status -cne $targetStatus) { throw 'existing status conflict' }
            if ($targetStatus -cne 'CLEARED' -and (([string]$current.task_id -cne [string]$taskId) -or ([string]$current.pointer_text -cne [string]$pointer))) { throw 'existing payload conflict' }
            if ($targetStatus -ceq 'CLEARED' -and ($null -ne $current.task_id -or $null -ne $current.pointer_text)) { throw 'existing cleared conflict' }
        }
        $rows += [ordered]@{session_id=$session;status=$targetStatus;task_id=$taskId;pointer_text=$pointer;existing=($null-ne$current)}
    }
    catch { $invalid += [ordered]@{reason='V1_RECORD_INVALID'} }
}

if ($invalid.Count -gt 0) {
    Write-MigrationReceipt -Scanned ($rows.Count + $invalid.Count) -Migrated 0 -Existing 0 -Invalid $invalid.Count
    exit 2
}

$migrated=0; $existing=@($rows | Where-Object { [bool]$_.existing }).Count
if ($Apply) {
    foreach ($row in $rows) {
        if ([bool]$row.existing) { continue }
        $state = New-TPV2State -SessionId ([string]$row.session_id) -Generation (New-TPV2Generation) -Revision 1 -Status ([string]$row.status) -TaskId $row.task_id -PointerText $row.pointer_text
        [void](Write-TPV2StateFile -StateRoot $v2 -SessionId ([string]$row.session_id) -State $state)
        $migrated++
    }
}
Write-MigrationReceipt -Scanned $rows.Count -Migrated $migrated -Existing $existing -Invalid 0
exit 0
