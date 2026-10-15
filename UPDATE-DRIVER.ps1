# Legacy name: safely forward to the existing-only updater.
& (Join-Path $PSScriptRoot 'UPDATE-EXISTING.ps1')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
