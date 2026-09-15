# Deployment & Operational Guide: Employee Document Vault

This guide details how to deploy, configure, test, and operate the Employee Document Vault using the AWS CLI and automated cross-platform scripts.

---

## 1. Prerequisites

1. **AWS CLI** (v2.x or later) installed and configured with administrative privileges:
   ```bash
   aws sts get-caller-identity
   ```
2. **Python 3.10+** and **Boto3** for running automated integration test suites.
3. **PowerShell 7+** (on Windows) or **Bash** (on Linux/macOS/WSL).

---

## 2. Automated One-Command Deployment

### On Windows (PowerShell)
From the project root:
```powershell
.\infrastructure\deploy.ps1
```

### On Linux / macOS / WSL / Git Bash
From the project root:
```bash
chmod +x infrastructure/*.sh scripts/*.sh
./infrastructure/deploy.sh
```

### What the Deployment Script Does:
1. Detects AWS Account ID and Region dynamically.
2. Provisions a dedicated AWS KMS Customer Managed Key (`alias/employee-document-vault-key`).
3. Provisions S3 Document Vault bucket with:
   - S3 Versioning enabled.
   - S3 Public Access Block enforced.
   - S3 Bucket Owner Enforced object ownership.
   - SSE-KMS default encryption.
   - 90-day non-current version transition to S3-IA.
   - HTTPS-only bucket policy.
4. Provisions 3 DynamoDB tables (`document_metadata`, `employee_directory`, `audit_log`) with GSIs and Point-In-Time Recovery.
5. Provisions Cognito User Pool (`EmployeeVaultUserPool`), App Client, and Groups (`HR_Admin`, `Manager`, `Employee`).
6. Creates least-privilege IAM execution roles for all 5 Lambdas.
7. Packages and deploys 5 Python 3.12 Lambda functions.
8. Configures API Gateway REST API with Cognito User Pool Authorizer, CORS, and deployment stage `prod`.
9. Configures S3 static frontend hosting, injects runtime configuration into `config.js`, and uploads the UI assets.
10. Automatically provisions demo users (`EMP001`, `EMP002`, `EMP003`, `EMP999`, `MGR001`, `HR001`).
11. Automatically seeds employee directory and sample documents (including 2 S3 versions for `EMP001`'s employment contract).

---

## 3. Running Automated Acceptance Tests

To verify all 10 security and access control scenarios:

### Using PowerShell:
```powershell
.\scripts\test_access.ps1
```

### Using Bash:
```bash
./scripts/test_access.sh
```

### Using Python directly:
```bash
python tests/test_access_control.py
```

### Expected Output:
```text
=====================================================================================================
Test Scenario                                                          | Exp   | Got   | Result
=====================================================================================================
Test 1: EMP001 downloads EMP001 document (Self access)                 | 200   | 200   | PASS  
Test 2: EMP001 attempts to download EMP002 document (Unauthorized)     | 403   | 403   | PASS  
Test 3: MGR001 downloads direct report EMP001 document                 | 200   | 200   | PASS  
Test 4: MGR001 downloads direct report EMP002 document                 | 200   | 200   | PASS  
Test 5: MGR001 attempts download of unrelated employee EMP999          | 403   | 403   | PASS  
Test 6: HR001 downloads unrelated employee EMP999 document             | 200   | 200   | PASS  
Test 7: EMP001 attempts DELETE on EMP002 document                      | 403   | 403   | PASS  
Test 8: Soft delete marks deleted=true and retains physical S3 object  | 200   | 200   | PASS  
Test 9: Version history returns 2 versions for contract                | 200   | 200   | PASS  
Test 10: Unauthenticated request rejected by Cognito authorizer       | 401   | 401   | PASS  
=====================================================================================================
ALL 10 ACCESS CONTROL ACCEPTANCE TESTS PASSED!
```

---

## 4. Exporting Audit Logs

Export the DynamoDB immutable audit trail to JSON and CSV:

### Using PowerShell:
```powershell
.\scripts\export_audit_logs.ps1
```

### Using Bash:
```bash
./scripts/export_audit_logs.sh
```

Outputs created:
- `audit-log-export.json`
- `audit-log-export.csv`

---

## 5. Teardown & Resource Cleanup

To delete all AWS infrastructure, buckets, tables, and roles:

### Using PowerShell:
```powershell
.\scripts\teardown.ps1
```

### Using Bash:
```bash
./scripts/teardown.sh
```
