# Script to safely delete all provisioned AWS resources

$ErrorActionPreference = "Continue"

Write-Host "Teardown: Cleaning up Employee Document Vault resources..." -ForegroundColor Yellow

$REGION = (aws configure get region)
if (-not $REGION) { $REGION = "us-east-2" }
$REGION = $REGION.Trim()

$ACCOUNT_ID = (aws sts get-caller-identity --query Account --output text).Trim()
$DOC_BUCKET = "employee-document-vault-$ACCOUNT_ID-$REGION"
$FRONTEND_BUCKET = "employee-vault-frontend-$ACCOUNT_ID-$REGION"
$API_NAME = "EmployeeDocumentVaultAPI"
$USER_POOL_NAME = "EmployeeVaultUserPool"

# 1. Empty & Delete S3 Buckets
Write-Host "  -> Emptying and deleting S3 buckets..." -ForegroundColor Gray
# Delete all versions in doc bucket
$versions = aws s3api list-object-versions --bucket $DOC_BUCKET --region $REGION 2>$null | ConvertFrom-Json
if ($versions) {
    if ($versions.Versions) {
        foreach ($v in $versions.Versions) {
            aws s3api delete-object --bucket $DOC_BUCKET --key $v.Key --version-id $v.VersionId --region $REGION | Out-Null
        }
    }
    if ($versions.DeleteMarkers) {
        foreach ($dm in $versions.DeleteMarkers) {
            aws s3api delete-object --bucket $DOC_BUCKET --key $dm.Key --version-id $dm.VersionId --region $REGION | Out-Null
        }
    }
}
aws s3 rb "s3://$DOC_BUCKET" --force --region $REGION 2>$null | Out-Null
aws s3 rb "s3://$FRONTEND_BUCKET" --force --region $REGION 2>$null | Out-Null

# 2. Delete API Gateway
Write-Host "  -> Deleting API Gateway..." -ForegroundColor Gray
$apiId = aws apigateway get-rest-apis --region $REGION --query "items[?name=='$API_NAME'].id" --output text 2>$null
if ($apiId -and $apiId -ne "None") {
    aws apigateway delete-rest-api --rest-api-id $apiId.Trim() --region $REGION | Out-Null
}

# 3. Delete Lambdas
Write-Host "  -> Deleting Lambda functions..." -ForegroundColor Gray
$fns = @("EmployeeVaultUpload", "EmployeeVaultDownload", "EmployeeVaultList", "EmployeeVaultDelete", "EmployeeVaultVersion")
foreach ($fn in $fns) {
    aws lambda delete-function --function-name $fn --region $REGION 2>$null | Out-Null
}

# 4. Delete DynamoDB Tables
Write-Host "  -> Deleting DynamoDB tables..." -ForegroundColor Gray
aws dynamodb delete-table --table-name document_metadata --region $REGION 2>$null | Out-Null
aws dynamodb delete-table --table-name employee_directory --region $REGION 2>$null | Out-Null
aws dynamodb delete-table --table-name audit_log --region $REGION 2>$null | Out-Null

# 5. Delete Cognito User Pool
Write-Host "  -> Deleting Cognito User Pool..." -ForegroundColor Gray
$userPoolId = aws cognito-idp list-user-pools --max-results 60 --region $REGION --query "UserPools[?Name=='$USER_POOL_NAME'].Id" --output text 2>$null
if ($userPoolId -and $userPoolId -ne "None") {
    aws cognito-idp delete-user-pool --user-pool-id $userPoolId.Trim() --region $REGION 2>$null | Out-Null
}

# 6. Delete IAM Roles
Write-Host "  -> Deleting IAM roles..." -ForegroundColor Gray
$roles = @("LambdaUploadRole", "LambdaDownloadRole", "LambdaListRole", "LambdaDeleteRole", "LambdaVersionRole")
foreach ($r in $roles) {
    aws iam delete-role-policy --role-name $r --policy-name "${r}Policy" 2>$null | Out-Null
    aws iam delete-role --role-name $r 2>$null | Out-Null
}

# 7. KMS Alias & Schedule Deletion
Write-Host "  -> Cleaning up KMS Key alias..." -ForegroundColor Gray
$kmsKeyId = aws kms list-aliases --region $REGION --query "Aliases[?AliasName=='alias/employee-document-vault-key'].TargetKeyId" --output text 2>$null
if ($kmsKeyId -and $kmsKeyId -ne "None") {
    aws kms delete-alias --alias-name "alias/employee-document-vault-key" --region $REGION 2>$null | Out-Null
    aws kms schedule-key-deletion --key-id $kmsKeyId.Trim() --pending-window-in-days 7 --region $REGION 2>$null | Out-Null
}

Write-Host "Teardown complete." -ForegroundColor Green
