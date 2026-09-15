#!/usr/bin/env bash
# Bash script to safely delete all provisioned AWS resources

set -euo pipefail

echo "Teardown: Cleaning up Employee Document Vault resources..."

REGION=$(aws configure get region || echo "us-east-2")
REGION=$(echo "$REGION" | tr -d '[:space:]')
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text | tr -d '[:space:]')

DOC_BUCKET="employee-document-vault-${ACCOUNT_ID}-${REGION}"
FRONTEND_BUCKET="employee-vault-frontend-${ACCOUNT_ID}-${REGION}"
API_NAME="EmployeeDocumentVaultAPI"
USER_POOL_NAME="EmployeeVaultUserPool"

# 1. Empty & Delete S3 Buckets
echo "  -> Emptying and deleting S3 buckets..."
if aws s3api head-bucket --bucket "${DOC_BUCKET}" 2>/dev/null; then
    # Delete object versions
    VERSIONS=$(aws s3api list-object-versions --bucket "${DOC_BUCKET}" --region "${REGION}" --output json 2>/dev/null || true)
    if [ -n "${VERSIONS}" ]; then
        python3 - <<EOF
import json, boto3
s3 = boto3.client("s3", region_name="${REGION}")
data = json.loads("""${VERSIONS}""")
for v in data.get("Versions", []):
    s3.delete_object(Bucket="${DOC_BUCKET}", Key=v["Key"], VersionId=v["VersionId"])
for dm in data.get("DeleteMarkers", []):
    s3.delete_object(Bucket="${DOC_BUCKET}", Key=dm["Key"], VersionId=dm["VersionId"])
EOF
    fi
    aws s3 rb "s3://${DOC_BUCKET}" --force --region "${REGION}" || true
fi

if aws s3api head-bucket --bucket "${FRONTEND_BUCKET}" 2>/dev/null; then
    aws s3 rb "s3://${FRONTEND_BUCKET}" --force --region "${REGION}" || true
fi

# 2. Delete API Gateway
echo "  -> Deleting API Gateway..."
API_ID=$(aws apigateway get-rest-apis --region "${REGION}" --query "items[?name=='${API_NAME}'].id" --output text 2>/dev/null || true)
if [ -n "${API_ID}" ] && [ "${API_ID}" != "None" ]; then
    aws apigateway delete-rest-api --rest-api-id "${API_ID}" --region "${REGION}" || true
fi

# 3. Delete Lambdas
echo "  -> Deleting Lambda functions..."
for fn in "EmployeeVaultUpload" "EmployeeVaultDownload" "EmployeeVaultList" "EmployeeVaultDelete" "EmployeeVaultVersion"; do
    aws lambda delete-function --function-name "${fn}" --region "${REGION}" 2>/dev/null || true
done

# 4. Delete DynamoDB Tables
echo "  -> Deleting DynamoDB tables..."
for tb in "document_metadata" "employee_directory" "audit_log"; do
    aws dynamodb delete-table --table-name "${tb}" --region "${REGION}" 2>/dev/null || true
done

# 5. Delete Cognito
echo "  -> Deleting Cognito User Pool..."
UP_ID=$(aws cognito-idp list-user-pools --max-results 60 --region "${REGION}" --query "UserPools[?Name=='${USER_POOL_NAME}'].Id" --output text 2>/dev/null || true)
if [ -n "${UP_ID}" ] && [ "${UP_ID}" != "None" ]; then
    aws cognito-idp delete-user-pool --user-pool-id "${UP_ID}" --region "${REGION}" || true
fi

# 6. Delete IAM Roles
echo "  -> Deleting IAM roles..."
for r in "LambdaUploadRole" "LambdaDownloadRole" "LambdaListRole" "LambdaDeleteRole" "LambdaVersionRole"; do
    aws iam delete-role-policy --role-name "${r}" --policy-name "${r}Policy" 2>/dev/null || true
    aws iam delete-role --role-name "${r}" 2>/dev/null || true
done

# 7. KMS Alias
echo "  -> Scheduling KMS key deletion..."
KMS_ID=$(aws kms list-aliases --region "${REGION}" --query "Aliases[?AliasName=='alias/employee-document-vault-key'].TargetKeyId" --output text 2>/dev/null || true)
if [ -n "${KMS_ID}" ] && [ "${KMS_ID}" != "None" ]; then
    aws kms delete-alias --alias-name "alias/employee-document-vault-key" --region "${REGION}" 2>/dev/null || true
    aws kms schedule-key-deletion --key-id "${KMS_ID}" --pending-window-in-days 7 --region "${REGION}" 2>/dev/null || true
fi

echo "Teardown complete."
