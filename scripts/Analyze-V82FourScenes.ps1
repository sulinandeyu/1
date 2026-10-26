param(
    [string]$CaseDirectory = (Join-Path $PSScriptRoot '..\TestPhotos\V8_2_FourScenes'),
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'
$ffmpeg = (Get-Command ffmpeg -ErrorAction Stop).Source
$ffprobe = (Get-Command ffprobe -ErrorAction Stop).Source

$cases = @(
    [pscustomobject]@{
        id = 'A_selfie'
        original = 'A_selfie_original.jpg'
        edited = 'A_selfie_v81.jpg'
        regions = [ordered]@{
            full = 'crop=1280:1707:0:0'
            face = 'crop=620:760:300:300'
            greyJacket = 'crop=1080:560:100:1050'
        }
    },
    [pscustomobject]@{
        id = 'B_building'
        original = 'B_building_original.jpg'
        edited = 'B_building_v81.jpg'
        regions = [ordered]@{
            full = 'crop=1707:1280:0:0'
            overcastSky = 'crop=680:850:0:0'
            building = 'crop=980:900:700:0'
        }
    },
    [pscustomobject]@{
        id = 'C_vehicle_person'
        original = 'C_vehicle_person_original.jpg'
        edited = 'C_vehicle_person_v81.jpg'
        regions = [ordered]@{
            full = 'crop=1707:1280:0:0'
            person = 'crop=390:700:565:485'
            whiteVehicle = 'crop=820:760:690:285'
            sky = 'crop=620:460:0:0'
        }
    },
    [pscustomobject]@{
        id = 'D_trees'
        original = 'D_trees_original.jpg'
        edited = 'D_trees_v81.jpg'
        regions = [ordered]@{
            full = 'crop=1707:1280:0:0'
            overcastSky = 'crop=1707:520:0:0'
            vegetation = 'crop=1450:650:150:360'
            ground = 'crop=1707:360:0:920'
        }
    }
)

function Get-Geometry([string]$Path) {
    $json = & $ffprobe -v error -select_streams v:0 -show_entries stream=width,height,pix_fmt,color_space -of json -- $Path
    $stream = ($json | ConvertFrom-Json).streams[0]
    [pscustomobject]@{
        width = [int]$stream.width
        height = [int]$stream.height
        pixelFormat = [string]$stream.pix_fmt
        colorSpace = [string]$stream.color_space
    }
}

function Get-SignalStatistics([string]$Path, [string]$Crop) {
    $filter = "$Crop,signalstats,metadata=print:file=-"
    $lines = & $ffmpeg -hide_banner -v error -i $Path -vf $filter -frames:v 1 -f null NUL
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

function Get-Comparison([string]$Original, [string]$Edited) {
    $psnrOutput = (& $ffmpeg -hide_banner -i $Original -i $Edited -lavfi psnr -f null NUL 2>&1) -join "`n"
    $ssimOutput = (& $ffmpeg -hide_banner -i $Original -i $Edited -lavfi ssim -f null NUL 2>&1) -join "`n"
    [pscustomobject]@{
        psnr = if ($psnrOutput -match 'average:([0-9.]+)') { [double]$Matches[1] } else { $null }
        ssim = if ($ssimOutput -match 'All:([0-9.]+)') { [double]$Matches[1] } else { $null }
    }
}

$results = foreach ($case in $cases) {
    $originalPath = Join-Path $CaseDirectory $case.original
    $editedPath = Join-Path $CaseDirectory $case.edited
    foreach ($path in @($originalPath, $editedPath)) {
        if (-not (Test-Path -LiteralPath $path)) { throw "Missing paired photo: $path" }
    }
    $originalGeometry = Get-Geometry $originalPath
    $editedGeometry = Get-Geometry $editedPath
    if ($originalGeometry.width -ne $editedGeometry.width -or $originalGeometry.height -ne $editedGeometry.height) {
        throw "Canvas mismatch for $($case.id)"
    }
    $measurements = foreach ($file in @(
        [pscustomobject]@{ role = 'original'; path = $originalPath },
        [pscustomobject]@{ role = 'v8_1'; path = $editedPath }
    )) {
        foreach ($region in $case.regions.GetEnumerator()) {
            [pscustomobject]@{
                role = $file.role
                region = $region.Key
                metrics = Get-SignalStatistics -Path $file.path -Crop $region.Value
            }
        }
    }
    [pscustomobject]@{
        id = $case.id
        original = [pscustomobject]@{
            path = (Resolve-Path $originalPath).Path
            sha256 = (Get-FileHash $originalPath -Algorithm SHA256).Hash
            geometry = $originalGeometry
        }
        v8_1 = [pscustomobject]@{
            path = (Resolve-Path $editedPath).Path
            sha256 = (Get-FileHash $editedPath -Algorithm SHA256).Hash
            geometry = $editedGeometry
        }
        comparison = Get-Comparison -Original $originalPath -Edited $editedPath
        measurements = $measurements
    }
}

$report = [pscustomobject]@{
    generatedAt = [DateTimeOffset]::Now.ToString('o')
    sourceStatus = 'The user stated that the first image in each supplied pair is the original and the second is the V8.1 output.'
    warning = 'FFmpeg is used only to quantify the supplied JPEG pairs. It does not reproduce or validate the iOS Core Image pipeline.'
    cases = $results
}

if (-not $OutputPath) { $OutputPath = Join-Path $CaseDirectory 'v8_1_pair_metrics.json' }
$json = $report | ConvertTo-Json -Depth 9
Set-Content -LiteralPath $OutputPath -Value $json -Encoding utf8
$json
