#requires -Version 7.5
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SessionId,
    [AllowNull()][string]$StateRoot = $null
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8 = [System.Text.UTF8Encoding]::new($false, $true)
$maxRequestBytes = 12288
. (Join-Path $PSScriptRoot 'task-pointer-store.ps1')

function Write-Receipt {
    param([System.Collections.IDictionary]$Value)
    [Console]::Out.WriteLine(($Value | ConvertTo-Json -Compress -Depth 20))
}

function Read-RequestFromStdin {
    $inputStream = [Console]::OpenStandardInput()
    $memory = [System.IO.MemoryStream]::new()
    try {
        $buffer = [byte[]]::new(4096)
        while (($read = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $memory.Write($buffer, 0, $read)
            if ($memory.Length -gt $maxRequestBytes) { Throw-TPV2Error -Code 'INPUT_TOO_LARGE' -Detail ([string]$memory.Length) }
        }
        if ($memory.Length -eq 0) { Throw-TPV2Error -Code 'INPUT_EMPTY' }
        try { return $utf8.GetString($memory.ToArray()) }
        catch { Throw-TPV2Error -Code 'INPUT_UTF8_INVALID' }
    }
    finally { $memory.Dispose() }
}

try {
    Assert-TPV2SessionId -SessionId $SessionId
    $root = Resolve-TPV2StateRoot -StateRoot $StateRoot
    $raw = Read-RequestFromStdin
    try {
        $jsonDocument = [System.Text.Json.JsonDocument]::Parse($raw)
        try {
            if ($jsonDocument.RootElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) { Throw-TPV2Error -Code 'INPUT_SCHEMA_INVALID' }
            $names = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($property in $jsonDocument.RootElement.EnumerateObject()) {
                if (-not $names.Add($property.Name)) { Throw-TPV2Error -Code 'INPUT_DUPLICATE_FIELD' -Detail $property.Name }
            }
        }
        finally { $jsonDocument.Dispose() }
    }
    catch [System.InvalidOperationException] { throw }
    catch { Throw-TPV2Error -Code 'INPUT_PARSE_FAILED' }
    try { $request = $raw | ConvertFrom-Json -AsHashtable -Depth 20 -DateKind String }
    catch { Throw-TPV2Error -Code 'INPUT_PARSE_FAILED' }
    if ($request -isnot [System.Collections.IDictionary]) { Throw-TPV2Error -Code 'INPUT_SCHEMA_INVALID' }
    $expected = @('schema_version','session_id','expected_generation','expected_revision','task_id','target_status','pointer_text')
    $actual = @($request.Keys | ForEach-Object { [string]$_ } | Sort-Object)
    if (($actual -join "`0") -cne (($expected | Sort-Object) -join "`0")) { Throw-TPV2Error -Code 'INPUT_FIELDS_INVALID' }
    if ($request.schema_version -isnot [int] -and $request.schema_version -isnot [long]) { Throw-TPV2Error -Code 'INPUT_SCHEMA_INVALID' }
    if ([int]$request.schema_version -ne 3) { Throw-TPV2Error -Code 'INPUT_SCHEMA_INVALID' }
    if ($request.session_id -isnot [string] -or [string]$request.session_id -cne $SessionId) { Throw-TPV2Error -Code 'INPUT_SESSION_INVALID' }
    if ($request.expected_generation -isnot [string] -or [string]$request.expected_generation -notmatch '^(ABSENT|LEGACY_V2|g-[0-9a-f]{32})$') { Throw-TPV2Error -Code 'INPUT_GENERATION_INVALID' }
    if ($request.expected_revision -isnot [int] -and $request.expected_revision -isnot [long]) { Throw-TPV2Error -Code 'INPUT_REVISION_INVALID' }
    if ([int64]$request.expected_revision -lt 0) { Throw-TPV2Error -Code 'INPUT_REVISION_INVALID' }
    if ($request.target_status -isnot [string]) { Throw-TPV2Error -Code 'INPUT_STATUS_INVALID' }
    $status = [string]$request.target_status
    if ($status -cnotin @('CLEAN','CLEARED')) { Throw-TPV2Error -Code 'INPUT_STATUS_INVALID' }
    if ($status -ceq 'CLEARED' -and ($null -ne $request.task_id -or $null -ne $request.pointer_text)) { Throw-TPV2Error -Code 'INPUT_CLEARED_FIELDS_INVALID' }

    $receipt = Publish-TPV2State -StateRoot $root -SessionId $SessionId -ExpectedGeneration ([string]$request.expected_generation) -ExpectedRevision ([int64]$request.expected_revision) -TaskId $request.task_id -TargetStatus $status -PointerText $request.pointer_text
    Write-Receipt -Value $receipt
    if (-not [bool]$receipt.ok) { exit 2 }
    exit 0
}
catch {
    Write-Receipt -Value ([ordered]@{ok=$false;code=Get-TPV2ErrorCode $_})
    exit 2
}
