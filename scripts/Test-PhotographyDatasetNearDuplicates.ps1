[CmdletBinding()]
param(
    [string]$DatasetRoot = (Join-Path $PSScriptRoot '..\PhotographyDataset'),
    [int]$DHashThreshold = 8,
    [int]$AHashThreshold = 6
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Drawing

$root = [System.IO.Path]::GetFullPath($DatasetRoot)
$reportRoot = Join-Path $root 'reports'
New-Item -ItemType Directory -Path $reportRoot -Force | Out-Null

function Read-JsonLines {
    param([string]$Path)
    return @(Get-Content -LiteralPath $Path | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json -Depth 30 })
}

function Get-TinyLuma {
    param([string]$Path, [int]$Width, [int]$Height)
    $source = [System.Drawing.Image]::FromFile($Path)
    try {
        $bitmap = [System.Drawing.Bitmap]::new($Width, $Height, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
        try {
            $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
            try {
                $graphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
                $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $graphics.DrawImage($source, 0, 0, $Width, $Height)
            } finally { $graphics.Dispose() }
            $values = [double[]]::new($Width * $Height)
            for ($y = 0; $y -lt $Height; $y++) {
                for ($x = 0; $x -lt $Width; $x++) {
                    $pixel = $bitmap.GetPixel($x, $y)
                    $values[$y * $Width + $x] = (0.2126 * $pixel.R) + (0.7152 * $pixel.G) + (0.0722 * $pixel.B)
                }
            }
            return ,$values
        } finally { $bitmap.Dispose() }
    } finally { $source.Dispose() }
}

function Convert-BitsToHex {
    param([bool[]]$Bits)
    $builder = [System.Text.StringBuilder]::new()
    for ($offset = 0; $offset -lt $Bits.Count; $offset += 4) {
        $value = 0
        for ($bit = 0; $bit -lt 4; $bit++) {
            if ($Bits[$offset + $bit]) { $value = $value -bor (1 -shl (3 - $bit)) }
        }
        [void]$builder.Append($value.ToString('x1'))
    }
    return $builder.ToString()
}

function Get-PerceptualSignature {
    param([string]$Path)
    $dLuma = Get-TinyLuma -Path $Path -Width 9 -Height 8
    $dBits = [bool[]]::new(64)
    for ($y = 0; $y -lt 8; $y++) {
        for ($x = 0; $x -lt 8; $x++) {
            $dBits[$y * 8 + $x] = $dLuma[$y * 9 + $x] -gt $dLuma[$y * 9 + $x + 1]
        }
    }
    $aLuma = Get-TinyLuma -Path $Path -Width 8 -Height 8
    $average = ($aLuma | Measure-Object -Average).Average
    $aBits = [bool[]]::new(64)
    for ($index = 0; $index -lt 64; $index++) { $aBits[$index] = $aLuma[$index] -ge $average }
    $image = [System.Drawing.Image]::FromFile($Path)
    try { $aspect = $image.Width / [double]$image.Height } finally { $image.Dispose() }
    return [pscustomobject]@{
        dHash = Convert-BitsToHex $dBits
        aHash = Convert-BitsToHex $aBits
        aspectRatio = [Math]::Round($aspect, 6)
    }
}

function Get-HammingDistance {
    param([string]$Left, [string]$Right)
    $distance = 0
    for ($index = 0; $index -lt $Left.Length; $index++) {
        $xor = [Convert]::ToInt32($Left.Substring($index, 1), 16) -bxor [Convert]::ToInt32($Right.Substring($index, 1), 16)
        while ($xor -ne 0) { $distance += ($xor -band 1); $xor = $xor -shr 1 }
    }
    return $distance
}

$reference = Read-JsonLines (Join-Path $root 'manifests/reference.jsonl')
$validation = Read-JsonLines (Join-Path $root 'manifests/validation.jsonl')
$signatures = @{}
foreach ($record in @($reference) + @($validation)) {
    $path = Join-Path $root $record.localAsset.relativePath
    $signatures[$record.id] = Get-PerceptualSignature -Path $path
}

$matches = [System.Collections.Generic.List[object]]::new()
foreach ($validationRecord in $validation) {
    $validationSignature = $signatures[$validationRecord.id]
    foreach ($referenceRecord in $reference) {
        $referenceSignature = $signatures[$referenceRecord.id]
        $dDistance = Get-HammingDistance $validationSignature.dHash $referenceSignature.dHash
        $aDistance = Get-HammingDistance $validationSignature.aHash $referenceSignature.aHash
        $aspectDelta = [Math]::Abs($validationSignature.aspectRatio - $referenceSignature.aspectRatio)
        $isCandidate = ($dDistance -le $DHashThreshold -and $aspectDelta -le 0.08) -or
            ($aDistance -le $AHashThreshold -and $aspectDelta -le 0.05)
        if ($isCandidate) {
            $matches.Add([ordered]@{
                validationId = $validationRecord.id
                referenceId = $referenceRecord.id
                dHashDistance = $dDistance
                aHashDistance = $aDistance
                aspectRatioDelta = [Math]::Round($aspectDelta, 6)
                status = 'requires_visual_review'
            })
        }
    }
}

$result = [ordered]@{
    schemaVersion = 1
    generatedAt = [DateTimeOffset]::UtcNow.ToString('o')
    method = '64-bit dHash + 64-bit average hash + aspect-ratio gate'
    limitations = @(
        'This detects likely resized/re-encoded duplicates; aggressive crops or large geometric edits may evade it.',
        'A flagged pair is not automatically leakage and requires visual review.'
    )
    referenceCount = $reference.Count
    validationCount = $validation.Count
    pairCount = $reference.Count * $validation.Count
    thresholds = [ordered]@{ dHash = $DHashThreshold; aHash = $AHashThreshold }
    potentialNearDuplicates = @($matches)
    status = if ($matches.Count -eq 0) { 'passed_no_candidates' } else { 'visual_review_required' }
}

$jsonPath = Join-Path $reportRoot 'near-duplicate-audit.json'
$result | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $jsonPath -Encoding utf8
$markdown = @(
    '# Reference / validation near-duplicate audit',
    '',
    "- Generated: $($result.generatedAt)",
    "- Reference images: $($reference.Count)",
    "- Validation images: $($validation.Count)",
    "- Cross-split comparisons: $($result.pairCount)",
    "- Potential near-duplicates: $($matches.Count)",
    ("- Status: {0}" -f $result.status),
    '',
    'The audit uses perceptual hashes in addition to the existing SHA-256 split check. A zero result does not prove the absence of heavily cropped or transformed copies.'
)
if ($matches.Count -gt 0) {
    $markdown += @('', '## Pairs requiring visual review', '')
    foreach ($match in $matches) {
        $markdown += ("- {0} vs {1}: dHash {2}, aHash {3}, aspect delta {4}" -f $match.validationId, $match.referenceId, $match.dHashDistance, $match.aHashDistance, $match.aspectRatioDelta)
    }
}
$markdown -join "`n" | Set-Content -LiteralPath (Join-Path $reportRoot 'NEAR_DUPLICATE_AUDIT.md') -Encoding utf8
$result | ConvertTo-Json -Depth 20
