"""
Download Handler: Generates S3 pre-signed GET URL (valid 15 mins) with fine-grained authorization.
"""
import os
import json
import time
import boto3
from botocore.config import Config
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


def lambda_handler(event, context):
    start_time = time.time()
    req_id = context.aws_request_id if context else "unknown"

    caller = authenticate_request(event)
    if not caller.get("authenticated"):
        duration_ms = (time.time() - start_time) * 1000
        write_audit_log(caller, "DOWNLOAD", None, result="DENIED", details="Unauthenticated request")
        log_event(req_id, "DOWNLOAD", caller, status="DENIED", duration_ms=duration_ms, error_type="UNAUTHORIZED", error_message="Authentication required")
        return make_response(401, {"success": False, "error": {"code": "UNAUTHORIZED", "message": "Authentication required"}})

    path_params = event.get("pathParameters") or {}
    doc_id = path_params.get("doc_id") or path_params.get("proxy")
    if not doc_id:
        duration_ms = (time.time() - start_time) * 1000
        log_event(req_id, "DOWNLOAD", caller, status="ERROR", duration_ms=duration_ms, error_type="MISSING_PARAM", error_message="doc_id is required")
        return make_response(400, {"success": False, "error": {"code": "MISSING_PARAM", "message": "doc_id is required"}})

    # Fetch document metadata
    table = dynamodb.Table(DOCUMENT_TABLE_NAME)
    try:
        resp = table.get_item(Key={"document_id": doc_id})
    except Exception as e:
        duration_ms = (time.time() - start_time) * 1000
        log_event(req_id, "DOWNLOAD", caller, status="ERROR", resource=doc_id, duration_ms=duration_ms, error_type="DATABASE_ERROR", error_message=str(e))
        return make_response(500, {"success": False, "error": {"code": "DATABASE_ERROR", "message": "Failed to retrieve metadata"}})

    item = resp.get("Item")
    if not item:
        duration_ms = (time.time() - start_time) * 1000
        log_event(req_id, "DOWNLOAD", caller, status="ERROR", resource=doc_id, duration_ms=duration_ms, error_type="NOT_FOUND", error_message="Document not found")
        return make_response(404, {"success": False, "error": {"code": "NOT_FOUND", "message": "Document not found"}})

    # Soft delete check
    if item.get("deleted"):
        duration_ms = (time.time() - start_time) * 1000
        log_event(req_id, "DOWNLOAD", caller, status="ERROR", resource=doc_id, duration_ms=duration_ms, error_type="DOCUMENT_DELETED", error_message="Document has been deleted")
        return make_response(404, {"success": False, "error": {"code": "DOCUMENT_DELETED", "message": "Document has been deleted"}})

    target_employee_id = item.get("employee_id")
    s3_key = item.get("s3_key")

    # Authorize caller
    is_auth, reason = authorize_document_access(caller, target_employee_id, "DOWNLOAD")
    if not is_auth:
        duration_ms = (time.time() - start_time) * 1000
        write_audit_log(
            caller=caller,
            action="ACCESS_DENIED",
            target_employee_id=target_employee_id,
            document_id=doc_id,
            s3_key=s3_key,
            result="DENIED",
            details=f"Unauthorized download attempt: {reason}"
        )
        log_event(req_id, "DOWNLOAD", caller, status="DENIED", resource=doc_id, duration_ms=duration_ms, error_type="ACCESS_DENIED", error_message=reason, extra={"target_employee": target_employee_id})
        return make_response(403, {"success": False, "error": {"code": "ACCESS_DENIED", "message": reason}})

    # Optional version_id from query params
    query_params = event.get("queryStringParameters") or {}
    version_id = query_params.get("version_id") if query_params else None

    # Generate pre-signed GET URL (15 minutes)
    get_params = {
        "Bucket": DOCUMENT_BUCKET_NAME,
        "Key": s3_key,
        "ResponseContentDisposition": f'attachment; filename="{item.get("filename", "document.pdf")}"'
    }
    if version_id:
        get_params["VersionId"] = version_id

    try:
        download_url = s3_client.generate_presigned_url(
            ClientMethod="get_object",
            Params=get_params,
            ExpiresIn=900
        )
    except Exception as e:
        duration_ms = (time.time() - start_time) * 1000
        log_event(req_id, "DOWNLOAD", caller, status="ERROR", resource=doc_id, duration_ms=duration_ms, error_type="PRESIGNED_URL_ERROR", error_message=str(e))
        return make_response(500, {"success": False, "error": {"code": "PRESIGNED_URL_ERROR", "message": "Failed to generate download URL"}})

    # Write audit log
    write_audit_log(
        caller=caller,
        action="DOWNLOAD",
        target_employee_id=target_employee_id,
        document_id=doc_id,
        s3_key=s3_key,
        result="SUCCESS",
        details=f"Generated presigned download URL for {item.get('filename')} (version: {version_id or 'latest'})"
    )

    duration_ms = (time.time() - start_time) * 1000
    log_event(req_id, "DOWNLOAD", caller, status="SUCCESS", resource=doc_id, duration_ms=duration_ms, extra={"document_type": item.get("document_type"), "has_version": bool(version_id)})

    return make_response(200, {
        "success": True,
        "data": {
            "document_id": doc_id,
            "filename": item.get("filename"),
            "download_url": download_url,
            "expires_in": 900
        }
    })
