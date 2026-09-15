# Security Model & Threat Mitigation Matrix: Employee Document Vault

## 1. Principles of Design

1. **Zero-Trust Backend**: The client browser is considered untrusted. Every request is verified server-side inside AWS Lambda against cryptographic tokens and directory records.
2. **Principle of Least Privilege**: Each Lambda function operates under an isolated IAM role with exact resource ARNs and minimal permissions. No wildcards (`*`) are used on sensitive actions.
3. **Defense in Depth**: Access control is enforced at the API Gateway layer (Cognito Authorizer), application layer (Lambda logic), IAM layer (execution roles), and storage layer (S3 bucket policy, KMS key policy).
4. **Data Immutability**: Historical file versions in S3 and audit records in DynamoDB cannot be altered or purged by regular users or standard application execution roles.

---

## 2. Threat Modeling & Mitigation Matrix

| Threat Category | Potential Attack Vector | Severity | Mitigation Strategy |
| :--- | :--- | :--- | :--- |
| **Unauthorized Employee Access** | Employee `EMP001` attempts to read or download documents belonging to `EMP002`. | **Critical** | Lambda inspects authenticated token claims. If `caller.employee_id != target.employee_id` and caller lacks elevated roles, Lambda immediately halts execution, writes an `ACCESS_DENIED` event to `audit_log`, and returns `403 Forbidden`. |
| **JWT Manipulation & Spoofing** | Adversary tampers with token payload to modify username or elevate `cognito:groups` to `HR_Admin`. | **Critical** | API Gateway and Lambda authenticate tokens against Amazon Cognito JWKS keys (`RS256`). Any signature mismatch, expired timestamp, or forged issuer results in instant rejection (`401 Unauthorized`). |
| **S3 Public Exposure** | S3 bucket misconfiguration or accidental ACL change exposes sensitive payroll records to the internet. | **Critical** | S3 `BlockPublicAccess` is fully enabled (`BlockPublicAcls`, `IgnorePublicAcls`, `BlockPublicPolicy`, `RestrictPublicBuckets`). Bucket ownership is enforced (`BucketOwnerEnforced`), ignoring client ACLs. Bucket policy explicitly denies any request without HTTPS. |
| **Path Traversal & Arbitrary S3 Keys** | Malicious user passes filenames such as `../../root.pdf` or arbitrary prefixes to overwrite files outside their scope. | **High** | The server completely ignores any user-supplied S3 key. Lambda sanitizes the filename using regex (`re.sub(r"[^a-zA-Z0-9_\-\.]", "_", basename)`) and constructs the prefix strictly as `documents/{employee_id}/{document_type}/{filename}`. |
| **Pre-signed URL Abuse** | Pre-signed URL intercepted or retained indefinitely by an unauthorized third party. | **Medium** | Pre-signed URLs are configured with a strict expiration window of **900 seconds (15 minutes)**. S3 operations require HTTPS (TLS 1.3). |
| **Privilege Escalation** | Employee attempts to invoke administrative endpoints (e.g. bulk listing or unassigned downloads). | **High** | Endpoints evaluate the caller's Cognito group and directory role server-side. Direct calls to `/upload` or `/download` check whether the target belongs to the caller's allowed scope. |
| **Manager Accessing Unrelated Employees** | Manager `MGR001` attempts to inspect documents of an employee (`EMP999`) who does not report to them. | **High** | Lambda queries the `employee_directory` table (`ManagerIndex` GSI) to verify active reporting relationships. If `target.manager_id != caller.employee_id`, access is denied with `403 Forbidden` and audited. |
| **Soft-Delete Bypass** | Adversary attempts to physically purge document files from S3 to destroy evidence. | **High** | The `DELETE /files/{doc_id}` endpoint only marks `deleted = true` in DynamoDB. The Lambda execution role (`LambdaDeleteRole`) has **no `s3:DeleteObject` permissions whatsoever**, making physical deletion via the API impossible. |
| **Audit-Log Tampering** | Malicious actor attempts to delete or alter audit records to cover up unauthorized access. | **Critical** | The `audit_log` table execution roles are restricted to `dynamodb:PutItem` only. Normal application roles have **no `dynamodb:DeleteItem` or `dynamodb:UpdateItem` permissions**. DynamoDB Point-in-Time Recovery (PITR) is enabled. |
| **Credential Exposure** | AWS credentials leaked in frontend code or repository commits. | **Critical** | Frontend contains **zero AWS credentials**. It authenticates via Cognito and uses temporary JWT bearer tokens. Direct S3 access is granted strictly through temporary pre-signed URLs generated server-side. |

---

## 3. Cryptographic Architecture

### Encryption at Rest
- **Amazon S3**: Server-Side Encryption with AWS KMS Customer Managed Keys (`aws:kms`). Every document version is encrypted with an envelope key managed in KMS.
- **Amazon DynamoDB**: Encrypted at rest using AWS owned keys with continuous point-in-time recovery.

### Encryption in Transit
- **TLS 1.3**: Enforced across all communication layers:
  - Client to API Gateway: HTTPS only.
  - Client to S3 Pre-signed URLs: HTTPS only.
  - S3 Bucket Policy: Explicit `Deny` for any request where `aws:SecureTransport == false`.
  - Lambda to AWS Services: TLS enforced via the AWS SDK.
