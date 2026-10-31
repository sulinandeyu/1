[CmdletBinding()]
param(
    [int]$TargetCount = 250,
    [int]$ValidationCount = 30,
    [int]$ThumbnailWidth = 1600,
    [int]$MaximumApiPages = 80,
    [string]$OutputRoot = (Join-Path $PSScriptRoot '..\PhotographyDataset')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Drawing

$datasetRoot = [System.IO.Path]::GetFullPath($OutputRoot)
$manifestRoot = Join-Path $datasetRoot 'manifests'
$reportRoot = Join-Path $datasetRoot 'reports'
$assetRoot = Join-Path $datasetRoot 'assets'
$referenceRoot = Join-Path $assetRoot 'reference'
$validationRoot = Join-Path $assetRoot 'validation'

@($manifestRoot, $reportRoot, $referenceRoot, $validationRoot) | ForEach-Object {
    New-Item -ItemType Directory -Path $_ -Force | Out-Null
}

$referenceManifest = Join-Path $manifestRoot 'reference.jsonl'
$validationManifest = Join-Path $manifestRoot 'validation.jsonl'
$rejectedManifest = Join-Path $manifestRoot 'rejected.jsonl'
@($referenceManifest, $validationManifest, $rejectedManifest) | ForEach-Object {
    Set-Content -LiteralPath $_ -Value '' -NoNewline -Encoding utf8
}

$apiEndpoint = 'https://commons.wikimedia.org/w/api.php'
$featuredCategories = @(
    'Category:Featured pictures on Wikimedia Commons',
    'Category:Featured pictures of agriculture',
    'Category:Featured pictures of architecture',
    'Category:Featured pictures of astronomy',
    'Category:Featured pictures of cityscapes',
    'Category:Featured pictures of chemistry',
    'Category:Featured pictures of villages',
    'Category:Featured pictures of geology',
    'Category:Featured pictures of landscapes',
    'Category:Featured pictures of nature',
    'Category:Featured night photography',
    'Category:Featured pictures of objects',
    'Category:Featured pictures taken from satellites',
    'Category:Featured still-life photographs',
    'Category:Featured pictures of transport'
)
$headers = @{
    'User-Agent' = 'XiaoSuCameraDatasetBuilder/1.0 (license-audit; local-development)'
}

$allowedLicensePatterns = @(
    '^Public domain$',
    '^CC0',
    '^CC BY [234](\.0)?$',
    '^CC BY-SA [234](\.0|\.5)?$'
)

# This first import intentionally avoids obvious scans/artworks and identifiable
# people. The check is conservative metadata screening, not a legal or visual
# guarantee; every accepted record remains marked as automatic_screen_only.
$nonPhotoPattern = '(?i)(\bmap\b|painting|artwork|drawing|engraving|lithograph|manuscript|poster|restor(?:ed|ation)|fresco|illustration|diagram|coat of arms|banknote|postage stamp|book page|sheet music|screenshot)'
$personPattern = '(?i)(portrait|selfie|wedding|bride|groom|\bpeople\b|\bperson\b|\bwoman\b|\bwomen\b|\bman\b|\bmen\b|\bgirl\b|\bboy\b|\bchild\b|children|crowd)'
$rightsRiskPattern = '(?i)(\blogo\b|trademark|advertisement|billboard|sculpture|mural|museum artwork)'

function ConvertFrom-HtmlText {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '' }
    $text = [string]$Value
    $text = $text -replace '<[^>]+>', ' '
    $text = [System.Net.WebUtility]::HtmlDecode($text)
    return ($text -replace '\s+', ' ').Trim()
}

function Get-ExtMetadataValue {
    param([AllowNull()][object]$Metadata, [string]$Name)
    if ($null -eq $Metadata) { return '' }
    $property = $Metadata.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return '' }
    $valueProperty = $property.Value.PSObject.Properties['value']
    if ($null -eq $valueProperty) { return '' }
    return ConvertFrom-HtmlText $valueProperty.Value
}

function Test-AllowedLicense {
    param([string]$LicenseName)
    foreach ($pattern in $allowedLicensePatterns) {
        if ($LicenseName -match $pattern) { return $true }
    }
    return $false
}

function Get-SourcePageUrl {
    param([string]$Title)
    $normalized = $Title.Replace(' ', '_')
    return 'https://commons.wikimedia.org/wiki/' + [uri]::EscapeDataString($normalized)
}

function Get-LicenseDecision {
    param([string]$LicenseName)
    $isPublicDomain = $LicenseName -match '^(Public domain|CC0)'
    $isShareAlike = $LicenseName -match '^CC BY-SA'
    return [ordered]@{
        name = $LicenseName
        attributionRequired = -not $isPublicDomain
        shareAlike = $isShareAlike
        modelTraining = if ($isShareAlike) {
            'blocked_pending_legal_review'
        } else {
            'candidate_after_legal_review'
        }
        redistribution = if ($isShareAlike) {
            'allowed_with_share_alike'
        } else {
            'allowed_with_attribution'
        }
    }
}

function Get-PhotographyAnnotations {
    param([string]$Text)
    $categories = [System.Collections.Generic.List[string]]::new()
    $subjects = [System.Collections.Generic.List[string]]::new()
    $lighting = [System.Collections.Generic.List[string]]::new()

    if ($Text -match '(?i)(mountain|valley|landscape|canyon|volcano|forest|desert|cliff|field)') {
        $categories.Add('landscape'); $subjects.Add('natural_landscape')
    }
    if ($Text -match '(?i)(ocean|sea|lake|river|waterfall|coast|beach|harbour|harbor)') {
        $categories.Add('waterscape'); $subjects.Add('water')
    }
    if ($Text -match '(?i)(building|architecture|church|cathedral|mosque|temple|castle|bridge|city|street|tower)') {
        $categories.Add('architecture'); $subjects.Add('built_environment')
    }
    if ($Text -match '(?i)(bird|animal|wildlife|deer|fox|bear|whale|fish|insect|butterfly|dragonfly|bee)') {
        $categories.Add('wildlife'); $subjects.Add('animal')
    }
    if ($Text -match '(?i)(flower|plant|tree|leaf|orchid|fungus|mushroom)') {
        $categories.Add('nature_detail'); $subjects.Add('flora')
    }
    if ($Text -match '(?i)(aerial|drone|satellite)') { $categories.Add('aerial') }
    if ($Text -match '(?i)(train|aircraft|airplane|ship|boat|car|vehicle)') {
        $categories.Add('transport'); $subjects.Add('vehicle')
    }
    if ($Text -match '(?i)(interior|indoor|room|hall|library)') { $categories.Add('interior') }
    if ($Text -match '(?i)(night|milky way|starry|aurora|moonlight)') {
        $lighting.Add('night'); $categories.Add('low_light')
    } elseif ($Text -match '(?i)(sunset|sunrise|dawn|dusk|golden hour|twilight)') {
        $lighting.Add('transitional_natural_light')
    } elseif ($Text -match '(?i)(overcast|cloudy|storm cloud|fog|mist)') {
        $lighting.Add('diffuse_or_overcast')
    } elseif ($categories.Contains('interior')) {
        $lighting.Add('interior_or_mixed')
    } else {
        $lighting.Add('unspecified_natural_light')
    }
    if ($categories.Count -eq 0) { $categories.Add('documentary_or_other') }
    if ($subjects.Count -eq 0) { $subjects.Add('unspecified') }
    return [ordered]@{
        photographyCategories = @($categories | Select-Object -Unique)
        subjects = @($subjects | Select-Object -Unique)
        lighting = @($lighting | Select-Object -Unique)
        colorCharacteristics = @()
        annotationStatus = 'source_metadata_only'
    }
}

function Write-JsonLine {
    param([string]$Path, [object]$Value)
    $json = $Value | ConvertTo-Json -Depth 12 -Compress
    Add-Content -LiteralPath $Path -Value $json -Encoding utf8
}

function Write-Rejection {
    param([string]$Title, [string]$Reason, [string]$License = '')
    Write-JsonLine -Path $rejectedManifest -Value ([ordered]@{
        title = $Title
        reason = $Reason
        license = $License
    })
}

function Invoke-Download {
    param([string]$Uri, [string]$Destination)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Invoke-WebRequest -UseBasicParsing -Headers $headers -Uri $Uri -OutFile $Destination
            return
        } catch {
            if ($attempt -eq 3) { throw }
            Start-Sleep -Seconds $attempt
        }
    }
}

$accepted = 0
$validationAccepted = 0
$apiPages = 0
$categoryIndex = 0
$continuation = $null
$seenPageIds = [System.Collections.Generic.HashSet[string]]::new()
$licenseCounts = @{}
$categoryCounts = @{}
$startedAt = [DateTimeOffset]::UtcNow

while ($accepted -lt $TargetCount -and $apiPages -lt $MaximumApiPages -and $categoryIndex -lt $featuredCategories.Count) {
    $featuredCategory = $featuredCategories[$categoryIndex]
    $parameters = [ordered]@{
        action = 'query'
        generator = 'categorymembers'
        gcmtitle = $featuredCategory
        gcmtype = 'file'
        gcmsort = 'timestamp'
        gcmdir = 'older'
        gcmlimit = 'max'
        prop = 'imageinfo'
        iiprop = 'url|size|mime|sha1|extmetadata'
        iiurlwidth = $ThumbnailWidth
        format = 'json'
        formatversion = '2'
    }
    if ($continuation) { $parameters.gcmcontinue = $continuation }
    $query = ($parameters.GetEnumerator() | ForEach-Object {
        [System.Net.WebUtility]::UrlEncode([string]$_.Key) + '=' +
            [System.Net.WebUtility]::UrlEncode([string]$_.Value)
    }) -join '&'
    $response = Invoke-RestMethod -Headers $headers -Uri ($apiEndpoint + '?' + $query)
    $apiPages++

    foreach ($page in @($response.query.pages)) {
        if ($accepted -ge $TargetCount) { break }
        if (-not $seenPageIds.Add([string]$page.pageid)) { continue }
        $imageInfoProperty = $page.PSObject.Properties['imageinfo']
        if ($null -eq $imageInfoProperty -or $null -eq $imageInfoProperty.Value -or $imageInfoProperty.Value.Count -eq 0) {
            Write-Rejection -Title $page.title -Reason 'missing_imageinfo'
            continue
        }
        $info = $imageInfoProperty.Value[0]
        $metadata = $info.extmetadata
        $licenseName = Get-ExtMetadataValue $metadata 'LicenseShortName'
        $description = Get-ExtMetadataValue $metadata 'ImageDescription'
        $categoriesText = Get-ExtMetadataValue $metadata 'Categories'
        $creator = Get-ExtMetadataValue $metadata 'Artist'
        $credit = Get-ExtMetadataValue $metadata 'Credit'
        $licenseUrl = Get-ExtMetadataValue $metadata 'LicenseUrl'
        $screeningText = "$($page.title) $description $categoriesText"

        if (-not (Test-AllowedLicense $licenseName)) {
            Write-Rejection -Title $page.title -Reason 'license_not_in_allowlist' -License $licenseName
            continue
        }
        if ($info.mime -notin @('image/jpeg', 'image/png')) {
            Write-Rejection -Title $page.title -Reason 'unsupported_mime' -License $licenseName
            continue
        }
        if ([int]$info.width -lt 1200 -or [int]$info.height -lt 800) {
            Write-Rejection -Title $page.title -Reason 'insufficient_resolution' -License $licenseName
            continue
        }
        if ($screeningText -match $nonPhotoPattern) {
            Write-Rejection -Title $page.title -Reason 'metadata_indicates_non_photograph' -License $licenseName
            continue
        }
        if ($screeningText -match $personPattern) {
            Write-Rejection -Title $page.title -Reason 'possible_identifiable_people_deferred' -License $licenseName
            continue
        }
        if ($screeningText -match $rightsRiskPattern) {
            Write-Rejection -Title $page.title -Reason 'possible_trademark_or_artwork_deferred' -License $licenseName
            continue
        }

        $isValidation = $validationAccepted -lt $ValidationCount -and (($accepted % 8) -eq 0)
        $split = if ($isValidation) { 'validation' } else { 'reference' }
        $destinationRoot = if ($isValidation) { $validationRoot } else { $referenceRoot }
        $extension = if ($info.mime -eq 'image/png') { '.png' } else { '.jpg' }
        $id = 'commons-' + [string]$page.pageid
        $filename = $id + $extension
        $destination = Join-Path $destinationRoot $filename
        $thumbProperty = $info.PSObject.Properties['thumburl']
        $downloadUrl = if ($null -ne $thumbProperty -and $thumbProperty.Value) { [string]$thumbProperty.Value } else { [string]$info.url }

        try {
            Invoke-Download -Uri $downloadUrl -Destination $destination
            $bitmap = [System.Drawing.Image]::FromFile($destination)
            try {
                $localWidth = $bitmap.Width
                $localHeight = $bitmap.Height
            } finally {
                $bitmap.Dispose()
            }
            $sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $destination).Hash.ToLowerInvariant()
        } catch {
            if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Force }
            Write-Rejection -Title $page.title -Reason ('download_or_decode_failed: ' + $_.Exception.Message) -License $licenseName
            continue
        }

        $sourcePage = Get-SourcePageUrl $page.title
        $licenseDecision = Get-LicenseDecision $licenseName
        if ([string]::IsNullOrWhiteSpace($licenseUrl)) { $licenseUrl = $sourcePage }
        $annotations = Get-PhotographyAnnotations $screeningText
        $relativePath = [System.IO.Path]::GetRelativePath($datasetRoot, $destination).Replace('\', '/')
        $record = [ordered]@{
            id = $id
            split = $split
            assetRole = 'single_reference'
            pairId = $null
            source = [ordered]@{
                datasetId = 'wikimedia-commons-featured'
                title = [string]$page.title
                pageUrl = $sourcePage
                downloadUrl = $downloadUrl
                creator = $(if ($creator) { $creator } else { 'unknown' })
                credit = $credit
                description = $description
                sourceSha1 = [string]$info.sha1
            }
            license = [ordered]@{
                name = $licenseDecision.name
                url = $licenseUrl
                attributionRequired = $licenseDecision.attributionRequired
                shareAlike = $licenseDecision.shareAlike
                evidencePage = $sourcePage
            }
            authorization = [ordered]@{
                commercialReference = $true
                featureAnalysis = $true
                modelTraining = $licenseDecision.modelTraining
                redistribution = $licenseDecision.redistribution
                reviewStatus = 'dataset_rule_checked'
                notes = 'Per-file Commons metadata recorded. Human legal/content review is still required before model training or product distribution.'
            }
            contentRisk = [ordered]@{
                identifiablePeople = 'not_indicated'
                trademarkOrArtwork = 'not_indicated'
                reviewStatus = 'automatic_screen_only'
            }
            localAsset = [ordered]@{
                relativePath = $relativePath
                sha256 = $sha256
                ignoredByGit = $true
            }
            image = [ordered]@{
                width = $localWidth
                height = $localHeight
                mimeType = [string]$info.mime
            }
            annotations = $annotations
            provenance = [ordered]@{
                importedAt = [DateTimeOffset]::UtcNow.ToString('o')
                api = $apiEndpoint
                featuredCollection = $true
                originalEditedPairVerified = $false
            }
        }

        $manifest = if ($isValidation) { $validationManifest } else { $referenceManifest }
        Write-JsonLine -Path $manifest -Value $record
        $accepted++
        if ($isValidation) { $validationAccepted++ }
        if (-not $licenseCounts.ContainsKey($licenseName)) { $licenseCounts[$licenseName] = 0 }
        $licenseCounts[$licenseName]++
        foreach ($category in $annotations.photographyCategories) {
            if (-not $categoryCounts.ContainsKey($category)) { $categoryCounts[$category] = 0 }
            $categoryCounts[$category]++
        }
        Write-Progress -Activity 'Importing licensed featured photographs' -Status "$accepted / $TargetCount" -PercentComplete (($accepted / $TargetCount) * 100)
    }

    $continuationProperty = $response.PSObject.Properties['continue']
    if ($null -eq $continuationProperty -or $null -eq $response.continue) {
        $categoryIndex++
        $continuation = $null
        continue
    }
    $gcmContinuationProperty = $response.continue.PSObject.Properties['gcmcontinue']
    if ($null -eq $gcmContinuationProperty -or $null -eq $gcmContinuationProperty.Value) {
        $categoryIndex++
        $continuation = $null
        continue
    }
    $continuation = [string]$gcmContinuationProperty.Value
    if ([string]::IsNullOrWhiteSpace($continuation)) {
        $categoryIndex++
        $continuation = $null
    }
}

$summary = [ordered]@{
    source = 'wikimedia-commons-featured'
    api = $apiEndpoint
    startedAt = $startedAt.ToString('o')
    finishedAt = [DateTimeOffset]::UtcNow.ToString('o')
    requested = $TargetCount
    accepted = $accepted
    reference = $accepted - $validationAccepted
    validation = $validationAccepted
    validationDisjointBy = 'different Commons page ID, source URL and local SHA256'
    apiPagesRead = $apiPages
    sourceCategoriesRead = @($featuredCategories | Select-Object -First ([Math]::Min($featuredCategories.Count, $categoryIndex + 1)))
    targetReached = ($accepted -eq $TargetCount)
    licenses = $licenseCounts
    categories = $categoryCounts
    limitations = @(
        'Featured status is a Wikimedia community quality signal, not a professional retouch label.',
        'Metadata screening is not human legal review or reliable person/trademark detection.',
        'No original/expert-edited pairs were created.',
        'Downloaded pixels are local-only and ignored by Git.'
    )
}
$summaryPath = Join-Path $reportRoot 'import-summary.json'
$summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $summaryPath -Encoding utf8
Write-Progress -Activity 'Importing licensed featured photographs' -Completed
$summary | ConvertTo-Json -Depth 10

if ($accepted -lt $TargetCount) {
    throw "Only imported $accepted of $TargetCount requested images. Increase MaximumApiPages or review screening rules."
}
