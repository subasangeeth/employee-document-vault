"""
Delete Handler: Implements SOFT DELETE in DynamoDB without removing the underlying S3 object or its versions.
"""
import os
import json
import datetime
import time
import boto3
from auth import authenticate_request,  authorize_document_access, write_audit_log, make_response, log_event

dynamodb = boto3.resource("dynamodb")
DOCUMENT_TABLE_NAME = os.environ.get("DOCUMENT_TABLE", "document_metadata")


def lambda_handler(event, context):
    start_time = time.time()
    req_id = context.aws_request_id if context else "unknown"

    caller = authenticate_request(event)
    if not caller.get("authenticated"):
        duration_ms = (time.time() - start_time) * 1000
        write_audit_log(caller, "DELETE", None, result="DENIED", details="Unauthenticated request")
        log_event(req_id, "DELETE", caller, status="DENIED", duration_ms=duration_ms, error_type="UNAUTHORIZED", error_message="Authentication required")
        return make_response(401, {"success": False, "error": {"code": "UNAUTHORIZED", "message": "Authentication required"}})

    path_params = event.get("pathParameters") or {}
    doc_id = path_params.get("doc_id") or path_params.get("proxy")
    if not doc_id:
        duration_ms = (time.time() - start_time) * 1000
        log_event(req_id, "DELETE", caller, status="ERROR", duration_ms=duration_ms, error_type="MISSING_PARAM", error_message="doc_id is required")
        return make_response(400, {"success": False, "error": {"code": "MISSING_PARAM", "message": "doc_id is required"}})

    table = dynamodb.Table(DOCUMENT_TABLE_NAME)
    try:
        resp = table.get_item(Key={"document_id": doc_id})
    except Exception as e:
        duration_ms = (time.time() - start_time) * 1000
        print(f"DynamoDB get error: {e}")
        log_event(req_id, "DELETE", caller, resource=doc_id, status="ERROR", duration_ms=duration_ms, error_type="DATABASE_ERROR", error_message=str(e))
        return make_response(500, {"success": False, "error": {"code": "DATABASE_ERROR", "message": "Failed to retrieve metadata"}})

    item = resp.get("Item")
    if not item or item.get("deleted"):
        duration_ms = (time.time() - start_time) * 1000
        log_event(req_id, "DELETE", caller, resource=doc_id, status="ERROR", duration_ms=duration_ms, error_type="NOT_FOUND", error_message="Document not found")
        return make_response(404, {"success": False, "error": {"code": "NOT_FOUND", "message": "Document not found"}})

    target_employee_id = item.get("employee_id")
    s3_key = item.get("s3_key")

    # Authorize caller
    is_auth, reason = authorize_document_access(caller, target_employee_id, "DELETE")
    if not is_auth:
        duration_ms = (time.time() - start_time) * 1000
        write_audit_log(
            caller=caller,
            action="ACCESS_DENIED",
            target_employee_id=target_employee_id,
            document_id=doc_id,
            s3_key=s3_key,
            result="DENIED",
            details=f"Unauthorized delete attempt: {reason}"
        )
        log_event(
            req_id, "DELETE", caller, resource=doc_id,
            status="DENIED", duration_ms=duration_ms,
            error_type="ACCESS_DENIED", error_message=reason
        )
        return make_response(403, {"success": False, "error": {"code": "ACCESS_DENIED", "message": reason}})

    # Perform soft-delete in DynamoDB (DO NOT DELETE S3 OBJECT)
    deleted_timestamp = datetime.datetime.now(datetime.timezone.utc).isoformat()
    try:
        table.update_item(
            Key={"document_id": doc_id},
            UpdateExpression="SET deleted = :del, deleted_timestamp = :ts",
            ExpressionAttributeValues={
                ":del": True,
                ":ts": deleted_timestamp
            }
        )
    except Exception as e:
        duration_ms = (time.time() - start_time) * 1000
        print(f"DynamoDB update error: {e}")
        log_event(req_id, "DELETE", caller, resource=doc_id, status="ERROR", duration_ms=duration_ms, error_type="DATABASE_ERROR", error_message=str(e))
        return make_response(500, {"success": False, "error": {"code": "DATABASE_ERROR", "message": "Failed to update document status"}})

    duration_ms = (time.time() - start_time) * 1000

    # Write audit log
    write_audit_log(
        caller=caller,
        action="DELETE",
        target_employee_id=target_employee_id,
        document_id=doc_id,
        s3_key=s3_key,
        result="SUCCESS",
        details=f"Soft-deleted document {doc_id} ({item.get('filename')})"
    )

    log_event(
        req_id, "DELETE", caller,
        resource=doc_id,
        status="SUCCESS",
        duration_ms=duration_ms,
        extra={"target_employee_id": target_employee_id, "s3_key": s3_key}
    )

    return make_response(200, {
        "success": True,
        "data": {
            "document_id": doc_id,
            "deleted": True,
            "deleted_timestamp": deleted_timestamp,
            "message": "Document soft-deleted successfully (physical S3 object retained)"
        }
    })
