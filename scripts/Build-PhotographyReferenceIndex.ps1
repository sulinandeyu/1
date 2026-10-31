[CmdletBinding()]
param(
    [string]$DatasetRoot = (Join-Path $PSScriptRoot '..\PhotographyDataset'),
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\MasterCamera\ReferenceData\PhotographyReferenceIndex.v1.json'),
    [ValidateSet('testflight-internal', 'local-research')]
    [string]$Profile = 'testflight-internal'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Read-JsonLines {
    param([string]$Path)
    return @(Get-Content -LiteralPath $Path | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json -Depth 30 })
}

$root = [System.IO.Path]::GetFullPath($DatasetRoot)
$output = [System.IO.Path]::GetFullPath($OutputPath)
$manifest = Read-JsonLines (Join-Path $root 'manifests/reference.jsonl')
$features = Read-JsonLines (Join-Path $root 'features/reference-features.jsonl')
$featureById = @{}
foreach ($feature in $features) { $featureById[$feature.id] = $feature }

# These records are permitted for feature analysis and commercial reference by
# their per-file metadata, but still carry the project's legal-review gate.
# Therefore the generated index is enabled only in diagnostic validation mode.
$eligible = @($manifest | Where-Object {
    $_.authorization.featureAnalysis -eq $true -and
    $_.authorization.commercialReference -eq $true -and
    $_.authorization.modelTraining -eq 'candidate_after_legal_review' -and
    $_.contentRisk.identifiablePeople -eq 'not_indicated'
})
if ($Profile -eq 'testflight-internal') {
    # A TestFlight build is distributed outside the local research workspace.
    # Until the app exposes a complete attribution surface and human legal/content
    # review is complete, exclude attribution-bearing and ShareAlike records.
    # The remaining PD/CC0 numeric descriptors still stay diagnostic-only;
    # this does not change any record's production/training authorization.
    $eligible = @($eligible | Where-Object {
        $_.license.name -in @('Public domain', 'CC0') -and
        $_.license.attributionRequired -eq $false -and
        $_.license.shareAlike -eq $false
    })
}

$records = foreach ($item in $eligible) {
    $feature = $featureById[$item.id]
    if ($null -eq $feature) { throw "Missing measured feature record for $($item.id)" }
    $contrastRange = [double]$feature.luminance.p95 - [double]$feature.luminance.p05
    $meanRGB = @($feature.color.meanRGB)
    [ordered]@{
        id = [string]$item.id
        usage = [ordered]@{
            validationModeAllowed = $true
            productionUseAllowed = $false
            modelTrainingAllowed = $false
            reason = if ($Profile -eq 'testflight-internal') {
                'PD/CC0 numeric descriptor selected for isolated internal TestFlight diagnostics; production and model training remain prohibited.'
            } else {
                'Per-file feature analysis/commercial reference metadata is present, but human legal/content review has not cleared production embedding or training.'
            }
        }
        license = [ordered]@{
            name = [string]$item.license.name
            url = [string]$item.license.url
            attributionRequired = [bool]$item.license.attributionRequired
            shareAlike = [bool]$item.license.shareAlike
        }
        source = [ordered]@{
            pageUrl = [string]$item.source.pageUrl
            creator = [string]$item.source.creator
            title = [string]$item.source.title
        }
        semantics = [ordered]@{
            categories = @($item.annotations.photographyCategories)
            subjects = @($item.annotations.subjects)
            lighting = @($item.annotations.lighting)
            annotationStatus = [string]$item.annotations.annotationStatus
        }
        vector = [ordered]@{
            averageLuminance = [double]$feature.luminance.mean
            contrastRange = [Math]::Round($contrastRange, 6)
            shadowRatio = [double]$feature.luminance.shadowRatio
            highlightRatio = [double]$feature.luminance.highlightRatio
            averageSaturation = [double]$feature.color.meanSaturation
            redAverage = [double]$meanRGB[0]
            greenAverage = [double]$meanRGB[1]
            blueAverage = [double]$meanRGB[2]
            neutralCoverage = [double]$feature.color.neutralCoverage
            warmPixelRatio = [double]$feature.color.warmPixelRatio
            coolPixelRatio = [double]$feature.color.coolPixelRatio
            localContrast = [double]$feature.detail.gridLocalContrastMean
            gradientEnergy = [double]$feature.detail.gradientEnergy
            centerLuminanceDelta = [Math]::Round([double]$feature.compositionProxy.centerLuminance - [double]$feature.compositionProxy.borderLuminance, 6)
            centerSaturationDelta = [Math]::Round([double]$feature.compositionProxy.centerSaturation - [double]$feature.compositionProxy.borderSaturation, 6)
        }
        nonTransferable = @(
            'absolute white balance',
            'absolute HSL values',
            'histogram shape',
            'tone curve',
            'content-specific colors',
            'center/border proxy as subject identity'
        )
    }
}

$document = [ordered]@{
    schemaVersion = 1
    generatedAt = [DateTimeOffset]::UtcNow.ToString('o')
    sourceDataset = 'wikimedia-commons-featured'
    usageScope = if ($Profile -eq 'testflight-internal') {
        'internal_testflight_diagnostic_only'
    } else {
        'local_research_diagnostic_only'
    }
    distributionProfile = $Profile
    productionUseAllowed = $false
    modelTrainingAllowed = $false
    referencePixelsBundled = $false
    matchingRuleIds = @('PT-REF-001', 'PT-REF-002', 'PT-REF-003')
    notes = @(
        'Only precomputed numeric descriptors are bundled; reference image pixels stay outside the app.',
        'A match can calibrate a per-image target only after applicability checks. It never supplies a preset.',
        'Production activation requires separate human legal/content review and real iPhone visual validation.',
        $(if ($Profile -eq 'testflight-internal') {
            'Attribution-bearing CC BY and all CC BY-SA records are excluded from this distributed diagnostic index.'
        } else {
            'This local research index must not be bundled into a distributed app.'
        })
    )
    records = @($records)
}

$directory = Split-Path -Parent $output
New-Item -ItemType Directory -Path $directory -Force | Out-Null
$document | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $output -Encoding utf8
[ordered]@{
    output = $output
    profile = $Profile
    records = $records.Count
    productionUseAllowed = $false
    referencePixelsBundled = $false
} | ConvertTo-Json
