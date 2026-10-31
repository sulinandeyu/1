[CmdletBinding()]
param(
    [string]$ModelPath = (Join-Path $PSScriptRoot '..\MasterCamera\MLModels\DETRResnet50SemanticSegmentationF16P6.mlpackage\Data\com.apple.CoreML\model.mlmodel'),
    [string]$SourcePath = (Join-Path $PSScriptRoot '..\MasterCamera\Analysis\SkySegmentationService.swift')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$resolvedModel = (Resolve-Path -LiteralPath $ModelPath -ErrorAction Stop).Path
$resolvedSource = (Resolve-Path -LiteralPath $SourcePath -ErrorAction Stop).Path
$modelText = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($resolvedModel))
$labelMatch = [regex]::Match($modelText, '\{"labels":\s*(\[[^\]]+\])\}')
if (-not $labelMatch.Success) { throw 'Embedded Core ML label metadata was not found.' }
$labels = @($labelMatch.Groups[1].Value | ConvertFrom-Json)

$expected = [ordered]@{
    person = [ordered]@{ ids = @(1); labels = @('person') }
    vehicle = [ordered]@{ ids = @(2, 3, 4, 6, 7, 8, 9); labels = @('bicycle', 'car', 'motorcycle', 'bus', 'train', 'truck', 'boat') }
    animal = [ordered]@{ ids = @(16, 17, 18, 19, 20, 21, 22, 23, 24, 25); labels = @('bird', 'cat', 'dog', 'horse', 'sheep', 'cow', 'elephant', 'bear', 'zebra', 'giraffe') }
    foodOrFruit = [ordered]@{ ids = @(52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 122, 196); labels = @('banana', 'apple', 'sandwich', 'orange', 'broccoli', 'carrot', 'hot dog', 'pizza', 'donut', 'cake', 'fruit', 'food (other)') }
    furnitureOrWorkspace = [ordered]@{ ids = @(62, 63, 65, 67, 72, 73, 74, 75, 76, 77, 84); labels = @('chair', 'couch', 'bed', 'dining table', 'tv', 'laptop', 'mouse', 'remote', 'keyboard', 'cell phone', 'book') }
    artificialLight = [ordered]@{ ids = @(10, 130); labels = @('traffic light', 'light') }
    pathOrRoad = [ordered]@{ ids = @(147, 149, 191); labels = @('railroad', 'road', 'pavement') }
}

$sourceText = Get-Content -Raw -LiteralPath $resolvedSource
$mappingMatch = [regex]::Match(
    $sourceText,
    'semanticObjectClassIDs:\s*\[SemanticObjectRole:\s*Set<Int32>\]\s*=\s*\[(?<body>[\s\S]*?)\n\s*\]'
)
if (-not $mappingMatch.Success) { throw 'Swift semantic mapping dictionary was not found.' }
$sourceMappings = @{}
foreach ($match in [regex]::Matches($mappingMatch.Groups['body'].Value, '\.(?<role>\w+):\s*\[(?<ids>[0-9,\s]+)\]')) {
    $sourceMappings[$match.Groups['role'].Value] = @(
        $match.Groups['ids'].Value.Split(',') |
            ForEach-Object { [int]$_.Trim() }
    )
}

foreach ($role in $expected.Keys) {
    if (-not $sourceMappings.ContainsKey($role)) { throw "Missing Swift mapping for $role." }
    $expectedIds = @($expected[$role].ids)
    $actualIds = @($sourceMappings[$role])
    if (($expectedIds -join ',') -ne ($actualIds -join ',')) {
        throw "Swift mapping mismatch for ${role}: expected $($expectedIds -join ','), actual $($actualIds -join ',')."
    }
    for ($index = 0; $index -lt $expectedIds.Count; $index++) {
        $id = $expectedIds[$index]
        $expectedLabel = $expected[$role].labels[$index]
        if ($id -ge $labels.Count -or $labels[$id] -ne $expectedLabel) {
            throw "Core ML label mismatch for ${role} id ${id}: expected '$expectedLabel', actual '$($labels[$id])'."
        }
    }
}

[ordered]@{
    status = 'passed'
    modelLabelCount = $labels.Count
    validatedRoles = $expected.Count
    validatedClassIDs = @($expected.Values | ForEach-Object { $_.ids }).Count
    source = $resolvedSource
    model = $resolvedModel
} | ConvertTo-Json -Depth 5
