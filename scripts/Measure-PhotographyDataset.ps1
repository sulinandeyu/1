[CmdletBinding()]
param(
    [string]$DatasetRoot = (Join-Path $PSScriptRoot '..\PhotographyDataset'),
    [int]$MaximumSampleDimension = 256
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Drawing

$root = [System.IO.Path]::GetFullPath($DatasetRoot)
$featureRoot = Join-Path $root 'features'
$reportRoot = Join-Path $root 'reports'
New-Item -ItemType Directory -Path $featureRoot -Force | Out-Null
New-Item -ItemType Directory -Path $reportRoot -Force | Out-Null

function Get-PercentileFromHistogram {
    param([int[]]$Histogram, [int]$Count, [double]$Percentile)
    $target = [Math]::Max(1, [Math]::Ceiling($Count * $Percentile))
    $running = 0
    for ($i = 0; $i -lt $Histogram.Length; $i++) {
        $running += $Histogram[$i]
        if ($running -ge $target) { return [Math]::Round($i / 255.0, 6) }
    }
    return 1.0
}

function Get-Mean {
    param([double[]]$Values)
    if ($Values.Count -eq 0) { return 0.0 }
    return ($Values | Measure-Object -Average).Average
}

function Get-StandardDeviation {
    param([double[]]$Values)
    if ($Values.Count -le 1) { return 0.0 }
    $mean = Get-Mean $Values
    $sum = 0.0
    foreach ($value in $Values) { $sum += ($value - $mean) * ($value - $mean) }
    return [Math]::Sqrt($sum / $Values.Count)
}

function Measure-ImageFeatures {
    param([string]$Path, [string]$RecordId, [string]$Split, [string[]]$Categories)

    $source = [System.Drawing.Image]::FromFile($Path)
    try {
        $scale = [Math]::Min(1.0, $MaximumSampleDimension / [double][Math]::Max($source.Width, $source.Height))
        $width = [Math]::Max(1, [int][Math]::Round($source.Width * $scale))
        $height = [Math]::Max(1, [int][Math]::Round($source.Height * $scale))
        $bitmap = [System.Drawing.Bitmap]::new($width, $height, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
        try {
            $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
            try {
                $graphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
                $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
                $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                $graphics.DrawImage($source, 0, 0, $width, $height)
            } finally {
                $graphics.Dispose()
            }

            $rect = [System.Drawing.Rectangle]::new(0, 0, $width, $height)
            $data = $bitmap.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
            try {
                $stride = [Math]::Abs($data.Stride)
                $bytes = [byte[]]::new($stride * $height)
                [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
            } finally {
                $bitmap.UnlockBits($data)
            }
        } finally {
            $bitmap.Dispose()
        }
    } finally {
        $source.Dispose()
    }

    $count = $width * $height
    $histogram = [int[]]::new(256)
    $hueHistogram = [int[]]::new(12)
    $lumaMap = [double[]]::new($count)
    $gridSum = [double[]]::new(16)
    $gridSquare = [double[]]::new(16)
    $gridCount = [int[]]::new(16)
    $sumR = 0.0; $sumG = 0.0; $sumB = 0.0; $sumL = 0.0; $sumL2 = 0.0; $sumSat = 0.0
    $shadow = 0; $highlight = 0; $black = 0; $white = 0; $midtone = 0
    $warm = 0; $cool = 0; $neutral = 0; $neutralR = 0.0; $neutralG = 0.0; $neutralB = 0.0
    $centerL = 0.0; $centerSat = 0.0; $centerCount = 0
    $borderL = 0.0; $borderSat = 0.0; $borderCount = 0

    for ($y = 0; $y -lt $height; $y++) {
        for ($x = 0; $x -lt $width; $x++) {
            $offset = ($y * $stride) + ($x * 3)
            $b = $bytes[$offset] / 255.0
            $g = $bytes[$offset + 1] / 255.0
            $r = $bytes[$offset + 2] / 255.0
            $maximum = [Math]::Max($r, [Math]::Max($g, $b))
            $minimum = [Math]::Min($r, [Math]::Min($g, $b))
            $delta = $maximum - $minimum
            $lightness = ($maximum + $minimum) / 2.0
            $saturation = if ($delta -lt 0.000001) { 0.0 } else { $delta / (1.0 - [Math]::Abs((2.0 * $lightness) - 1.0)) }
            $luma = (0.2126 * $r) + (0.7152 * $g) + (0.0722 * $b)
            $lumaMap[($y * $width) + $x] = $luma
            $histogram[[Math]::Min(255, [Math]::Max(0, [int][Math]::Round($luma * 255)))]++
            $sumR += $r; $sumG += $g; $sumB += $b; $sumL += $luma; $sumL2 += $luma * $luma; $sumSat += $saturation

            if ($luma -lt 0.10) { $shadow++ }
            if ($luma -gt 0.90) { $highlight++ }
            if ($luma -lt 0.02) { $black++ }
            if ($luma -gt 0.98) { $white++ }
            if ($luma -ge 0.20 -and $luma -le 0.80) { $midtone++ }
            if ($saturation -gt 0.15 -and $r -gt $b + 0.03) { $warm++ }
            if ($saturation -gt 0.15 -and $b -gt $r + 0.03) { $cool++ }
            if ($delta -le 0.04 -and $luma -ge 0.15 -and $luma -le 0.95) {
                $neutral++; $neutralR += $r; $neutralG += $g; $neutralB += $b
            }

            if ($delta -gt 0.000001) {
                if ($maximum -eq $r) { $hue = 60.0 * ((($g - $b) / $delta) % 6.0) }
                elseif ($maximum -eq $g) { $hue = 60.0 * ((($b - $r) / $delta) + 2.0) }
                else { $hue = 60.0 * ((($r - $g) / $delta) + 4.0) }
                if ($hue -lt 0) { $hue += 360.0 }
                $hueHistogram[[Math]::Min(11, [int][Math]::Floor($hue / 30.0))]++
            }

            $gridX = [Math]::Min(3, [int][Math]::Floor(($x * 4.0) / $width))
            $gridY = [Math]::Min(3, [int][Math]::Floor(($y * 4.0) / $height))
            $gridIndex = ($gridY * 4) + $gridX
            $gridSum[$gridIndex] += $luma
            $gridSquare[$gridIndex] += $luma * $luma
            $gridCount[$gridIndex]++

            $inCenter = $x -ge ($width * 0.25) -and $x -lt ($width * 0.75) -and $y -ge ($height * 0.25) -and $y -lt ($height * 0.75)
            if ($inCenter) {
                $centerL += $luma; $centerSat += $saturation; $centerCount++
            } else {
                $borderL += $luma; $borderSat += $saturation; $borderCount++
            }
        }
    }

    $edgeSum = 0.0; $edgeCount = 0
    for ($y = 0; $y -lt $height - 1; $y++) {
        for ($x = 0; $x -lt $width - 1; $x++) {
            $index = ($y * $width) + $x
            $edgeSum += [Math]::Abs($lumaMap[$index] - $lumaMap[$index + 1])
            $edgeSum += [Math]::Abs($lumaMap[$index] - $lumaMap[$index + $width])
            $edgeCount += 2
        }
    }

    $gridContrast = [System.Collections.Generic.List[double]]::new()
    for ($i = 0; $i -lt 16; $i++) {
        if ($gridCount[$i] -eq 0) { $gridContrast.Add(0); continue }
        $mean = $gridSum[$i] / $gridCount[$i]
        $variance = [Math]::Max(0.0, ($gridSquare[$i] / $gridCount[$i]) - ($mean * $mean))
        $gridContrast.Add([Math]::Sqrt($variance))
    }

    $meanLuma = $sumL / $count
    $contrastStd = [Math]::Sqrt([Math]::Max(0.0, ($sumL2 / $count) - ($meanLuma * $meanLuma)))
    $p05 = Get-PercentileFromHistogram $histogram $count 0.05
    $p25 = Get-PercentileFromHistogram $histogram $count 0.25
    $p50 = Get-PercentileFromHistogram $histogram $count 0.50
    $p75 = Get-PercentileFromHistogram $histogram $count 0.75
    $p95 = Get-PercentileFromHistogram $histogram $count 0.95
    $toneLabel = if ($meanLuma -lt 0.32) { 'low_key' } elseif ($meanLuma -gt 0.68) { 'high_key' } elseif (($p95 - $p05) -lt 0.42) { 'compressed_range' } else { 'broad_or_balanced_range' }
    $hueTotal = [Math]::Max(1, ($hueHistogram | Measure-Object -Sum).Sum)

    return [ordered]@{
        schemaVersion = 1
        id = $RecordId
        split = $Split
        measuredAt = [DateTimeOffset]::UtcNow.ToString('o')
        analyzer = 'Measure-PhotographyDataset.ps1/System.Drawing/downsampled-sRGB'
        sample = [ordered]@{ width = $width; height = $height; pixels = $count }
        sourceCategories = $Categories
        luminance = [ordered]@{
            mean = [Math]::Round($meanLuma, 6)
            standardDeviation = [Math]::Round($contrastStd, 6)
            p05 = $p05; p25 = $p25; p50 = $p50; p75 = $p75; p95 = $p95
            shadowRatio = [Math]::Round($shadow / [double]$count, 6)
            highlightRatio = [Math]::Round($highlight / [double]$count, 6)
            pureBlackRatio = [Math]::Round($black / [double]$count, 6)
            pureWhiteRatio = [Math]::Round($white / [double]$count, 6)
            midtoneRatio = [Math]::Round($midtone / [double]$count, 6)
            toneCharacteristic = $toneLabel
        }
        color = [ordered]@{
            meanRGB = @([Math]::Round($sumR / $count, 6), [Math]::Round($sumG / $count, 6), [Math]::Round($sumB / $count, 6))
            meanSaturation = [Math]::Round($sumSat / $count, 6)
            hueHistogram30Degrees = @($hueHistogram | ForEach-Object { [Math]::Round($_ / [double]$hueTotal, 6) })
            warmPixelRatio = [Math]::Round($warm / [double]$count, 6)
            coolPixelRatio = [Math]::Round($cool / [double]$count, 6)
            neutralCoverage = [Math]::Round($neutral / [double]$count, 6)
            neutralMeanRGB = if ($neutral -gt 0) { @([Math]::Round($neutralR / $neutral, 6), [Math]::Round($neutralG / $neutral, 6), [Math]::Round($neutralB / $neutral, 6)) } else { $null }
        }
        detail = [ordered]@{
            gradientEnergy = [Math]::Round($edgeSum / [Math]::Max(1, $edgeCount), 6)
            gridLocalContrastMean = [Math]::Round((Get-Mean $gridContrast.ToArray()), 6)
            gridLocalContrastStd = [Math]::Round((Get-StandardDeviation $gridContrast.ToArray()), 6)
            grid4x4 = @($gridContrast | ForEach-Object { [Math]::Round($_, 6) })
        }
        compositionProxy = [ordered]@{
            isSubjectMeasurement = $false
            limitation = 'Center-versus-border statistics are composition proxies only; no subject identity or segmentation is inferred.'
            centerLuminance = [Math]::Round($centerL / [Math]::Max(1, $centerCount), 6)
            borderLuminance = [Math]::Round($borderL / [Math]::Max(1, $borderCount), 6)
            centerSaturation = [Math]::Round($centerSat / [Math]::Max(1, $centerCount), 6)
            borderSaturation = [Math]::Round($borderSat / [Math]::Max(1, $borderCount), 6)
        }
        verification = [ordered]@{
            renderedByCoreImage = $false
            iphoneValidated = $false
            aestheticJudgment = 'not_performed'
        }
    }
}

$allFeatures = [System.Collections.Generic.List[object]]::new()
foreach ($split in @('reference', 'validation')) {
    $manifestPath = Join-Path $root "manifests/$split.jsonl"
    $featurePath = Join-Path $featureRoot "$split-features.jsonl"
    Set-Content -LiteralPath $featurePath -Value '' -NoNewline -Encoding utf8
    $records = Get-Content -LiteralPath $manifestPath | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json -Depth 20 }
    $index = 0
    foreach ($record in $records) {
        $index++
        $assetPath = Join-Path $root $record.localAsset.relativePath
        if (-not (Test-Path -LiteralPath $assetPath)) { throw "Missing asset for $($record.id): $assetPath" }
        $features = Measure-ImageFeatures -Path $assetPath -RecordId $record.id -Split $split -Categories @($record.annotations.photographyCategories)
        Add-Content -LiteralPath $featurePath -Value ($features | ConvertTo-Json -Depth 12 -Compress) -Encoding utf8
        $allFeatures.Add([pscustomobject]$features)
        Write-Progress -Activity 'Measuring photography dataset' -Status "$split $index / $($records.Count)" -PercentComplete (($index / [Math]::Max(1, $records.Count)) * 100)
    }
}
Write-Progress -Activity 'Measuring photography dataset' -Completed

$referenceCount = @($allFeatures | Where-Object split -eq 'reference').Count
$validationCount = @($allFeatures | Where-Object split -eq 'validation').Count
$meanLuminance = ($allFeatures | ForEach-Object { $_.luminance.mean } | Measure-Object -Average).Average
$meanSaturation = ($allFeatures | ForEach-Object { $_.color.meanSaturation } | Measure-Object -Average).Average
$meanContrast = ($allFeatures | ForEach-Object { $_.detail.gridLocalContrastMean } | Measure-Object -Average).Average
$toneCounts = $allFeatures | Group-Object { $_.luminance.toneCharacteristic } | Sort-Object Count -Descending
$categoryCounts = $allFeatures | ForEach-Object { $_.sourceCategories } | Group-Object | Sort-Object Count -Descending

$reportLines = [System.Collections.Generic.List[string]]::new()
$reportLines.Add('# 摄影样本特征统计')
$reportLines.Add('')
$reportLines.Add('生成时间：' + [DateTimeOffset]::Now.ToString('yyyy-MM-dd HH:mm:ss zzz'))
$reportLines.Add('')
$reportLines.Add("- 参考集：$referenceCount 张")
$reportLines.Add("- 隔离验证集：$validationCount 张")
$reportLines.Add("- 平均亮度：$([Math]::Round($meanLuminance, 4))")
$reportLines.Add("- 平均饱和度：$([Math]::Round($meanSaturation, 4))")
$reportLines.Add("- 平均网格局部对比：$([Math]::Round($meanContrast, 4))")
$reportLines.Add('')
$reportLines.Add('## 影调分布')
$reportLines.Add('')
foreach ($item in $toneCounts) { $reportLines.Add("- $($item.Name)：$($item.Count)") }
$reportLines.Add('')
$reportLines.Add('## 来源元数据类别')
$reportLines.Add('')
foreach ($item in $categoryCounts) { $reportLines.Add("- $($item.Name)：$($item.Count)") }
$reportLines.Add('')
$reportLines.Add('## 解释边界')
$reportLines.Add('')
$reportLines.Add('- 这些是缩小 sRGB 图像上的实际统计，不是 RAW 测量，也不是 Lightroom/Core Image 参数。')
$reportLines.Add('- 中心/边缘关系只是构图代理，不是主体识别。')
$reportLines.Add('- 特征变化不能证明审美提升；本轮没有运行 Core Image 或 iPhone 真机渲染。')
$reportLines.Add('- 数据集不存在官方原图—专家成片配对，本轮没有伪造配对。')
$reportLines | Set-Content -LiteralPath (Join-Path $reportRoot 'SAMPLE_STATISTICS.md') -Encoding utf8

[ordered]@{
    total = $allFeatures.Count
    reference = $referenceCount
    validation = $validationCount
    averageLuminance = [Math]::Round($meanLuminance, 6)
    averageSaturation = [Math]::Round($meanSaturation, 6)
    averageGridLocalContrast = [Math]::Round($meanContrast, 6)
} | ConvertTo-Json
