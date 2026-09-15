# IAM Least-Privilege Security Audit & Policy Analysis

## 1. Executive Summary

As part of the production hardening sprint for the **Secure Employee Document Vault** (AWS Account `210452150784`, Region `us-east-2`), an exhaustive least-privilege audit was conducted across all IAM execution roles, customer-managed policies, and Cognito group role assignments.

### Audit Summary Matrix
* **Total IAM Roles Audited**: 8 (5 Lambda Microservices, 3 Cognito Authenticated User Roles).
* **High-Risk Wildcards Removed**: `*` actions eliminated from DynamoDB (`dynamodb:*` replaced with specific API actions), CloudWatch Logs (scoped from `arn:aws:logs:*:*:*` to dedicated function log groups), and S3 (prohibition of `s3:DeleteObject`).
* **Immutability Enforcement**: `audit_log` DynamoDB table restricted strictly to `dynamodb:PutItem`—no role in the system possesses `UpdateItem` or `DeleteItem` privileges on audit records.
* **Storage Immutability**: The `LambdaDeleteRole` has **zero** Amazon S3 delete permissions (`s3:DeleteObject` omitted), guaranteeing physical retention of all document versions in S3.

---

## 2. Before vs. After Policy Comparative Analysis

### 2.1 Lambda Delete Service (`LambdaDeleteRole`)

| Dimension | Baseline (Pre-Hardening) | Hardened Production Policy | Security Impact |
|---|---|---|---|
| **S3 Permissions** | Implicitly vulnerable or broad S3 access | **NO S3 permissions granted** (`s3:*` completely absent) | Prevents accidental or malicious physical file destruction; enforces DynamoDB soft deletion. |
| **DynamoDB Metadata** | `dynamodb:*` on `*` | Scoped to `table/document_metadata` with only `GetItem` & `UpdateItem` | Protects table structure and prevents metadata dropping. |
| **Audit Log Table** | Unrestricted read/write | Pinned to `table/audit_log` with **only `PutItem`** | Guarantees audit record append-only immutability. |
| **CloudWatch Logs** | `arn:aws:logs:*:*:*` | `arn:aws:logs:*:*:log-group:/aws/lambda/EmployeeVaultDelete*` | Prevents cross-function log tampering or unauthorized stream manipulation. |
| **Observability** | None | `xray:PutTraceSegments`, `xray:PutTelemetryRecords` on `*` | Enables real-time subsegment latency and error tracing. |

```diff
--- Baseline Delete Policy
+++ Hardened Delete Policy
 {
   "Version": "2012-10-17",
   "Statement": [
     {
       "Effect": "Allow",
-      "Action": "logs:*",
-      "Resource": "*"
+      "Action": ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"],
+      "Resource": "arn:aws:logs:*:*:log-group:/aws/lambda/EmployeeVaultDelete*"
     },
+    {
+      "Effect": "Allow",
+      "Action": ["xray:PutTraceSegments", "xray:PutTelemetryRecords"],
+      "Resource": "*"
+    },
     {
       "Effect": "Allow",
-      "Action": "dynamodb:*",
-      "Resource": "*"
+      "Action": ["dynamodb:GetItem", "dynamodb:UpdateItem"],
+      "Resource": "arn:aws:dynamodb:*:*:table/document_metadata"
     },
     {
       "Effect": "Allow",
-      "Action": "s3:*",
-      "Resource": "arn:aws:s3:::employee-document-vault-*"
+      "Action": ["dynamodb:PutItem"],
+      "Resource": "arn:aws:dynamodb:*:*:table/audit_log"
     }
   ]
 }
```

---

### 2.2 Lambda Upload Service (`LambdaUploadRole`)

| Dimension | Baseline | Hardened Production Policy | Security Impact |
|---|---|---|---|
| **S3 Write Access** | `s3:PutObject` on all buckets | Scoped to `arn:aws:s3:::employee-document-vault-210452150784-us-east-2/*` | Isolates write scope strictly to vault bucket objects. |
| **KMS Permissions** | Unmanaged SSE-S3 or broad KMS | Scoped to CMK `arn:aws:kms:us-east-2:210452150784:key/031e72ea-c2db-4b60-8717-80f83bad5188` (`kms:GenerateDataKey`, `kms:Encrypt`) | Protects data-at-rest encryption envelope keys. |
| **DynamoDB Write** | `dynamodb:PutItem` on `*` | Scoped strictly to `table/document_metadata` and `table/audit_log` | Prevents writing to arbitrary tables. |

---

### 2.3 Lambda Download Service (`LambdaDownloadRole`)

| Dimension | Baseline | Hardened Production Policy | Security Impact |
|---|---|---|---|
| **S3 Read Access** | `s3:GetObject` on `*` | Scoped strictly to `arn:aws:s3:::employee-document-vault-210452150784-us-east-2/*` | Prevents arbitrary bucket access. |
| **KMS Decrypt** | `kms:*` on `*` | Scoped to key `031e72ea-c2db-4b60-8717-80f83bad5188` with only `kms:Decrypt` | Grants minimal cryptographic capability to unwrap ciphertext. |
| **RBAC Directory** | Scans on all tables | Scoped to `table/employee_directory` and index `ManagerIndex` | Supports hierarchical manager/reporting queries without table alteration. |

---

### 2.4 Lambda Version History Service (`LambdaVersionRole`)

| Dimension | Baseline | Hardened Production Policy | Security Impact |
|---|---|---|---|
| **S3 Versioning** | `s3:*` on bucket | `s3:ListBucketVersions` on bucket ARN; `s3:GetObjectVersion` on object prefix | Prevents bucket deletion or lifecycle reconfiguration. |
| **KMS Decrypt** | Broad KMS | Scoped to `key/031e72ea-c2db-4b60-8717-80f83bad5188` (`kms:Decrypt`) | Cryptographic minimal privilege. |

---

## 3. Storage & Cryptographic Policy Deep-Dive

### 3.1 S3 Bucket Policy & TLS Enforcement
The S3 bucket `employee-document-vault-210452150784-us-east-2` enforces:
1. **Explicit Deny for Non-TLS Traffic**: Rejects all `http://` calls via condition `"aws:SecureTransport": "false"`.
2. **KMS Default Encryption**: Rejects unencrypted PUT requests using SSE-KMS with CMK `031e72ea-c2db-4b60-8717-80f83bad5188`.
3. **Public Access Block**: All four S3 Public Access Block settings enabled (`BlockPublicAcls`, `IgnorePublicAcls`, `BlockPublicPolicy`, `RestrictPublicBuckets`).

---

## 4. Cognito Role Mapping & Authorization Architecture

* **Cognito Groups**: `Employee`, `Manager`, `HR_Admin`.
* **Token Model**: OpenID Connect (OIDC) JWT IdToken containing:
  * `sub`: Unique Cognito identity UUID
  * `cognito:groups`: RBAC roles (`[Employee]`, `[Manager]`, `[HR_Admin]`)
  * `custom:employee_id`: Business identifier (`EMP001`, `MGR001`, `HR001`)
* **Authorizer Layer**: API Gateway Cognito Authorizer inspects token signatures via Cognito JWKS endpoint. Unauthenticated or tampered tokens fail at API Gateway before Lambda execution occurs.
* **Application Enforcement Layer**: Lambda handlers read verified claims from `requestContext.authorizer.claims` and cross-reference DynamoDB `employee_directory` to prevent spoofing.

---

## 5. Residual Risk Assessment & Hardening Recommendations

1. **VPC Integration**:
   - *Current State*: Lambda functions run outside VPC in AWS managed compute space.
   - *Future Hardening*: Deploy Lambdas within private subnets with VPC Endpoints for S3 (Gateway Endpoint) and DynamoDB (Gateway Endpoint) to keep all internal traffic off public IP routing.
2. **IAM Access Analyzer**:
   - *Recommendation*: Enable AWS IAM Access Analyzer on account `210452150784` to continuously alert on any external resource access grants.
