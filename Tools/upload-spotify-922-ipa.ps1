# Upload a user-supplied Spotify 9.2.2 IPA to a temporary Filebin link
# The file is renamed .zip for broad host compatibility; its bytes are not modified.
# Anyone with the link can access it. Filebin links are temporary.

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms

$dialog = New-Object System.Windows.Forms.OpenFileDialog
$dialog.Title = "Select your own Spotify 9.2.2 IPA"
$dialog.Filter = "IPA files (*.ipa)|*.ipa|All files (*.*)|*.*"
$dialog.Multiselect = $false

if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
    Write-Host "No file selected. Nothing was uploaded."
    exit 0
}

$file = Get-Item -LiteralPath $dialog.FileName
if ($file.Length -lt 50000000) {
    throw "The selected file is unexpectedly small ($($file.Length) bytes). Select the complete Spotify IPA."
}

$curl = Get-Command curl.exe -ErrorAction SilentlyContinue
if (-not $curl) {
    throw "curl.exe was not found. Use a current Windows 10/11 installation or install curl."
}

$sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
$bin = [Guid]::NewGuid().ToString("N").Substring(0, 20)
$hostName = "spotify-9.2.2-base.zip"
$encodedName = [Uri]::EscapeDataString($hostName)
$binUrl = "https://filebin.net/$bin"
$uploadUrl = "$binUrl/$encodedName"
$responsePath = Join-Path $env:TEMP ("filebin-upload-" + [Guid]::NewGuid().ToString("N") + ".json")

Write-Host ""
Write-Host "File:   $($file.Name)"
Write-Host "Size:   $([Math]::Round($file.Length / 1MB, 2)) MB"
Write-Host "SHA256: $sha256"
Write-Host ""
Write-Warning "Filebin is a temporary link host. Anyone with the link can access the uploaded file. Do not continue if you do not want to share this IPA through a link."
$confirm = Read-Host "Type UPLOAD to continue"
if ($confirm -cne "UPLOAD") {
    Write-Host "Cancelled. Nothing was uploaded."
    exit 0
}

$args = @(
    "--fail", "--show-error", "--silent",
    "--request", "POST",
    "--header", "Content-Type: application/octet-stream",
    "--header", "Content-SHA256: $sha256",
    "--data-binary", "@$($file.FullName)",
    "--output", $responsePath,
    $uploadUrl
)

Write-Host "Uploading to Filebin..."
& curl.exe @args
if ($LASTEXITCODE -ne 0) {
    throw "Filebin upload failed (curl exit code $LASTEXITCODE). The service may be at capacity; try again later or use a private file host with a direct download URL."
}

try {
    $upload = Get-Content -LiteralPath $responsePath -Raw | ConvertFrom-Json
} finally {
    Remove-Item -LiteralPath $responsePath -Force -ErrorAction SilentlyContinue
}

if ($upload.file -and $upload.file.sha256 -and $upload.file.sha256.ToLowerInvariant() -ne $sha256) {
    throw "Filebin's returned SHA256 does not match the local file."
}

$binInfo = Invoke-RestMethod -Method Get -Uri $binUrl -Headers @{ Accept = "application/json" }
$remote = $binInfo.files | Where-Object { $_.filename -eq $hostName } | Select-Object -First 1
if (-not $remote) {
    throw "The upload response was received, but the file could not be found in the bin."
}
if ($remote.sha256 -and $remote.sha256.ToLowerInvariant() -ne $sha256) {
    throw "Remote SHA256 verification failed."
}

try {
    & curl.exe --fail --show-error --silent --request PUT --output NUL $binUrl
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "The upload succeeded, but Filebin did not confirm the read-only lock."
    }
} catch {
    Write-Warning "The upload succeeded, but the read-only lock could not be applied."
}

$directUrl = "$binUrl/$encodedName"

Write-Host ""
Write-Host "UPLOAD VERIFIED" -ForegroundColor Green
Write-Host "Remote SHA256: $sha256"
Write-Host ""
Write-Host "DIRECT DOWNLOAD URL:"
Write-Host $directUrl -ForegroundColor Cyan
Write-Host ""
Write-Host "Paste that direct URL into GitHub Actions > Build EeveeSpotify 7.5.0 + Local Mix Studio (Spotify 9.2.2) > Run workflow."
Write-Host "The filebin link is temporary. Delete the bin after the build if you no longer need it."
Write-Host ""
[void](Read-Host "Press Enter to close")
