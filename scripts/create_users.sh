#!/usr/bin/env bash
# Script to provision demo Cognito users with permanent passwords and group memberships

set -euo pipefail

REGION=$(aws configure get region || echo "us-east-2")
REGION=$(echo "$REGION" | tr -d '[:space:]')

USER_POOL_ID=$(aws cognito-idp list-user-pools --max-results 60 --region "${REGION}" --query "UserPools[?Name=='EmployeeVaultUserPool'].Id" --output text | tr -d '[:space:]' || true)
if [ -z "${USER_POOL_ID}" ] || [ "${USER_POOL_ID}" = "None" ]; then
    echo "Cognito User Pool 'EmployeeVaultUserPool' not found. Run deploy.sh first."
    exit 1
fi

echo "Configuring Demo Users in User Pool: ${USER_POOL_ID} (${REGION})..."

DEMO_PASSWORD="TempPass123!"

declare -a USERS=(
  "EMP001:Employee:Employee:emp001@example.com:EMP001"
  "EMP002:Employee:Employee:emp002@example.com:EMP002"
  "EMP003:Employee:Employee:emp003@example.com:EMP003"
  "EMP999:Employee:Employee:emp999@example.com:EMP999"
  "MGR001:Manager:Manager:mgr001@example.com:MGR001"
  "HR001:HR_Admin:HR_Admin:hr001@example.com:HR001"
)

for entry in "${USERS[@]}"; do
    IFS=":" read -r uname role grp email empId <<< "${entry}"
    echo "  -> Processing user ${uname} (${role})..."

    if ! aws cognito-idp admin-get-user --user-pool-id "${USER_POOL_ID}" --username "${uname}" --region "${REGION}" 2>/dev/null; then
        aws cognito-idp admin-create-user \
          --user-pool-id "${USER_POOL_ID}" \
          --username "${uname}" \
          --user-attributes Name=email,Value="${email}" Name=email_verified,Value=true Name=custom:employee_id,Value="${empId}" Name=custom:role,Value="${role}" \
          --message-action SUPPRESS \
          --region "${REGION}" >/dev/null
    fi

    aws cognito-idp admin-set-user-password \
      --user-pool-id "${USER_POOL_ID}" \
      --username "${uname}" \
      --password "${DEMO_PASSWORD}" \
      --permanent \
      --region "${REGION}" >/dev/null

    aws cognito-idp admin-add-user-to-group \
      --user-pool-id "${USER_POOL_ID}" \
      --username "${uname}" \
      --group-name "${grp}" \
      --region "${REGION}" >/dev/null

    echo "     Configured ${uname} with group ${grp}"
done

echo "All Demo Users ready. Default Demo Password: ${DEMO_PASSWORD}"
