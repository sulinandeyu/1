[CmdletBinding()]
param(
    [string]$DatasetRoot = (Join-Path $PSScriptRoot '..\PhotographyDataset'),
    [int]$MinimumReferenceCount = 200,
    [int]$MinimumValidationCount = 30
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = [System.IO.Path]::GetFullPath($DatasetRoot)

function Read-JsonLines {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Missing file: $Path" }
    return @(Get-Content -LiteralPath $Path | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json -Depth 20 })
}

$schema = Get-Content -Raw -LiteralPath (Join-Path $root 'schemas/photo-record.schema.json') | ConvertFrom-Json -Depth 30
$registry = Get-Content -Raw -LiteralPath (Join-Path $root 'licenses/source-registry.json') | ConvertFrom-Json -Depth 20
if (-not $schema.title -or -not $registry.sources) { throw 'Schema or source registry is invalid.' }

$reference = Read-JsonLines (Join-Path $root 'manifests/reference.jsonl')
$validation = Read-JsonLines (Join-Path $root 'manifests/validation.jsonl')
$referenceFeatures = Read-JsonLines (Join-Path $root 'features/reference-features.jsonl')
$validationFeatures = Read-JsonLines (Join-Path $root 'features/validation-features.jsonl')

if ($reference.Count -lt $MinimumReferenceCount) { throw "Reference count $($reference.Count) is below $MinimumReferenceCount." }
if ($validation.Count -lt $MinimumValidationCount) { throw "Validation count $($validation.Count) is below $MinimumValidationCount." }

$all = @($reference) + @($validation)
$ids = @($all.id)
$hashes = @($all.localAsset.sha256)
if (($ids | Select-Object -Unique).Count -ne $ids.Count) { throw 'Duplicate record IDs detected.' }
if (($hashes | Select-Object -Unique).Count -ne $hashes.Count) { throw 'Duplicate local image SHA256 detected across splits.' }

$referenceIds = [System.Collections.Generic.HashSet[string]]::new([string[]]$reference.id)
foreach ($record in $validation) {
    if ($referenceIds.Contains([string]$record.id)) { throw "Split leakage detected: $($record.id)" }
}

foreach ($record in $all) {
    foreach ($required in @('id', 'split', 'assetRole', 'source', 'license', 'authorization', 'contentRisk', 'localAsset', 'image', 'annotations', 'provenance')) {
        if ($null -eq $record.PSObject.Properties[$required]) { throw "Record $($record.id) missing $required" }
    }
    if ($record.assetRole -ne 'single_reference' -or $record.pairId) { throw "Unverified pair data in $($record.id)" }
    if ($record.provenance.originalEditedPairVerified -ne $false) { throw "False pair verification in $($record.id)" }
    if ($record.authorization.featureAnalysis -ne $true) { throw "Feature analysis not authorized for $($record.id)" }
    $path = Join-Path $root $record.localAsset.relativePath
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing local asset: $path" }
    $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
    if ($actualHash -ne $record.localAsset.sha256) { throw "Hash mismatch: $($record.id)" }
    $ignored = git -C (Split-Path $root -Parent) check-ignore --quiet -- $path
    if ($LASTEXITCODE -ne 0) { throw "Third-party pixel file is not ignored by Git: $path" }
}

if ($referenceFeatures.Count -ne $reference.Count) { throw 'Reference feature count mismatch.' }
if ($validationFeatures.Count -ne $validation.Count) { throw 'Validation feature count mismatch.' }
$referenceFeatureKey = (@($referenceFeatures.id) | Sort-Object) -join '|'
$referenceManifestKey = (@($reference.id) | Sort-Object) -join '|'
$validationFeatureKey = (@($validationFeatures.id) | Sort-Object) -join '|'
$validationManifestKey = (@($validation.id) | Sort-Object) -join '|'
if ($referenceFeatureKey -ne $referenceManifestKey) { throw 'Reference feature IDs mismatch.' }
if ($validationFeatureKey -ne $validationManifestKey) { throw 'Validation feature IDs mismatch.' }
foreach ($feature in @($referenceFeatures) + @($validationFeatures)) {
    if ($feature.verification.renderedByCoreImage -ne $false -or $feature.verification.iphoneValidated -ne $false) {
        throw "Windows measurements incorrectly claim Apple validation: $($feature.id)"
    }
}

[ordered]@{
    status = 'passed'
    reference = $reference.Count
    validation = $validation.Count
    total = $all.Count
    splitLeakage = $false
    duplicatePixels = $false
    assetsIgnoredByGit = $true
    originalExpertPairs = 0
    coreImageValidated = $false
    iphoneValidated = $false
} | ConvertTo-Json
