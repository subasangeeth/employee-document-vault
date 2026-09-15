#!/usr/bin/env bash
# Bash Automated Deployment Script for Employee Document Vault
# Idempotent provisioning using AWS CLI

set -euo pipefail

echo "=========================================================="
echo "   Employee Document Vault - AWS CLI Automated Deployment   "
echo "=========================================================="

# 1. Environment Detection
echo "[1/11] Detecting AWS Environment..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text | tr -d '[:space:]')
REGION=$(aws configure get region || echo "us-east-2")
REGION=$(echo "$REGION" | tr -d '[:space:]')

DOC_BUCKET="employee-document-vault-${ACCOUNT_ID}-${REGION}"
FRONTEND_BUCKET="employee-vault-frontend-${ACCOUNT_ID}-${REGION}"
DOC_TABLE="document_metadata"
EMPLOYEE_TABLE="employee_directory"
AUDIT_TABLE="audit_log"
USER_POOL_NAME="EmployeeVaultUserPool"
API_NAME="EmployeeDocumentVaultAPI"

echo "  -> Account ID: ${ACCOUNT_ID}"
echo "  -> Region:     ${REGION}"
echo "  -> Doc Bucket: ${DOC_BUCKET}"

# 2. KMS Key Setup
echo ""
echo "[2/11] Configuring KMS Customer-Managed Key..."
KMS_ALIAS="alias/employee-document-vault-key"
KMS_KEY_ID=$(aws kms list-aliases --region "${REGION}" --query "Aliases[?AliasName=='${KMS_ALIAS}'].TargetKeyId" --output text | tr -d '[:space:]' || true)

if [ -n "${KMS_KEY_ID}" ] && [ "${KMS_KEY_ID}" != "None" ]; then
    echo "  -> KMS Key already exists: ${KMS_KEY_ID}"
else
    echo "  -> Creating KMS Key with key-policy.json..."
    TEMP_POL=$(mktemp)
    sed "s/ACCOUNT_ID/${ACCOUNT_ID}/g" infrastructure/kms/key-policy.json > "${TEMP_POL}"
    KMS_KEY_ID=$(aws kms create-key --description "KMS Key for Employee Document Vault SSE-KMS" --policy "file://${TEMP_POL}" --region "${REGION}" --query KeyMetadata.KeyId --output text | tr -d '[:space:]')
    aws kms create-alias --alias-name "${KMS_ALIAS}" --target-key-id "${KMS_KEY_ID}" --region "${REGION}"
    rm -f "${TEMP_POL}"
    echo "  -> Created KMS Key: ${KMS_KEY_ID}"
fi
KMS_KEY_ARN="arn:aws:kms:${REGION}:${ACCOUNT_ID}:key/${KMS_KEY_ID}"

# 3. S3 Document Bucket Provisioning
echo ""
echo "[3/11] Provisioning S3 Document Vault Bucket..."
if ! aws s3api head-bucket --bucket "${DOC_BUCKET}" 2>/dev/null; then
    echo "  -> Creating bucket ${DOC_BUCKET}..."
    if [ "${REGION}" = "us-east-1" ]; then
        aws s3api create-bucket --bucket "${DOC_BUCKET}" --region "${REGION}" >/dev/null
    else
        aws s3api create-bucket --bucket "${DOC_BUCKET}" --region "${REGION}" --create-bucket-configuration LocationConstraint="${REGION}" >/dev/null
    fi
else
    echo "  -> Bucket ${DOC_BUCKET} exists."
fi

# Versioning
aws s3api put-bucket-versioning --bucket "${DOC_BUCKET}" --versioning-configuration Status=Enabled --region "${REGION}"

# Block Public Access
aws s3api put-public-access-block --bucket "${DOC_BUCKET}" --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" --region "${REGION}"

# Bucket Owner Enforced
aws s3api put-bucket-ownership-controls --bucket "${DOC_BUCKET}" --ownership-controls "Rules=[{ObjectOwnership=BucketOwnerEnforced}]" --region "${REGION}"

# SSE-KMS Default Encryption
ENC_CONF=$(cat <<EOF
{
  "Rules": [
    {
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "aws:kms",
        "KMSMasterKeyId": "${KMS_KEY_ARN}"
      },
      "BucketKeyEnabled": true
    }
  ]
}
EOF
)
TEMP_ENC=$(mktemp)
echo "${ENC_CONF}" > "${TEMP_ENC}"
aws s3api put-bucket-encryption --bucket "${DOC_BUCKET}" --server-side-encryption-configuration "file://${TEMP_ENC}" --region "${REGION}"
rm -f "${TEMP_ENC}"

# Lifecycle Policy
aws s3api put-bucket-lifecycle-configuration --bucket "${DOC_BUCKET}" --lifecycle-configuration file://infrastructure/s3/lifecycle.json --region "${REGION}"

# Enforce HTTPS Only Bucket Policy
TEMP_BP=$(mktemp)
sed "s/BUCKET_NAME/${DOC_BUCKET}/g" infrastructure/s3/bucket-policy.json > "${TEMP_BP}"
aws s3api put-bucket-policy --bucket "${DOC_BUCKET}" --policy "file://${TEMP_BP}" --region "${REGION}"
rm -f "${TEMP_BP}"
echo "  -> S3 Storage successfully configured."

# 4. DynamoDB Tables
echo ""
echo "[4/11] Provisioning DynamoDB Tables..."
if ! aws dynamodb describe-table --table-name "${DOC_TABLE}" --region "${REGION}" 2>/dev/null; then
    aws dynamodb create-table \
      --table-name "${DOC_TABLE}" \
      --attribute-definitions AttributeName=document_id,AttributeType=S AttributeName=employee_id,AttributeType=S AttributeName=upload_timestamp,AttributeType=S \
      --key-schema AttributeName=document_id,KeyType=HASH \
      --global-secondary-indexes "IndexName=EmployeeDocumentsIndex,KeySchema=[{AttributeName=employee_id,KeyType=HASH},{AttributeName=upload_timestamp,KeyType=RANGE}],Projection={ProjectionType=ALL}" \
      --billing-mode PAY_PER_REQUEST \
      --region "${REGION}" >/dev/null
    aws dynamodb wait table-exists --table-name "${DOC_TABLE}" --region "${REGION}"
    aws dynamodb update-continuous-backups --table-name "${DOC_TABLE}" --point-in-time-recovery-specification PointInTimeRecoveryEnabled=true --region "${REGION}" >/dev/null
fi

if ! aws dynamodb describe-table --table-name "${EMPLOYEE_TABLE}" --region "${REGION}" 2>/dev/null; then
    aws dynamodb create-table \
      --table-name "${EMPLOYEE_TABLE}" \
      --attribute-definitions AttributeName=employee_id,AttributeType=S AttributeName=manager_id,AttributeType=S \
      --key-schema AttributeName=employee_id,KeyType=HASH \
      --global-secondary-indexes "IndexName=ManagerIndex,KeySchema=[{AttributeName=manager_id,KeyType=HASH}],Projection={ProjectionType=ALL}" \
      --billing-mode PAY_PER_REQUEST \
      --region "${REGION}" >/dev/null
    aws dynamodb wait table-exists --table-name "${EMPLOYEE_TABLE}" --region "${REGION}"
fi

if ! aws dynamodb describe-table --table-name "${AUDIT_TABLE}" --region "${REGION}" 2>/dev/null; then
    aws dynamodb create-table \
      --table-name "${AUDIT_TABLE}" \
      --attribute-definitions AttributeName=audit_id,AttributeType=S AttributeName=timestamp,AttributeType=S \
      --key-schema AttributeName=audit_id,KeyType=HASH AttributeName=timestamp,KeyType=RANGE \
      --billing-mode PAY_PER_REQUEST \
      --region "${REGION}" >/dev/null
    aws dynamodb wait table-exists --table-name "${AUDIT_TABLE}" --region "${REGION}"
    aws dynamodb update-continuous-backups --table-name "${AUDIT_TABLE}" --point-in-time-recovery-specification PointInTimeRecoveryEnabled=true --region "${REGION}" >/dev/null
fi
echo "  -> DynamoDB Tables ready."

# 5. Cognito User Pool
echo ""
echo "[5/11] Provisioning Amazon Cognito User Pool..."
USER_POOL_ID=$(aws cognito-idp list-user-pools --max-results 60 --region "${REGION}" --query "UserPools[?Name=='${USER_POOL_NAME}'].Id" --output text | tr -d '[:space:]' || true)
if [ -z "${USER_POOL_ID}" ] || [ "${USER_POOL_ID}" = "None" ]; then
    USER_POOL_ID=$(aws cognito-idp create-user-pool \
      --pool-name "${USER_POOL_NAME}" \
      --auto-verified-attributes email \
      --schema Name=employee_id,AttributeDataType=String,Mutable=true Name=role,AttributeDataType=String,Mutable=true \
      --policies "PasswordPolicy={MinimumLength=8,RequireUppercase=true,RequireLowercase=true,RequireNumbers=true,RequireSymbols=true}" \
      --region "${REGION}" --query UserPool.Id --output text | tr -d '[:space:]')
fi
USER_POOL_ARN="arn:aws:cognito-idp:${REGION}:${ACCOUNT_ID}:userpool/${USER_POOL_ID}"

for grp in "HR_Admin" "Manager" "Employee"; do
    if ! aws cognito-idp get-group --group-name "${grp}" --user-pool-id "${USER_POOL_ID}" --region "${REGION}" 2>/dev/null; then
        aws cognito-idp create-group --group-name "${grp}" --user-pool-id "${USER_POOL_ID}" --description "${grp} Group for Document Vault" --region "${REGION}" >/dev/null
    fi
done

CLIENT_ID=$(aws cognito-idp list-user-pool-clients --user-pool-id "${USER_POOL_ID}" --region "${REGION}" --query "UserPoolClients[?ClientName=='EmployeeVaultWebClient'].ClientId" --output text | tr -d '[:space:]' || true)
if [ -z "${CLIENT_ID}" ] || [ "${CLIENT_ID}" = "None" ]; then
    CLIENT_ID=$(aws cognito-idp create-user-pool-client \
      --user-pool-id "${USER_POOL_ID}" \
      --client-name "EmployeeVaultWebClient" \
      --no-generate-secret \
      --explicit-auth-flows ALLOW_USER_PASSWORD_AUTH ALLOW_REFRESH_TOKEN_AUTH ALLOW_USER_SRP_AUTH \
      --region "${REGION}" --query UserPoolClient.ClientId --output text | tr -d '[:space:]')
fi
echo "  -> Cognito Pool: ${USER_POOL_ID}, Client: ${CLIENT_ID}"

# 6. IAM Roles
echo ""
echo "[6/11] Provisioning IAM Roles..."
declare -A ROLES=(
  ["LambdaUploadRole"]="infrastructure/iam/upload-policy.json"
  ["LambdaDownloadRole"]="infrastructure/iam/download-policy.json"
  ["LambdaListRole"]="infrastructure/iam/list-policy.json"
  ["LambdaDeleteRole"]="infrastructure/iam/delete-policy.json"
  ["LambdaVersionRole"]="infrastructure/iam/version-policy.json"
)

for roleName in "${!ROLES[@]}"; do
    if ! aws iam get-role --role-name "${roleName}" 2>/dev/null; then
        aws iam create-role --role-name "${roleName}" --assume-role-policy-document file://infrastructure/iam/trust-policy.json >/dev/null
    fi
    TEMP_POL=$(mktemp)
    sed -e "s/BUCKET_NAME/${DOC_BUCKET}/g" -e "s|KMS_KEY_ARN|${KMS_KEY_ARN}|g" "${ROLES[$roleName]}" > "${TEMP_POL}"
    aws iam put-role-policy --role-name "${roleName}" --policy-name "${roleName}Policy" --policy-document "file://${TEMP_POL}"
    rm -f "${TEMP_POL}"
done
echo "  -> Waiting 10s for IAM propagation..."
sleep 10

# 7. Package and Deploy Lambdas
echo ""
echo "[7/11] Packaging & Deploying Lambda Functions..."
mkdir -p dist
declare -A FNS=(
  ["EmployeeVaultUpload"]="lambda/upload:LambdaUploadRole"
  ["EmployeeVaultDownload"]="lambda/download:LambdaDownloadRole"
  ["EmployeeVaultList"]="lambda/list_files:LambdaListRole"
  ["EmployeeVaultDelete"]="lambda/delete:LambdaDeleteRole"
  ["EmployeeVaultVersion"]="lambda/version_history:LambdaVersionRole"
)

for fnName in "${!FNS[@]}"; do
    IFS=":" read -r fnDir fnRole <<< "${FNS[$fnName]}"
    roleArn="arn:aws:iam::${ACCOUNT_ID}:role/${fnRole}"
    zipPath="dist/${fnName}.zip"
    
    TEMP_PACK=$(mktemp -d)
    cp "${fnDir}/handler.py" "${TEMP_PACK}/"
    cp "lambda/common/auth.py" "${TEMP_PACK}/"
    (cd "${TEMP_PACK}" && zip -r -q - .) > "${zipPath}"
    rm -rf "${TEMP_PACK}"

    if aws lambda get-function --function-name "${fnName}" --region "${REGION}" 2>/dev/null; then
        aws lambda update-function-code --function-name "${fnName}" --zip-file "fileb://${zipPath}" --region "${REGION}" >/dev/null
        aws lambda update-function-configuration --function-name "${fnName}" \
          --environment "Variables={DOCUMENT_BUCKET=${DOC_BUCKET},DOCUMENT_TABLE=${DOC_TABLE},EMPLOYEE_TABLE=${EMPLOYEE_TABLE},AUDIT_TABLE=${AUDIT_TABLE},KMS_KEY_ID=${KMS_KEY_ID},COGNITO_USER_POOL_ID=${USER_POOL_ID},AWS_REGION=${REGION}}" \
          --region "${REGION}" >/dev/null
    else
        aws lambda create-function \
          --function-name "${fnName}" \
          --runtime python3.12 \
          --role "${roleArn}" \
          --handler "handler.lambda_handler" \
          --zip-file "fileb://${zipPath}" \
          --timeout 15 \
          --memory-size 256 \
          --environment "Variables={DOCUMENT_BUCKET=${DOC_BUCKET},DOCUMENT_TABLE=${DOC_TABLE},EMPLOYEE_TABLE=${EMPLOYEE_TABLE},AUDIT_TABLE=${AUDIT_TABLE},KMS_KEY_ID=${KMS_KEY_ID},COGNITO_USER_POOL_ID=${USER_POOL_ID},AWS_REGION=${REGION}}" \
          --region "${REGION}" >/dev/null
    fi
    echo "  -> Deployed ${fnName}"
done

# 8. API Gateway Setup
echo ""
echo "[8/11] Setting up API Gateway REST API & Cognito Authorizer..."
API_ID=$(aws apigateway get-rest-apis --region "${REGION}" --query "items[?name=='${API_NAME}'].id" --output text | tr -d '[:space:]' || true)
if [ -z "${API_ID}" ] || [ "${API_ID}" = "None" ]; then
    API_ID=$(aws apigateway create-rest-api --name "${API_NAME}" --description "Employee Document Vault REST API" --endpoint-configuration types=REGIONAL --region "${REGION}" --query id --output text | tr -d '[:space:]')
fi
ROOT_ID=$(aws apigateway get-resources --rest-api-id "${API_ID}" --region "${REGION}" --query "items[?path=='/'].id" --output text | tr -d '[:space:]')

AUTHORIZER_ID=$(aws apigateway get-authorizers --rest-api-id "${API_ID}" --region "${REGION}" --query "items[?name=='CognitoAuthorizer'].id" --output text | tr -d '[:space:]' || true)
if [ -z "${AUTHORIZER_ID}" ] || [ "${AUTHORIZER_ID}" = "None" ]; then
    AUTHORIZER_ID=$(aws apigateway create-authorizer \
      --rest-api-id "${API_ID}" \
      --name "CognitoAuthorizer" \
      --type COGNITO_USER_POOLS \
      --provider-arns "${USER_POOL_ARN}" \
      --identity-source "method.request.header.Authorization" \
      --region "${REGION}" --query id --output text | tr -d '[:space:]')
fi

# Helper functions
get_or_create_res() {
    local pId="$1"
    local pPart="$2"
    local ex
    ex=$(aws apigateway get-resources --rest-api-id "${API_ID}" --region "${REGION}" --query "items[?parentId=='${pId}' && pathPart=='${pPart}'].id" --output text | tr -d '[:space:]' || true)
    if [ -n "${ex}" ] && [ "${ex}" != "None" ]; then
        echo "${ex}"
    else
        aws apigateway create-resource --rest-api-id "${API_ID}" --parent-id "${pId}" --path-part "${pPart}" --region "${REGION}" --query id --output text | tr -d '[:space:]'
    fi
}

setup_method() {
    local rId="$1"
    local meth="$2"
    local fn="$3"
    local lArn="arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:${fn}"
    local uri="arn:aws:apigateway:${REGION}:lambda:path/2015-03-31/functions/${lArn}/invocations"

    aws apigateway delete-method --rest-api-id "${API_ID}" --resource-id "${rId}" --http-method "${meth}" --region "${REGION}" 2>/dev/null || true
    aws apigateway put-method \
      --rest-api-id "${API_ID}" \
      --resource-id "${rId}" \
      --http-method "${meth}" \
      --authorization-type COGNITO_USER_POOLS \
      --authorizer-id "${AUTHORIZER_ID}" \
      --region "${REGION}" >/dev/null

    aws apigateway put-integration \
      --rest-api-id "${API_ID}" \
      --resource-id "${rId}" \
      --http-method "${meth}" \
      --type AWS_PROXY \
      --integration-http-method POST \
      --uri "${uri}" \
      --region "${REGION}" >/dev/null

    local stmtId="apigateway-${rId}-${meth}"
    aws lambda remove-permission --function-name "${lArn}" --statement-id "${stmtId}" --region "${REGION}" 2>/dev/null || true
    aws lambda add-permission \
      --function-name "${lArn}" \
      --statement-id "${stmtId}" \
      --action lambda:InvokeFunction \
      --principal apigateway.amazonaws.com \
      --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT_ID}:${API_ID}/*/${meth}/*" \
      --region "${REGION}" >/dev/null

    # OPTIONS CORS
    aws apigateway delete-method --rest-api-id "${API_ID}" --resource-id "${rId}" --http-method OPTIONS --region "${REGION}" 2>/dev/null || true
    aws apigateway put-method --rest-api-id "${API_ID}" --resource-id "${rId}" --http-method OPTIONS --authorization-type NONE --region "${REGION}" >/dev/null
    aws apigateway put-integration --rest-api-id "${API_ID}" --resource-id "${rId}" --http-method OPTIONS --type MOCK --request-templates '{"application/json":"{\"statusCode\": 200}"}' --region "${REGION}" >/dev/null
    aws apigateway put-method-response --rest-api-id "${API_ID}" --resource-id "${rId}" --http-method OPTIONS --status-code 200 \
      --response-parameters '{"method.response.header.Access-Control-Allow-Headers":true,"method.response.header.Access-Control-Allow-Methods":true,"method.response.header.Access-Control-Allow-Origin":true}' --region "${REGION}" >/dev/null
    aws apigateway put-integration-response --rest-api-id "${API_ID}" --resource-id "${rId}" --http-method OPTIONS --status-code 200 \
      --response-parameters '{"method.response.header.Access-Control-Allow-Headers":"\x27Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token\x27","method.response.header.Access-Control-Allow-Methods":"\x27GET,POST,DELETE,OPTIONS\x27","method.response.header.Access-Control-Allow-Origin":"\x27*\x27"}' --region "${REGION}" >/dev/null
}

resUpload=$(get_or_create_res "${ROOT_ID}" "upload")
setup_method "${resUpload}" "POST" "EmployeeVaultUpload"

resFiles=$(get_or_create_res "${ROOT_ID}" "files")
setup_method "${resFiles}" "GET" "EmployeeVaultList"

resFilesDocId=$(get_or_create_res "${resFiles}" "{doc_id}")
setup_method "${resFilesDocId}" "DELETE" "EmployeeVaultDelete"

resVersions=$(get_or_create_res "${resFilesDocId}" "versions")
setup_method "${resVersions}" "GET" "EmployeeVaultVersion"

resDownload=$(get_or_create_res "${ROOT_ID}" "download")
resDownloadDocId=$(get_or_create_res "${resDownload}" "{doc_id}")
setup_method "${resDownloadDocId}" "GET" "EmployeeVaultDownload"

aws apigateway create-deployment --rest-api-id "${API_ID}" --stage-name prod --region "${REGION}" >/dev/null
API_BASE_URL="https://${API_ID}.execute-api.${REGION}.amazonaws.com/prod"
echo "  -> API Gateway: ${API_BASE_URL}"

# 9. S3 Frontend
echo ""
echo "[9/11] Deploying S3 Frontend..."
if ! aws s3api head-bucket --bucket "${FRONTEND_BUCKET}" 2>/dev/null; then
    if [ "${REGION}" = "us-east-1" ]; then
        aws s3api create-bucket --bucket "${FRONTEND_BUCKET}" --region "${REGION}" >/dev/null
    else
        aws s3api create-bucket --bucket "${FRONTEND_BUCKET}" --region "${REGION}" --create-bucket-configuration LocationConstraint="${REGION}" >/dev/null
    fi
fi
aws s3api put-public-access-block --bucket "${FRONTEND_BUCKET}" --public-access-block-configuration "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false" --region "${REGION}"
aws s3api put-bucket-ownership-controls --bucket "${FRONTEND_BUCKET}" --ownership-controls "Rules=[{ObjectOwnership=BucketOwnerEnforced}]" --region "${REGION}"
aws s3api put-bucket-website --bucket "${FRONTEND_BUCKET}" --website-configuration '{"IndexDocument":{"Suffix":"index.html"}}' --region "${REGION}"

FE_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "PublicReadGetObject",
      "Effect": "Allow",
      "Principal": "*",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::${FRONTEND_BUCKET}/*"
    }
  ]
}
EOF
)
TEMP_FEPOL=$(mktemp)
echo "${FE_POLICY}" > "${TEMP_FEPOL}"
aws s3api put-bucket-policy --bucket "${FRONTEND_BUCKET}" --policy "file://${TEMP_FEPOL}" --region "${REGION}"
rm -f "${TEMP_FEPOL}"

cat <<EOF > frontend/config.js
window.APP_CONFIG = {
  API_BASE_URL: "${API_BASE_URL}",
  COGNITO_USER_POOL_ID: "${USER_POOL_ID}",
  COGNITO_CLIENT_ID: "${CLIENT_ID}",
  AWS_REGION: "${REGION}"
};
EOF

aws s3 cp frontend/index.html "s3://${FRONTEND_BUCKET}/index.html" --content-type "text/html" --region "${REGION}" >/dev/null
aws s3 cp frontend/styles.css "s3://${FRONTEND_BUCKET}/styles.css" --content-type "text/css" --region "${REGION}" >/dev/null
aws s3 cp frontend/app.js "s3://${FRONTEND_BUCKET}/app.js" --content-type "application/javascript" --region "${REGION}" >/dev/null
aws s3 cp frontend/config.js "s3://${FRONTEND_BUCKET}/config.js" --content-type "application/javascript" --region "${REGION}" >/dev/null

FRONTEND_URL="http://${FRONTEND_BUCKET}.s3-website.${REGION}.amazonaws.com"

# 10. Environment output
cat <<EOF > .env
AWS_REGION=${REGION}
AWS_ACCOUNT_ID=${ACCOUNT_ID}
S3_BUCKET=${DOC_BUCKET}
S3_FRONTEND_BUCKET=${FRONTEND_BUCKET}
FRONTEND_URL=${FRONTEND_URL}
COGNITO_USER_POOL_ID=${USER_POOL_ID}
COGNITO_CLIENT_ID=${CLIENT_ID}
API_GATEWAY_URL=${API_BASE_URL}
DOCUMENT_TABLE=${DOC_TABLE}
AUDIT_TABLE=${AUDIT_TABLE}
EMPLOYEE_TABLE=${EMPLOYEE_TABLE}
KMS_KEY_ID=${KMS_KEY_ID}
KMS_KEY_ARN=${KMS_KEY_ARN}
EOF
cp .env .env.example

# 11. Seed
echo ""
echo "[11/11] Initializing Demo Users and Seeding Files..."
bash scripts/create_users.sh
bash scripts/seed_data.sh

echo ""
echo "=========================================================="
echo "  DEPLOYMENT COMPLETE! Resources Ready:                   "
echo "=========================================================="
echo "  Frontend URL:       ${FRONTEND_URL}"
echo "  API Gateway:        ${API_BASE_URL}"
echo "  S3 Document Vault:  ${DOC_BUCKET}"
echo "  Cognito Pool ID:    ${USER_POOL_ID}"
echo "=========================================================="
