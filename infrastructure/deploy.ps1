# PowerShell Automated Deployment Script for Employee Document Vault
# Idempotent provisioning using AWS CLI

$ErrorActionPreference = "Continue"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "   Employee Document Vault - AWS CLI Automated Deployment   " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# 1. Environment Detection
Write-Host "[1/11] Detecting AWS Environment..." -ForegroundColor Yellow
$ACCOUNT_ID = (aws sts get-caller-identity --query Account --output text).Trim()
$REGION = (aws configure get region)
if (-not $REGION) { $REGION = "us-east-2" }
$REGION = $REGION.Trim()

$DOC_BUCKET = "employee-document-vault-$ACCOUNT_ID-$REGION"
$FRONTEND_BUCKET = "employee-vault-frontend-$ACCOUNT_ID-$REGION"
$DOC_TABLE = "document_metadata"
$EMPLOYEE_TABLE = "employee_directory"
$AUDIT_TABLE = "audit_log"
$USER_POOL_NAME = "EmployeeVaultUserPool"
$API_NAME = "EmployeeDocumentVaultAPI"

Write-Host "  -> Account ID: $ACCOUNT_ID" -ForegroundColor Green
Write-Host "  -> Region:     $REGION" -ForegroundColor Green
Write-Host "  -> Doc Bucket: $DOC_BUCKET" -ForegroundColor Green

# 2. KMS Key Setup
Write-Host "`n[2/11] Configuring KMS Customer-Managed Key..." -ForegroundColor Yellow
$KMS_ALIAS = "alias/employee-document-vault-key"
$KMS_KEY_ID = $null

$existingKeys = aws kms list-aliases --region $REGION --query "Aliases[?AliasName=='$KMS_ALIAS'].TargetKeyId" --output text
if ($existingKeys -and $existingKeys.Trim() -ne "None" -and $existingKeys.Trim() -ne "") {
    $KMS_KEY_ID = ($existingKeys -split "\s+")[0].Trim()
    Write-Host "  -> KMS Key already exists: $KMS_KEY_ID" -ForegroundColor Green
} else {
    Write-Host "  -> Creating KMS Key with key-policy.json..." -ForegroundColor Gray
    $policyContent = Get-Content -Path "infrastructure\kms\key-policy.json" -Raw
    $policyContent = $policyContent.Replace("ACCOUNT_ID", $ACCOUNT_ID)
    
    $tempPolicyPath = "$env:TEMP\kms-policy-resolved.json"
    Set-Content -Path $tempPolicyPath -Value $policyContent

    $KMS_KEY_ID = (aws kms create-key --description "KMS Key for Employee Document Vault SSE-KMS" --policy file://$tempPolicyPath --region $REGION --query KeyMetadata.KeyId --output text).Trim()
    aws kms create-alias --alias-name $KMS_ALIAS --target-key-id $KMS_KEY_ID --region $REGION
    Remove-Item $tempPolicyPath -Force
    Write-Host "  -> Created KMS Key: $KMS_KEY_ID" -ForegroundColor Green
}
$KMS_KEY_ARN = "arn:aws:kms:${REGION}:${ACCOUNT_ID}:key/${KMS_KEY_ID}"

# 3. S3 Document Bucket Provisioning
Write-Host "`n[3/11] Provisioning S3 Document Vault Bucket..." -ForegroundColor Yellow
$bucketCheck = aws s3api list-buckets --query "Buckets[?Name=='$DOC_BUCKET'].Name" --output text
if (-not $bucketCheck -or $bucketCheck.Trim() -eq "None" -or $bucketCheck.Trim() -eq "") {
    Write-Host "  -> Creating bucket $DOC_BUCKET..." -ForegroundColor Gray
    if ($REGION -eq "us-east-1") {
        aws s3api create-bucket --bucket $DOC_BUCKET --region $REGION | Out-Null
    } else {
        aws s3api create-bucket --bucket $DOC_BUCKET --region $REGION --create-bucket-configuration LocationConstraint=$REGION | Out-Null
    }
} else {
    Write-Host "  -> Bucket $DOC_BUCKET exists." -ForegroundColor Green
}

# Versioning
Write-Host "  -> Enabling Versioning..." -ForegroundColor Gray
aws s3api put-bucket-versioning --bucket $DOC_BUCKET --versioning-configuration Status=Enabled --region $REGION

# Block Public Access
Write-Host "  -> Enforcing BlockPublicAccess..." -ForegroundColor Gray
aws s3api put-public-access-block --bucket $DOC_BUCKET --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" --region $REGION

# Bucket Owner Enforced
Write-Host "  -> Enforcing Object Ownership..." -ForegroundColor Gray
aws s3api put-bucket-ownership-controls --bucket $DOC_BUCKET --ownership-controls "Rules=[{ObjectOwnership=BucketOwnerEnforced}]" --region $REGION

# SSE-KMS Default Encryption (Note KMSMasterKeyID)
Write-Host "  -> Setting SSE-KMS Default Encryption..." -ForegroundColor Gray
$encConfig = @"
{
  "Rules": [
    {
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "aws:kms",
        "KMSMasterKeyID": "$KMS_KEY_ARN"
      },
      "BucketKeyEnabled": true
    }
  ]
}
"@
$tempEncPath = "$env:TEMP\enc-config.json"
Set-Content -Path $tempEncPath -Value $encConfig
aws s3api put-bucket-encryption --bucket $DOC_BUCKET --server-side-encryption-configuration file://$tempEncPath --region $REGION
Remove-Item $tempEncPath -Force

# Lifecycle Policy (90-day S3-IA Transition for Non-current Versions)
Write-Host "  -> Applying S3 Lifecycle Transition (90 days -> S3-IA)..." -ForegroundColor Gray
aws s3api put-bucket-lifecycle-configuration --bucket $DOC_BUCKET --lifecycle-configuration file://infrastructure/s3/lifecycle.json --region $REGION

# Enforce HTTPS Only Bucket Policy
Write-Host "  -> Applying HTTPS-only Bucket Policy..." -ForegroundColor Gray
$bucketPolicy = Get-Content -Path "infrastructure\s3\bucket-policy.json" -Raw
$bucketPolicy = $bucketPolicy.Replace("BUCKET_NAME", $DOC_BUCKET)
$tempBucketPolicyPath = "$env:TEMP\s3-bucket-policy.json"
Set-Content -Path $tempBucketPolicyPath -Value $bucketPolicy
aws s3api put-bucket-policy --bucket $DOC_BUCKET --policy file://$tempBucketPolicyPath --region $REGION
Remove-Item $tempBucketPolicyPath -Force
Write-Host "  -> S3 Storage successfully configured." -ForegroundColor Green

# 4. DynamoDB Tables
Write-Host "`n[4/11] Provisioning DynamoDB Tables..." -ForegroundColor Yellow

# Table 1: document_metadata
$t1Exists = aws dynamodb list-tables --region $REGION --query "TableNames[?@=='$DOC_TABLE']" --output text
if (-not $t1Exists -or $t1Exists.Trim() -eq "None" -or $t1Exists.Trim() -eq "") {
    Write-Host "  -> Creating DynamoDB table: $DOC_TABLE..." -ForegroundColor Gray
    aws dynamodb create-table `
      --table-name $DOC_TABLE `
      --attribute-definitions AttributeName=document_id,AttributeType=S AttributeName=employee_id,AttributeType=S AttributeName=upload_timestamp,AttributeType=S `
      --key-schema AttributeName=document_id,KeyType=HASH `
      --global-secondary-indexes "IndexName=EmployeeDocumentsIndex,KeySchema=[{AttributeName=employee_id,KeyType=HASH},{AttributeName=upload_timestamp,KeyType=RANGE}],Projection={ProjectionType=ALL}" `
      --billing-mode PAY_PER_REQUEST `
      --region $REGION | Out-Null
    aws dynamodb wait table-exists --table-name $DOC_TABLE --region $REGION
    aws dynamodb update-continuous-backups --table-name $DOC_TABLE --point-in-time-recovery-specification PointInTimeRecoveryEnabled=true --region $REGION | Out-Null
} else {
    Write-Host "  -> Table $DOC_TABLE exists." -ForegroundColor Green
}

# Table 2: employee_directory
$t2Exists = aws dynamodb list-tables --region $REGION --query "TableNames[?@=='$EMPLOYEE_TABLE']" --output text
if (-not $t2Exists -or $t2Exists.Trim() -eq "None" -or $t2Exists.Trim() -eq "") {
    Write-Host "  -> Creating DynamoDB table: $EMPLOYEE_TABLE..." -ForegroundColor Gray
    aws dynamodb create-table `
      --table-name $EMPLOYEE_TABLE `
      --attribute-definitions AttributeName=employee_id,AttributeType=S AttributeName=manager_id,AttributeType=S `
      --key-schema AttributeName=employee_id,KeyType=HASH `
      --global-secondary-indexes "IndexName=ManagerIndex,KeySchema=[{AttributeName=manager_id,KeyType=HASH}],Projection={ProjectionType=ALL}" `
      --billing-mode PAY_PER_REQUEST `
      --region $REGION | Out-Null
    aws dynamodb wait table-exists --table-name $EMPLOYEE_TABLE --region $REGION
} else {
    Write-Host "  -> Table $EMPLOYEE_TABLE exists." -ForegroundColor Green
}

# Table 3: audit_log
$t3Exists = aws dynamodb list-tables --region $REGION --query "TableNames[?@=='$AUDIT_TABLE']" --output text
if (-not $t3Exists -or $t3Exists.Trim() -eq "None" -or $t3Exists.Trim() -eq "") {
    Write-Host "  -> Creating DynamoDB table: $AUDIT_TABLE..." -ForegroundColor Gray
    aws dynamodb create-table `
      --table-name $AUDIT_TABLE `
      --attribute-definitions AttributeName=audit_id,AttributeType=S AttributeName=timestamp,AttributeType=S `
      --key-schema AttributeName=audit_id,KeyType=HASH AttributeName=timestamp,KeyType=RANGE `
      --billing-mode PAY_PER_REQUEST `
      --region $REGION | Out-Null
    aws dynamodb wait table-exists --table-name $AUDIT_TABLE --region $REGION
    aws dynamodb update-continuous-backups --table-name $AUDIT_TABLE --point-in-time-recovery-specification PointInTimeRecoveryEnabled=true --region $REGION | Out-Null
} else {
    Write-Host "  -> Table $AUDIT_TABLE exists." -ForegroundColor Green
}
Write-Host "  -> DynamoDB Tables ready." -ForegroundColor Green

# 5. Cognito User Pool Provisioning
Write-Host "`n[5/11] Provisioning Amazon Cognito User Pool..." -ForegroundColor Yellow
$userPools = aws cognito-idp list-user-pools --max-results 60 --region $REGION --query "UserPools[?Name=='$USER_POOL_NAME'].Id" --output text
$USER_POOL_ID = $null

if ($userPools -and $userPools.Trim() -ne "None" -and $userPools.Trim() -ne "") {
    $USER_POOL_ID = ($userPools -split "\s+")[0].Trim()
    Write-Host "  -> User Pool exists: $USER_POOL_ID" -ForegroundColor Green
} else {
    Write-Host "  -> Creating User Pool $USER_POOL_NAME..." -ForegroundColor Gray
    $USER_POOL_ID = (aws cognito-idp create-user-pool `
      --pool-name $USER_POOL_NAME `
      --auto-verified-attributes email `
      --schema Name=employee_id,AttributeDataType=String,Mutable=true Name=role,AttributeDataType=String,Mutable=true `
      --policies "PasswordPolicy={MinimumLength=8,RequireUppercase=true,RequireLowercase=true,RequireNumbers=true,RequireSymbols=true}" `
      --region $REGION --query UserPool.Id --output text).Trim()
    Write-Host "  -> Created User Pool: $USER_POOL_ID" -ForegroundColor Green
}
$USER_POOL_ARN = "arn:aws:cognito-idp:${REGION}:${ACCOUNT_ID}:userpool/${USER_POOL_ID}"

# Cognito Groups
$groups = @("HR_Admin", "Manager", "Employee")
foreach ($grp in $groups) {
    $grpExists = aws cognito-idp list-groups --user-pool-id $USER_POOL_ID --region $REGION --query "Groups[?GroupName=='$grp'].GroupName" --output text
    if (-not $grpExists -or $grpExists.Trim() -eq "None" -or $grpExists.Trim() -eq "") {
        aws cognito-idp create-group --group-name $grp --user-pool-id $USER_POOL_ID --description "$grp Group for Document Vault" --region $REGION | Out-Null
        Write-Host "  -> Created Cognito Group: $grp" -ForegroundColor Gray
    }
}

# App Client
$existingClients = aws cognito-idp list-user-pool-clients --user-pool-id $USER_POOL_ID --region $REGION --query "UserPoolClients[?ClientName=='EmployeeVaultWebClient'].ClientId" --output text
$CLIENT_ID = $null

if ($existingClients -and $existingClients.Trim() -ne "None" -and $existingClients.Trim() -ne "") {
    $CLIENT_ID = ($existingClients -split "\s+")[0].Trim()
    Write-Host "  -> App Client exists: $CLIENT_ID" -ForegroundColor Green
} else {
    Write-Host "  -> Creating App Client..." -ForegroundColor Gray
    $CLIENT_ID = (aws cognito-idp create-user-pool-client `
      --user-pool-id $USER_POOL_ID `
      --client-name "EmployeeVaultWebClient" `
      --no-generate-secret `
      --explicit-auth-flows ALLOW_USER_PASSWORD_AUTH ALLOW_REFRESH_TOKEN_AUTH ALLOW_USER_SRP_AUTH `
      --region $REGION --query UserPoolClient.ClientId --output text).Trim()
    Write-Host "  -> Created App Client: $CLIENT_ID" -ForegroundColor Green
}

# 6. IAM Roles for Lambdas (Least Privilege)
Write-Host "`n[6/11] Provisioning IAM Roles..." -ForegroundColor Yellow
$roles = @{
    "LambdaUploadRole" = "infrastructure/iam/upload-policy.json"
    "LambdaDownloadRole" = "infrastructure/iam/download-policy.json"
    "LambdaListRole" = "infrastructure/iam/list-policy.json"
    "LambdaDeleteRole" = "infrastructure/iam/delete-policy.json"
    "LambdaVersionRole" = "infrastructure/iam/version-policy.json"
}

foreach ($roleName in $roles.Keys) {
    $roleExists = aws iam list-roles --query "Roles[?RoleName=='$roleName'].RoleName" --output text
    if (-not $roleExists -or $roleExists.Trim() -eq "None" -or $roleExists.Trim() -eq "") {
        Write-Host "  -> Creating IAM role $roleName..." -ForegroundColor Gray
        aws iam create-role --role-name $roleName --assume-role-policy-document file://infrastructure/iam/trust-policy.json | Out-Null
    }

    # Populate policy variables
    $policyPath = $roles[$roleName]
    $policyJson = Get-Content -Path $policyPath -Raw
    $policyJson = $policyJson.Replace("BUCKET_NAME", $DOC_BUCKET).Replace("KMS_KEY_ARN", $KMS_KEY_ARN)
    
    $tempPol = "$env:TEMP\$roleName-resolved.json"
    Set-Content -Path $tempPol -Value $policyJson
    aws iam put-role-policy --role-name $roleName --policy-name "${roleName}Policy" --policy-document file://$tempPol
    Remove-Item $tempPol -Force
}
Write-Host "  -> IAM Roles and policies configured. Waiting 10s for IAM propagation..." -ForegroundColor Gray
Start-Sleep -Seconds 10

# 7. Package and Deploy Lambda Functions
Write-Host "`n[7/11] Packaging & Deploying Lambda Functions..." -ForegroundColor Yellow
$lambdaFunctions = @(
    @{ Name = "EmployeeVaultUpload"; Dir = "lambda\upload"; Role = "LambdaUploadRole"; Handler = "handler.lambda_handler" },
    @{ Name = "EmployeeVaultDownload"; Dir = "lambda\download"; Role = "LambdaDownloadRole"; Handler = "handler.lambda_handler" },
    @{ Name = "EmployeeVaultList"; Dir = "lambda\list_files"; Role = "LambdaListRole"; Handler = "handler.lambda_handler" },
    @{ Name = "EmployeeVaultDelete"; Dir = "lambda\delete"; Role = "LambdaDeleteRole"; Handler = "handler.lambda_handler" },
    @{ Name = "EmployeeVaultVersion"; Dir = "lambda\version_history"; Role = "LambdaVersionRole"; Handler = "handler.lambda_handler" }
)

$distDir = "dist"
if (Test-Path $distDir) { Remove-Item $distDir -Recurse -Force }
New-Item -ItemType Directory -Path $distDir | Out-Null

$LAMBDA_ARNS = @{}
$envVars = "Variables={DOCUMENT_BUCKET=$DOC_BUCKET,DOCUMENT_TABLE=$DOC_TABLE,EMPLOYEE_TABLE=$EMPLOYEE_TABLE,AUDIT_TABLE=$AUDIT_TABLE,KMS_KEY_ID=$KMS_KEY_ID,COGNITO_USER_POOL_ID=$USER_POOL_ID}"

foreach ($fn in $lambdaFunctions) {
    $fnName = $fn.Name
    $fnDir = $fn.Dir
    $roleArn = "arn:aws:iam::${ACCOUNT_ID}:role/$($fn.Role)"
    $zipPath = "$distDir\$fnName.zip"

    Write-Host "  -> Packaging $fnName..." -ForegroundColor Gray
    $tempPackDir = "$env:TEMP\pack_$fnName"
    if (Test-Path $tempPackDir) { Remove-Item $tempPackDir -Recurse -Force }
    New-Item -ItemType Directory -Path $tempPackDir | Out-Null
    
    Copy-Item "$fnDir\handler.py" -Destination $tempPackDir
    Copy-Item "lambda\common\auth.py" -Destination $tempPackDir
    Compress-Archive -Path "$tempPackDir\*" -DestinationPath $zipPath -Force
    Remove-Item $tempPackDir -Recurse -Force

    # Check if lambda exists
    $fnExists = aws lambda list-functions --region $REGION --query "Functions[?FunctionName=='$fnName'].FunctionName" --output text
    if ($fnExists -and $fnExists.Trim() -ne "None" -and $fnExists.Trim() -ne "") {
        Write-Host "  -> Updating code for $fnName..." -ForegroundColor Gray
        aws lambda update-function-code --function-name $fnName --zip-file fileb://$zipPath --region $REGION | Out-Null
        Start-Sleep -Seconds 2
        aws lambda update-function-configuration --function-name $fnName --environment $envVars --region $REGION | Out-Null
    } else {
        Write-Host "  -> Creating Lambda function $fnName..." -ForegroundColor Gray
        aws lambda create-function `
          --function-name $fnName `
          --runtime python3.12 `
          --role $roleArn `
          --handler $fn.Handler `
          --zip-file fileb://$zipPath `
          --timeout 15 `
          --memory-size 256 `
          --environment $envVars `
          --region $REGION | Out-Null
    }
    
    # Retrieve FunctionArn
    $arn = (aws lambda get-function --function-name $fnName --region $REGION --query Configuration.FunctionArn --output text).Trim()
    $LAMBDA_ARNS[$fnName] = $arn
    Write-Host "  -> Deployed $fnName ($arn)" -ForegroundColor Green
}

# 8. API Gateway Setup
Write-Host "`n[8/11] Setting up API Gateway REST API & Cognito Authorizer..." -ForegroundColor Yellow
$apis = aws apigateway get-rest-apis --region $REGION --query "items[?name=='$API_NAME'].id" --output text
$API_ID = $null

if ($apis -and $apis.Trim() -ne "None" -and $apis.Trim() -ne "") {
    $API_ID = ($apis -split "\s+")[0].Trim()
    Write-Host "  -> REST API exists: $API_ID" -ForegroundColor Green
} else {
    Write-Host "  -> Creating REST API $API_NAME..." -ForegroundColor Gray
    $API_ID = (aws apigateway create-rest-api --name $API_NAME --description "Employee Document Vault REST API" --endpoint-configuration types=REGIONAL --region $REGION --query id --output text).Trim()
    Write-Host "  -> Created REST API: $API_ID" -ForegroundColor Green
}

# Root Resource
$ROOT_ID = (aws apigateway get-resources --rest-api-id $API_ID --region $REGION --query "items[?path=='/'].id" --output text).Trim()

# Create Cognito Authorizer
$auths = aws apigateway get-authorizers --rest-api-id $API_ID --region $REGION --query "items[?name=='CognitoAuthorizer'].id" --output text
$AUTHORIZER_ID = $null
if ($auths -and $auths.Trim() -ne "None" -and $auths.Trim() -ne "") {
    $AUTHORIZER_ID = ($auths -split "\s+")[0].Trim()
    Write-Host "  -> Cognito Authorizer exists: $AUTHORIZER_ID" -ForegroundColor Green
} else {
    Write-Host "  -> Creating Cognito Authorizer..." -ForegroundColor Gray
    $AUTHORIZER_ID = (aws apigateway create-authorizer `
      --rest-api-id $API_ID `
      --name "CognitoAuthorizer" `
      --type COGNITO_USER_POOLS `
      --provider-arns $USER_POOL_ARN `
      --identity-source "method.request.header.Authorization" `
      --region $REGION --query id --output text).Trim()
    Write-Host "  -> Created Authorizer: $AUTHORIZER_ID" -ForegroundColor Green
}

# Helper function to create resource
function Get-OrCreate-Resource($parentId, $pathPart) {
    $existing = aws apigateway get-resources --rest-api-id $API_ID --region $REGION --query "items[?parentId=='$parentId' && pathPart=='$pathPart'].id" --output text
    if ($existing -and $existing.Trim() -ne "None" -and $existing.Trim() -ne "") {
        return ($existing -split "\s+")[0].Trim()
    }
    $created = (aws apigateway create-resource --rest-api-id $API_ID --parent-id $parentId --path-part $pathPart --region $REGION --query id --output text).Trim()
    return $created
}

# Helper to configure method + integration
function Setup-Api-Method($resourceId, $httpMethod, $lambdaArn, $requiresAuth = $true) {
    Write-Host "    * Configuring $httpMethod on resource $resourceId..." -ForegroundColor Gray
    # Method
    if ($requiresAuth) {
        aws apigateway put-method `
          --rest-api-id $API_ID `
          --resource-id $resourceId `
          --http-method $httpMethod `
          --authorization-type COGNITO_USER_POOLS `
          --authorizer-id $AUTHORIZER_ID `
          --region $REGION | Out-Null
    } else {
        aws apigateway put-method `
          --rest-api-id $API_ID `
          --resource-id $resourceId `
          --http-method $httpMethod `
          --authorization-type NONE `
          --region $REGION | Out-Null
    }

    # Integration
    $uri = "arn:aws:apigateway:${REGION}:lambda:path/2015-03-31/functions/${lambdaArn}/invocations"
    aws apigateway put-integration `
      --rest-api-id $API_ID `
      --resource-id $resourceId `
      --http-method $httpMethod `
      --type AWS_PROXY `
      --integration-http-method POST `
      --uri $uri `
      --region $REGION | Out-Null

    # Lambda Permission
    $stmtId = "apigateway-${resourceId}-${httpMethod}"
    aws lambda remove-permission --function-name $lambdaArn --statement-id $stmtId --region $REGION 2>$null | Out-Null
    aws lambda add-permission `
      --function-name $lambdaArn `
      --statement-id $stmtId `
      --action lambda:InvokeFunction `
      --principal apigateway.amazonaws.com `
      --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT_ID}:${API_ID}/*/${httpMethod}/*" `
      --region $REGION | Out-Null

    # Setup OPTIONS for CORS
    aws apigateway put-method --rest-api-id $API_ID --resource-id $resourceId --http-method OPTIONS --authorization-type NONE --region $REGION | Out-Null

    # Mock Integration
    $mockFile = "$env:TEMP\mock-$resourceId.json"
    Set-Content -Path $mockFile -Value '{"application/json":"{\"statusCode\": 200}"}'
    aws apigateway put-integration --rest-api-id $API_ID --resource-id $resourceId --http-method OPTIONS --type MOCK --request-templates file://$mockFile --region $REGION | Out-Null
    Remove-Item $mockFile -Force

    # Method Response
    $mrFile = "$env:TEMP\mr-$resourceId.json"
    Set-Content -Path $mrFile -Value '{"method.response.header.Access-Control-Allow-Headers":true,"method.response.header.Access-Control-Allow-Methods":true,"method.response.header.Access-Control-Allow-Origin":true}'
    aws apigateway put-method-response --rest-api-id $API_ID --resource-id $resourceId --http-method OPTIONS --status-code 200 --response-parameters file://$mrFile --region $REGION | Out-Null
    Remove-Item $mrFile -Force

    # Integration Response
    $irFile = "$env:TEMP\ir-$resourceId.json"
    $irContent = '{"method.response.header.Access-Control-Allow-Headers":"''Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token''","method.response.header.Access-Control-Allow-Methods":"''GET,POST,DELETE,OPTIONS''","method.response.header.Access-Control-Allow-Origin":"''*''"}'
    Set-Content -Path $irFile -Value $irContent
    aws apigateway put-integration-response --rest-api-id $API_ID --resource-id $resourceId --http-method OPTIONS --status-code 200 --response-parameters file://$irFile --region $REGION | Out-Null
    Remove-Item $irFile -Force
}

# Build Endpoints
Write-Host "  -> Building API resource hierarchy..." -ForegroundColor Gray
$resUpload = Get-OrCreate-Resource $ROOT_ID "upload"
Setup-Api-Method $resUpload "POST" $LAMBDA_ARNS["EmployeeVaultUpload"]

$resFiles = Get-OrCreate-Resource $ROOT_ID "files"
Setup-Api-Method $resFiles "GET" $LAMBDA_ARNS["EmployeeVaultList"]

$resFilesDocId = Get-OrCreate-Resource $resFiles "{doc_id}"
Setup-Api-Method $resFilesDocId "DELETE" $LAMBDA_ARNS["EmployeeVaultDelete"]

$resVersions = Get-OrCreate-Resource $resFilesDocId "versions"
Setup-Api-Method $resVersions "GET" $LAMBDA_ARNS["EmployeeVaultVersion"]

$resDownload = Get-OrCreate-Resource $ROOT_ID "download"
$resDownloadDocId = Get-OrCreate-Resource $resDownload "{doc_id}"
Setup-Api-Method $resDownloadDocId "GET" $LAMBDA_ARNS["EmployeeVaultDownload"]

# Deploy API Gateway
Write-Host "  -> Creating API Gateway Deployment to stage 'prod'..." -ForegroundColor Gray
aws apigateway create-deployment --rest-api-id $API_ID --stage-name prod --region $REGION | Out-Null
$API_BASE_URL = "https://${API_ID}.execute-api.${REGION}.amazonaws.com/prod"
Write-Host "  -> API Gateway deployed at: $API_BASE_URL" -ForegroundColor Green

# 9. S3 Frontend Hosting
Write-Host "`n[9/11] Deploying S3 Frontend..." -ForegroundColor Yellow
$feCheck = aws s3api list-buckets --query "Buckets[?Name=='$FRONTEND_BUCKET'].Name" --output text
if (-not $feCheck -or $feCheck.Trim() -eq "None" -or $feCheck.Trim() -eq "") {
    if ($REGION -eq "us-east-1") {
        aws s3api create-bucket --bucket $FRONTEND_BUCKET --region $REGION | Out-Null
    } else {
        aws s3api create-bucket --bucket $FRONTEND_BUCKET --region $REGION --create-bucket-configuration LocationConstraint=$REGION | Out-Null
    }
}
# Frontend bucket needs public read for static site hosting
aws s3api put-public-access-block --bucket $FRONTEND_BUCKET --public-access-block-configuration "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false" --region $REGION
aws s3api put-bucket-ownership-controls --bucket $FRONTEND_BUCKET --ownership-controls "Rules=[{ObjectOwnership=BucketOwnerEnforced}]" --region $REGION

# Website Configuration
aws s3api put-bucket-website --bucket $FRONTEND_BUCKET --website-configuration "{\`"IndexDocument\`":{\`"Suffix\`":\`"index.html\`"}}" --region $REGION

# Public Read Policy for Website
$fePolicy = @"
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "PublicReadGetObject",
      "Effect": "Allow",
      "Principal": "*",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::$FRONTEND_BUCKET/*"
    }
  ]
}
"@
$tempFePol = "$env:TEMP\fe-policy.json"
Set-Content -Path $tempFePol -Value $fePolicy
aws s3api put-bucket-policy --bucket $FRONTEND_BUCKET --policy file://$tempFePol --region $REGION
Remove-Item $tempFePol -Force

# Generate and inject config.js
$configJs = @"
window.APP_CONFIG = {
  API_BASE_URL: "$API_BASE_URL",
  COGNITO_USER_POOL_ID: "$USER_POOL_ID",
  COGNITO_CLIENT_ID: "$CLIENT_ID",
  AWS_REGION: "$REGION"
};
"@
Set-Content -Path "frontend\config.js" -Value $configJs

# Upload Frontend assets
Write-Host "  -> Uploading frontend files to s3://$FRONTEND_BUCKET/..." -ForegroundColor Gray
aws s3 cp frontend\index.html s3://$FRONTEND_BUCKET/index.html --content-type "text/html" --region $REGION | Out-Null
aws s3 cp frontend\styles.css s3://$FRONTEND_BUCKET/styles.css --content-type "text/css" --region $REGION | Out-Null
aws s3 cp frontend\app.js s3://$FRONTEND_BUCKET/app.js --content-type "application/javascript" --region $REGION | Out-Null
aws s3 cp frontend\config.js s3://$FRONTEND_BUCKET/config.js --content-type "application/javascript" --region $REGION | Out-Null

$FRONTEND_URL = "http://${FRONTEND_BUCKET}.s3-website.${REGION}.amazonaws.com"
Write-Host "  -> Frontend live at: $FRONTEND_URL" -ForegroundColor Green

# 10. Generate .env File
Write-Host "`n[10/11] Writing Configuration Environment Variables..." -ForegroundColor Yellow
$envContent = @"
AWS_REGION=$REGION
AWS_ACCOUNT_ID=$ACCOUNT_ID
S3_BUCKET=$DOC_BUCKET
S3_FRONTEND_BUCKET=$FRONTEND_BUCKET
FRONTEND_URL=$FRONTEND_URL
COGNITO_USER_POOL_ID=$USER_POOL_ID
COGNITO_CLIENT_ID=$CLIENT_ID
API_GATEWAY_URL=$API_BASE_URL
DOCUMENT_TABLE=$DOC_TABLE
AUDIT_TABLE=$AUDIT_TABLE
EMPLOYEE_TABLE=$EMPLOYEE_TABLE
KMS_KEY_ID=$KMS_KEY_ID
KMS_KEY_ARN=$KMS_KEY_ARN
"@
Set-Content -Path ".env" -Value $envContent
Set-Content -Path ".env.example" -Value $envContent
Write-Host "  -> Saved configuration to .env" -ForegroundColor Green

# 11. Seed Users and Demo Data
Write-Host "`n[11/11] Initializing Demo Users and Seeding Files..." -ForegroundColor Yellow
powershell -ExecutionPolicy Bypass -File .\scripts\create_users.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\seed_data.ps1

Write-Host "`n==========================================================" -ForegroundColor Green
Write-Host "  DEPLOYMENT COMPLETE! Resources Ready:                    " -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green
Write-Host "  S3 Document Vault:  $DOC_BUCKET" -ForegroundColor Cyan
Write-Host "  KMS Key ARN:        $KMS_KEY_ARN" -ForegroundColor Cyan
Write-Host "  Cognito User Pool:  $USER_POOL_ID" -ForegroundColor Cyan
Write-Host "  Cognito Client ID:  $CLIENT_ID" -ForegroundColor Cyan
Write-Host "  API Gateway Base:   $API_BASE_URL" -ForegroundColor Cyan
Write-Host "  Frontend URL:       $FRONTEND_URL" -ForegroundColor Yellow
Write-Host "==========================================================" -ForegroundColor Green
