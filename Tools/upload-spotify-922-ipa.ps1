# Upload a user-supplied Spotify 9.2.2 IPA to temporary Litterbox storage.
# The file is renamed .zip for broad host compatibility; its bytes are not modified.
# Litterbox links are public to anyone with the URL and expire after 72 hours.

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
if ($file.Length -gt 200000000) {
    throw "The selected file exceeds Litterbox's documented 200 MB upload limit."
}

if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
    throw "curl.exe was not found. Use a current Windows 10/11 installation or install curl."
}

$sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
$hostName = "spotify-9.2.2-base.zip"
$uploadUrl = "https://litterbox.catbox.moe/resources/internals/api.php"
$responsePath = Join-Path $env:TEMP ("litterbox-upload-" + [Guid]::NewGuid().ToString("N") + ".txt")

Write-Host ""
Write-Host "File:   $($file.Name)"
Write-Host "Size:   $([Math]::Round($file.Length / 1MB, 2)) MB"
Write-Host "SHA256: $sha256"
Write-Host ""
Write-Warning "Litterbox is temporary public hosting. Anyone with the link can download the file. It expires after 72 hours."
$confirm = Read-Host "Type UPLOAD to continue"
if ($confirm -cne "UPLOAD") {
    Write-Host "Cancelled. Nothing was uploaded."
    exit 0
}

$curlArgs = @(
    "--fail", "--show-error", "--silent",
    "--form", "reqtype=fileupload",
    "--form", "time=72h",
    "--form", "fileToUpload=@$($file.FullName);filename=$hostName",
    "--output", $responsePath,
    $uploadUrl
)

Write-Host "Uploading to temporary storage..."
& curl.exe @curlArgs
if ($LASTEXITCODE -ne 0) {
    throw "Litterbox upload failed (curl exit code $LASTEXITCODE). Check your connection and try again."
}

try {
    $directUrl = (Get-Content -LiteralPath $responsePath -Raw).Trim()
} finally {
    Remove-Item -LiteralPath $responsePath -Force -ErrorAction SilentlyContinue
}

if ($directUrl -notmatch '^https://litterbox\.catbox\.moe/') {
    throw "The upload service did not return a valid direct-download URL. Response: $directUrl"
}

try {
    Set-Clipboard -Value $directUrl
    $copied = $true
} catch {
    $copied = $false
}

Write-Host ""
Write-Host "UPLOAD COMPLETE" -ForegroundColor Green
Write-Host "Local SHA256: $sha256"
Write-Host "DIRECT DOWNLOAD URL:"
Write-Host $directUrl -ForegroundColor Cyan
if ($copied) { Write-Host "The URL has been copied to your clipboard." }
Write-Host ""
Write-Host "Paste that direct URL into GitHub Actions > Build EeveeSpotify 7.5.0 + Local Mix Studio (Spotify 9.2.2) > Run workflow."
Write-Host "The Litterbox link expires after 72 hours."
Write-Host ""
[void](Read-Host "Press Enter to close")
