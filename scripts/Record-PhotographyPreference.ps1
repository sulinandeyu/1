param(
    [Parameter(Mandatory = $true)]
    [string]$CaseId,

    [Parameter(Mandatory = $true)]
    [ValidateSet('A', 'B', 'C', 'none', 'original')]
    [string]$Choice,

    [Parameter(Mandatory = $true)]
    [string]$Build,

    [Parameter(Mandatory = $true)]
    [string]$PhotoSha256,

    [Parameter(Mandatory = $true)]
    [string]$Reason,

    [string]$ProblemSummary = '',
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\TestPhotos\photography_preferences.jsonl')
)

$ErrorActionPreference = 'Stop'
if ($PhotoSha256 -notmatch '^[A-Fa-f0-9]{64}$') {
    throw 'PhotoSha256 must contain exactly 64 hexadecimal characters.'
}
if ([string]::IsNullOrWhiteSpace($Reason)) {
    throw 'Reason is required; an unlabeled preference is not valid evidence.'
}

$record = [ordered]@{
    recordedAt = [DateTimeOffset]::Now.ToString('o')
    caseId = $CaseId
    build = $Build
    photoSha256 = $PhotoSha256.ToUpperInvariant()
    choice = $Choice
    candidateMapping = 'A=natural;B=dimensional;C=targeted;none=all bad;original=original preferred'
    reason = $Reason
    problemSummary = $ProblemSummary
    evidenceStatus = 'human-confirmed'
}

$parent = Split-Path -Parent $OutputPath
if ($parent -and -not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent | Out-Null
}
($record | ConvertTo-Json -Compress) | Add-Content -LiteralPath $OutputPath -Encoding utf8
$record | ConvertTo-Json -Depth 4
