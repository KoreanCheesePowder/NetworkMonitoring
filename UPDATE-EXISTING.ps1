$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot
Write-Host 'C.P Wallpad Network Monitor v1.1.5 - UPDATE EXISTING DRIVER ONLY' -ForegroundColor Cyan
$channelId = 'cd373cad-c1db-4b2a-943b-6ed6fb51d2fa'
$hubId = 'c9e6b370-41a7-499a-ae95-3496747cd165'
$driverId = 'b08dbe13-6340-4c77-8939-5b3e2ea4c837'
if (-not (Get-Command smartthings -ErrorAction SilentlyContinue)) {
  throw 'SmartThings CLI was not found on PATH.'
}
$config = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'config.yml') -Raw -Encoding UTF8
if ($config -notmatch '(?m)^packageKey:\s*cp-wallpad-network-monitor-v100\s*$') {
  throw 'Package key mismatch; existing driver was NOT changed.'
}
$profile = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'profiles/network-monitor.yml') -Raw -Encoding UTF8
if ($profile -notmatch '(?m)^\s*vid:\s*40758e17-c4bc-3b3f-a549-a3562f312024\s*$') {
  throw 'Presentation VID mismatch; existing driver was NOT changed.'
}
Write-Host 'Checking the existing driver on main hub...' -ForegroundColor Cyan
$installed = (& smartthings edge:drivers:installed "--hub=$hubId" -j 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0 -or $installed -notmatch [regex]::Escape($driverId)) {
  throw 'Existing Network Monitor driver was not confirmed on this hub. No changes made.'
}
Write-Host 'Packaging and updating the existing channel and hub...' -ForegroundColor Cyan
# SmartThings CLI 2.1.2: --hub implies install; do NOT add --install.
& smartthings edge:drivers:package . "--channel=$channelId" "--hub=$hubId"
if ($LASTEXITCODE -ne 0) { throw 'Wallpad Network Monitor driver update failed.' }
Write-Host 'UPDATE COMPLETE. Existing monitor device, 8 targets, routines and VID retained.' -ForegroundColor Green
Write-Host 'Check the existing Network Monitor device availability and v1.1.5 driver info.'
