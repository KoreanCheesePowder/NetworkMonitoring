$ErrorActionPreference = "Stop"
Set-Location -LiteralPath $PSScriptRoot
Write-Host "C.P Wallpad Network Monitor v1.1.4 - EXISTING DEVICE UPDATE ONLY"
Write-Host "This process does not create new custom capabilities or a new presentation."
Write-Host "Do not delete an existing SmartThings device."
if (-not (Test-Path ".\config.yml")) { throw "config.yml not found" }
$configText = Get-Content ".\config.yml" -Raw
if ($configText -notmatch 'packageKey:\s*cp-wallpad-network-monitor-v100') { throw "Unexpected packageKey; stop." }
& smartthings --version
if ($LASTEXITCODE -ne 0) { throw "SmartThings CLI not found" }
& smartthings edge:drivers:package . --install
if ($LASTEXITCODE -ne 0) { throw "Edge driver update failed" }
Write-Host "Package update submitted. Check the existing device's driver version v1.1.4 in SmartThings."
