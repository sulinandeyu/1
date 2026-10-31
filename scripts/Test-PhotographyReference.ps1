param(
    [Parameter(Mandatory = $true)]
    [string]$ManifestPath
)

$resolvedManifest = Resolve-Path -LiteralPath $ManifestPath -ErrorAction Stop
$manifestDirectory = Split-Path -Parent $resolvedManifest.Path
$record = Get-Content -Raw -LiteralPath $resolvedManifest.Path | ConvertFrom-Json
$errors = [System.Collections.Generic.List[string]]::new()

foreach ($field in @('id', 'license', 'originalPath', 'editedPath', 'goals', 'validation')) {
    if ($null -eq $record.$field) {
        $errors.Add("缺少必填字段: $field")
    }
}

if ($null -ne $record.license) {
    foreach ($field in @('owner', 'grant', 'evidencePath')) {
        if ([string]::IsNullOrWhiteSpace([string]$record.license.$field)) {
            $errors.Add("授权信息缺失: license.$field")
        }
    }
}

function Resolve-ReferenceFile([string]$value, [string]$label) {
    if ([string]::IsNullOrWhiteSpace($value)) {
        $errors.Add("路径为空: $label")
        return $null
    }
    $candidate = if ([System.IO.Path]::IsPathRooted($value)) {
        $value
    } else {
        Join-Path $manifestDirectory $value
    }
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        $errors.Add("文件不存在: $label -> $candidate")
        return $null
    }
    return (Resolve-Path -LiteralPath $candidate).Path
}

$original = Resolve-ReferenceFile ([string]$record.originalPath) 'originalPath'
$edited = Resolve-ReferenceFile ([string]$record.editedPath) 'editedPath'
$licenseEvidence = if ($null -ne $record.license) {
    Resolve-ReferenceFile ([string]$record.license.evidencePath) 'license.evidencePath'
}

$decision = [string]$record.validation.decision
if ($decision -notin @('pending', 'accepted', 'rejected')) {
    $errors.Add("validation.decision 必须是 pending、accepted 或 rejected")
}
if ($decision -eq 'accepted' -and [string]::IsNullOrWhiteSpace([string]$record.validation.reviewer)) {
    $errors.Add('accepted 记录必须填写 validation.reviewer')
}

$result = [pscustomobject]@{
    Manifest = $resolvedManifest.Path
    ID = [string]$record.id
    Original = $original
    Edited = $edited
    LicenseEvidence = $licenseEvidence
    ValidationDecision = $decision
    IsImportable = $errors.Count -eq 0
    Errors = @($errors)
}

$result | ConvertTo-Json -Depth 5
if ($errors.Count -gt 0) { exit 1 }
