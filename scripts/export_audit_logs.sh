#!/usr/bin/env bash
# Bash script to export DynamoDB audit_log entries to JSON and CSV formats

set -euo pipefail

REGION=$(aws configure get region || echo "us-east-2")
REGION=$(echo "$REGION" | tr -d '[:space:]')
AUDIT_TABLE="audit_log"

echo "Exporting Audit Logs from DynamoDB table '${AUDIT_TABLE}' (${REGION})..."

python3 - <<EOF
import json
import csv
import boto3

region = "${REGION}"
table_name = "${AUDIT_TABLE}"

dynamodb = boto3.resource("dynamodb", region_name=region)
table = dynamodb.Table(table_name)

response = table.scan()
items = response.get("Items", [])

# Sort by timestamp descending
items.sort(key=lambda x: x.get("timestamp", ""), reverse=True)

# Export JSON
with open("audit-log-export.json", "w", encoding="utf-8") as f:
    json.dump(items, f, indent=2)
print(f"  -> Exported {len(items)} items to audit-log-export.json")

# Export CSV
fieldnames = [
    "audit_id", "timestamp", "user_id", "employee_id", "caller_employee_id",
    "role", "action", "document_id", "s3_key", "result", "ip_address", "details"
]

with open("audit-log-export.csv", "w", newline="", encoding="utf-8") as f:
    writer = csv.DictWriter(f, fieldnames=fieldnames, extrasaction="ignore")
    writer.writeheader()
    for it in items:
        writer.writerow(it)
print(f"  -> Exported {len(items)} items to audit-log-export.csv")

print("\nRecent Audit Log Preview (Top 10 Events):")
for it in items[:10]:
    print(f"  [{it.get('timestamp')}] {it.get('action'):<16} | {it.get('role'):<10} | {it.get('employee_id'):<8} | {it.get('result'):<7} | {it.get('details')}")
EOF

echo "Audit log export complete."
