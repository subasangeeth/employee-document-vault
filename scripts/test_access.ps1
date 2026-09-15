# PowerShell wrapper to run the access control integration test suite

$ErrorActionPreference = "Stop"

Write-Host "Running Employee Document Vault Access Control Tests..." -ForegroundColor Cyan

python tests\test_access_control.py

if ($LASTEXITCODE -eq 0) {
    Write-Host "`nAll 10 Access Control Scenarios Verified Successfully." -ForegroundColor Green
} else {
    Write-Error "Access control test suite failed."
}
