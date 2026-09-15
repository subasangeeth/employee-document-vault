"""
List Files Handler: Returns document metadata filtered strictly by caller's role and permissions.
"""
import os
import json
import time
import boto3
from boto3.dynamodb.conditions import Key, Attr
from auth import authenticate_request, get_direct_reports, write_audit_log, make_response, log_event

dynamodb = boto3.resource("dynamodb")
DOCUMENT_TABLE_NAME = os.environ.get("DOCUMENT_TABLE", "document_metadata")


def lambda_handler(event, context):
    start_time = time.time()
    req_id = context.aws_request_id if context else "unknown"

    caller = authenticate_request(event)
    if not caller.get("authenticated"):
        duration_ms = (time.time() - start_time) * 1000
        write_audit_log(caller, "LIST", None, result="DENIED", details="Unauthenticated request")
        log_event(req_id, "LIST_FILES", caller, status="DENIED", duration_ms=duration_ms, error_type="UNAUTHORIZED", error_message="Authentication required")
        return make_response(401, {"success": False, "error": {"code": "UNAUTHORIZED", "message": "Authentication required"}})

    query_params = event.get("queryStringParameters") or {}
    requested_employee_id = query_params.get("employee_id")
    filter_doc_type = query_params.get("document_type")
    filter_tag = query_params.get("tag")
    sort_by = query_params.get("sort", "upload_timestamp")

    role = caller.get("role")
    caller_emp_id = caller.get("employee_id")
    table = dynamodb.Table(DOCUMENT_TABLE_NAME)

    target_employees = []

    if role == "HR_Admin" or "HR_Admin" in caller.get("groups", []):
        if requested_employee_id:
            target_employees = [requested_employee_id]
        else:
            target_employees = None  # None indicates all employees

    elif role == "Manager" or "Manager" in caller.get("groups", []):
        direct_reports = get_direct_reports(caller_emp_id)
        accessible_team = [caller_emp_id] + direct_reports
        if requested_employee_id:
            if requested_employee_id in accessible_team:
                target_employees = [requested_employee_id]
            else:
                duration_ms = (time.time() - start_time) * 1000
                write_audit_log(
                    caller=caller,
                    action="ACCESS_DENIED",
                    target_employee_id=requested_employee_id,
                    result="DENIED",
                    details=f"Manager {caller_emp_id} unauthorized to list files for {requested_employee_id}"
                )
                log_event(
                    req_id, "LIST_FILES", caller, resource=requested_employee_id,
                    status="DENIED", duration_ms=duration_ms,
                    error_type="ACCESS_DENIED",
                    error_message=f"Manager not authorized to access documents for {requested_employee_id}"
                )
                return make_response(403, {
                    "success": False,
                    "error": {
                        "code": "ACCESS_DENIED",
                        "message": f"Manager not authorized to access documents for {requested_employee_id}"
                    }
                })
        else:
            target_employees = accessible_team

    else:  # Standard Employee
        if requested_employee_id and requested_employee_id != caller_emp_id:
            duration_ms = (time.time() - start_time) * 1000
            write_audit_log(
                caller=caller,
                action="ACCESS_DENIED",
                target_employee_id=requested_employee_id,
                result="DENIED",
                details=f"Employee {caller_emp_id} unauthorized to list files for {requested_employee_id}"
            )
            log_event(
                req_id, "LIST_FILES", caller, resource=requested_employee_id,
                status="DENIED", duration_ms=duration_ms,
                error_type="ACCESS_DENIED",
                error_message="Employees may only list their own documents"
            )
            return make_response(403, {
                "success": False,
                "error": {
                    "code": "ACCESS_DENIED",
                    "message": "Employees may only list their own documents"
                }
            })
        target_employees = [caller_emp_id]

    items = []

    try:
        if target_employees is not None:
            # Query per authorized employee using GSI EmployeeDocumentsIndex
            for emp_id in target_employees:
                try:
                    resp = table.query(
                        IndexName="EmployeeDocumentsIndex",
                        KeyConditionExpression=Key("employee_id").eq(emp_id),
                        FilterExpression=Attr("deleted").ne(True)
                    )
                    items.extend(resp.get("Items", []))
                except Exception as q_err:
                    print(f"GSI query failed for {emp_id}, falling back to scan: {q_err}")
                    scan_resp = table.scan(
                        FilterExpression=Attr("employee_id").eq(emp_id) & Attr("deleted").ne(True)
                    )
                    items.extend(scan_resp.get("Items", []))
        else:
            # HR_Admin viewing all active documents
            scan_resp = table.scan(
                FilterExpression=Attr("deleted").ne(True)
            )
            items.extend(scan_resp.get("Items", []))

    except Exception as e:
        duration_ms = (time.time() - start_time) * 1000
        print(f"Error querying documents: {e}")
        log_event(req_id, "LIST_FILES", caller, status="ERROR", duration_ms=duration_ms, error_type="DATABASE_ERROR", error_message=str(e))
        return make_response(500, {"success": False, "error": {"code": "DATABASE_ERROR", "message": "Failed to list documents"}})

    # In-memory filtering for document_type and tags if specified
    if filter_doc_type:
        items = [i for i in items if i.get("document_type") == filter_doc_type.strip().lower()]

    if filter_tag:
        items = [i for i in items if filter_tag.lower() in [t.lower() for t in (i.get("tags") or [])]]

    # Sorting
    reverse = True
    if sort_by == "filename":
        items.sort(key=lambda x: x.get("filename", "").lower(), reverse=False)
    elif sort_by == "document_type":
        items.sort(key=lambda x: x.get("document_type", "").lower(), reverse=False)
    else:  # default upload_timestamp descending
        items.sort(key=lambda x: x.get("upload_timestamp", ""), reverse=reverse)

    # Convert DynamoDB Decimals to float/int if needed
    cleaned_items = []
    for item in items:
        cleaned = dict(item)
        if "deleted" in cleaned:
            del cleaned["deleted"]
        cleaned_items.append(cleaned)

    duration_ms = (time.time() - start_time) * 1000
    target_emp_str = ",".join(target_employees) if target_employees else "ALL"

    # Audit log
    write_audit_log(
        caller=caller,
        action="LIST",
        target_employee_id=target_emp_str,
        result="SUCCESS",
        details=f"Listed {len(cleaned_items)} documents"
    )

    log_event(
        req_id, "LIST_FILES", caller,
        resource=target_emp_str,
        status="SUCCESS",
        duration_ms=duration_ms,
        extra={"item_count": len(cleaned_items)}
    )

    return make_response(200, {
        "success": True,
        "data": {
            "documents": cleaned_items,
            "count": len(cleaned_items)
        }
    })
