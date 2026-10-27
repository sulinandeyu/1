param(
    [string]$ManifestPath = "PhoneValidationDataset/manifest.jsonl"
)

$ErrorActionPreference = 'Stop'
$resolvedManifest = Resolve-Path -LiteralPath $ManifestPath -ErrorAction Stop
$manifestDirectory = Split-Path -Parent $resolvedManifest.Path
Add-Type -AssemblyName System.Drawing

$records = @(
    Get-Content -LiteralPath $resolvedManifest.Path |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_ | ConvertFrom-Json }
)
$failures = [System.Collections.Generic.List[string]]::new()
$ids = [System.Collections.Generic.HashSet[string]]::new()

foreach ($record in $records) {
    if (-not $ids.Add([string]$record.id)) {
        $failures.Add("duplicate id: $($record.id)")
    }
    if ($record.source.ownership -notin @('user_captured', 'explicitly_authorized')) {
        $failures.Add("unsupported ownership: $($record.id) -> $($record.source.ownership)")
    }
    if ([string]::IsNullOrWhiteSpace([string]$record.source.authorization)) {
        $failures.Add("missing authorization: $($record.id)")
    }
    $assetPath = [System.IO.Path]::GetFullPath(
        (Join-Path $manifestDirectory ([string]$record.relativePath))
    )
    if (-not (Test-Path -LiteralPath $assetPath -PathType Leaf)) {
        $failures.Add("missing asset: $($record.id) -> $assetPath")
        continue
    }
    $actualHash = (Get-FileHash -LiteralPath $assetPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne [string]$record.sha256) {
        $failures.Add("hash mismatch: $($record.id)")
    }
    $image = [System.Drawing.Image]::FromFile($assetPath)
    try {
        if ($image.Width -ne [int]$record.width -or $image.Height -ne [int]$record.height) {
            $failures.Add("dimension mismatch: $($record.id) expected $($record.width)x$($record.height), actual $($image.Width)x$($image.Height)")
        }
    } finally {
        $image.Dispose()
    }
}

$result = [ordered]@{
    status = if ($failures.Count -eq 0) { 'passed' } else { 'failed' }
    records = $records.Count
    targetRecords = 30
    missingRecords = [Math]::Max(0, 30 - $records.Count)
    ownershipAndAuthorizationRecorded = $failures.Count -eq 0
    baselineIPhoneExportsComplete = @($records | Where-Object { $_.validation.baselineB -ne 'pending_iphone_export' }).Count
    referenceCandidateIPhoneExportsComplete = @($records | Where-Object { $_.validation.referenceCandidateC -ne 'pending_iphone_export' }).Count
    humanPreferencesComplete = @($records | Where-Object { $_.validation.humanPreference -ne 'not_performed' }).Count
    failures = @($failures)
}

$result | ConvertTo-Json -Depth 6
if ($failures.Count -gt 0) { exit 1 }
