$ErrorActionPreference = "Continue"
Set-Location $PSScriptRoot

Write-Host "==============================================="
Write-Host " C.P Wallpad Network Monitor Edge Driver v1.0.6"
Write-Host "==============================================="
Write-Host ""

& smartthings --version
if ($LASTEXITCODE -ne 0) { throw "SmartThings CLI not available." }

function Setup-Capability($capId, $capFile, $presFile, $transFile) {
    Write-Host "  Capability: $capId"
    $createOut = & smartthings capabilities:create -i $capFile -j 2>&1
    $createCode = $LASTEXITCODE
    $createText = ($createOut | Out-String)
    if ($createCode -ne 0) {
        if ($createText -match "already exists|Conflict|409|403|Forbidden|422") {
            Write-Host "  Capability already exists or create is restricted; continuing."
        } else {
            Write-Host $createText
            throw "Capability setup failed: $capId"
        }
    }

    $presOut = & smartthings capabilities:presentation:create $capId -i $presFile -j 2>&1
    if ($LASTEXITCODE -ne 0) {
        $updOut = & smartthings capabilities:presentation:update $capId -i $presFile -j 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host (($presOut | Out-String) + ($updOut | Out-String))
            throw "Capability presentation setup failed: $capId"
        }
    }

    $trOut = & smartthings capabilities:translations:upsert $capId -i $transFile -j 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host ($trOut | Out-String)
        Write-Host "  Translation skipped; continuing."
    }
}

Write-Host "[1/4] Setting network monitor capabilities..."
Setup-Capability "buildbook37604.wallpadStatusV102" ".\capabilities\status.json" ".\presentations\status.json" ".\translations\status-ko.json"
Setup-Capability "buildbook37604.wallpadSummaryV102" ".\capabilities\summary.json" ".\presentations\summary.json" ".\translations\summary-ko.json"
Setup-Capability "buildbook37604.wallpadCheckedV102" ".\capabilities\checked.json" ".\presentations\checked.json" ".\translations\checked-ko.json"

Write-Host "[2/4] Creating Device Presentation..."
$generated = ".\generated-device-config.json"
if (Test-Path $generated) { Remove-Item $generated -Force }
& smartthings presentation:device-config:create -i ".\device-config.json" -o $generated -j
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $generated)) { throw "Device presentation creation failed." }

$generatedText = [IO.File]::ReadAllText((Resolve-Path $generated),(New-Object Text.UTF8Encoding($false)))
$dp = $generatedText | ConvertFrom-Json
$vid = if ($dp.presentationId) {[string]$dp.presentationId} elseif ($dp.vid) {[string]$dp.vid} else {""}
$mnmn = if ($dp.manufacturerName) {[string]$dp.manufacturerName} elseif ($dp.mnmn) {[string]$dp.mnmn} else {""}
if ([string]::IsNullOrWhiteSpace($vid) -or [string]::IsNullOrWhiteSpace($mnmn)) { throw "VID/MNMN read failed." }

Write-Host "[3/4] Applying Device Presentation VID..."
$profilePath = ".\profiles\network-monitor.yml"
$profile = [IO.File]::ReadAllText((Resolve-Path $profilePath),(New-Object Text.UTF8Encoding($false)))
$profile = [regex]::Replace($profile,'(?m)^\s*mnmn:\s*.*$',"  mnmn: $mnmn")
$profile = [regex]::Replace($profile,'(?m)^\s*vid:\s*.*$',"  vid: $vid")
[IO.File]::WriteAllText((Resolve-Path $profilePath),$profile,(New-Object Text.UTF8Encoding($false)))

Write-Host "[4/4] Packaging/installing v1.0.6..."
& smartthings edge:drivers:package . --install
if ($LASTEXITCODE -ne 0) { throw "Driver package/install failed." }

Write-Host ""
Write-Host "Installation completed."
Write-Host "SmartThings app -> Add device -> Scan nearby"
Write-Host "Open device settings to edit/add/remove targets."
