"""
Version History Handler: Lists historical versions of a document from S3 with RBAC validation.
"""
import os
import json
import time
import boto3
from auth import authenticate_request, authorize_document_access, write_audit_log, make_response, log_event

s3_client = boto3.client("s3")
dynamodb = boto3.resource("dynamodb")

DOCUMENT_TABLE_NAME = os.environ.get("DOCUMENT_TABLE", "document_metadata")
DOCUMENT_BUCKET_NAME = os.environ.get("DOCUMENT_BUCKET", "")


def lambda_handler(event, context):
    start_time = time.time()
    req_id = context.aws_request_id if context else "unknown"

    caller = authenticate_request(event)
    if not caller.get("authenticated"):
        duration_ms = (time.time() - start_time) * 1000
        write_audit_log(caller, "VERSION_HISTORY", None, result="DENIED", details="Unauthenticated request")
        log_event(req_id, "VERSION_HISTORY", caller, status="DENIED", duration_ms=duration_ms, error_type="UNAUTHORIZED", error_message="Authentication required")
        return make_response(401, {"success": False, "error": {"code": "UNAUTHORIZED", "message": "Authentication required"}})

    path_params = event.get("pathParameters") or {}
    doc_id = path_params.get("doc_id") or path_params.get("proxy")
    if not doc_id:
        duration_ms = (time.time() - start_time) * 1000
        log_event(req_id, "VERSION_HISTORY", caller, status="ERROR", duration_ms=duration_ms, error_type="MISSING_PARAM", error_message="doc_id is required")
        return make_response(400, {"success": False, "error": {"code": "MISSING_PARAM", "message": "doc_id is required"}})

    table = dynamodb.Table(DOCUMENT_TABLE_NAME)
    try:
        resp = table.get_item(Key={"document_id": doc_id})
    except Exception as e:
        duration_ms = (time.time() - start_time) * 1000
        print(f"DynamoDB get error: {e}")
        log_event(req_id, "VERSION_HISTORY", caller, resource=doc_id, status="ERROR", duration_ms=duration_ms, error_type="DATABASE_ERROR", error_message=str(e))
        return make_response(500, {"success": False, "error": {"code": "DATABASE_ERROR", "message": "Failed to retrieve metadata"}})

    item = resp.get("Item")
    if not item:
        duration_ms = (time.time() - start_time) * 1000
        log_event(req_id, "VERSION_HISTORY", caller, resource=doc_id, status="ERROR", duration_ms=duration_ms, error_type="NOT_FOUND", error_message="Document not found")
        return make_response(404, {"success": False, "error": {"code": "NOT_FOUND", "message": "Document not found"}})

    target_employee_id = item.get("employee_id")
    s3_key = item.get("s3_key")

    # Authorize caller
    is_auth, reason = authorize_document_access(caller, target_employee_id, "VERSION_HISTORY")
    if not is_auth:
        duration_ms = (time.time() - start_time) * 1000
        write_audit_log(
            caller=caller,
            action="ACCESS_DENIED",
            target_employee_id=target_employee_id,
            document_id=doc_id,
            s3_key=s3_key,
            result="DENIED",
            details=f"Unauthorized version history attempt: {reason}"
        )
        log_event(
            req_id, "VERSION_HISTORY", caller, resource=doc_id,
            status="DENIED", duration_ms=duration_ms,
            error_type="ACCESS_DENIED", error_message=reason
        )
        return make_response(403, {"success": False, "error": {"code": "ACCESS_DENIED", "message": reason}})

    # Fetch object versions from S3
    try:
        versions_resp = s3_client.list_object_versions(
            Bucket=DOCUMENT_BUCKET_NAME,
            Prefix=s3_key
        )
        s3_versions = versions_resp.get("Versions", [])
        
        # Filter strictly for this specific key
        matched_versions = []
        for v in s3_versions:
            if v.get("Key") == s3_key:
                matched_versions.append({
                    "version_id": v.get("VersionId"),
                    "last_modified": v.get("LastModified").isoformat() if v.get("LastModified") else "",
                    "size": v.get("Size", 0),
                    "is_latest": v.get("IsLatest", False)
                })

    except Exception as e:
        duration_ms = (time.time() - start_time) * 1000
        print(f"S3 list_object_versions error: {e}")
        log_event(req_id, "VERSION_HISTORY", caller, resource=doc_id, status="ERROR", duration_ms=duration_ms, error_type="S3_ERROR", error_message=str(e))
        return make_response(500, {"success": False, "error": {"code": "S3_ERROR", "message": "Failed to retrieve S3 version history"}})

    duration_ms = (time.time() - start_time) * 1000

    # Write audit log
    write_audit_log(
        caller=caller,
        action="VERSION_HISTORY",
        target_employee_id=target_employee_id,
        document_id=doc_id,
        s3_key=s3_key,
        result="SUCCESS",
        details=f"Retrieved {len(matched_versions)} versions for {item.get('filename')}"
    )

    log_event(
        req_id, "VERSION_HISTORY", caller,
        resource=doc_id,
        status="SUCCESS",
        duration_ms=duration_ms,
        extra={"version_count": len(matched_versions), "target_employee_id": target_employee_id}
    )

    return make_response(200, {
        "success": True,
        "data": {
            "document_id": doc_id,
            "filename": item.get("filename"),
            "s3_key": s3_key,
            "versions": matched_versions
        }
    })
