"""
Upload Handler: Generates S3 pre-signed PUT URL and registers document metadata in DynamoDB.
"""
import os
import json
import uuid
import datetime
import time
import re
import boto3
from botocore.config import Config
from botocore.exceptions import ClientError
from auth import authenticate_request, authorize_document_access, write_audit_log, make_response, log_event

AWS_REGION = os.environ.get("AWS_REGION", "us-east-2")
s3_client = boto3.client(
    "s3",
    region_name=AWS_REGION,
    endpoint_url=f"https://s3.{AWS_REGION}.amazonaws.com",
    config=Config(signature_version="s3v4", s3={"addressing_style": "virtual"})
)
dynamodb = boto3.resource("dynamodb")

DOCUMENT_TABLE_NAME = os.environ.get("DOCUMENT_TABLE", "document_metadata")
DOCUMENT_BUCKET_NAME = os.environ.get("DOCUMENT_BUCKET", "")
KMS_KEY_ID = os.environ.get("KMS_KEY_ID", "")

ALLOWED_DOCUMENT_TYPES = {
    "offer-letter",
    "contract",
    "payslip",
    "appraisal",
    "compliance"
}

ALLOWED_EXTENSIONS = {".pdf", ".docx", ".xlsx", ".png", ".jpg", ".jpeg"}


def sanitize_filename(filename: str) -> str:
    base = os.path.basename(filename)
    clean = re.sub(r"[^a-zA-Z0-9_\-\.]", "_", base)
    return clean


def lambda_handler(event, context):
    start_time = time.time()
    req_id = context.aws_request_id if context else "unknown"

    caller = authenticate_request(event)
    if not caller.get("authenticated"):
        duration_ms = (time.time() - start_time) * 1000
        write_audit_log(caller, "UPLOAD_REQUEST", None, result="DENIED", details="Unauthenticated request")
        log_event(req_id, "UPLOAD", caller, status="DENIED", duration_ms=duration_ms, error_type="UNAUTHORIZED", error_message="Authentication required")
        return make_response(401, {"success": False, "error": {"code": "UNAUTHORIZED", "message": "Authentication required"}})

    try:
        body = json.loads(event.get("body") or "{}")
    except Exception:
        duration_ms = (time.time() - start_time) * 1000
        log_event(req_id, "UPLOAD", caller, status="ERROR", duration_ms=duration_ms, error_type="INVALID_JSON", error_message="Malformed request body")
        return make_response(400, {"success": False, "error": {"code": "INVALID_JSON", "message": "Malformed request body"}})

    target_employee_id = body.get("employee_id") or caller.get("employee_id")
    document_type = body.get("document_type", "").strip().lower()
    raw_filename = body.get("filename", "").strip()
    content_type = body.get("content_type", "application/pdf").strip()
    tags = body.get("tags") or []
    if isinstance(tags, str):
        tags = [t.strip() for t in tags.split(",") if t.strip()]

    # Validate target employee
    if not target_employee_id:
        duration_ms = (time.time() - start_time) * 1000
        log_event(req_id, "UPLOAD", caller, status="ERROR", duration_ms=duration_ms, error_type="MISSING_FIELD", error_message="employee_id is required")
        return make_response(400, {"success": False, "error": {"code": "MISSING_FIELD", "message": "employee_id is required"}})

    # Validate document type
    if document_type not in ALLOWED_DOCUMENT_TYPES:
        duration_ms = (time.time() - start_time) * 1000
        log_event(req_id, "UPLOAD", caller, status="ERROR", duration_ms=duration_ms, error_type="INVALID_DOCUMENT_TYPE", error_message=f"Invalid type: {document_type}")
        return make_response(400, {
            "success": False,
            "error": {
                "code": "INVALID_DOCUMENT_TYPE",
                "message": f"Document type must be one of: {', '.join(sorted(ALLOWED_DOCUMENT_TYPES))}"
            }
        })

    # Validate and sanitize filename
    if not raw_filename:
        duration_ms = (time.time() - start_time) * 1000
        log_event(req_id, "UPLOAD", caller, status="ERROR", duration_ms=duration_ms, error_type="MISSING_FIELD", error_message="filename is required")
        return make_response(400, {"success": False, "error": {"code": "MISSING_FIELD", "message": "filename is required"}})

    filename = sanitize_filename(raw_filename)
    ext = os.path.splitext(filename)[1].lower()
    if ext not in ALLOWED_EXTENSIONS:
        duration_ms = (time.time() - start_time) * 1000
        log_event(req_id, "UPLOAD", caller, status="ERROR", duration_ms=duration_ms, error_type="INVALID_EXTENSION", error_message=f"Invalid extension: {ext}")
        return make_response(400, {
            "success": False,
            "error": {
                "code": "INVALID_EXTENSION",
                "message": f"File extension must be one of: {', '.join(sorted(ALLOWED_EXTENSIONS))}"
            }
        })

    # Authorize caller
    is_auth, reason = authorize_document_access(caller, target_employee_id, "UPLOAD")
    if not is_auth:
        duration_ms = (time.time() - start_time) * 1000
        write_audit_log(
            caller=caller,
            action="ACCESS_DENIED",
            target_employee_id=target_employee_id,
            result="DENIED",
            details=f"Unauthorized upload attempt: {reason}"
        )
        log_event(req_id, "UPLOAD", caller, status="DENIED", resource=filename, duration_ms=duration_ms, error_type="ACCESS_DENIED", error_message=reason, extra={"target_employee": target_employee_id})
        return make_response(403, {"success": False, "error": {"code": "ACCESS_DENIED", "message": reason}})

    # Construct S3 key
    s3_key = f"documents/{target_employee_id}/{document_type}/{filename}"
    document_id = f"DOC-{uuid.uuid4().hex[:8].upper()}"
    timestamp = datetime.datetime.now(datetime.timezone.utc).isoformat()

    # Generate pre-signed PUT URL (valid 15 minutes = 900 seconds)
    put_params = {
        "Bucket": DOCUMENT_BUCKET_NAME,
        "Key": s3_key,
        "ContentType": content_type
    }

    try:
        presigned_url = s3_client.generate_presigned_url(
            ClientMethod="put_object",
            Params=put_params,
            ExpiresIn=900
        )
    except Exception as e:
        duration_ms = (time.time() - start_time) * 1000
        log_event(req_id, "UPLOAD", caller, status="ERROR", resource=document_id, duration_ms=duration_ms, error_type="PRESIGNED_URL_ERROR", error_message=str(e))
        return make_response(500, {"success": False, "error": {"code": "PRESIGNED_URL_ERROR", "message": "Could not generate upload URL"}})

    # Store metadata in DynamoDB
    table = dynamodb.Table(DOCUMENT_TABLE_NAME)
    meta_item = {
        "document_id": document_id,
        "employee_id": target_employee_id,
        "uploaded_by": caller.get("employee_id") or caller.get("username"),
        "document_type": document_type,
        "filename": filename,
        "s3_key": s3_key,
        "upload_timestamp": timestamp,
        "tags": tags,
        "content_type": content_type,
        "deleted": False
    }

    try:
        table.put_item(Item=meta_item)
    except Exception as e:
        duration_ms = (time.time() - start_time) * 1000
        log_event(req_id, "UPLOAD", caller, status="ERROR", resource=document_id, duration_ms=duration_ms, error_type="DATABASE_ERROR", error_message=str(e))
        return make_response(500, {"success": False, "error": {"code": "DATABASE_ERROR", "message": "Failed to record metadata"}})

    # Write audit log
    write_audit_log(
        caller=caller,
        action="UPLOAD_REQUEST",
        target_employee_id=target_employee_id,
        document_id=document_id,
        s3_key=s3_key,
        result="SUCCESS",
        details=f"Generated presigned upload URL for {filename}"
    )

    duration_ms = (time.time() - start_time) * 1000
    log_event(req_id, "UPLOAD", caller, status="SUCCESS", resource=document_id, duration_ms=duration_ms, extra={"document_type": document_type, "filename": filename})

    return make_response(201, {
        "success": True,
        "data": {
            "document_id": document_id,
            "upload_url": presigned_url,
            "s3_key": s3_key,
            "expires_in": 900
        }
    })
