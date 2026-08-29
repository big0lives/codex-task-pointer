#requires -Version 7.5
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$homeRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-task-pointer-install-' + [guid]::NewGuid().ToString('N'))
$freshHomeRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-task-pointer-install-fresh-' + [guid]::NewGuid().ToString('N'))
$invalidUtf8HomeRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-task-pointer-install-invalid-utf8-' + [guid]::NewGuid().ToString('N'))
$invalidSchemaHomeRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-task-pointer-install-invalid-schema-' + [guid]::NewGuid().ToString('N'))
$collisionHomeRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-task-pointer-install-collision-' + [guid]::NewGuid().ToString('N'))
$hooksPath = Join-Path $homeRoot 'hooks.json'
$configPath = Join-Path $homeRoot 'config.toml'
$installer = Join-Path $repoRoot 'scripts\install.ps1'
$originalHooks = [ordered]@{
    hooks = [ordered]@{
        UserPromptSubmit = @([ordered]@{ hooks = @([ordered]@{ type = 'command'; command = 'pwsh -NoProfile -File C:\fixture\unrelated.ps1' }) })
    }
}
$originalHooksJson = ($originalHooks | ConvertTo-Json -Depth 20) + "`n"

try {
    New-Item -ItemType Directory -Path $homeRoot | Out-Null
    [IO.File]::WriteAllText($hooksPath, $originalHooksJson, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($configPath, "model = 'fixture-model'`n", [Text.UTF8Encoding]::new($false))

    $installOutput = @(& pwsh -NonInteractive -NoProfile -File $installer -CodexHome $homeRoot -Apply -Confirm:$false 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "install failed: $($installOutput -join ' ')" }
    $install = ($installOutput | Select-Object -Last 1) | ConvertFrom-Json
    if (-not $install.installed) { throw 'install receipt missing installed=true' }
    if (-not (Test-Path -LiteralPath (Join-Path $homeRoot 'task-pointer\src\task-pointer-store.ps1'))) { throw 'owned store missing' }
    $configAfterInstall = [IO.File]::ReadAllText($configPath)
    if ($configAfterInstall -ne "model = 'fixture-model'`n") { throw 'config changed during install' }
    $hooks = Get-Content -LiteralPath $hooksPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 30
    foreach ($eventName in @('PreCompact', 'SessionStart', 'UserPromptSubmit')) {
        if (-not $hooks.hooks.Contains($eventName)) { throw "missing hook group: $eventName" }
        $text = ($hooks.hooks[$eventName] | ConvertTo-Json -Depth 20 -Compress).Replace('/', '\').ToLowerInvariant()
        $expectedStateRoot = [IO.Path]::GetFullPath((Join-Path $homeRoot 'state\task-pointers\v2')).ToLowerInvariant()
        if ($text -notmatch 'task-pointer-lifecycle\.ps1' -or $text -notmatch [regex]::Escape($expectedStateRoot)) { throw "hook path/state root missing: $eventName text=$text expected=$expectedStateRoot" }
    }
    if (($hooks.hooks.UserPromptSubmit | ConvertTo-Json -Depth 20 -Compress) -notmatch 'unrelated\.ps1') { throw 'unrelated hook removed' }

    $backup = [string]$install.backup
    $rollbackOutput = @(& pwsh -NonInteractive -NoProfile -File $installer -CodexHome $homeRoot -Rollback -BackupPath $backup -Confirm:$false 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "rollback failed: $($rollbackOutput -join ' ')" }
    if (([IO.File]::ReadAllText($hooksPath)) -ne $originalHooksJson) {
        Write-Host ('ROLLBACK_CURRENT=' + [IO.File]::ReadAllText($hooksPath))
        Write-Host ('ROLLBACK_EXPECTED=' + $originalHooksJson)
        throw 'hooks rollback mismatch'
    }
    if (([IO.File]::ReadAllText($configPath)) -ne "model = 'fixture-model'`n") { throw 'config rollback mismatch' }
    if (Test-Path -LiteralPath (Join-Path $homeRoot 'task-pointer')) { throw 'owned directory remains after rollback' }

    New-Item -ItemType Directory -Path $freshHomeRoot | Out-Null
    $freshInstallOutput = @(& pwsh -NonInteractive -NoProfile -File $installer -CodexHome $freshHomeRoot -Apply -Confirm:$false 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "fresh install failed: $($freshInstallOutput -join ' ')" }
    $freshInstall = ($freshInstallOutput | Select-Object -Last 1) | ConvertFrom-Json
    $freshRollbackOutput = @(& pwsh -NonInteractive -NoProfile -File $installer -CodexHome $freshHomeRoot -Rollback -BackupPath ([string]$freshInstall.backup) -Confirm:$false 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "fresh rollback failed: $($freshRollbackOutput -join ' ')" }
    if (Test-Path -LiteralPath (Join-Path $freshHomeRoot 'task-pointer')) { throw 'fresh owned directory remains after rollback' }
    if (Test-Path -LiteralPath (Join-Path $freshHomeRoot 'hooks.json')) { throw 'fresh hooks.json remains after rollback' }

    New-Item -ItemType Directory -Path $invalidUtf8HomeRoot | Out-Null
    $invalidHooksPath = Join-Path $invalidUtf8HomeRoot 'hooks.json'
    $invalidBytes = [byte[]](0x7B,0x22,0x78,0x22,0x3A,0x22,0xC3,0x28,0x22,0x7D)
    [IO.File]::WriteAllBytes($invalidHooksPath, $invalidBytes)
    $invalidOutput = @(& pwsh -NonInteractive -NoProfile -File $installer -CodexHome $invalidUtf8HomeRoot -Apply -Confirm:$false 2>&1)
    if ($LASTEXITCODE -eq 0) { throw 'invalid UTF-8 hooks.json was accepted' }
    if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($invalidHooksPath)) -cne [Convert]::ToBase64String($invalidBytes)) { throw 'invalid UTF-8 hooks.json bytes changed' }
    if (Test-Path -LiteralPath (Join-Path $invalidUtf8HomeRoot 'task-pointer')) { throw 'invalid UTF-8 install left owned files' }

    New-Item -ItemType Directory -Path $invalidSchemaHomeRoot | Out-Null
    $invalidSchemaHooks = Join-Path $invalidSchemaHomeRoot 'hooks.json'
    $duplicateJson = '{"hooks":{},"other":{"value":1,"value":2}}'
    [IO.File]::WriteAllText($invalidSchemaHooks, $duplicateJson, [Text.UTF8Encoding]::new($false))
    $duplicateOutput = @(& pwsh -NonInteractive -NoProfile -File $installer -CodexHome $invalidSchemaHomeRoot -Apply -Confirm:$false 2>&1)
    if ($LASTEXITCODE -eq 0) { throw 'duplicate JSON property was accepted' }
    if ([IO.File]::ReadAllText($invalidSchemaHooks) -cne $duplicateJson) { throw 'duplicate JSON bytes changed' }
    $scalarJson = '{"hooks":"user-owned-value","other":"keep"}'
    [IO.File]::WriteAllText($invalidSchemaHooks, $scalarJson, [Text.UTF8Encoding]::new($false))
    $schemaOutput = @(& pwsh -NonInteractive -NoProfile -File $installer -CodexHome $invalidSchemaHomeRoot -Apply -Confirm:$false 2>&1)
    if ($LASTEXITCODE -eq 0) { throw 'non-object hooks value was accepted' }
    if ([IO.File]::ReadAllText($invalidSchemaHooks) -cne $scalarJson) { throw 'non-object hooks bytes changed' }

    $collisionPath = Join-Path $collisionHomeRoot 'task-pointer\src\task-pointer-store.ps1'
    New-Item -ItemType Directory -Path $collisionPath -Force | Out-Null
    $collisionOutput = @(& pwsh -NonInteractive -NoProfile -File $installer -CodexHome $collisionHomeRoot -Apply -Confirm:$false 2>&1)
    if ($LASTEXITCODE -eq 0) { throw 'owned destination directory collision was accepted' }
    if (-not (Test-Path -LiteralPath $collisionPath -PathType Container)) { throw 'owned destination collision directory changed' }
    if (@(Get-ChildItem -LiteralPath $collisionPath -Force).Count -ne 0) { throw 'owned destination collision received copied files' }

    [pscustomobject]@{ verdict = 'PASS'; install = $true; rollback = $true; fresh_install = $true; fresh_rollback = $true; invalid_utf8_rejected = $true; duplicate_json_rejected = $true; invalid_hook_schema_rejected = $true; destination_collision_rejected = $true; config_preserved = $true; unrelated_hook_preserved = $true }
}
finally {
    if (Test-Path -LiteralPath $homeRoot) { Remove-Item -LiteralPath $homeRoot -Recurse -Force }
    if (Test-Path -LiteralPath $freshHomeRoot) { Remove-Item -LiteralPath $freshHomeRoot -Recurse -Force }
    if (Test-Path -LiteralPath $invalidUtf8HomeRoot) { Remove-Item -LiteralPath $invalidUtf8HomeRoot -Recurse -Force }
    if (Test-Path -LiteralPath $invalidSchemaHomeRoot) { Remove-Item -LiteralPath $invalidSchemaHomeRoot -Recurse -Force }
    if (Test-Path -LiteralPath $collisionHomeRoot) { Remove-Item -LiteralPath $collisionHomeRoot -Recurse -Force }
}
