# Architecture Audit: Secure Employee Document Vault

## 1. Executive Summary & Inventory

The **Secure Employee Document Vault** is a centralized serverless document repository built on AWS. It provides fine-grained Role-Based Access Control (RBAC) across three distinct organizational roles: **Employee**, **Manager**, and **HR Admin**.

This document represents the baseline architectural audit conducted prior to the Production Hardening, Observability, and Cost Optimization Sprint.

---

## 2. AWS Services Currently Utilized

| Service | Specific Resource Name / ID | Purpose |
| :--- | :--- | :--- |
| **Amazon S3** | `employee-document-vault-210452150784-us-east-2` | Private document storage repository with Versioning and 90-day S3-IA lifecycle transition. |
| **Amazon S3** | `employee-vault-frontend-210452150784-us-east-2` | Static website hosting for the Single Page Application (SPA). |
| **AWS KMS** | `031e72ea-c2db-4b60-8717-80f83bad5188` (`alias/employee-document-vault-key`) | Customer Managed Key (CMK) enforcing Server-Side Encryption (SSE-KMS) on all document objects. |
| **Amazon Cognito** | `us-east-2_xlMw5oMEz` (Client: `6tr2dmu8c71hcqr3lgtj9oc6i1`) | User authentication, JWT token issuance, custom claims (`custom:employee_id`, `custom:role`), and groups (`Employee`, `Manager`, `HR_Admin`). |
| **Amazon API Gateway** | `gk6sav3uah` (Stage: `prod`) | REST API with Cognito User Pool Authorizer (`vh0skj`), CORS filtering, and proxy integrations. |
| **AWS Lambda** | 5 Python 3.12 Functions | Serverless backend computing identity decoding, RBAC authorization, pre-signed URL generation, and metadata management. |
| **Amazon DynamoDB** | 3 On-Demand Tables (`document_metadata`, `employee_directory`, `audit_log`) | Fast key-value and secondary index queries for file metadata, organizational reporting hierarchy, and immutable audit logs. |
| **Amazon CloudWatch** | `/aws/lambda/EmployeeVault*` | Centralized log ingestion for serverless function output. |

---

## 3. Serverless Compute & API Gateway Endpoints

### Lambda Functions (Runtime: Python 3.12, Region: `us-east-2`)
1. **`EmployeeVaultUpload`** (`arn:aws:lambda:us-east-2:210452150784:function:EmployeeVaultUpload`):
   - Memory: 256 MB, Timeout: 15 seconds.
   - Generates 15-minute S3 pre-signed `PUT` URLs.
   - Stages document record in `document_metadata` with status `deleted = false`.
   - Writes `UPLOAD_REQUEST` audit event.
2. **`EmployeeVaultDownload`** (`arn:aws:lambda:us-east-2:210452150784:function:EmployeeVaultDownload`):
   - Memory: 256 MB, Timeout: 15 seconds.
   - Verifies target document exists and `deleted != true`.
   - Authorizes caller against document owner.
   - Generates 15-minute S3 pre-signed `GET` URLs (optional `version_id` support).
   - Writes `DOWNLOAD` or `ACCESS_DENIED` audit events.
3. **`EmployeeVaultList`** (`arn:aws:lambda:us-east-2:210452150784:function:EmployeeVaultList`):
   - Memory: 256 MB, Timeout: 15 seconds.
   - Queries `document_metadata` using `EmployeeDocumentsIndex` GSI.
   - Filters results by role scope (Self, Team, or Universal) and query parameters (`document_type`, `tag`, `sort`).
   - Writes `LIST` audit events.
4. **`EmployeeVaultDelete`** (`arn:aws:lambda:us-east-2:210452150784:function:EmployeeVaultDelete`):
   - Memory: 256 MB, Timeout: 15 seconds.
   - Performs a soft-delete in DynamoDB by setting `deleted = true` and `deleted_timestamp = ISO8601`.
   - Retains physical S3 object and version history intact.
   - Writes `DELETE` or `ACCESS_DENIED` audit events.
5. **`EmployeeVaultVersion`** (`arn:aws:lambda:us-east-2:210452150784:function:EmployeeVaultVersion`):
   - Memory: 256 MB, Timeout: 15 seconds.
   - Calls `s3_client.list_object_versions` for the document's `s3_key`.
   - Returns version stack with version IDs, timestamps, and sizes.
   - Writes `VERSION_HISTORY` audit events.

### API Gateway REST API Routes (`gk6sav3uah` - Stage `prod`)
- `POST /upload` -> `EmployeeVaultUpload` (Cognito Authorizer)
- `GET /files` -> `EmployeeVaultList` (Cognito Authorizer)
- `GET /download/{doc_id}` -> `EmployeeVaultDownload` (Cognito Authorizer)
- `DELETE /files/{doc_id}` -> `EmployeeVaultDelete` (Cognito Authorizer)
- `GET /files/{doc_id}/versions` -> `EmployeeVaultVersion` (Cognito Authorizer)
- `OPTIONS /*` -> Mock Integration returning CORS headers (`Access-Control-Allow-Origin: *`, `Methods: GET,POST,DELETE,OPTIONS`).

---

## 4. DynamoDB Schema & Storage Design

### Tables (`PAY_PER_REQUEST` Billing Mode, Server-Side Encryption Enabled)
1. **`document_metadata`**:
   - Partition Key: `document_id` (String)
   - GSI: `EmployeeDocumentsIndex` (PK: `employee_id`, SK: `upload_timestamp`, Projection: `ALL`)
   - Backup: Point-in-Time Recovery (PITR) Enabled.
2. **`employee_directory`**:
   - Partition Key: `employee_id` (String)
   - GSI: `ManagerIndex` (PK: `manager_id`, Projection: `ALL`)
   - Backup: Point-in-Time Recovery (PITR) Enabled.
3. **`audit_log`**:
   - Partition Key: `audit_id` (String)
   - Sort Key: `timestamp` (String, ISO-8601 UTC)
   - Backup: Point-in-Time Recovery (PITR) Enabled.

### S3 Storage Architecture
- Bucket Name: `employee-document-vault-210452150784-us-east-2`
- Structured Layout: `documents/{employee_id}/{document_type}/{filename}`
- Object Encryption: SSE-KMS via Key `arn:aws:kms:us-east-2:210452150784:key/031e72ea-c2db-4b60-8717-80f83bad5188` (Bucket Key Enabled).
- Integrity: S3 Versioning enabled (`Status=Enabled`).
- Lifecycle Transition: Transition non-current object versions older than 90 days to `STANDARD_IA`.
- Protection: `BlockPublicAccess` fully enabled on all 4 flags; BucketOwnerEnforced object ownership; HTTPS-only bucket policy (`aws:SecureTransport: false` -> Deny).

---

## 5. IAM Roles & Permissions Baseline

Each Lambda runs under a dedicated execution role assuming `lambda.amazonaws.com`:
1. `LambdaUploadRole`: `s3:PutObject` on bucket documents prefix; `dynamodb:PutItem`, `dynamodb:GetItem` on `document_metadata`; `dynamodb:GetItem`, `dynamodb:Scan`, `dynamodb:Query` on `employee_directory`; `dynamodb:PutItem` on `audit_log`; `kms:Encrypt`, `kms:GenerateDataKey`.
2. `LambdaDownloadRole`: `s3:GetObject`, `s3:GetObjectVersion` on bucket documents prefix; `dynamodb:GetItem` on `document_metadata`; `dynamodb:GetItem`, `dynamodb:Scan`, `dynamodb:Query` on `employee_directory`; `dynamodb:PutItem` on `audit_log`; `kms:Decrypt`.
3. `LambdaListRole`: `dynamodb:Query`, `dynamodb:Scan`, `dynamodb:GetItem` on `document_metadata`; read permissions on `employee_directory`; `dynamodb:PutItem` on `audit_log`.
4. `LambdaDeleteRole`: `dynamodb:GetItem`, `dynamodb:UpdateItem` on `document_metadata`; read permissions on `employee_directory`; `dynamodb:PutItem` on `audit_log`. Zero S3 delete permissions.
5. `LambdaVersionRole`: `s3:ListBucketVersions` on bucket; `s3:GetObjectVersion` on bucket prefix; read permissions on `document_metadata` and `employee_directory`; `dynamodb:PutItem` on `audit_log`.

---

## 6. End-to-End Operational Flows

### A. Authentication Flow
1. User supplies credentials (`username`, `password`) to the S3-hosted frontend.
2. Frontend initiates authentication via `AWSCognitoIdentityProviderService.InitiateAuth` (`USER_PASSWORD_AUTH`) directly against `cognito-idp.us-east-2.amazonaws.com`.
3. Cognito validates credentials and issues signed JWT ID and Access Tokens containing `sub`, `cognito:groups`, `custom:employee_id`, and `custom:role`.
4. The frontend stores tokens in `sessionStorage` and attaches `Authorization: Bearer <ID_Token>` to subsequent API Gateway requests.

### B. Document Upload Flow
1. Client sends `POST /upload` with metadata (`employee_id`, `document_type`, `filename`, `content_type`, `tags`).
2. API Gateway Cognito Authorizer cryptographically validates the token against Cognito JWKS.
3. `EmployeeVaultUpload` decodes claims, enforces authorization (Employee can only upload to self; Manager can upload to self and direct reports; HR Admin can upload to any employee).
4. Lambda constructs deterministic S3 key: `documents/{employee_id}/{document_type}/{filename}`.
5. Lambda generates a 15-minute S3 pre-signed `PUT` URL.
6. Lambda inserts metadata into `document_metadata` and logs `UPLOAD_REQUEST` in `audit_log`.
7. Client receives the pre-signed URL and performs direct `PUT` to Amazon S3. S3 automatically encrypts the payload with SSE-KMS and records a new version ID.

### C. Document Download Flow
1. Client sends `GET /download/{doc_id}` (optional query parameter `version_id`).
2. API Gateway authorizer verifies JWT.
3. `EmployeeVaultDownload` looks up document in `document_metadata`. If `deleted == true`, returns 404.
4. Lambda queries `employee_directory` to determine if caller is authorized for target `employee_id`.
   - If unauthorized: Lambda writes an `ACCESS_DENIED` event to `audit_log` and returns `403 Forbidden`.
   - If authorized: Lambda generates a 15-minute S3 pre-signed `GET` URL and writes a `DOWNLOAD` event to `audit_log`.
5. Client browser triggers download directly from S3 using the pre-signed URL.

### D. Role-Specific Access Scopes
- **Employee (`EMP001`)**: Access strictly bounded to `employee_id == EMP001`. Attempting to access another employee's records yields `403 Forbidden`.
- **Manager (`MGR001`)**: Access bounded to self and verified direct reports (`EMP001`, `EMP002`, `EMP003`). Accessing unrelated employee `EMP999` yields `403 Forbidden`.
- **HR Admin (`HR001`)**: Universal administrative access across all employee documents and audit logs.

---

## 7. Gap Analysis & Hardening Opportunities

| Area | Current Baseline | Identified Gap / Risk | Hardening Requirement |
| :--- | :--- | :--- | :--- |
| **Observability** | Standard CloudWatch logging only. | Zero distributed tracing; impossible to trace request lifecycle across API Gateway -> Lambda -> DynamoDB/S3. | Enable AWS X-Ray active tracing on all Lambdas and API Gateway stage `prod`. Document end-to-end trace. |
| **Logging** | Unstructured text print statements. | Difficult to query programmatically; potential risk of leaking sensitive fields during ad-hoc prints. | Implement structured JSON logging with strict PII/token redaction. |
| **Log Analysis** | Manual console log scanning. | No pre-canned operational analytics for security or error triage. | Provide CloudWatch Logs Insights queries for errors, latency, and access denials. |
| **Monitoring** | No centralized dashboard. | Lack of single-pane-of-glass visibility for operational metrics. | Deploy unified CloudWatch dashboard `SecureEmployeeVault-Production`. |
| **Alerting** | No alarms or notifications configured. | Failures or latency spikes occur silently without operator notification. | Provision `secure-employee-vault-alerts` SNS topic, High Error Rate alarm (>5%), and High P95 Latency alarm (>3s). |
| **Operations** | Informal procedures. | No documented incident response protocol for on-call engineers. | Author 1-page operational runbook `docs/runbook.md`. |
| **IAM Permissions**| General least-privilege applied, but CloudWatch log permissions use wildcard resource `arn:aws:logs:*:*:*`. | Overly broad CloudWatch Logs permissions across all log groups in account. | Scope CloudWatch Logs permissions to specific Lambda log group ARNs. |
| **Cost Management**| CloudWatch log retention defaults to `Never Expire`. | Inactive and operational log data accumulates indefinitely, causing runaway storage costs. | Implement 14-day retention policy across all Lambda log groups. |
| **Compute Right-Sizing** | All Lambdas allocated 256 MB memory. | Baseline testing shows actual peak memory usage is ~98-100 MB. Over-provisioned memory increases cost per GB-second. | Benchmark right-sizing Lambdas to 128 MB and analyze latency vs cost impact. |
| **CI/CD** | Manual deployment scripts. | Lack of automated Build -> Test -> Deploy pipeline with security gating. | Configure GitHub Actions pipeline with AWS OIDC authentication. |
| **Load Testing** | Single-user integration tests only. | Concurrency limits and P95 latency under stress unknown. | Author and execute Artillery load test (50 concurrent requests, 60 seconds). |
