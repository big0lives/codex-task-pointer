#requires -Version 7.5
# 全量验证入口。app-server 检查（hooks/list 与 E2E）在隔离 CODEX_HOME 上执行前，
# 会先对本仓库的 install.ps1 -Apply 安装 Hook；E2E 还要求：
#   1. 目标 home 中的 Hook 已在宿主 /hooks 界面完成信任审阅（宿主安全门，无法自动化）；
#   2. 目标 home 具备可用的模型认证（E2E 会产生真实模型回合）。
# 不满足时请使用 -SkipAppServer 只跑静态/核心/安装门。
[CmdletBinding()]
param(
    [switch]$SkipAppServer,
    [string]$TempRoot,
    [string]$CodexHome,
    [string]$StateRoot,
    [string]$OutputRoot,
    [string]$AppServerCommand,
    [Alias('OutputPath')]
    [string]$ReceiptPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script:Utf8NoBom = [Text.UTF8Encoding]::new($false)
$script:Checks = [Collections.Generic.List[object]]::new()
$script:CleanupErrors = [Collections.Generic.List[object]]::new()
$script:CreatedPaths = [Collections.Generic.List[string]]::new()
$script:RunRoot = $null
$script:TempBoundary = $null
$script:RunId = [guid]::NewGuid().ToString('N')

function Get-NormalizedFullPath {
    param([Parameter(Mandatory)][string]$Path)
    return [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
}

function Test-PathInsideRoot {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RootPath
    )
    $full = Get-NormalizedFullPath $Path
    $root = Get-NormalizedFullPath $RootPath
    if ($full.Equals($root, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $full.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Get-TextSummary {
    param([AllowEmptyString()][string]$Text)
    $bytes = $script:Utf8NoBom.GetBytes($Text)
    return [ordered]@{
        byte_count = $bytes.Length
        sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    }
}

function New-OwnedDirectory {
    param([Parameter(Mandatory)][string]$Path)
    $full = Get-NormalizedFullPath $Path
    if (Test-Path -LiteralPath $full) {
        $item = Get-Item -LiteralPath $full -Force
        if (-not $item.PSIsContainer) { throw 'TEMP_PATH_NOT_DIRECTORY' }
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $null -ne $item.LinkType) { throw 'TEMP_PATH_REPARSE_POINT' }
        return $full
    }
    [IO.Directory]::CreateDirectory($full) | Out-Null
    $script:CreatedPaths.Add($full)
    return $full
}

function Add-Check {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][int]$ExitCode,
        [AllowEmptyString()][string]$Output,
        [ValidateSet('PASS', 'FAIL', 'SKIP')][string]$Verdict,
        [AllowNull()][string]$Reason = $null
    )
    $summary = Get-TextSummary $Output
    $check = [ordered]@{
        id = $Id
        exit_code = $ExitCode
        output_byte_count = $summary.byte_count
        output_sha256 = $summary.sha256
        verdict = $Verdict
    }
    if (-not [string]::IsNullOrWhiteSpace($Reason)) { $check['reason'] = $Reason }
    $script:Checks.Add([pscustomobject]$check)
    Write-Host ('CHECK id={0} verdict={1} exit={2}' -f $Id, $Verdict, $ExitCode)
}

function Invoke-CapturedProcess {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [AllowNull()][Collections.IDictionary]$Environment = $null
    )
    $stdoutPath = Join-Path $script:OutputRoot ($Id + '.out')
    $stderrPath = Join-Path $script:OutputRoot ($Id + '.err')
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $ArgumentList) { [void]$startInfo.ArgumentList.Add($argument) }
    if ($null -ne $Environment) {
        foreach ($key in $Environment.Keys) { $startInfo.Environment[[string]$key] = [string]$Environment[$key] }
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        [void]$process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        [IO.File]::WriteAllText($stdoutPath, $stdout, $script:Utf8NoBom)
        [IO.File]::WriteAllText($stderrPath, $stderr, $script:Utf8NoBom)
        $combined = $stdout + $stderr
        $code = $process.ExitCode
        Add-Check -Id $Id -ExitCode $code -Output $combined -Verdict $(if ($code -eq 0) { 'PASS' } else { 'FAIL' })
        return $code
    }
    catch {
        $summary = $_.Exception.GetType().FullName
        Add-Check -Id $Id -ExitCode 127 -Output $summary -Verdict 'FAIL' -Reason 'process-start-failed'
        return 127
    }
    finally { $process.Dispose() }
}

function Get-ResolvedAppServerCommand {
    param([AllowNull()][string]$Explicit)
    if (-not [string]::IsNullOrWhiteSpace($Explicit)) { return $Explicit.Trim() }
    $envValue = $env:CODEX_APP_SERVER_COMMAND
    if (-not [string]::IsNullOrWhiteSpace($envValue)) { return $envValue.Trim() }
    $fromPath = Get-Command codex.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $fromPath) { return ('"' + $fromPath.Source + '" app-server --listen stdio://') }
    $appData = [Environment]::GetFolderPath('ApplicationData')
    $candidates = @(
        (Join-Path $appData 'npm\node_modules\@openai\codex\node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\bin\codex.exe'),
        (Join-Path $appData 'npm\node_modules\@openai\codex\vendor\x86_64-pc-windows-msvc\bin\codex.exe')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return ('"' + $candidate + '" app-server --listen stdio://') }
    }
    return $null
}

function Invoke-StaticParserChecks {
    $errorIds = [Collections.Generic.List[string]]::new()
    $files = @(Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'src'), (Join-Path $script:RepoRoot 'scripts'), (Join-Path $script:RepoRoot 'tests') -File -Filter '*.ps1' | Sort-Object FullName)
    foreach ($file in $files) {
        $tokens = $null
        $errors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
        foreach ($error in @($errors)) { $errorIds.Add([string]$error.ErrorId) }
    }
    $output = 'files=' + $files.Count + ';errors=' + $errorIds.Count + ';ids=' + (($errorIds | Sort-Object -Unique) -join ',')
    Add-Check -Id 'powershell-parser' -ExitCode $(if ($errorIds.Count -eq 0) { 0 } else { 1 }) -Output $output -Verdict $(if ($errorIds.Count -eq 0) { 'PASS' } else { 'FAIL' })
}

function Invoke-JsonChecks {
    $failures = [Collections.Generic.List[string]]::new()
    $files = @(
        Join-Path $script:RepoRoot 'hooks\hooks.example.json'
        Join-Path $script:RepoRoot 'schemas\publish-request-v3.schema.json'
        Join-Path $script:RepoRoot 'schemas\state-v3.schema.json'
    )
    foreach ($file in $files) {
        try { $null = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 100 -ErrorAction Stop }
        catch { $failures.Add([IO.Path]::GetFileName($file)) }
    }
    $output = 'files=' + $files.Count + ';failures=' + $failures.Count + ';names=' + (($failures | Sort-Object) -join ',')
    Add-Check -Id 'json-parse' -ExitCode $(if ($failures.Count -eq 0) { 0 } else { 1 }) -Output $output -Verdict $(if ($failures.Count -eq 0) { 'PASS' } else { 'FAIL' })
}

function Remove-OwnedRunRoot {
    if ($null -eq $script:RunRoot -or -not (Test-Path -LiteralPath $script:RunRoot)) { return }
    try {
        $full = Get-NormalizedFullPath $script:RunRoot
        $boundary = Get-NormalizedFullPath $script:TempBoundary
        $systemTemp = Get-NormalizedFullPath ([IO.Path]::GetTempPath())
        $insideBoundary = Test-PathInsideRoot -Path $full -RootPath $boundary
        $insideSystemTemp = Test-PathInsideRoot -Path $full -RootPath $systemTemp
        $isNamedRun = [IO.Path]::GetFileName($full).StartsWith('codex-task-pointer-run-', [StringComparison]::Ordinal)
        $item = Get-Item -LiteralPath $full -Force
        $isReparse = (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or $null -ne $item.LinkType
        if (-not $insideBoundary -or -not $insideSystemTemp -or -not $isNamedRun -or $isReparse -or $full.Equals($boundary, [StringComparison]::OrdinalIgnoreCase) -or $full.Equals($systemTemp, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'UNSAFE_CLEANUP_TARGET'
        }
        Remove-Item -LiteralPath $full -Recurse -Force
    }
    catch {
        $script:CleanupErrors.Add([pscustomobject][ordered]@{
            operation = 'remove-run-root'
            error_type = $_.Exception.GetType().FullName
        })
    }
}

$startedAt = [DateTime]::UtcNow
$exitCode = 1
$script:OutputRoot = $null
$baseRoot = $null

try {
    $systemTemp = Get-NormalizedFullPath ([IO.Path]::GetTempPath())
    if ([string]::IsNullOrWhiteSpace($TempRoot)) {
        $script:RunRoot = Get-NormalizedFullPath (Join-Path $systemTemp ('codex-task-pointer-run-' + $script:RunId))
    }
    else {
        $script:RunRoot = Get-NormalizedFullPath $TempRoot
        if (-not (Test-PathInsideRoot -Path $script:RunRoot -RootPath $systemTemp)) { throw 'TEMP_ROOT_OUTSIDE_SYSTEM_TEMP' }
        if (-not [IO.Path]::GetFileName($script:RunRoot).StartsWith('codex-task-pointer-run-', [StringComparison]::Ordinal)) { throw 'TEMP_ROOT_PREFIX_INVALID' }
        if (Test-Path -LiteralPath $script:RunRoot) { throw 'TEMP_ROOT_ALREADY_EXISTS' }
    }
    $script:TempBoundary = $systemTemp
    $script:RunRoot = New-OwnedDirectory -Path $script:RunRoot

    $resolvedCodexHome = if ([string]::IsNullOrWhiteSpace($CodexHome)) { Join-Path $script:RunRoot 'codex-home' } else { Get-NormalizedFullPath $CodexHome }
    # install.ps1 固定把 Hook 的 -StateRoot 写为 <CODEX_HOME>\state\task-pointers\v2；
    # E2E 断言的状态根必须与之对齐，否则 Hook 写入与断言读取会落在两个目录。
    $installStateRoot = Join-Path $resolvedCodexHome 'state\task-pointers\v2'
    $resolvedStateRoot = if ([string]::IsNullOrWhiteSpace($StateRoot)) { $installStateRoot } else {
        $given = Get-NormalizedFullPath $StateRoot
        if (-not $given.Equals((Get-NormalizedFullPath $installStateRoot), [StringComparison]::OrdinalIgnoreCase)) { throw 'STATE_ROOT_MUST_MATCH_INSTALL_STATE_ROOT' }
        $given
    }
    $script:OutputRoot = if ([string]::IsNullOrWhiteSpace($OutputRoot)) { Join-Path $script:RunRoot 'reports' } else { Get-NormalizedFullPath $OutputRoot }
    foreach ($path in @($resolvedCodexHome, $resolvedStateRoot, $script:OutputRoot)) {
        if (-not (Test-PathInsideRoot -Path $path -RootPath $script:RunRoot)) { throw 'ISOLATED_PATH_OUTSIDE_RUN_ROOT' }
        [void](New-OwnedDirectory -Path $path)
    }
    $appCwd = New-OwnedDirectory -Path (Join-Path $script:RunRoot 'cwd')

    Invoke-StaticParserChecks
    Invoke-JsonChecks

    $pwsh = (Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $node = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $script:AppServerResolved = $null
    if (-not $SkipAppServer) {
        $script:AppServerResolved = Get-ResolvedAppServerCommand -Explicit $AppServerCommand
        Add-Check -Id 'app-server-command' -ExitCode $(if ($script:AppServerResolved) { 0 } else { 1 }) -Output $(if ($script:AppServerResolved) { 'resolved' } else { 'codex app-server executable not found; pass -AppServerCommand or set CODEX_APP_SERVER_COMMAND' }) -Verdict $(if ($script:AppServerResolved) { 'PASS' } else { 'FAIL' })
    }
    $environment = [ordered]@{ CODEX_HOME = $resolvedCodexHome }
    if ($script:AppServerResolved) { $environment['CODEX_APP_SERVER_COMMAND'] = $script:AppServerResolved }

    [void](Invoke-CapturedProcess -Id 'core-tests' -FilePath $pwsh -ArgumentList @('-NonInteractive', '-NoProfile', '-File', (Join-Path $script:RepoRoot 'tests\Test-TaskPointerLifecycle.ps1')) -WorkingDirectory $script:RepoRoot -Environment $environment)
    [void](Invoke-CapturedProcess -Id 'install-smoke' -FilePath $pwsh -ArgumentList @('-NonInteractive', '-NoProfile', '-File', (Join-Path $script:RepoRoot 'tests\install-smoke.ps1')) -WorkingDirectory $script:RepoRoot -Environment $environment)

    if ($null -eq $node) {
        Add-Check -Id 'node-syntax' -ExitCode 127 -Output 'node-unavailable' -Verdict 'FAIL' -Reason 'tool-unavailable'
    }
    else {
        foreach ($scriptFile in @(
            Join-Path $script:RepoRoot 'tests\app-server-hooks-list.mjs'
            Join-Path $script:RepoRoot 'tests\app-server-task-pointer-e2e.mjs'
        )) {
            $id = 'node-check-' + [IO.Path]::GetFileNameWithoutExtension($scriptFile)
            [void](Invoke-CapturedProcess -Id $id -FilePath $node.Source -ArgumentList @('--check', $scriptFile) -WorkingDirectory $script:RepoRoot)
        }
    }

    if ($SkipAppServer) {
        Add-Check -Id 'app-server-hooks-list' -ExitCode 0 -Output '' -Verdict 'SKIP' -Reason 'SkipAppServer'
        Add-Check -Id 'app-server-e2e' -ExitCode 0 -Output '' -Verdict 'SKIP' -Reason 'SkipAppServer'
    }
    elseif ($null -eq $node) {
        Add-Check -Id 'app-server-hooks-list' -ExitCode 127 -Output 'node-unavailable' -Verdict 'FAIL' -Reason 'tool-unavailable'
        Add-Check -Id 'app-server-e2e' -ExitCode 127 -Output 'node-unavailable' -Verdict 'FAIL' -Reason 'tool-unavailable'
    }
    else {
        # 隔离 home 初始为空；hooks/list 与 E2E 的断言都要求 Task Pointer Hook 已安装。
        [void](Invoke-CapturedProcess -Id 'install-app-home' -FilePath $pwsh -ArgumentList @('-NonInteractive', '-NoProfile', '-File', (Join-Path $script:RepoRoot 'scripts\install.ps1'), '-CodexHome', $resolvedCodexHome, '-Apply') -WorkingDirectory $script:RepoRoot -Environment $environment)

        $hooksReceipt = Join-Path $script:OutputRoot 'hooks-list.json'
        $hooksArguments = @((Join-Path $script:RepoRoot 'tests\app-server-hooks-list.mjs'), '--cwd', $appCwd, '--codex-home', $resolvedCodexHome, '--output', $hooksReceipt)
        if ($script:AppServerResolved) { $hooksArguments += @('--app-server-command', $script:AppServerResolved) }
        [void](Invoke-CapturedProcess -Id 'app-server-hooks-list' -FilePath $node.Source -ArgumentList $hooksArguments -WorkingDirectory $script:RepoRoot -Environment $environment)

        $e2eReceipt = Join-Path $script:OutputRoot 'app-server-e2e.json'
        $e2eArguments = @((Join-Path $script:RepoRoot 'tests\app-server-task-pointer-e2e.mjs'), '--cwd', $appCwd, '--codex-home', $resolvedCodexHome, '--state-root', $resolvedStateRoot, '--publisher', (Join-Path $script:RepoRoot 'src\task-pointer-publish.ps1'), '--output', $e2eReceipt, '--case', 'all')
        if ($script:AppServerResolved) { $e2eArguments += @('--app-server-command', $script:AppServerResolved) }
        [void](Invoke-CapturedProcess -Id 'app-server-e2e' -FilePath $node.Source -ArgumentList $e2eArguments -WorkingDirectory $script:RepoRoot -Environment $environment)
    }

    $validatorReceipt = Join-Path $script:OutputRoot 'public-tree.json'
    [void](Invoke-CapturedProcess -Id 'public-tree' -FilePath $pwsh -ArgumentList @('-NonInteractive', '-NoProfile', '-File', (Join-Path $script:RepoRoot 'scripts\validate-public-tree.ps1'), '-Root', $script:RepoRoot, '-OutputPath', $validatorReceipt) -WorkingDirectory $script:RepoRoot)
}
catch {
    Add-Check -Id 'run-all-internal' -ExitCode 2 -Output ($_.Exception.GetType().FullName + '|' + $_.Exception.Message) -Verdict 'FAIL' -Reason 'orchestration-failed'
}
finally {
    Remove-OwnedRunRoot
}

$failed = @($script:Checks | Where-Object verdict -ceq 'FAIL').Count
$passed = @($script:Checks | Where-Object verdict -ceq 'PASS').Count
$skipped = @($script:Checks | Where-Object verdict -ceq 'SKIP').Count
if ($failed -eq 0 -and $script:CleanupErrors.Count -eq 0) { $exitCode = 0 }
$receipt = [ordered]@{
    schema_version = 1
    runner = 'codex-task-pointer-run-all'
    generated_at = [DateTime]::UtcNow.ToString('o')
    duration_ms = [int64]([DateTime]::UtcNow - $startedAt).TotalMilliseconds
    skip_app_server = [bool]$SkipAppServer
    isolated = $true
    counts = [ordered]@{
        checks = $script:Checks.Count
        passed = $passed
        failed = $failed
        skipped = $skipped
        cleanup_errors = $script:CleanupErrors.Count
    }
    checks = @($script:Checks)
    cleanup = [ordered]@{
        run_root_removed = $null -ne $script:RunRoot -and -not (Test-Path -LiteralPath $script:RunRoot)
        errors = @($script:CleanupErrors)
    }
    verdict = if ($exitCode -eq 0) { 'PASS' } else { 'FAIL' }
}
$json = $receipt | ConvertTo-Json -Compress -Depth 20
if (-not [string]::IsNullOrWhiteSpace($ReceiptPath)) {
    $receiptFull = [IO.Path]::GetFullPath($ReceiptPath)
    $receiptParent = Split-Path -Parent $receiptFull
    if (-not (Test-Path -LiteralPath $receiptParent -PathType Container)) { [IO.Directory]::CreateDirectory($receiptParent) | Out-Null }
    [IO.File]::WriteAllText($receiptFull, $json + "`n", $script:Utf8NoBom)
}
Write-Output $json
exit $exitCode
