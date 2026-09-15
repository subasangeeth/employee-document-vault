# Employee Document Vault with Role-Based Access Control on AWS

[![CI/CD Pipeline](https://github.com/subasangeeth/employee-document-vault/actions/workflows/deploy.yml/badge.svg)](https://github.com/subasangeeth/employee-document-vault/actions)
[![AWS Architecture](https://img.shields.io/badge/AWS-Serverless-orange.svg)](https://aws.amazon.com)
[![Security](https://img.shields.io/badge/Security-Zero--Trust%20RBAC-green.svg)](security/iam-audit.md)
[![Encryption](https://img.shields.io/badge/Encryption-SSE--KMS%20%7C%20TLS%201.3-blue.svg)](security/iam-audit.md)
[![Audit](https://img.shields.io/badge/Audit-DynamoDB%20Immutable-purple.svg)](scripts/export_audit_logs.ps1)

A secure, centralized HR document management system on AWS — functioning as a private, restricted Google Drive for HR records with fine-grained access control:

- **Employees** view, download, upload, and manage **only their own** records.
- **Managers** view records belonging to themselves and their **direct reports** based on an organizational hierarchy.
- **HR Administrators** maintain **universal access** across all employee records and audit reports.
- **Zero-Trust Backend**: Authorization is enforced directly in serverless AWS Lambda by verifying Cognito JWT signatures and directory relationships.
- **Direct S3 File Transfers**: Secure uploads and downloads execute directly between the browser and Amazon S3 using 15-minute pre-signed URLs.
- **Data Preservation**: S3 versioning preserves all document edits; 90-day lifecycle rules archive older non-current versions to S3 Standard-IA; API deletions execute soft-deletions without purging physical objects.
- **Immutable Audit Logging**: Every transaction and unauthorized access attempt is recorded in a dedicated DynamoDB audit table with write-only privileges (`PutItem`).

---

## Architecture Overview

```text
                         ┌─────────────────────┐
                         │       User          │
                         │ Employee / Manager  │
                         │      / HR Admin     │
                         └──────────┬──────────┘
                                    │
                                    ▼
                         ┌─────────────────────┐
                         │   S3 Frontend       │
                         │ React / HTML / JS   │
                         └──────────┬──────────┘
                                    │
                                    ▼
                         ┌─────────────────────┐
                         │ Amazon Cognito       │
                         │ User Pool            │
                         │ Employee             │
                         │ Manager              │
                         │ HR_Admin             │
                         └──────────┬──────────┘
                                    │ JWT
                                    ▼
                         ┌─────────────────────┐
                         │ API Gateway REST API │
                         └──────────┬──────────┘
                                    │
                  ┌─────────────────┼──────────────────┐
                  │                 │                  │
                  ▼                 ▼                  ▼
             Upload Lambda     List Lambda       Download Lambda
                  │                 │                  │
                  │                 ▼                  │
                  │          DynamoDB Metadata         │
                  │                                    │
                  ▼                                    ▼
              S3 Bucket                         S3 Pre-signed URL
                  │
                  │
                  ▼
            Document Versions
                  │
                  ▼
             S3 Lifecycle
                  │
                  ▼
                 S3-IA

                    All operations
                          │
                          ▼
                 DynamoDB audit_log
```

---

## Key Features

### 1. Storage Design (Amazon S3 & DynamoDB)
- **Bucket Layout**: `documents/{employee_id}/{document_type}/{filename}`
- **Supported Categories**: `offer-letter`, `contract`, `payslip`, `appraisal`, `compliance`.
- **S3 Versioning**: Enabled. Updating an existing document creates a new S3 object version.
- **S3 Lifecycle Management**: Non-current versions older than 90 days automatically transition to `STANDARD_IA`.
- **Encryption**: Server-Side Encryption with a dedicated AWS KMS Customer Managed Key (`alias/employee-document-vault-key`).
- **Security Baseline**: BlockPublicAccess enabled (100%), BucketOwnerEnforced, HTTPS-only policy.

### 2. Authentication & Authorization (Cognito & Lambda Zero-Trust)
- **Cognito User Pool**: Dedicated user pool with custom attributes `custom:employee_id` and `custom:role`.
- **Cognito Groups**: `Employee`, `Manager`, `HR_Admin`.
- **Token Verification**: Lambda decodes JWTs and verifies signatures against Cognito's JWKS endpoint (`RS256`).
- **Organizational Hierarchy**: Manager-to-report relationships are resolved dynamically via the `employee_directory` DynamoDB table (`ManagerIndex` GSI).
- **Access Denial**: Unauthorized cross-employee requests immediately return `403 Forbidden` and trigger an `ACCESS_DENIED` audit entry.

### 3. Serverless Backend Logic
- **`POST /upload`**: Validates caller role and file type; generates 15-min S3 pre-signed `PUT` URL; records metadata in DynamoDB.
- **`GET /files`**: Queries metadata indexed by `EmployeeDocumentsIndex`; filters soft-deleted items; enforces role scoping.
- **`GET /download/{doc_id}`**: Validates authorization; generates 15-min S3 pre-signed `GET` URL.
- **`DELETE /files/{doc_id}`**: Marks `deleted = true` in DynamoDB (soft delete); never calls `s3:DeleteObject`.
- **`GET /files/{doc_id}/versions`**: Queries S3 version stack for the document; returns version IDs, timestamps, and sizes.

### 4. Immutable Audit Logging
- Every interaction (`UPLOAD_REQUEST`, `DOWNLOAD`, `LIST`, `DELETE`, `VERSION_HISTORY`, `ACCESS_DENIED`) is recorded in `audit_log`.
- Execution roles are restricted to `dynamodb:PutItem` only (no `DeleteItem` or `UpdateItem` permissions).
- DynamoDB Point-In-Time Recovery (PITR) enabled.

---

## Project Structure

```text
employee-document-vault/
│
├── infrastructure/
│   ├── iam/
│   │   ├── trust-policy.json
│   │   ├── upload-policy.json
│   │   ├── download-policy.json
│   │   ├── list-policy.json
│   │   ├── delete-policy.json
│   │   └── version-policy.json
│   ├── cognito/
│   ├── s3/
│   │   ├── bucket-policy.json
│   │   └── lifecycle.json
│   ├── kms/
│   │   └── key-policy.json
│   ├── dynamodb/
│   ├── apigateway/
│   ├── deploy.ps1             # PowerShell automated deployment
│   └── deploy.sh              # Bash automated deployment
│
├── lambda/
│   ├── common/
│   │   └── auth.py            # Shared JWT validation & RBAC authorization
│   ├── upload/
│   │   └── handler.py         # POST /upload (Pre-signed PUT)
│   ├── download/
│   │   └── handler.py         # GET /download/{doc_id} (Pre-signed GET)
│   ├── list_files/
│   │   └── handler.py         # GET /files (RBAC listing)
│   ├── delete/
│   │   └── handler.py         # DELETE /files/{doc_id} (Soft-delete)
│   └── version_history/
│       └── handler.py         # GET /files/{doc_id}/versions (S3 versions)
│
├── frontend/
│   ├── index.html             # Responsive portal UI with folder categories
│   ├── app.js                 # Frontend SPA logic (Cognito & API Gateway)
│   ├── styles.css             # Custom styling
│   └── config.js              # Injected endpoint & pool config
│
├── scripts/
│   ├── create_users.ps1 / .sh # Provisions demo personas in Cognito
│   ├── seed_data.ps1 / .sh    # Seeds directory and demo documents with versions
│   ├── test_access.ps1 / .sh  # Automated acceptance test suite
│   ├── export_audit_logs.ps1  # Exports audit trail to JSON & CSV
│   └── teardown.ps1 / .sh     # Cleans up all provisioned AWS resources
│
├── docs/
│   ├── architecture.md        # Deep architecture specification
│   ├── security.md            # Threat model & mitigation matrix
│   ├── deployment.md          # CLI deployment and ops guide
│   └── api.md                 # REST API specification
│
├── diagrams/
│   └── architecture.mmd       # Mermaid architecture diagram
│
├── tests/
│   └── test_access_control.py # Python integration test suite
│
├── audit-log-export.json      # Generated audit log export (JSON)
├── audit-log-export.csv       # Generated audit log export (CSV)
└── README.md
```

---

## Quick Start: Deployment

### 1. Automated Deployment
Run the automated deployment script:

**PowerShell (Windows):**
```powershell
.\infrastructure\deploy.ps1
```

**Bash (Linux / macOS / WSL):**
```bash
chmod +x infrastructure/*.sh scripts/*.sh
./infrastructure/deploy.sh
```

### 2. Demo User Credentials
The deployment script seeds the following personas (Default Password: `TempPass123!`):

| Username | Role | Group | Scope / Relationship |
| :--- | :--- | :--- | :--- |
| `EMP001` | Employee | `Employee` | Reports to `MGR001`. Access only to `EMP001` records. |
| `EMP002` | Employee | `Employee` | Reports to `MGR001`. Access only to `EMP002` records. |
| `EMP003` | Employee | `Employee` | Reports to `MGR001`. Access only to `EMP003` records. |
| `EMP999` | Employee | `Employee` | Reports to `MGR999` (Legal). Outside `MGR001`'s team. |
| `MGR001` | Manager | `Manager` | Manages `EMP001`, `EMP002`, `EMP003`. Cannot access `EMP999`. |
| `HR001` | HR Admin | `HR_Admin` | Universal access across all employee records. |

---

## Verification & Testing

### 1. Run Automated Access Control Tests
Verify all 10 acceptance scenarios:

```powershell
.\scripts\test_access.ps1
```
*or*
```bash
python tests/test_access_control.py
```

Scenarios Tested:
- **Test 1**: EMP001 downloads own document -> **200 OK**
- **Test 2**: EMP001 attempts download of EMP002 document -> **403 Forbidden**
- **Test 3**: MGR001 downloads direct report EMP001 document -> **200 OK**
- **Test 4**: MGR001 downloads direct report EMP002 document -> **200 OK**
- **Test 5**: MGR001 attempts download of unrelated employee EMP999 -> **403 Forbidden**
- **Test 6**: HR001 downloads any employee document -> **200 OK**
- **Test 7**: EMP001 attempts DELETE on EMP002 document -> **403 Forbidden**
- **Test 8**: Soft delete sets `deleted = true` in DynamoDB and preserves physical S3 object -> **200 OK**
- **Test 9**: Version history returns multiple S3 versions for `employment-contract.pdf` -> **200 OK**
- **Test 10**: Unauthenticated API request -> **401 Unauthorized**

### 2. Export Immutable Audit Logs
Export at least 10 sample audit events to JSON and CSV:

```powershell
.\scripts\export_audit_logs.ps1
```
Produces `audit-log-export.json` and `audit-log-export.csv`.

---

## Production Security Enhancements
For enterprise production environments, consider adding:
1. **AWS WAF**: Attach to API Gateway to protect against rate-based attacks, SQLi, and common exploits.
2. **Amazon CloudFront**: Place in front of the S3 frontend bucket with Origin Access Control (OAC) and custom SSL certificate.
3. **S3 Malware Scanning**: Asynchronous inspection pipeline via EventBridge -> SQS -> Antivirus Scanner Lambda.
4. **Cognito Advanced Security**: Enable Adaptive Authentication and Multi-Factor Authentication (MFA).
5. **Amazon Macie & GuardDuty**: Continuous scanning for sensitive PII data leakage and threat detection.
