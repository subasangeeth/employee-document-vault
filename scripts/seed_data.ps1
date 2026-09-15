# PowerShell wrapper to seed employee directory and demo documents

$ErrorActionPreference = "Stop"

Write-Host "Seeding Employee Vault data using Python..." -ForegroundColor Cyan

python scripts\seed_data.py

if ($LASTEXITCODE -eq 0) {
    Write-Host "Seed completed successfully." -ForegroundColor Green
} else {
    Write-Error "Seed data script failed."
}
