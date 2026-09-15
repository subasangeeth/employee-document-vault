# Architecture Specification: Employee Document Vault

## 1. System Overview

The **Employee Document Vault** is a centralized, enterprise-grade HR document repository implementing fine-grained Role-Based Access Control (RBAC). It provides isolated document storage and retrieval with zero-trust backend authorization, preventing unauthorized lateral access across organizational boundaries.

```
+-------------------------------------------------------------------------+
|                               AWS Cloud                                 |
|                                                                         |
|  [ S3 Frontend ]  -->  [ Cognito User Pool ]                            |
|          |                     | (JWT Tokens)                           |
|          v                     v                                        |
|  [ Direct S3 PUT/GET ] <-- [ API Gateway (REST API + Authorizer) ]      |
|                                |                                        |
|                                v                                        |
|                    [ Serverless Lambdas ]                               |
|                     /         |         \                               |
|                    v          v          v                              |
|           [ S3 Vault ]   [ DynamoDB ]   [ KMS Key ]                     |
|           (Versioning,   (Metadata,     (SSE-KMS)                       |
|             S3-IA)        Directory,                                    |
|                           Audit Log)                                    |
+-------------------------------------------------------------------------+
```

---

## 2. Core AWS Services & Responsibilities

| Service | Component / Purpose | Key Configuration |
| :--- | :--- | :--- |
| **Amazon S3** | **Document Storage Vault** | Private bucket, BucketOwnerEnforced, BlockPublicAccess=true, HTTPS enforcement policy. |
| **Amazon S3** | **Frontend Static Site** | Hosts SPA HTML5, CSS, and JS application. |
| **AWS KMS** | **Customer-Managed Key (CMK)** | Dedicated encryption key for SSE-KMS on S3 document bucket. |
| **Amazon Cognito** | **Identity & User Pools** | Handles authentication, password policies, JWT token generation, and role group mapping. |
| **Amazon API Gateway**| **REST API Gateway** | Provides HTTP endpoints, CORS headers, Cognito authorizer validation, and Lambda routing. |
| **AWS Lambda** | **Serverless Compute** | Decodes JWTs, enforces RBAC against employee directory, issues pre-signed URLs, writes audit logs. |
| **Amazon DynamoDB** | **NoSQL Metadata & Audit** | Fast key-value and GSI lookups for document metadata, organizational hierarchy, and immutable audit logs. |
| **Amazon CloudWatch** | **Observability** | Retains operational execution logs for all Lambdas with automated log group management. |

---

## 3. Storage Architecture (Amazon S3)

### Prefix Hierarchy
Documents are isolated using a deterministic prefix structure:
```text
documents/{employee_id}/{document_type}/{filename}
```
Examples:
- `documents/EMP001/offer-letter/offer-letter.pdf`
- `documents/EMP001/contract/employment-contract.pdf`
- `documents/EMP001/payslip/payslip-2026-08.pdf`
- `documents/EMP002/appraisal/appraisal-2026.pdf`
- `documents/EMP002/compliance/first-aid-certificate.pdf`

### S3 Versioning & Integrity
- **Status**: Enabled on the bucket.
- **Behavior**: Every upload of an existing filename creates a new immutable version with a unique `VersionId`.
- **Soft Deletion**: Calling `DELETE /files/{doc_id}` does **not** issue `s3:DeleteObject`. It only updates the DynamoDB metadata flag `deleted = true`. All S3 historical versions remain physically intact.

### S3 Lifecycle Rules
- **Rule ID**: `ArchiveNonCurrentVersionsToIA`
- **Prefix Filter**: `documents/`
- **Action**: Non-current versions older than 90 days are transitioned to `STANDARD_IA` (Infrequent Access) to optimize storage costs while preserving historical records.

---

## 4. DynamoDB Schema Design

### 1. `document_metadata`
Stores active state and indexing for all uploaded documents.
- **Partition Key**: `document_id` (String, e.g. `DOC-EMP001-101`)
- **Global Secondary Index**: `EmployeeDocumentsIndex`
  - Partition Key: `employee_id` (String)
  - Sort Key: `upload_timestamp` (String, ISO-8601)
- **Attributes**: `document_id`, `employee_id`, `uploaded_by`, `document_type`, `filename`, `s3_key`, `upload_timestamp`, `tags`, `current_version_id`, `deleted`, `deleted_timestamp`.
- **Backup**: Point-In-Time Recovery (PITR) enabled.

### 2. `employee_directory`
Maintains reporting relationships and department assignments.
- **Partition Key**: `employee_id` (String, e.g. `EMP001`)
- **Global Secondary Index**: `ManagerIndex`
  - Partition Key: `manager_id` (String, e.g. `MGR001`)
- **Attributes**: `employee_id`, `name`, `manager_id`, `department`, `email`, `role`.

### 3. `audit_log`
Provides an immutable record of all document interactions.
- **Partition Key**: `audit_id` (String, e.g. `AUDIT-9F4A8C2B1D3E`)
- **Sort Key**: `timestamp` (String, ISO-8601 UTC)
- **Attributes**: `audit_id`, `timestamp`, `user_id`, `employee_id`, `caller_employee_id`, `role`, `action`, `document_id`, `s3_key`, `result`, `ip_address`, `user_agent`, `details`.
- **Backup**: Point-In-Time Recovery (PITR) enabled.

---

## 5. Zero-Trust Access Control Flow

```text
Browser User                    Cognito                       API Gateway                     Lambda Handler                  S3 / DynamoDB
     |                             |                               |                                |                               |
     |---- 1. Login (User/Pass) -->|                               |                                |                               |
     |<--- 2. Returns ID Token ----|                               |                                |                               |
     |                                                             |                                |                               |
     |---- 3. HTTP Request (GET /download/:id) + Bearer JWT ------>|                                |                               |
     |                                                             |---- 4. Validates Token Signature (JWKS)                       |
     |                                                             |---- 5. Passes Claims & Context->|                              |
     |                                                             |                                |-- 6. Decodes Caller Identity   |
     |                                                             |                                |-- 7. Resolves Target Emp ID    |
     |                                                             |                                |-- 8. Checks Org Hierarchy ---->| (Query Dir)
     |                                                             |                                |-- 9. Authorize (Allow/Deny)    |
     |                                                             |                                |-- 10. Write Audit Log -------->| (PutItem)
     |                                                             |                                |-- 11. Generate Presigned URL ->| (S3 SDK)
     |<--- 12. Returns Presigned URL (HTTP 200) -------------------|                                |                               |
     |                                                                                                                              |
     |==== 13. Direct GET to S3 via Presigned URL (Expires in 15 mins) =============================================================>|
     |<=== 14. Document Bytes Streamed (Decrypted via KMS) =========================================================================|
```
