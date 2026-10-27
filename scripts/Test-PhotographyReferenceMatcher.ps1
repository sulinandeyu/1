[CmdletBinding()]
param(
    [string]$DatasetRoot = (Join-Path $PSScriptRoot '..\PhotographyDataset'),
    [string]$IndexPath = (Join-Path $PSScriptRoot '..\MasterCamera\ReferenceData\PhotographyReferenceIndex.v1.json')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Read-JsonLines {
    param([string]$Path)
    return @(Get-Content -LiteralPath $Path | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json -Depth 30 })
}
function Clamp01([double]$value) { return [Math]::Min(1.0, [Math]::Max(0.0, $value)) }
function Distance([double]$left, [double]$right, [double]$scale) { return Clamp01 ([Math]::Abs($left - $right) / $scale) }
function TokenSet($values) {
    $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($value in @($values)) {
        foreach ($token in ([string]$value -split '[^a-zA-Z0-9]+')) {
            if ($token.Length -gt 2) { [void]$set.Add($token.ToLowerInvariant()) }
        }
    }
    return ,$set
}
function SetSimilarity($leftValues, $rightValues) {
    $left = TokenSet $leftValues; $right = TokenSet $rightValues
    if ($left.Count -eq 0 -or $right.Count -eq 0) { return 0.0 }
    $intersection = 0
    foreach ($token in $left) { if ($right.Contains($token)) { $intersection++ } }
    $union = $left.Count + $right.Count - $intersection
    if ($union -eq 0) { return 0.0 }
    return $intersection / [double]$union
}
function Get-MatchScore($query, $record) {
    $vector = $record.vector
    $parts = @(
        @{ w = 0.17; d = (Distance $query.luminance.mean $vector.averageLuminance 0.25) },
        @{ w = 0.16; d = (Distance ($query.luminance.p95 - $query.luminance.p05) $vector.contrastRange 0.30) },
        @{ w = 0.10; d = (Distance $query.luminance.shadowRatio $vector.shadowRatio 0.25) },
        @{ w = 0.10; d = (Distance $query.luminance.highlightRatio $vector.highlightRatio 0.18) },
        @{ w = 0.12; d = (Distance $query.color.meanSaturation $vector.averageSaturation 0.35) },
        @{ w = 0.07; d = (Distance (($query.color.meanRGB[0] - $query.color.meanRGB[2])) (($vector.redAverage - $vector.blueAverage)) 0.18) },
        @{ w = 0.05; d = (Distance (($query.color.meanRGB[1] - (($query.color.meanRGB[0] + $query.color.meanRGB[2]) * 0.5))) (($vector.greenAverage - (($vector.redAverage + $vector.blueAverage) * 0.5))) 0.14) },
        @{ w = 0.08; d = (Distance $query.color.neutralCoverage $vector.neutralCoverage 0.40) },
        @{ w = 0.05; d = (Distance (($query.compositionProxy.centerLuminance - $query.compositionProxy.borderLuminance)) $vector.centerLuminanceDelta 0.24) }
    )
    $metricDistance = 0.0
    foreach ($part in $parts) { $metricDistance += $part.w * $part.d }
    $metricWeight = ($parts | ForEach-Object { $_.w } | Measure-Object -Sum).Sum
    $metricSimilarity = 1.0 - ($metricDistance / $metricWeight)
    $semantic = SetSimilarity $query.sourceCategories $record.semantics.categories
    $score = Clamp01 (($metricSimilarity * 0.90) + ($semantic * 0.10))
    return [ordered]@{ score = [Math]::Round($score, 6); metric = [Math]::Round($metricSimilarity, 6); semantic = [Math]::Round($semantic, 6) }
}

$root = [System.IO.Path]::GetFullPath($DatasetRoot)
$index = Get-Content -Raw -LiteralPath ([System.IO.Path]::GetFullPath($IndexPath)) | ConvertFrom-Json -Depth 30
if ($index.productionUseAllowed -ne $false -or $index.referencePixelsBundled -ne $false) { throw 'Unsafe reference index policy.' }
$queries = Read-JsonLines (Join-Path $root 'features/validation-features.jsonl')
$output = [System.Collections.Generic.List[object]]::new()
$stopwatch = [Diagnostics.Stopwatch]::StartNew()
foreach ($query in $queries) {
    $scored = foreach ($record in $index.records) {
        $score = Get-MatchScore $query $record
        [pscustomobject]@{
            id = $record.id
            score = $score.score
            metric = $score.metric
            semantic = $score.semantic
            record = $record
            basis = [ordered]@{
                luminanceDelta = [Math]::Round([Math]::Abs($query.luminance.mean - $record.vector.averageLuminance), 6)
                contrastDelta = [Math]::Round([Math]::Abs(($query.luminance.p95 - $query.luminance.p05) - $record.vector.contrastRange), 6)
                saturationDelta = [Math]::Round([Math]::Abs($query.color.meanSaturation - $record.vector.averageSaturation), 6)
                compositionProxyDelta = [Math]::Round([Math]::Abs(($query.compositionProxy.centerLuminance - $query.compositionProxy.borderLuminance) - $record.vector.centerLuminanceDelta), 6)
            }
        }
    }
    $top = @($scored | Sort-Object score -Descending | Select-Object -First 3)
    $best = if ($top.Count -gt 0) { [double]$top[0].score } else { 0.0 }
    $margin = if ($top.Count -gt 1) { [Math]::Max(0, $best - [double]$top[1].score) } else { 0.0 }
    $confidence = Clamp01 (($best * 0.82) + ([Math]::Min(1.0, $margin / 0.12) * 0.18))
    $status = if ($top.Count -gt 0 -and $best -ge 0.58 -and $confidence -ge 0.54) { 'matched_for_validation' } else { 'fallback_to_measurement_solver' }
    $output.Add([ordered]@{
        queryId = $query.id
        status = $status
        confidence = [Math]::Round($confidence, 6)
        topMatches = @($top | ForEach-Object { [ordered]@{ id = $_.id; score = $_.score; metricSimilarity = $_.metric; semanticSimilarity = $_.semantic; basis = $_.basis } })
        nonTransferable = @('absolute white balance', 'absolute HSL', 'histogram', 'tone curve', 'content identity')
        aestheticJudgment = 'not_performed'
        coreImageRendered = $false
        iphoneValidated = $false
    })
}
$stopwatch.Stop()

$reportPath = Join-Path $root 'reports/reference-matcher-validation.jsonl'
$output | ForEach-Object { $_ | ConvertTo-Json -Depth 20 -Compress } | Set-Content -LiteralPath $reportPath -Encoding utf8
$summary = [ordered]@{
    status = 'passed_algorithm_execution'
    referenceRecords = @($index.records).Count
    validationQueries = $queries.Count
    matchedForValidation = @($output | Where-Object { $_.status -eq 'matched_for_validation' }).Count
    safeFallbacks = @($output | Where-Object { $_.status -eq 'fallback_to_measurement_solver' }).Count
    elapsedMilliseconds = $stopwatch.ElapsedMilliseconds
    serializedIndexBytes = (Get-Item -LiteralPath ([System.IO.Path]::GetFullPath($IndexPath))).Length
    coreImageRendered = $false
    iphoneValidated = $false
    aestheticJudgment = 'not_performed'
    output = $reportPath
}
$summary | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'reports/reference-matcher-summary.json') -Encoding utf8
$summary | ConvertTo-Json
