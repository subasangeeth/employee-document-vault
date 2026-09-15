# Script to provision demo Cognito users with permanent passwords and group memberships

$ErrorActionPreference = "Continue"

$REGION = (aws configure get region)
if (-not $REGION) { $REGION = "us-east-2" }
$REGION = $REGION.Trim()

$USER_POOL_ID = (aws cognito-idp list-user-pools --max-results 60 --region $REGION --query "UserPools[?Name=='EmployeeVaultUserPool'].Id" --output text).Trim()
if (-not $USER_POOL_ID -or $USER_POOL_ID -eq "None") {
    Write-Error "Cognito User Pool 'EmployeeVaultUserPool' not found. Run deploy.ps1 first."
    exit 1
}

Write-Host "Configuring Demo Users in User Pool: $USER_POOL_ID ($REGION)..." -ForegroundColor Cyan

$DEMO_USERS = @(
    @{ Username = "EMP001"; Role = "Employee"; Group = "Employee"; Email = "emp001@example.com"; EmpId = "EMP001" },
    @{ Username = "EMP002"; Role = "Employee"; Group = "Employee"; Email = "emp002@example.com"; EmpId = "EMP002" },
    @{ Username = "EMP003"; Role = "Employee"; Group = "Employee"; Email = "emp003@example.com"; EmpId = "EMP003" },
    @{ Username = "EMP999"; Role = "Employee"; Group = "Employee"; Email = "emp999@example.com"; EmpId = "EMP999" },
    @{ Username = "MGR001"; Role = "Manager";  Group = "Manager";  Email = "mgr001@example.com"; EmpId = "MGR001" },
    @{ Username = "HR001";  Role = "HR_Admin"; Group = "HR_Admin"; Email = "hr001@example.com";  EmpId = "HR001" }
)

$DEMO_PASSWORD = "TempPass123!"

foreach ($u in $DEMO_USERS) {
    $uname = $u.Username
    Write-Host "  -> Processing user $uname ($($u.Role))..." -ForegroundColor Gray
    
    # Check if user exists
    $userCheck = aws cognito-idp list-users --user-pool-id $USER_POOL_ID --filter "username = \`"$uname\`"" --region $REGION --query "Users[0].Username" --output text
    if (-not $userCheck -or $userCheck.Trim() -eq "None" -or $userCheck.Trim() -eq "") {
        # Create user
        aws cognito-idp admin-create-user `
          --user-pool-id $USER_POOL_ID `
          --username $uname `
          --user-attributes Name=email,Value=$($u.Email) Name=email_verified,Value=true Name=custom:employee_id,Value=$($u.EmpId) Name=custom:role,Value=$($u.Role) `
          --message-action SUPPRESS `
          --region $REGION | Out-Null
    }

    # Set permanent password
    aws cognito-idp admin-set-user-password `
      --user-pool-id $USER_POOL_ID `
      --username $uname `
      --password $DEMO_PASSWORD `
      --permanent `
      --region $REGION | Out-Null

    # Add to group
    aws cognito-idp admin-add-user-to-group `
      --user-pool-id $USER_POOL_ID `
      --username $uname `
      --group-name $($u.Group) `
      --region $REGION | Out-Null

    Write-Host "     Configured $uname with group $($u.Group)" -ForegroundColor Green
}

Write-Host "All Demo Users ready. Default Demo Password: $DEMO_PASSWORD" -ForegroundColor Green
