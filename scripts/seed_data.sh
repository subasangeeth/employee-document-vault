#!/usr/bin/env bash
# Bash script to seed employee directory and demo documents with versioning

set -euo pipefail

REGION=$(aws configure get region || echo "us-east-2")
REGION=$(echo "$REGION" | tr -d '[:space:]')
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text | tr -d '[:space:]')

DOC_BUCKET="employee-document-vault-${ACCOUNT_ID}-${REGION}"
DOC_TABLE="document_metadata"
EMPLOYEE_TABLE="employee_directory"

echo "Seeding Employee Directory and Demo Vault Data..."

# 1. Seed Directory
declare -a EMPLOYEES=(
  "EMP001:Alice Chen:MGR001:Engineering:emp001@example.com:Employee"
  "EMP002:Bob Smith:MGR001:Engineering:emp002@example.com:Employee"
  "EMP003:Charlie Davis:MGR001:Engineering:emp003@example.com:Employee"
  "EMP999:Zoe Vance:MGR999:Legal:emp999@example.com:Employee"
  "MGR001:Marcus Miller:EXEC:Engineering:mgr001@example.com:Manager"
  "HR001:Helen Ross:EXEC:HR:hr001@example.com:HR_Admin"
)

for emp in "${EMPLOYEES[@]}"; do
    IFS=":" read -r eId name mgr dept email role <<< "${emp}"
    ITEM_JSON=$(cat <<EOF
{
  "employee_id": {"S": "${eId}"},
  "name": {"S": "${name}"},
  "manager_id": {"S": "${mgr}"},
  "department": {"S": "${dept}"},
  "email": {"S": "${email}"},
  "role": {"S": "${role}"}
}
EOF
)
    TEMP_EMP=$(mktemp)
    echo "${ITEM_JSON}" > "${TEMP_EMP}"
    aws dynamodb put-item --table-name "${EMPLOYEE_TABLE}" --item "file://${TEMP_EMP}" --region "${REGION}" >/dev/null
    rm -f "${TEMP_EMP}"
done
echo "     Employee directory populated."

# 2. Upload Demo Docs
declare -a DEMO_DOCS=(
  "EMP001:offer-letter:offer-letter.pdf:Offer of Employment for Alice Chen - Senior Staff Engineer:offer,onboarding,2026"
  "EMP001:contract:employment-contract.pdf:Employment Agreement v1 for Alice Chen:contract,legal,confidential"
  "EMP001:payslip:payslip-2026-08.pdf:Salary Payslip August 2026 for Alice Chen:salary,payroll,2026"
  "EMP001:appraisal:appraisal-2026.pdf:Performance Appraisal 2026: Exceeds Expectations:appraisal,review"
  "EMP001:compliance:first-aid-certificate.pdf:Standard First Aid & CPR Level C Certificate:compliance,safety"
  "EMP002:offer-letter:offer-letter.pdf:Offer of Employment for Bob Smith - DevOps Engineer:offer,onboarding"
  "EMP002:contract:employment-contract.pdf:Employment Contract for Bob Smith:contract,legal"
  "EMP002:payslip:payslip-2026-08.pdf:Salary Payslip August 2026 for Bob Smith:salary,payroll"
  "EMP003:offer-letter:offer-letter.pdf:Offer of Employment for Charlie Davis - Frontend Engineer:offer,onboarding"
  "EMP003:contract:employment-contract.pdf:Employment Contract for Charlie Davis:contract,legal"
  "EMP999:contract:legal-confidentiality-contract.pdf:Confidentiality Agreement for Zoe Vance (Legal Dept):legal,privileged"
)

counter=100
versionedContractDocId=""

for d in "${DEMO_DOCS[@]}"; do
    IFS=":" read -r empId dType dFile dContent dTags <<< "${d}"
    counter=$((counter + 1))
    docId="DOC-${empId}-${counter}"
    s3Key="documents/${empId}/${dType}/${dFile}"
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    if [ "${empId}" = "EMP001" ] && [ "${dType}" = "contract" ]; then
        versionedContractDocId="${docId}"
    fi

    TEMP_FILE=$(mktemp)
    echo "${dContent}" > "${TEMP_FILE}"
    putResp=$(aws s3api put-object --bucket "${DOC_BUCKET}" --key "${s3Key}" --body "${TEMP_FILE}" --content-type "application/pdf" --region "${REGION}")
    vId=$(echo "${putResp}" | grep -o '"VersionId": "[^"]*' | cut -d'"' -f4 || echo "")
    rm -f "${TEMP_FILE}"

    # Build tags
    tagArr=()
    IFS="," read -ra tagsList <<< "${dTags}"
    for t in "${tagsList[@]}"; do
        tagArr+=("{\"S\": \"${t}\"}")
    done
    tagJson=$(IFS=,; echo "${tagArr[*]}")

    META_JSON=$(cat <<EOF
{
  "document_id": {"S": "${docId}"},
  "employee_id": {"S": "${empId}"},
  "uploaded_by": {"S": "${empId}"},
  "document_type": {"S": "${dType}"},
  "filename": {"S": "${dFile}"},
  "s3_key": {"S": "${s3Key}"},
  "upload_timestamp": {"S": "${timestamp}"},
  "tags": {"L": [${tagJson}]},
  "current_version_id": {"S": "${vId}"},
  "deleted": {"BOOL": false}
}
EOF
)
    TEMP_META=$(mktemp)
    echo "${META_JSON}" > "${TEMP_META}"
    aws dynamodb put-item --table-name "${DOC_TABLE}" --item "file://${TEMP_META}" --region "${REGION}" >/dev/null
    rm -f "${TEMP_META}"
done

# Version 2 of EMP001 Contract
v2Key="documents/EMP001/contract/employment-contract.pdf"
TEMP_V2=$(mktemp)
echo "Employment Agreement v2 (Amended Compensation & Title) for Alice Chen - Staff Principal" > "${TEMP_V2}"
putV2Resp=$(aws s3api put-object --bucket "${DOC_BUCKET}" --key "${v2Key}" --body "${TEMP_V2}" --content-type "application/pdf" --region "${REGION}")
v2VersionId=$(echo "${putV2Resp}" | grep -o '"VersionId": "[^"]*' | cut -d'"' -f4 || echo "")
rm -f "${TEMP_V2}"

aws dynamodb update-item --table-name "${DOC_TABLE}" --key "{\"document_id\":{\"S\":\"${versionedContractDocId}\"}}" \
  --update-expression "SET current_version_id = :v" --expression-attribute-values "{\":v\":{\"S\":\"${v2VersionId}\"}}" --region "${REGION}" >/dev/null

echo "Demo data seeded successfully."
