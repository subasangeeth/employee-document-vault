# Security & Authorization Validation Report

## 1. Executive Summary & Test Execution Metadata

This document records the empirical security verification results for the **Secure Employee Document Vault** deployed in AWS Account `210452150784` (`us-east-2`). 

All seven mandatory security attack scenarios were executed live against the production API Gateway and AWS cloud services using the automated security test suite `tests/test_security_scenarios.py`.

* **Execution Timestamp**: `2026-09-15T12:17:50Z`
* **AWS Region**: `us-east-2`
* **API Gateway Base URL**: `https://gk6sav3uah.execute-api.us-east-2.amazonaws.com/prod`
* **Cognito User Pool ID**: `us-east-2_xlMw5oMEz`
* **S3 Vault Bucket**: `employee-document-vault-210452150784-us-east-2`
* **Overall Outcome**: **7 / 7 PASSED (100% Security Coverage)**

---

## 2. Test Results Summary Table

| Scenario # | Attack Vector / Test Description | Caller Persona | Expected HTTP Status | Actual HTTP Status | Measured Latency | Security Result |
|---|---|---|---|---|---|---|
| **Scenario 1** | Cross-User Isolation: Employee attempts access to peer's document | `EMP001` (Employee) | `403 Forbidden` | `403 Forbidden` | 1352.8ms | **PASS** |
| **Scenario 2** | Manager Boundary: Manager attempts access to non-reporting employee's document | `MGR001` (Manager) | `403 Forbidden` | `403 Forbidden` | 985.8ms | **PASS** |
| **Scenario 3** | Role Boundary: Employee attempts to list documents of another employee | `EMP001` (Employee) | `403 Forbidden` | `403 Forbidden` | 2503.1ms | **PASS** |
| **Scenario 4** | Cryptographic Integrity: Tampered JWT signature submitted to API | Unauthenticated Attacker | `401 / 403` | `403 Forbidden` | 868.7ms | **PASS** |
| **Scenario 5** | Storage Isolation: Direct unauthenticated HTTP GET to S3 object key | Public Internet | `403 Forbidden` | `403 Forbidden` | 1149.9ms | **PASS** |
| **Scenario 6** | Temporal Expiration: Access attempt via expired pre-signed URL | Authorized Recipient (expired) | `403 Forbidden` | `403 Forbidden` | 892.3ms | **PASS** |
| **Scenario 7** | Data Immutability: Soft-deleted document API access & S3 retention | `HR001` (HR Admin) | `404 Not Found` | `404 Not Found` | 1164.9ms | **PASS** |

---

## 3. Deep-Dive Scenario Evidence & Raw Payloads

### Scenario 1: Cross-User Isolation (Horizontal Privilege Escalation)
* **Description**: Standard Employee `EMP001` attempts to download document `DOC-EMP002-107` belonging to `EMP002`.
* **Request**:
  ```http
  GET /download/DOC-EMP002-107 HTTP/1.1
  Host: gk6sav3uah.execute-api.us-east-2.amazonaws.com
  Authorization: Bearer eyJraWQiOi... (EMP001 Valid Token)
  ```
* **Raw Response Body**:
  ```json
  {
    "success": false,
    "error": {
      "code": "ACCESS_DENIED",
      "message": "Employee EMP001 cannot access records belonging to employee EMP002"
    }
  }
  ```
* **Security Validation**: Lambda authorization interceptor detects `caller_emp_id != target_employee_id` and emits `ACCESS_DENIED` audit record to DynamoDB. Request blocked.

---

### Scenario 2: Manager Boundary Enforcement
* **Description**: Manager `MGR001` (manager of `EMP001`, `EMP002`, `EMP003`) attempts to download document `DOC-EMP999-111` belonging to `EMP999` (reports to a different department/manager).
* **Request**:
  ```http
  GET /download/DOC-EMP999-111 HTTP/1.1
  Host: gk6sav3uah.execute-api.us-east-2.amazonaws.com
  Authorization: Bearer eyJraWQiOi... (MGR001 Valid Token)
  ```
* **Raw Response Body**:
  ```json
  {
    "success": false,
    "error": {
      "code": "ACCESS_DENIED",
      "message": "Manager MGR001 is not authorized to access documents for employee EMP999"
    }
  }
  ```
* **Security Validation**: DynamoDB GSI lookup on `employee_directory` confirms `EMP999` is not in `MGR001`'s direct reporting chain. Request blocked.

---

### Scenario 3: Unauthorized Document Listing
* **Description**: Standard Employee `EMP001` queries the document listing endpoint for target employee `EMP002`.
* **Request**:
  ```http
  GET /files?employee_id=EMP002 HTTP/1.1
  Host: gk6sav3uah.execute-api.us-east-2.amazonaws.com
  Authorization: Bearer eyJraWQiOi... (EMP001 Valid Token)
  ```
* **Raw Response Body**:
  ```json
  {
    "success": false,
    "error": {
      "code": "ACCESS_DENIED",
      "message": "Employees may only list their own documents"
    }
  }
  ```
* **Security Validation**: Strict RBAC prevents non-HR callers from specifying arbitrary target employee query parameters. Request blocked.

---

### Scenario 4: Tampered JWT Signature Rejection
* **Description**: Attacker crafts a JWT where claims are modified and signature is replaced with `INVALID_SIGNATURE_TAMPERED`.
* **Request**:
  ```http
  GET /download/DOC-EMP001-102 HTTP/1.1
  Host: gk6sav3uah.execute-api.us-east-2.amazonaws.com
  Authorization: Bearer eyJraWQiOi...INVALID_SIGNATURE_TAMPERED
  ```
* **Raw Response Body**:
  ```json
  {
    "Message": "Access Denied"
  }
  ```
* **Security Validation**: API Gateway Cognito Authorizer cryptographically validates RSA-256 signature against Cognito JWKS before forwarding to backend. Request terminated at AWS edge with zero compute cost.

---

### Scenario 5: Direct S3 Bucket Access Without Pre-signed URL
* **Description**: Unauthenticated client attempts direct HTTP GET to S3 vault object `https://employee-document-vault-210452150784-us-east-2.s3.us-east-2.amazonaws.com/documents/EMP001/offer-letter/EMP001_offer_letter.pdf`.
* **Request**:
  ```http
  GET /documents/EMP001/offer-letter/EMP001_offer_letter.pdf HTTP/1.1
  Host: employee-document-vault-210452150784-us-east-2.s3.us-east-2.amazonaws.com
  ```
* **Raw Response Body**:
  ```xml
  <?xml version="1.0" encoding="UTF-8"?>
  <Error>
    <Code>AccessDenied</Code>
    <Message>Access Denied</Message>
    <RequestId>RAYPG0Q8NMY8VWCH</RequestId>
    <HostId>/R4K0uNlWHd0ucDadi2cLwdFyEJ50Ap/wxMELWxxONMWbQTv4IE+uakiWj87PIjqff6syJiM4tSDGhOQd6p+q7zPJgn97dmi</HostId>
  </Error>
  ```
* **Security Validation**: S3 Public Access Block + S3 Bucket Policy blocks all direct non-signed or non-TLS requests.

---

### Scenario 6: Expired Pre-Signed URL Rejection
* **Description**: Pre-signed URL generated with a 1-second TTL accessed after 3 seconds.
* **Request**:
  ```http
  GET /documents/EMP001/offer-letter/EMP001_offer_letter.pdf?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=...&X-Amz-Expires=1 HTTP/1.1
  Host: employee-document-vault-210452150784-us-east-2.s3.us-east-2.amazonaws.com
  ```
* **Raw Response Body**:
  ```xml
  <?xml version="1.0" encoding="UTF-8"?>
  <Error>
    <Code>AccessDenied</Code>
    <Message>Request has expired</Message>
    <X-Amz-Expires>1</X-Amz-Expires>
    <Expires>2026-09-15T12:17:45Z</Expires>
    <ServerTime>2026-09-15T12:17:55Z</ServerTime>
    <RequestId>50Q42QSTP49M4QGY</RequestId>
  </Error>
  ```
* **Security Validation**: AWS S3 Signature Version 4 enforcement terminates validity immediately after expiration window.

---

### Scenario 7: Soft-Delete Immutability & Physical S3 Retention
* **Description**: A document is soft-deleted via API Gateway `DELETE /files/{doc_id}`. Validation checks both API behavior and physical S3 storage.
* **Verification Steps**:
  1. `meta_table.get_item(Key={"document_id": doc_id})` shows `deleted: true`, `deleted_timestamp: 2026-09-15T...`.
  2. `s3_client.head_object(Bucket=DOC_BUCKET, Key=s3_key)` returns `200 OK` with physical `VersionId` intact.
  3. API download request returns `404 Not Found` (`Document not found`).
* **Security Validation**: Confirms that soft deletion hides the document from standard business operations while retaining complete non-repudiation forensic evidence and audit logs.
