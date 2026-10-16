#requires -Version 7.5
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [string]$CodexHome,
    [switch]$Apply,
    [switch]$Rollback,
    [string]$BackupPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:OwnedCopies = @(
    [ordered]@{ source = 'src\task-pointer-store.ps1'; destination = 'src\task-pointer-store.ps1' },
    [ordered]@{ source = 'src\task-pointer-lifecycle.ps1'; destination = 'src\task-pointer-lifecycle.ps1' },
    [ordered]@{ source = 'src\task-pointer-publish.ps1'; destination = 'src\task-pointer-publish.ps1' },
    [ordered]@{ source = 'src\task-pointer-report.ps1'; destination = 'src\task-pointer-report.ps1' },
    [ordered]@{ source = 'scripts\migrate-v1-to-v3.ps1'; destination = 'scripts\migrate-v1-to-v3.ps1' },
    [ordered]@{ source = 'schemas\state-v3.schema.json'; destination = 'schemas\state-v3.schema.json' },
    [ordered]@{ source = 'schemas\publish-request-v3.schema.json'; destination = 'schemas\publish-request-v3.schema.json' },
    [ordered]@{ source = 'hooks\hooks.example.json'; destination = 'hooks.example.json' }
)
$script:OwnedFiles = @($script:OwnedCopies | ForEach-Object { [string]$_.destination })
$script:StrictUtf8 = [Text.UTF8Encoding]::new($false, $true)

function Get-FullPath {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $full = [IO.Path]::GetFullPath($Path)
        $root = [IO.Path]::GetPathRoot($full)
        if ($full.Length -gt $root.Length) { return $full.TrimEnd('\') }
        return $root
    }
    catch { throw 'PATH_INVALID' }
}

function Resolve-CodexHome {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { $Value = [Environment]::GetEnvironmentVariable('CODEX_HOME') }
    if ([string]::IsNullOrWhiteSpace($Value)) { $Value = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex' }
    return Get-FullPath $Value
}

function Test-SamePath {
    param([Parameter(Mandatory)][string]$Left, [Parameter(Mandatory)][string]$Right)
    return (Get-FullPath $Left).Equals((Get-FullPath $Right), [StringComparison]::OrdinalIgnoreCase)
}

function Test-Key {
    param([object]$Value, [string]$Key)
    return $Value -is [System.Collections.IDictionary] -and $Value.Contains($Key)
}

function Assert-PathUnder {
    param([Parameter(Mandatory)][string]$Child, [Parameter(Mandatory)][string]$Parent, [string]$Code = 'PATH_ESCAPE')
    $childFull = Get-FullPath $Child
    $parentFull = Get-FullPath $Parent
    if (-not (Test-SamePath $childFull $parentFull) -and -not (($childFull + '\').StartsWith($parentFull.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase))) {
        throw "$Code|$childFull"
    }
}

function Assert-NoUnexpectedReparse {
    param([Parameter(Mandatory)][string]$Path, [AllowNull()][string]$AllowRoot = $null)
    $full = Get-FullPath $Path
    $allow = if ([string]::IsNullOrWhiteSpace($AllowRoot)) { $null } else { Get-FullPath $AllowRoot }
    $volume = [IO.Path]::GetPathRoot($full)
    $current = $volume.TrimEnd('\')
    $relative = $full.Substring($volume.Length)
    foreach ($segment in $relative.Split('\', [StringSplitOptions]::RemoveEmptyEntries)) {
        $current = if ([string]::IsNullOrEmpty($current)) { $segment } else { Join-Path $current $segment }
        if (-not [IO.File]::Exists($current) -and -not [IO.Directory]::Exists($current)) { continue }
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            if ($null -eq $allow -or -not (Test-SamePath $current $allow)) { throw "PATH_REPARSE_POINT|$current" }
        }
    }
}

function Read-JsonObject {
    param([Parameter(Mandatory)][string]$Path)
    try { $bytes = [IO.File]::ReadAllBytes($Path) }
    catch { throw "JSON_READ_FAILED|$Path" }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        throw "JSON_ENCODING_INVALID|$Path"
    }
    try { $text = $script:StrictUtf8.GetString($bytes) }
    catch { throw "JSON_ENCODING_INVALID|$Path" }
    try { $document = [Text.Json.JsonDocument]::Parse($text) }
    catch { throw "JSON_PARSE_FAILED|$Path" }
    try {
        if ($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object) { throw "JSON_ROOT_INVALID|$Path" }
        try { Assert-NoDuplicateJsonProperties -Element $document.RootElement }
        catch { throw "JSON_DUPLICATE_FIELD|$Path" }
    }
    finally { $document.Dispose() }
    try { $value = $text | ConvertFrom-Json -AsHashtable -Depth 50 -DateKind String }
    catch { throw "JSON_PARSE_FAILED|$Path" }
    if ($value -isnot [System.Collections.IDictionary]) { throw "JSON_ROOT_INVALID|$Path" }
    return $value
}

function Assert-NoDuplicateJsonProperties {
    param([Parameter(Mandatory)][Text.Json.JsonElement]$Element)
    if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($property in $Element.EnumerateObject()) {
            if (-not $names.Add($property.Name)) { throw 'JSON_DUPLICATE_FIELD' }
            Assert-NoDuplicateJsonProperties -Element $property.Value
        }
        return
    }
    if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
        foreach ($item in $Element.EnumerateArray()) { Assert-NoDuplicateJsonProperties -Element $item }
    }
}

function ConvertTo-CanonicalValue {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        $ordered = [ordered]@{}
        foreach ($key in @($Value.Keys | ForEach-Object { [string]$_ } | Sort-Object)) {
            $ordered[$key] = ConvertTo-CanonicalValue $Value[$key]
        }
        return $ordered
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        return @($Value | ForEach-Object { ConvertTo-CanonicalValue $_ })
    }
    return $Value
}

function Get-CanonicalJson {
    param([AllowNull()][object]$Value)
    return (ConvertTo-CanonicalValue $Value | ConvertTo-Json -Compress -Depth 50)
}

function Test-EquivalentJson {
    param([AllowNull()][object]$Left, [AllowNull()][object]$Right)
    return (Get-CanonicalJson $Left) -ceq (Get-CanonicalJson $Right)
}

function Write-JsonObject {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][System.Collections.IDictionary]$Value)
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    Assert-NoUnexpectedReparse -Path $parent
    $temp = Join-Path $parent ('.' + [IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 50) + "`n")
    try {
        $stream = [IO.FileStream]::new($temp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $item = Get-Item -LiteralPath $Path -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "PATH_REPARSE_POINT|$Path" }
            [IO.File]::Move($temp, $Path, $true)
        }
        else { [IO.File]::Move($temp, $Path) }
        $readback = Read-JsonObject $Path
        if (-not (Test-EquivalentJson $Value $readback)) { throw "JSON_READBACK_FAILED|$Path" }
    }
    finally { if (Test-Path -LiteralPath $temp -PathType Leaf) { Remove-Item -LiteralPath $temp -Force } }
}

function Get-CommandFilePath {
    param([AllowNull()][string]$Command)
    if ([string]::IsNullOrWhiteSpace($Command)) { return $null }
    $match = [regex]::Match($Command, '(?i)-File\s+"([^"]+)"')
    if (-not $match.Success) { $match = [regex]::Match($Command, '(?i)-File\s+([^\s]+)') }
    if (-not $match.Success) { return $null }
    try { return Get-FullPath ($match.Groups[1].Value.Replace('/', '\')) } catch { return $null }
}

function Get-CommandStateRoot {
    param([AllowNull()][string]$Command)
    if ([string]::IsNullOrWhiteSpace($Command)) { return $null }
    $match = [regex]::Match($Command, '(?i)-StateRoot\s+"([^"]+)"')
    if (-not $match.Success) { $match = [regex]::Match($Command, '(?i)-StateRoot\s+([^\s]+)') }
    if (-not $match.Success) { return $null }
    try { return Get-FullPath ($match.Groups[1].Value.Replace('/', '\')) } catch { return $null }
}

function Test-TaskPointerHookHandler {
    param([AllowNull()][object]$Handler, [Parameter(Mandatory)][string]$LifecyclePath, [Parameter(Mandatory)][string]$StateRoot)
    if ($Handler -isnot [System.Collections.IDictionary]) { return $false }
    if ((Test-Key $Handler 'type') -and ([string]$Handler['type'] -cne 'command')) { return $false }
    $expectedLifecycle = Get-FullPath $LifecyclePath
    $expectedState = Get-FullPath $StateRoot
    foreach ($key in @('command', 'commandWindows')) {
        if (-not (Test-Key $Handler $key)) { continue }
        $command = [string]$Handler[$key]
        $actualLifecycle = Get-CommandFilePath $command
        $actualState = Get-CommandStateRoot $command
        if ($null -ne $actualLifecycle -and $null -ne $actualState -and $actualLifecycle.Equals($expectedLifecycle, [StringComparison]::OrdinalIgnoreCase) -and $actualState.Equals($expectedState, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Copy-EntryWithHandlers {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Entry, [Parameter(Mandatory)][object[]]$Handlers)
    $copy = [ordered]@{}
    foreach ($key in $Entry.Keys) { if ([string]$key -cne 'hooks') { $copy[[string]$key] = $Entry[$key] } }
    $copy['hooks'] = @($Handlers)
    return $copy
}

function New-TaskPointerHookDefinition {
    param([Parameter(Mandatory)][string]$LifecyclePath, [Parameter(Mandatory)][string]$StateRoot, [Parameter(Mandatory)][string]$EventName)
    $windows = 'pwsh -NoProfile -File "' + $LifecyclePath + '" -StateRoot "' + $StateRoot + '"'
    $portable = 'pwsh -NoProfile -File "' + $LifecyclePath.Replace('\', '/') + '" -StateRoot "' + $StateRoot.Replace('\', '/') + '"'
    $handler = [ordered]@{ type = 'command'; command = $portable; commandWindows = $windows; timeout = 15 }
    if ($EventName -ceq 'SessionStart') { $handler['statusMessage'] = 'Restoring task pointer'; $handler['additionalContextLimit'] = 0 }
    $matcher = switch ($EventName) {
        'PreCompact' { '^(manual|auto)$' }
        'SessionStart' { '^(startup|resume|clear|compact)$' }
        default { $null }
    }
    $entry = [ordered]@{ hooks = @($handler) }
    if ($null -ne $matcher) { $entry = [ordered]@{ matcher = $matcher; hooks = @($handler) } }
    return [ordered]@{ event = $EventName; handler = $handler; entry = $entry }
}

function Merge-TaskPointerHooks {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Document, [Parameter(Mandatory)][string]$LifecyclePath, [Parameter(Mandatory)][string]$StateRoot)
    if (-not (Test-Key $Document 'hooks')) { $Document['hooks'] = [ordered]@{} }
    elseif ($Document['hooks'] -isnot [System.Collections.IDictionary]) { throw 'HOOKS_SCHEMA_INVALID' }
    $hooks = $Document['hooks']
    $definitions = @()
    foreach ($eventName in @('PreCompact', 'SessionStart', 'UserPromptSubmit')) {
        $existing = if (Test-Key $hooks $eventName) { @($hooks[$eventName]) } else { @() }
        $keptEntries = @()
        foreach ($entry in $existing) {
            if ($entry -isnot [System.Collections.IDictionary] -or -not (Test-Key $entry 'hooks')) { $keptEntries += $entry; continue }
            $keptHandlers = @(@($entry['hooks']) | Where-Object { -not (Test-TaskPointerHookHandler $_ $LifecyclePath $StateRoot) })
            if ($keptHandlers.Count -gt 0) { $keptEntries += (Copy-EntryWithHandlers -Entry $entry -Handlers $keptHandlers) }
        }
        $definition = New-TaskPointerHookDefinition -LifecyclePath $LifecyclePath -StateRoot $StateRoot -EventName $eventName
        $hooks[$eventName] = @($keptEntries + $definition.entry)
        $definitions += [ordered]@{ event = $eventName; lifecycle_path = (Get-FullPath $LifecyclePath); state_root = (Get-FullPath $StateRoot); handler = $definition.handler }
    }
    return [ordered]@{ document = $Document; installations = @($definitions) }
}

function Assert-BackupTarget {
    param([Parameter(Mandatory)][string]$BackupRoot, [Parameter(Mandatory)][string]$CodexHome, [Parameter(Mandatory)][string]$OwnedRoot, [Parameter(Mandatory)][string]$HooksPath)
    $backup = Get-FullPath $BackupRoot
    if ((Test-SamePath $backup $CodexHome) -or (Test-SamePath $backup $OwnedRoot) -or (Test-SamePath $backup $HooksPath)) { throw "BACKUP_TARGET_CONFLICT|$backup" }
    foreach ($target in @($OwnedRoot, $HooksPath)) {
        $targetFull = Get-FullPath $target
        $backupContainsTarget = (($targetFull + '\').StartsWith($backup.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase))
        $targetContainsBackup = (($backup + '\').StartsWith($targetFull.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase))
        if ($backupContainsTarget -or $targetContainsBackup) { throw "BACKUP_TARGET_CONFLICT|$backup" }
    }
    $parent = Split-Path -Parent $backup
    if (Test-Path -LiteralPath $parent) { Assert-NoUnexpectedReparse -Path $parent -AllowRoot $CodexHome }
}

function Save-Backup {
    param([Parameter(Mandatory)][string]$CodexHome, [Parameter(Mandatory)][string]$OwnedRoot, [Parameter(Mandatory)][string]$HooksPath, [Parameter(Mandatory)][string]$BackupRoot, [Parameter(Mandatory)][object[]]$Installations)
    Assert-BackupTarget -BackupRoot $BackupRoot -CodexHome $CodexHome -OwnedRoot $OwnedRoot -HooksPath $HooksPath
    if (Test-Path -LiteralPath $BackupRoot) {
        if (@(Get-ChildItem -LiteralPath $BackupRoot -Force).Count -gt 0) { throw "BACKUP_ALREADY_EXISTS|$BackupRoot" }
    }
    New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null
    Assert-NoUnexpectedReparse -Path $BackupRoot -AllowRoot $CodexHome
    $ownedItem = Get-Item -LiteralPath $OwnedRoot -Force -ErrorAction SilentlyContinue
    $hooksItem = Get-Item -LiteralPath $HooksPath -Force -ErrorAction SilentlyContinue
    if ($ownedItem -and -not ($ownedItem.PSIsContainer)) { throw 'OWNED_ROOT_INVALID' }
    if ($hooksItem -and $hooksItem.PSIsContainer) { throw 'HOOKS_PATH_INVALID' }
    $ownedExists = $null -ne $ownedItem
    $hookExists = $null -ne $hooksItem
    $manifest = [ordered]@{ schema_version = 2; created_at = [DateTime]::UtcNow.ToString('o'); codex_home = $CodexHome; owned_root = $OwnedRoot; hooks_json_existed = $hookExists; owned_root_existed = $ownedExists; owned_files = @($script:OwnedFiles); hook_installations = @($Installations) }
    if ($hookExists) {
        Assert-NoUnexpectedReparse -Path $HooksPath -AllowRoot $CodexHome
        $before = Read-JsonObject $HooksPath
        if ((Test-Key $before 'hooks') -and ($before['hooks'] -is [System.Collections.IDictionary])) { $manifest['existing_hook_events'] = @($before['hooks'].Keys | ForEach-Object { [string]$_ }) }
        Copy-Item -LiteralPath $HooksPath -Destination (Join-Path $BackupRoot 'hooks.json') -Force
    }
    else { $manifest['existing_hook_events'] = @() }
    if ($ownedExists) {
        Assert-NoUnexpectedReparse -Path $OwnedRoot -AllowRoot $CodexHome
        foreach ($relative in $script:OwnedFiles) {
            $sourceFile = Join-Path $OwnedRoot $relative
            if (Test-Path -LiteralPath $sourceFile -PathType Leaf) {
                Assert-NoUnexpectedReparse -Path $sourceFile -AllowRoot $CodexHome
                $backupFile = Join-Path (Join-Path $BackupRoot 'task-pointer') $relative
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $backupFile) | Out-Null
                Copy-Item -LiteralPath $sourceFile -Destination $backupFile -Force
            }
        }
    }
    Write-JsonObject -Path (Join-Path $BackupRoot 'manifest.json') -Value $manifest
    return $manifest
}

function Assert-Manifest {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Manifest, [Parameter(Mandatory)][string]$CodexHome, [Parameter(Mandatory)][string]$OwnedRoot)
    if (-not (Test-Key $Manifest 'schema_version') -or $Manifest.schema_version -isnot [int] -and $Manifest.schema_version -isnot [long] -or [int]$Manifest.schema_version -ne 2) { throw 'BACKUP_MANIFEST_INVALID' }
    if (-not (Test-Key $Manifest 'codex_home') -or $Manifest.codex_home -isnot [string] -or -not (Test-SamePath ([string]$Manifest.codex_home) $CodexHome)) { throw 'BACKUP_HOME_MISMATCH' }
    if (-not (Test-Key $Manifest 'owned_root') -or $Manifest.owned_root -isnot [string] -or -not (Test-SamePath ([string]$Manifest.owned_root) $OwnedRoot)) { throw 'BACKUP_ROOT_MISMATCH' }
    if (-not (Test-Key $Manifest 'hooks_json_existed') -or $Manifest.hooks_json_existed -isnot [bool]) { throw 'BACKUP_HOOKS_FLAG_INVALID' }
    if (-not (Test-Key $Manifest 'owned_root_existed') -or $Manifest.owned_root_existed -isnot [bool]) { throw 'BACKUP_OWNED_FLAG_INVALID' }
    if (-not (Test-Key $Manifest 'existing_hook_events') -or $Manifest.existing_hook_events -isnot [System.Collections.IEnumerable] -or $Manifest.existing_hook_events -is [string]) { throw 'BACKUP_EVENTS_INVALID' }
    $actual = @($Manifest.owned_files | ForEach-Object { [string]$_ } | Sort-Object)
    $expected = @($script:OwnedFiles | Sort-Object)
    if (($actual -join "`0") -cne ($expected -join "`0")) { throw 'BACKUP_OWNED_FILES_INVALID' }
    if (-not (Test-Key $Manifest 'hook_installations') -or $Manifest.hook_installations -is [string] -or @($Manifest.hook_installations).Count -ne 3) { throw 'BACKUP_HOOK_INSTALLATIONS_INVALID' }
    foreach ($installation in @($Manifest.hook_installations)) {
        if ($installation -isnot [System.Collections.IDictionary]) { throw 'BACKUP_HOOK_INSTALLATION_INVALID' }
        if (-not (Test-Key $installation 'event') -or [string]$installation.event -cnotin @('PreCompact','SessionStart','UserPromptSubmit')) { throw 'BACKUP_HOOK_EVENT_INVALID' }
        if (-not (Test-Key $installation 'lifecycle_path') -or $installation.lifecycle_path -isnot [string]) { throw 'BACKUP_HOOK_PATH_INVALID' }
        if (-not (Test-Key $installation 'state_root') -or $installation.state_root -isnot [string]) { throw 'BACKUP_STATE_PATH_INVALID' }
        if (-not (Test-Key $installation 'handler') -or $installation.handler -isnot [System.Collections.IDictionary]) { throw 'BACKUP_HANDLER_INVALID' }
        if (-not (Test-Key $installation.handler 'type') -or [string]$installation.handler.type -cne 'command') { throw 'BACKUP_HANDLER_INVALID' }
    }
    foreach ($relative in $actual) {
        if ([IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[\\/])\.\.([\\/]|$)') { throw 'BACKUP_RELATIVE_PATH_INVALID' }
    }
}

function Remove-InstalledHandlers {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Document, [Parameter(Mandatory)][object[]]$Installations)
    if (-not (Test-Key $Document 'hooks') -or $Document['hooks'] -isnot [System.Collections.IDictionary]) { return $Document }
    $hooks = $Document['hooks']
    foreach ($installation in $Installations) {
        $eventName = [string]$installation.event
        $lifecycle = [string]$installation.lifecycle_path
        $stateRoot = [string]$installation.state_root
        if (-not (Test-Key $hooks $eventName)) { continue }
        $remainingEntries = @()
        foreach ($entry in @($hooks[$eventName])) {
            if ($entry -isnot [System.Collections.IDictionary] -or -not (Test-Key $entry 'hooks')) { $remainingEntries += $entry; continue }
            $remainingHandlers = @(@($entry['hooks']) | Where-Object { -not (Test-TaskPointerHookHandler $_ $lifecycle $stateRoot) })
            if ($remainingHandlers.Count -gt 0) { $remainingEntries += (Copy-EntryWithHandlers -Entry $entry -Handlers $remainingHandlers) }
        }
        if ($remainingEntries.Count -gt 0) { $hooks[$eventName] = @($remainingEntries) } else { $hooks.Remove($eventName) }
    }
    if ($hooks.Count -eq 0) { $Document.Remove('hooks') }
    return $Document
}

function Restore-Backup {
    param([Parameter(Mandatory)][string]$BackupRoot, [Parameter(Mandatory)][string]$ExpectedCodexHome)
    $backup = Get-FullPath $BackupRoot
    Assert-NoUnexpectedReparse -Path $backup
    $manifestPath = Join-Path $backup 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'BACKUP_MANIFEST_MISSING' }
    $manifest = Read-JsonObject $manifestPath
    $codexHomeResolved = Resolve-CodexHome $ExpectedCodexHome
    $owned = Join-Path $codexHomeResolved 'task-pointer'
    Assert-Manifest -Manifest $manifest -CodexHome $codexHomeResolved -OwnedRoot $owned
    $hooksPath = Join-Path $codexHomeResolved 'hooks.json'
    $backupHooks = Join-Path $backup 'hooks.json'
    $originalHooks = if ([bool]$manifest.hooks_json_existed) { if (-not (Test-Path -LiteralPath $backupHooks -PathType Leaf)) { throw 'BACKUP_HOOKS_MISSING' }; Read-JsonObject $backupHooks } else { $null }
    $currentHooksExists = Test-Path -LiteralPath $hooksPath -PathType Leaf
    if (Test-Path -LiteralPath $hooksPath -PathType Container) { throw 'HOOKS_PATH_INVALID' }
    if ($currentHooksExists) {
        Assert-NoUnexpectedReparse -Path $hooksPath -AllowRoot $codexHomeResolved
        $currentHooks = Read-JsonObject $hooksPath
        $filtered = Remove-InstalledHandlers -Document $currentHooks -Installations @($manifest.hook_installations)
        if ($null -ne $originalHooks -and (Test-EquivalentJson $filtered $originalHooks)) { Copy-Item -LiteralPath $backupHooks -Destination $hooksPath -Force }
        elseif ($null -eq $originalHooks -and $filtered.Count -eq 0) { Remove-Item -LiteralPath $hooksPath -Force }
        else { Write-JsonObject -Path $hooksPath -Value $filtered }
    }
    elseif ($null -ne $originalHooks) {
        Assert-NoUnexpectedReparse -Path (Split-Path -Parent $hooksPath) -AllowRoot $codexHomeResolved
        Copy-Item -LiteralPath $backupHooks -Destination $hooksPath -Force
    }
    $backupOwned = Join-Path $backup 'task-pointer'
    foreach ($relative in $script:OwnedFiles) {
        $targetFile = Join-Path $owned $relative
        $backupFile = Join-Path $backupOwned $relative
        if (Test-Path -LiteralPath $backupFile -PathType Leaf) {
            Assert-NoUnexpectedReparse -Path (Split-Path -Parent $targetFile) -AllowRoot $codexHomeResolved
            if (Test-Path -LiteralPath $targetFile -PathType Leaf) { Assert-NoUnexpectedReparse -Path $targetFile -AllowRoot $codexHomeResolved }
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $targetFile) | Out-Null
            Copy-Item -LiteralPath $backupFile -Destination $targetFile -Force
        }
        elseif (Test-Path -LiteralPath $targetFile -PathType Leaf) {
            Assert-NoUnexpectedReparse -Path $targetFile -AllowRoot $codexHomeResolved
            Remove-Item -LiteralPath $targetFile -Force
        }
    }
    if (-not [bool]$manifest.owned_root_existed -and (Test-Path -LiteralPath $owned -PathType Container)) {
        Assert-NoUnexpectedReparse -Path $owned -AllowRoot $codexHomeResolved
        Get-ChildItem -LiteralPath $owned -Directory -Recurse -Force | Sort-Object FullName -Descending | ForEach-Object { if (@(Get-ChildItem -LiteralPath $_.FullName -Force).Count -eq 0) { Remove-Item -LiteralPath $_.FullName -Force } }
        if (@(Get-ChildItem -LiteralPath $owned -Force).Count -eq 0) { Remove-Item -LiteralPath $owned -Force }
    }
    return [pscustomobject]@{ restored = $true; codex_home = $codexHomeResolved; owned_root = $owned; backup = $backup }
}

if ($Apply -and $Rollback) { throw 'APPLY_ROLLBACK_CONFLICT' }
$codexHomeResolved = Resolve-CodexHome $CodexHome
$sourceRoot = Get-FullPath (Join-Path $PSScriptRoot '..')
$ownedRoot = Join-Path $codexHomeResolved 'task-pointer'
$hooksPath = Join-Path $codexHomeResolved 'hooks.json'
$lifecyclePath = Join-Path $ownedRoot 'src\task-pointer-lifecycle.ps1'
$stateRoot = Join-Path $codexHomeResolved 'state\task-pointers\v2'

if ($Rollback) {
    if ([string]::IsNullOrWhiteSpace($BackupPath)) { throw 'ROLLBACK_BACKUP_REQUIRED' }
    if ($PSCmdlet.ShouldProcess($codexHomeResolved, 'restore Task Pointer installation')) { Restore-Backup -BackupRoot $BackupPath -ExpectedCodexHome $codexHomeResolved | ConvertTo-Json -Compress }
    exit 0
}

$backupRoot = if ([string]::IsNullOrWhiteSpace($BackupPath)) { Join-Path $codexHomeResolved ('task-pointer-install-backups\' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [guid]::NewGuid().ToString('N')) } else { Get-FullPath $BackupPath }
if (-not $Apply) {
    [pscustomobject]@{ mode = 'PLAN'; codex_home = $codexHomeResolved; owned_root = $ownedRoot; hooks_json = $hooksPath; backup = $backupRoot; source = $sourceRoot; actions = @('copy owned runtime files', 'merge three Task Pointer hook groups', 'write install manifest', 'review and trust hooks in Codex /hooks') } | ConvertTo-Json -Depth 5
    exit 0
}

if ($PSCmdlet.ShouldProcess($codexHomeResolved, 'install Task Pointer v2')) {
    Assert-NoUnexpectedReparse -Path $codexHomeResolved -AllowRoot $codexHomeResolved
    $ownedItem = Get-Item -LiteralPath $ownedRoot -Force -ErrorAction SilentlyContinue
    $hooksItem = Get-Item -LiteralPath $hooksPath -Force -ErrorAction SilentlyContinue
    if ($ownedItem -and (($ownedItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw "PATH_REPARSE_POINT|$ownedRoot" }
    if ($hooksItem -and (($hooksItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw "PATH_REPARSE_POINT|$hooksPath" }
    $definitions = @('PreCompact', 'SessionStart', 'UserPromptSubmit') | ForEach-Object { New-TaskPointerHookDefinition -LifecyclePath $lifecyclePath -StateRoot $stateRoot -EventName $_ }
    $installations = @($definitions | ForEach-Object { [ordered]@{ event = $_.event; lifecycle_path = (Get-FullPath $lifecyclePath); state_root = (Get-FullPath $stateRoot); handler = $_.handler } })
    $null = Save-Backup -CodexHome $codexHomeResolved -OwnedRoot $ownedRoot -HooksPath $hooksPath -BackupRoot $backupRoot -Installations $installations
    try {
        foreach ($copy in $script:OwnedCopies) {
            $source = Join-Path $sourceRoot ([string]$copy.source)
            $destination = Join-Path $ownedRoot ([string]$copy.destination)
            if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "SOURCE_MISSING|$($copy.source)" }
            $destinationItem = Get-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
            if ($destinationItem -and ($destinationItem.PSIsContainer -or ($destinationItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
                throw "DESTINATION_INVALID|$($copy.destination)"
            }
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
            Assert-NoUnexpectedReparse -Path (Split-Path -Parent $destination) -AllowRoot $codexHomeResolved
            if (Test-Path -LiteralPath $destination -PathType Leaf) { Assert-NoUnexpectedReparse -Path $destination -AllowRoot $codexHomeResolved }
            Copy-Item -LiteralPath $source -Destination $destination -Force
        }
        $document = if (Test-Path -LiteralPath $hooksPath -PathType Leaf) { Read-JsonObject $hooksPath } else { [ordered]@{} }
        $merged = Merge-TaskPointerHooks -Document $document -LifecyclePath $lifecyclePath -StateRoot $stateRoot
        Write-JsonObject -Path $hooksPath -Value $merged.document
    }
    catch {
        $original = $_
        try { Restore-Backup -BackupRoot $backupRoot -ExpectedCodexHome $codexHomeResolved | Out-Null }
        catch { throw "INSTALL_AND_ROLLBACK_FAILED|$($_.Exception.Message)" }
        throw $original
    }
    [pscustomobject]@{ installed = $true; codex_home = $codexHomeResolved; owned_root = $ownedRoot; hooks_json = $hooksPath; backup = $backupRoot; hook_events = @('PreCompact', 'SessionStart', 'UserPromptSubmit'); trust_required = $true } | ConvertTo-Json -Compress
}
