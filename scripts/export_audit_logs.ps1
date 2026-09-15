# Script to export DynamoDB audit_log entries to JSON and CSV formats

$ErrorActionPreference = "Stop"

$REGION = (aws configure get region)
if (-not $REGION) { $REGION = "us-east-2" }
$REGION = $REGION.Trim()

$AUDIT_TABLE = "audit_log"

Write-Host "Exporting Audit Logs from DynamoDB table '$AUDIT_TABLE' ($REGION)..." -ForegroundColor Cyan

# Scan all audit records
$scanResp = aws dynamodb scan --table-name $AUDIT_TABLE --region $REGION | ConvertFrom-Json
$items = $scanResp.Items

Write-Host "  -> Retrieved $($items.Count) audit events." -ForegroundColor Green

# Parse DynamoDB typed attributes to clean objects
$cleanList = @()

foreach ($item in $items) {
    $obj = [PSCustomObject]@{
        audit_id           = if ($item.audit_id) { $item.audit_id.S } else { "" }
        timestamp          = if ($item.timestamp) { $item.timestamp.S } else { "" }
        user_id            = if ($item.user_id) { $item.user_id.S } else { "" }
        employee_id        = if ($item.employee_id) { $item.employee_id.S } else { "" }
        caller_employee_id = if ($item.caller_employee_id) { $item.caller_employee_id.S } else { "" }
        role               = if ($item.role) { $item.role.S } else { "" }
        action             = if ($item.action) { $item.action.S } else { "" }
        document_id        = if ($item.document_id) { $item.document_id.S } else { "" }
        s3_key             = if ($item.s3_key) { $item.s3_key.S } else { "" }
        result             = if ($item.result) { $item.result.S } else { "" }
        ip_address         = if ($item.ip_address) { $item.ip_address.S } else { "" }
        details            = if ($item.details) { $item.details.S } else { "" }
    }
    $cleanList += $obj
}

# Sort by timestamp descending
$sortedList = $cleanList | Sort-Object -Property timestamp -Descending

# Export to JSON
$jsonPath = "audit-log-export.json"
$sortedList | ConvertTo-Json -Depth 5 | Set-Content -Path $jsonPath -Encoding utf8
Write-Host "  -> Exported $($sortedList.Count) items to $jsonPath" -ForegroundColor Green

# Export to CSV
$csvPath = "audit-log-export.csv"
$sortedList | Export-Csv -Path $csvPath -NoTypeInformation -Encoding utf8
Write-Host "  -> Exported $($sortedList.Count) items to $csvPath" -ForegroundColor Green

# Display preview
Write-Host "`nRecent Audit Log Preview (Top 10 Events):" -ForegroundColor Yellow
$sortedList | Select-Object -First 10 | Format-Table -Property timestamp, action, role, employee_id, result, details -AutoSize
