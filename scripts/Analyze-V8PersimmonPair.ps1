param(
    [string]$CaseDirectory = (Join-Path $PSScriptRoot '..\TestPhotos\V8_Persimmon'),
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'
$ffmpeg = (Get-Command ffmpeg -ErrorAction Stop).Source
$ffprobe = (Get-Command ffprobe -ErrorAction Stop).Source
$a = Join-Path $CaseDirectory 'original.jpg'
$b = Join-Path $CaseDirectory 'v8_build22_ai_edited.jpg'
foreach ($path in @($a, $b)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing paired photo: $path" }
}

function Get-Geometry([string]$path) {
    $json = & $ffprobe -v error -select_streams v:0 -show_entries stream=width,height,pix_fmt,color_space -of json -- $path
    $stream = ($json | ConvertFrom-Json).streams[0]
    [pscustomobject]@{
        width = [int]$stream.width
        height = [int]$stream.height
        pixelFormat = [string]$stream.pix_fmt
        colorSpace = [string]$stream.color_space
    }
}

function Get-SignalStatistics([string]$path, [string]$crop) {
    $filter = "$crop,signalstats,metadata=print:file=-"
    $lines = & $ffmpeg -hide_banner -v error -i $path -vf $filter -frames:v 1 -f null NUL
    $values = @{}
    foreach ($line in $lines) {
        if ($line -match 'lavfi\.signalstats\.(YLOW|YAVG|YHIGH|UAVG|VAVG|SATAVG)=([0-9.]+)') {
            $values[$Matches[1]] = [double]$Matches[2]
        }
    }
    [pscustomobject]@{
        yLow = $values.YLOW
        yAverage = $values.YAVG
        yHigh = $values.YHIGH
        yRange = $values.YHIGH - $values.YLOW
        uAverage = $values.UAVG
        vAverage = $values.VAVG
        saturationAverage = $values.SATAVG
    }
}

function Get-Comparison([string]$first, [string]$second) {
    $psnrOutput = (& $ffmpeg -hide_banner -i $first -i $second -lavfi psnr -f null NUL 2>&1) -join "`n"
    $ssimOutput = (& $ffmpeg -hide_banner -i $first -i $second -lavfi ssim -f null NUL 2>&1) -join "`n"
    $psnr = if ($psnrOutput -match 'average:([0-9.]+)') { [double]$Matches[1] } else { $null }
    $ssim = if ($ssimOutput -match 'All:([0-9.]+)') { [double]$Matches[1] } else { $null }
    [pscustomobject]@{ psnr = $psnr; ssim = $ssim }
}

$geometryA = Get-Geometry $a
$geometryB = Get-Geometry $b
if ($geometryA.width -ne $geometryB.width -or $geometryA.height -ne $geometryB.height) {
    throw 'The paired photos do not share the same canvas.'
}

$regions = [ordered]@{
    full = "crop=$($geometryA.width):$($geometryA.height):0:0"
    fruitCanopy = 'crop=850:900:0:0'
    overcastSky = 'crop=400:620:850:0'
    road = 'crop=520:760:760:760'
    foregroundFruitCrate = 'crop=380:330:540:1320'
}

$measurements = foreach ($item in @(
    [pscustomobject]@{ name = 'original'; path = $a },
    [pscustomobject]@{ name = 'v8_build22_ai_edited'; path = $b }
)) {
    foreach ($region in $regions.GetEnumerator()) {
        [pscustomobject]@{
            file = $item.name
            region = $region.Key
            metrics = Get-SignalStatistics -path $item.path -crop $region.Value
        }
    }
}

$result = [pscustomobject]@{
    generatedAt = [DateTimeOffset]::Now.ToString('o')
    sourceStatus = 'User confirmed on 2026-10-26 that 91999e... is the original; a789ec... is the paired V8 build 22 AI-edited output.'
    warning = 'FFmpeg is used only for paired diagnostics; it does not reproduce or validate the iOS Core Image pipeline.'
    files = @(
        [pscustomobject]@{ name = 'original'; path = (Resolve-Path $a).Path; sha256 = (Get-FileHash $a -Algorithm SHA256).Hash; geometry = $geometryA },
        [pscustomobject]@{ name = 'v8_build22_ai_edited'; path = (Resolve-Path $b).Path; sha256 = (Get-FileHash $b -Algorithm SHA256).Hash; geometry = $geometryB }
    )
    comparison = Get-Comparison -first $a -second $b
    measurements = $measurements
}

$json = $result | ConvertTo-Json -Depth 8
if (-not $OutputPath) { $OutputPath = Join-Path $CaseDirectory 'paired_metrics.json' }
Set-Content -LiteralPath $OutputPath -Value $json -Encoding utf8
$json
