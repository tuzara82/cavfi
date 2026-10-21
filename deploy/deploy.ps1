# CavFi - upload the site from this Windows PC to the Hetzner server and publish it.
# Run from C:\kingswap:
#   powershell -ExecutionPolicy Bypass -File deploy\deploy.ps1
# Run it again after any change to the site or addresses.json.

$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$ip   = Read-Host "Hetzner server IP"
$user = Read-Host "SSH user (press Enter for root)"
if (-not $user) { $user = "root" }
$target = "$user@$ip"

foreach ($f in @("$root\site\index.html", "$root\site\addresses.json", "$PSScriptRoot\setup-server.sh")) {
    if (-not (Test-Path $f)) { throw "Missing file: $f" }
}

Write-Host "Uploading to $target ..." -ForegroundColor Cyan
ssh $target "mkdir -p /tmp/cavfi-upload"
scp "$root\site\index.html" "$root\site\addresses.json" "$PSScriptRoot\setup-server.sh" "${target}:/tmp/cavfi-upload/"

Write-Host "Setting up the server ..." -ForegroundColor Cyan
$sudo = if ($user -eq "root") { "" } else { "sudo " }
ssh -t $target "sed -i 's/\r$//' /tmp/cavfi-upload/setup-server.sh && ${sudo}bash /tmp/cavfi-upload/setup-server.sh"
