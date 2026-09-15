# REST API Specification: Employee Document Vault

All endpoints require authentication through an Amazon Cognito User Pool JWT Bearer token in the `Authorization` header:
```http
Authorization: Bearer <Cognito_ID_Token>
```

---

## 1. POST /upload
Initializes an upload transaction and generates a 15-minute S3 pre-signed `PUT` URL.

### Request
```http
POST /upload HTTP/1.1
Content-Type: application/json
Authorization: Bearer <JWT>

{
  "employee_id": "EMP001",
  "document_type": "contract",
  "filename": "employment-contract.pdf",
  "content_type": "application/pdf",
  "tags": ["contract", "employment", "2026"]
}
```

### Authorization Rules
- **Employee**: Can upload only to their own `employee_id`.
- **Manager**: Can upload to own `employee_id` or direct reports.
- **HR_Admin**: Can upload to any employee.

### Response (201 Created)
```json
{
  "success": true,
  "data": {
    "document_id": "DOC-EMP001-102",
    "upload_url": "https://employee-document-vault-....s3.us-east-2.amazonaws.com/documents/EMP001/contract/employment-contract.pdf?X-Amz-Security-Token=...",
    "s3_key": "documents/EMP001/contract/employment-contract.pdf",
    "expires_in": 900
  }
}
```

### Error Responses
- `400 Bad Request`: Missing fields, invalid document type, or disallowed file extension.
- `401 Unauthorized`: Missing or invalid JWT.
- `403 Forbidden`: Caller not authorized for target employee.

### Audit Event
- **Action**: `UPLOAD_REQUEST` (or `ACCESS_DENIED`)
- **Details**: S3 key and filename recorded.

---

## 2. GET /files
Lists document metadata filtered according to caller permissions and query filters.

### Request
```http
GET /files?document_type=contract&sort=upload_timestamp HTTP/1.1
Authorization: Bearer <JWT>
```

### Query Parameters
- `employee_id` *(optional)*: Filter for a specific employee (Managers may only specify direct reports; Employees may only specify self).
- `document_type` *(optional)*: One of `offer-letter`, `contract`, `payslip`, `appraisal`, `compliance`.
- `tag` *(optional)*: Filter by tag keyword.
- `sort` *(optional)*: `upload_timestamp` (default), `filename`, `document_type`.

### Authorization Rules
- **Employee**: Automatically restricted to own records. Attempting to query another employee yields `403 Forbidden`.
- **Manager**: Restricted to self and direct reports.
- **HR_Admin**: Can view all employee records.

### Response (200 OK)
```json
{
  "success": true,
  "data": {
    "count": 1,
    "documents": [
      {
        "document_id": "DOC-EMP001-102",
        "employee_id": "EMP001",
        "uploaded_by": "EMP001",
        "document_type": "contract",
        "filename": "employment-contract.pdf",
        "s3_key": "documents/EMP001/contract/employment-contract.pdf",
        "upload_timestamp": "2026-09-08T12:00:00Z",
        "tags": ["contract", "employment", "2026"],
        "current_version_id": "3/Lfp01..."
      }
    ]
  }
}
```

### Audit Event
- **Action**: `LIST`

---

## 3. GET /download/{doc_id}
Generates a 15-minute S3 pre-signed `GET` URL for downloading the requested document.

### Request
```http
GET /download/DOC-EMP001-102 HTTP/1.1
Authorization: Bearer <JWT>
```

### Query Parameters
- `version_id` *(optional)*: S3 Version ID to retrieve an archived historical version.

### Authorization Rules
- **Employee**: Can download only their own documents. Cross-employee downloads return `403 Forbidden`.
- **Manager**: Can download documents for self and direct reports.
- **HR_Admin**: Can download any document.

### Response (200 OK)
```json
{
  "success": true,
  "data": {
    "document_id": "DOC-EMP001-102",
    "filename": "employment-contract.pdf",
    "download_url": "https://employee-document-vault-....s3.us-east-2.amazonaws.com/documents/EMP001/contract/employment-contract.pdf?X-Amz-Signature=...",
    "expires_in": 900
  }
}
```

### Error Responses
- `404 Not Found`: Document ID does not exist or has been soft-deleted.
- `403 Forbidden`: Caller lacks authorization for this employee.

### Audit Event
- **Action**: `DOWNLOAD` (or `ACCESS_DENIED`)

---

## 4. DELETE /files/{doc_id}
Performs a soft delete by marking `deleted = true` in DynamoDB. The underlying S3 object is preserved.

### Request
```http
DELETE /files/DOC-EMP001-102 HTTP/1.1
Authorization: Bearer <JWT>
```

### Authorization Rules
- **Employee**: Can delete only their own documents.
- **Manager**: Can delete documents for direct reports.
- **HR_Admin**: Can delete any document.

### Response (200 OK)
```json
{
  "success": true,
  "data": {
    "document_id": "DOC-EMP001-102",
    "deleted": true,
    "deleted_timestamp": "2026-09-08T12:30:00Z",
    "message": "Document soft-deleted successfully (physical S3 object retained)"
  }
}
```

### Audit Event
- **Action**: `DELETE` (or `ACCESS_DENIED`)

---

## 5. GET /files/{doc_id}/versions
Queries S3 object versions for the document, showing timestamps, sizes, and version identifiers.

### Request
```http
GET /files/DOC-EMP001-102/versions HTTP/1.1
Authorization: Bearer <JWT>
```

### Authorization Rules
- Follows the same role-based rules as document download.

### Response (200 OK)
```json
{
  "success": true,
  "data": {
    "document_id": "DOC-EMP001-102",
    "filename": "employment-contract.pdf",
    "s3_key": "documents/EMP001/contract/employment-contract.pdf",
    "versions": [
      {
        "version_id": "3/Lfp01abc...",
        "last_modified": "2026-09-08T12:15:00Z",
        "size": 84520,
        "is_latest": true
      },
      {
        "version_id": "yZ98aK2m...",
        "last_modified": "2026-09-08T11:00:00Z",
        "size": 82140,
        "is_latest": false
      }
    ]
  }
}
```

### Audit Event
- **Action**: `VERSION_HISTORY` (or `ACCESS_DENIED`)
