#requires -Version 7.5
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SessionId,
    [AllowNull()][string]$StateRoot = $null,
    [switch]$Recall,
    [AllowNull()][object]$Revision = $null,
    [int]$Last = 0,
    [AllowNull()][string]$TextMatch = $null,
    [switch]$Full
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'task-pointer-store.ps1')

# 只读诊断入口：不动 state、不动日志。默认输出状态面；-Recall 输出日志召回。
try {
    Assert-TPV2SessionId -SessionId $SessionId
    $root = Resolve-TPV2StateRoot -StateRoot $StateRoot
    if ($Recall) {
        $text = Get-TPV2RecallText -StateRoot $root -SessionId $SessionId -Revision $Revision -Last $Last -TextMatch $TextMatch -Full:$Full
    }
    else {
        $text = Format-TPV2Report -StateRoot $root -SessionId $SessionId
    }
    [Console]::Out.WriteLine($text)
    exit 0
}
catch {
    $code = Get-TPV2ErrorCode $_
    [Console]::Error.WriteLine('TASK_POINTER_V2_REPORT:' + $code)
    [Console]::Out.WriteLine('REPORT_FAILED|' + $code)
    exit 2
}
