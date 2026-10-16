#requires -Version 7.5
[CmdletBinding()]
param(
    [string]$Root,
    [string]$OutputPath,
    [ValidateRange(1024, 1073741824)]
    [long]$MaxFileBytes = 1048576
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Utf8NoBom = [Text.UTF8Encoding]::new($false)
$script:StrictUtf8 = [Text.UTF8Encoding]::new($false, $true)
$script:Findings = [Collections.Generic.List[object]]::new()
$script:RootPath = $null

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
    $rootFull = Get-NormalizedFullPath $RootPath
    if ($full.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $full.StartsWith($rootFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Get-RelativePublicPath {
    param([Parameter(Mandatory)][string]$Path)
    if ($null -eq $script:RootPath) { return '<root>' }
    try {
        $relative = [IO.Path]::GetRelativePath($script:RootPath, (Get-NormalizedFullPath $Path)).Replace('\', '/')
        return [regex]::Replace($relative, '[\x00-\x1f\x7f]', '?')
    }
    catch { return '<invalid-path>' }
}

function Get-TextDigest {
    param([AllowEmptyString()][string]$Text)
    $bytes = $script:Utf8NoBom.GetBytes($Text)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Add-Finding {
    param(
        [Parameter(Mandatory)][string]$RuleId,
        [Parameter(Mandatory)][string]$Path,
        [ValidateRange(1, [int]::MaxValue)][int]$Count = 1,
        [ValidateSet('error', 'warning')][string]$Severity = 'error',
        [AllowNull()][string]$DetailDigest = $null
    )
    $finding = [ordered]@{
        rule_id = $RuleId
        path = if ($Path -match '^<[^>]+>$') { $Path } else { Get-RelativePublicPath $Path }
        count = $Count
        severity = $Severity
    }
    if (-not [string]::IsNullOrWhiteSpace($DetailDigest)) { $finding['detail_sha256'] = $DetailDigest }
    $script:Findings.Add([pscustomobject]$finding)
}

function Get-PublicTreeItems {
    param([Parameter(Mandatory)][string]$RootPath)
    $files = [Collections.Generic.List[IO.FileInfo]]::new()
    $directories = [Collections.Generic.List[IO.DirectoryInfo]]::new()
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($RootPath)

    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        try { $children = @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop) }
        catch {
            Add-Finding -RuleId 'TREE_ENUMERATION' -Path $directory -DetailDigest (Get-TextDigest $_.Exception.GetType().FullName)
            continue
        }
        foreach ($child in $children) {
            $relative = Get-RelativePublicPath $child.FullName
            if ($relative -in @('.git', '.superpowers')) { continue }
            $isReparse = (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or $null -ne $child.LinkType
            if ($isReparse) {
                Add-Finding -RuleId 'REPARSE_POINT' -Path $child.FullName
                continue
            }
            if ($child.PSIsContainer) {
                $directories.Add([IO.DirectoryInfo]$child)
                $pending.Push($child.FullName)
            }
            else { $files.Add([IO.FileInfo]$child) }
        }
    }
    return [ordered]@{ files = @($files); directories = @($directories) }
}

function Test-PlaceholderUuid {
    param([Parameter(Mandatory)][string]$Value)
    if ($Value -ceq '00000000-0000-0000-0000-000000000000') { return $true }
    return [regex]::IsMatch($Value, '^([0-9a-f])\1{7}-\1{4}-4\1{3}-[89ab]\1{3}-\1{12}$', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

function Get-MarkdownLinkFailureCount {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$MarkdownPath
    )
    $targets = [Collections.Generic.List[string]]::new()
    foreach ($match in [regex]::Matches($Text, '!?(?:\[[^\]]*\])\((?<target>[^)]+)\)')) {
        $targets.Add($match.Groups['target'].Value)
    }
    foreach ($match in [regex]::Matches($Text, '(?m)^\s{0,3}\[[^\]]+\]:\s*(?<target><[^>]+>|\S+)')) {
        $targets.Add($match.Groups['target'].Value)
    }

    $failures = 0
    foreach ($rawTarget in $targets) {
        $target = $rawTarget.Trim()
        if ($target.StartsWith('<') -and $target.Contains('>')) {
            $target = $target.Substring(1, $target.IndexOf('>') - 1)
        }
        else {
            $space = $target.IndexOfAny([char[]]@(' ', "`t"))
            if ($space -ge 0) { $target = $target.Substring(0, $space) }
        }
        if ([string]::IsNullOrWhiteSpace($target) -or $target.StartsWith('#')) { continue }
        if ($target -match '^[A-Za-z]:[\/]' -or $target.StartsWith('/') -or $target.StartsWith('\')) {
            $failures++
            continue
        }
        if ($target -match '^[A-Za-z][A-Za-z0-9+.-]*:') { continue }

        $fragment = $target.IndexOf('#')
        if ($fragment -ge 0) { $target = $target.Substring(0, $fragment) }
        $query = $target.IndexOf('?')
        if ($query -ge 0) { $target = $target.Substring(0, $query) }
        if ([string]::IsNullOrWhiteSpace($target)) { continue }
        try {
            $decoded = [Uri]::UnescapeDataString($target).Replace('/', [IO.Path]::DirectorySeparatorChar)
            $resolved = Get-NormalizedFullPath (Join-Path (Split-Path -Parent $MarkdownPath) $decoded)
            if (-not (Test-PathInsideRoot -Path $resolved -RootPath $script:RootPath) -or -not (Test-Path -LiteralPath $resolved)) { $failures++ }
        }
        catch { $failures++ }
    }
    return $failures
}

function Invoke-NodeSyntaxCheck {
    param(
        [Parameter(Mandatory)][IO.FileInfo]$File,
        [AllowNull()][System.Management.Automation.ApplicationInfo]$NodeCommand
    )
    if ($null -eq $NodeCommand) {
        Add-Finding -RuleId 'NODE_TOOL_UNAVAILABLE' -Path $File.FullName
        return
    }
    $output = @(& $NodeCommand.Source --check $File.FullName 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $text = ($output | ForEach-Object { [string]$_ }) -join "`n"
        Add-Finding -RuleId 'NODE_SYNTAX' -Path $File.FullName -DetailDigest (Get-TextDigest $text)
    }
}

$startedAt = [DateTime]::UtcNow
$verdict = 'FAIL'
$exitCode = 1
$inventory = $null
$filesChecked = 0
$encodingChecked = 0
$jsonChecked = 0
$powershellChecked = 0
$nodeChecked = 0
$markdownChecked = 0
$sensitiveChecked = 0

try {
    if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Join-Path $PSScriptRoot '..' }
    $script:RootPath = Get-NormalizedFullPath $Root
    if (-not (Test-Path -LiteralPath $script:RootPath -PathType Container)) { throw 'ROOT_NOT_DIRECTORY' }
    $rootItem = Get-Item -LiteralPath $script:RootPath -Force
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $null -ne $rootItem.LinkType) { throw 'ROOT_REPARSE_POINT' }

    $allowedPaths = @(
        '.github/ISSUE_TEMPLATE/bug_report.md',
        '.github/ISSUE_TEMPLATE/config.yml',
        '.github/ISSUE_TEMPLATE/feature_request.md',
        '.github/PULL_REQUEST_TEMPLATE.md',
        '.github/workflows/ci.yml',
        '.gitattributes',
        '.gitignore',
        'AGENTS.md',
        'CHANGELOG.md',
        'CONTRIBUTING.md',
        'LICENSE',
        'NOTICE.md',
        'README.md',
        'README-zh.md',
        'SECURITY.md',
        'docs/architecture.md',
        'docs/design.md',
        'docs/installation-windows.md',
        'docs/migration.md',
        'docs/protocol.md',
        'docs/security.md',
        'hooks/hooks.example.json',
        'schemas/publish-request-v3.schema.json',
        'schemas/state-v3.schema.json',
        'scripts/install.ps1',
        'scripts/migrate-v1-to-v3.ps1',
        'scripts/validate-public-tree.ps1',
        'src/task-pointer-lifecycle.ps1',
        'src/task-pointer-publish.ps1',
        'src/task-pointer-report.ps1',
        'src/task-pointer-store.ps1',
        'tests/Test-TaskPointerLifecycle.ps1',
        'tests/app-server-hooks-list.mjs',
        'tests/app-server-task-pointer-e2e.mjs',
        'tests/install-smoke.ps1',
        'tests/run-all.ps1'
    )
    $allowlist = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $allowedPaths) { [void]$allowlist.Add($path) }
    $selfExcludedContent = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    # 验证器源码保存规则字面量；仅从敏感正文扫描排除自身，编码、语法、allowlist 与大小检查仍执行。
    [void]$selfExcludedContent.Add('scripts/validate-public-tree.ps1')

    $inventory = Get-PublicTreeItems -RootPath $script:RootPath
    $fileByRelativePath = [Collections.Generic.Dictionary[string, IO.FileInfo]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in $inventory.files) { $fileByRelativePath[(Get-RelativePublicPath $file.FullName)] = $file }
    foreach ($required in $allowedPaths) {
        if (-not $fileByRelativePath.ContainsKey($required)) { Add-Finding -RuleId 'ALLOWLIST_MISSING' -Path ('<' + $required + '>') }
    }

    $forbiddenDirectoryPattern = '(?i)(?:^|/)(?:\.superpowers|\.codegraph|\.cache|node_modules|__pycache__|coverage|dist|build|out|cache|state|sessions?|logs?|backups?|evidence|rollouts?|vendor|skills)(?:/|$)'
    $forbiddenFilePattern = '(?i)(?:^|/)(?:installation_id|[^/]+\.(?:sqlite(?:-(?:wal|shm))?|db(?:-(?:wal|shm))?|wal|shm|log|pid|tmp|bak|cache|py[co]|zip|7z|tar|gz|exe|dll|pdb|class|jar|map)|[^/]+\.receipt\.json)$'
    foreach ($directory in $inventory.directories) {
        $relative = Get-RelativePublicPath $directory.FullName
        if ($relative -match $forbiddenDirectoryPattern) { Add-Finding -RuleId 'FORBIDDEN_ARTIFACT' -Path $directory.FullName }
    }

    $nodeCommand = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $pathSeparatorPattern = '[\\/]'
    $windowsUserPathPattern = '(?i)(?:^|[^A-Za-z0-9_])(?:[A-Za-z]:)' + $pathSeparatorPattern + '(?:Users|Documents and Settings)' + $pathSeparatorPattern + '[^\\/\s"''<>]+'
    $unixUserPathPattern = '(?i)(?:^|[\s"''(])/(?:Users|home)/[^/\s"''<>]+'
    $privateRuntimePathPattern = '(?i)(?:[A-Za-z]:)' + $pathSeparatorPattern + '(?:Cache|ProgramData)' + $pathSeparatorPattern + '\.codex(?:' + $pathSeparatorPattern + '|\b)'
    $privateUrlPattern = '(?i)https?://(?:[^/@\s]+:[^/@\s]+@|localhost(?::\d+)?(?:/|\b)|127\.0\.0\.1(?::\d+)?(?:/|\b)|10(?:\.\d{1,3}){3}(?::\d+)?(?:/|\b)|192\.168(?:\.\d{1,3}){2}(?::\d+)?(?:/|\b)|172\.(?:1[6-9]|2\d|3[01])(?:\.\d{1,3}){2}(?::\d+)?(?:/|\b))'
    $credentialPattern = '(?i)\b(?:api[_-]?key|access[_-]?token|client[_-]?secret|password|passwd|authorization)\b\s*[:=]\s*["'']?(?!<|\$|YOUR_|REPLACE_|EXAMPLE|REDACTED|NULL\b)[^\s,;}\]"'']{6,}'
    $bearerPattern = '(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{10,}'
    $privateKeyPattern = '(?i)-----BEGIN\s+(?:RSA\s+|EC\s+|OPENSSH\s+)?PRIVATE\s+KEY-----'
    $providerPattern = '(?i)\b(?:model_provider|provider|base_url|api_base|endpoint)\b\s*[:=]\s*["'']?(?!<|\$|YOUR_|REPLACE_|EXAMPLE|NULL\b)[A-Za-z0-9][^\s,;}\]"'']{1,}'
    $productBoundaryPattern = '(?i)\b(?:fusion|grok|headroom|wsl2?|cliproxyapi)\b'
    $emailPattern = '(?i)\b[A-Z0-9._%+-]+@(?!example\.(?:com|org|net)\b)[A-Z0-9.-]+\.[A-Z]{2,}\b'
    $uuidPattern = '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b'

    foreach ($file in $inventory.files) {
        $filesChecked++
        $relative = Get-RelativePublicPath $file.FullName
        $isAllowed = $allowlist.Contains($relative)
        if (-not $isAllowed) { Add-Finding -RuleId 'ALLOWLIST_ORPHAN' -Path $file.FullName }
        if ($relative -match $forbiddenDirectoryPattern -or $relative -match $forbiddenFilePattern) {
            Add-Finding -RuleId 'FORBIDDEN_ARTIFACT' -Path $file.FullName
        }
        if ($file.Length -gt $MaxFileBytes) { Add-Finding -RuleId 'FILE_TOO_LARGE' -Path $file.FullName }
        if (-not $isAllowed) { continue }

        $bytes = [IO.File]::ReadAllBytes($file.FullName)
        $encodingChecked++
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xef -and $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf) {
            Add-Finding -RuleId 'UTF8_BOM' -Path $file.FullName
        }
        try { $text = $script:StrictUtf8.GetString($bytes) }
        catch {
            Add-Finding -RuleId 'UTF8_INVALID' -Path $file.FullName -DetailDigest (Get-TextDigest $_.Exception.GetType().FullName)
            continue
        }
        if ($text.Contains([char]0)) {
            Add-Finding -RuleId 'BINARY_CONTENT' -Path $file.FullName
            continue
        }

        switch -Regex ($file.Extension) {
            '^\.json$' {
                $jsonChecked++
                try { $null = $text | ConvertFrom-Json -Depth 100 -ErrorAction Stop }
                catch { Add-Finding -RuleId 'JSON_SYNTAX' -Path $file.FullName -DetailDigest (Get-TextDigest $_.Exception.GetType().FullName) }
                break
            }
            '^\.ps1$' {
                $powershellChecked++
                $tokens = $null
                $parseErrors = $null
                $null = [Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$parseErrors)
                if (@($parseErrors).Count -gt 0) {
                    $ids = (@($parseErrors) | ForEach-Object { [string]$_.ErrorId }) -join ','
                    Add-Finding -RuleId 'POWERSHELL_SYNTAX' -Path $file.FullName -Count @($parseErrors).Count -DetailDigest (Get-TextDigest $ids)
                }
                break
            }
            '^\.(?:mjs|cjs|js)$' {
                $nodeChecked++
                Invoke-NodeSyntaxCheck -File $file -NodeCommand $nodeCommand
                break
            }
        }

        if ($file.Extension -ceq '.md') {
            $markdownChecked++
            $linkFailures = Get-MarkdownLinkFailureCount -Text $text -MarkdownPath $file.FullName
            if ($linkFailures -gt 0) { Add-Finding -RuleId 'MARKDOWN_LINK' -Path $file.FullName -Count $linkFailures }
        }

        if (-not $selfExcludedContent.Contains($relative)) {
            $sensitiveChecked++
            foreach ($rule in @(
                [ordered]@{ id = 'PRIVATE_PATH'; pattern = $windowsUserPathPattern },
                [ordered]@{ id = 'PRIVATE_PATH'; pattern = $unixUserPathPattern },
                [ordered]@{ id = 'PRIVATE_PATH'; pattern = $privateRuntimePathPattern },
                [ordered]@{ id = 'PRIVATE_URL'; pattern = $privateUrlPattern },
                [ordered]@{ id = 'CREDENTIAL_PATTERN'; pattern = $credentialPattern },
                [ordered]@{ id = 'CREDENTIAL_PATTERN'; pattern = $bearerPattern },
                [ordered]@{ id = 'CREDENTIAL_PATTERN'; pattern = $privateKeyPattern },
                [ordered]@{ id = 'PROVIDER_VALUE'; pattern = $providerPattern },
                [ordered]@{ id = 'PRODUCT_BOUNDARY'; pattern = $productBoundaryPattern },
                [ordered]@{ id = 'PRIVATE_IDENTITY'; pattern = $emailPattern }
            )) {
                $count = [regex]::Matches($text, [string]$rule.pattern).Count
                if ($count -gt 0) { Add-Finding -RuleId ([string]$rule.id) -Path $file.FullName -Count $count }
            }
            $uuidCount = 0
            foreach ($match in [regex]::Matches($text, $uuidPattern)) {
                if (-not (Test-PlaceholderUuid -Value $match.Value)) { $uuidCount++ }
            }
            if ($uuidCount -gt 0) { Add-Finding -RuleId 'UUID_LITERAL' -Path $file.FullName -Count $uuidCount }
        }
    }

    foreach ($requiredRootFile in @('LICENSE', 'NOTICE.md')) {
        if (-not (Test-Path -LiteralPath (Join-Path $script:RootPath $requiredRootFile) -PathType Leaf)) {
            Add-Finding -RuleId ($requiredRootFile.Replace('.', '_').ToUpperInvariant() + '_MISSING') -Path ('<' + $requiredRootFile + '>')
        }
    }

    if (@($script:Findings | Where-Object severity -ceq 'error').Count -eq 0) {
        $verdict = 'PASS'
        $exitCode = 0
    }
}
catch {
    Add-Finding -RuleId 'VALIDATOR_INTERNAL' -Path '<root>' -DetailDigest (Get-TextDigest ($_.Exception.GetType().FullName + '|' + $_.Exception.Message))
    $verdict = 'FAIL'
    $exitCode = 2
}

$sortedFindings = @($script:Findings | Sort-Object rule_id, path, severity)
$receipt = [ordered]@{
    schema_version = 1
    validator = 'codex-task-pointer-public-tree'
    generated_at = [DateTime]::UtcNow.ToString('o')
    root_sha256 = if ($null -eq $script:RootPath) { $null } else { Get-TextDigest $script:RootPath }
    duration_ms = [int64]([DateTime]::UtcNow - $startedAt).TotalMilliseconds
    counts = [ordered]@{
        files = $filesChecked
        directories = if ($null -eq $inventory) { 0 } else { @($inventory.directories).Count }
        encoding = $encodingChecked
        json = $jsonChecked
        powershell = $powershellChecked
        node = $nodeChecked
        markdown = $markdownChecked
        sensitive = $sensitiveChecked
        findings = $sortedFindings.Count
        errors = @($sortedFindings | Where-Object severity -ceq 'error').Count
        warnings = @($sortedFindings | Where-Object severity -ceq 'warning').Count
    }
    self_exclusions = @(
        [ordered]@{
            path = '.superpowers/'
            scope = 'tree-enumeration'
            reason = 'ignored-local-execution-metadata'
        },
        [ordered]@{
            path = 'scripts/validate-public-tree.ps1'
            scope = 'sensitive-content-rules-only'
            reason = 'validator-rule-literals'
        }
    )
    findings = $sortedFindings
    verdict = $verdict
}
$json = $receipt | ConvertTo-Json -Compress -Depth 20
if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $outputFull = [IO.Path]::GetFullPath($OutputPath)
    $outputParent = Split-Path -Parent $outputFull
    if (-not (Test-Path -LiteralPath $outputParent -PathType Container)) {
        [IO.Directory]::CreateDirectory($outputParent) | Out-Null
    }
    [IO.File]::WriteAllText($outputFull, $json + "`n", $script:Utf8NoBom)
}
Write-Output $json
exit $exitCode
