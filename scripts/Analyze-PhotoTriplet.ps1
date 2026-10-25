param(
    [string]$PhotoDirectory = (Join-Path $PSScriptRoot '..\TestPhotos'),
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'
$names = @('original.jpg', 'mastercamera.jpg', 'reference.jpg')
$ffmpeg = (Get-Command ffmpeg -ErrorAction Stop).Source
$ffprobe = (Get-Command ffprobe -ErrorAction Stop).Source

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
    $filter = if ($crop) { "$crop,signalstats,metadata=print:file=-" } else { 'signalstats,metadata=print:file=-' }
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

$files = foreach ($name in $names) {
    $path = Join-Path $PhotoDirectory $name
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing required photo: $path" }
    $geometry = Get-Geometry $path
    [pscustomobject]@{
        name = $name
        path = (Resolve-Path -LiteralPath $path).Path
        sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        geometry = $geometry
    }
}

function Even([double]$value) { [int]([math]::Floor($value / 2) * 2) }
$commonWidth = Even (($files.geometry.width | Measure-Object -Minimum).Minimum)
$commonHeight = Even (($files.geometry.height | Measure-Object -Minimum).Minimum)

$regions = [ordered]@{
    full = "crop=${commonWidth}:${commonHeight}:0:0"
    sky = "crop=${commonWidth}:$(Even($commonHeight * 0.586)):0:0"
    mountain = "crop=${commonWidth}:$(Even($commonHeight * 0.246)):0:$(Even($commonHeight * 0.586))"
    foreground = "crop=${commonWidth}:$($commonHeight - (Even($commonHeight * 0.832))):0:$(Even($commonHeight * 0.832))"
    person = "crop=$(Even($commonWidth * 0.235)):$(Even($commonHeight * 0.363)):$(Even($commonWidth * 0.39)):$(Even($commonHeight * 0.615))"
}

$measurements = foreach ($file in $files) {
    foreach ($region in $regions.GetEnumerator()) {
        [pscustomobject]@{
            file = $file.name
            region = $region.Key
            metrics = Get-SignalStatistics -path $file.path -crop $region.Value
        }
    }
}

$result = [pscustomobject]@{
    generatedAt = [DateTimeOffset]::Now.ToString('o')
    note = 'FFmpeg diagnostic only; this does not execute or validate iOS Vision, Core ML, or Core Image.'
    commonComparisonCanvas = [pscustomobject]@{ width = $commonWidth; height = $commonHeight }
    files = $files
    measurements = $measurements
}

$jsonOutput = $result | ConvertTo-Json -Depth 8
if ($OutputPath) {
    $parent = Split-Path -Parent $OutputPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent | Out-Null }
    Set-Content -LiteralPath $OutputPath -Value $jsonOutput -Encoding utf8
}
$jsonOutput
