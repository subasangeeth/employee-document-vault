"""
Common Authentication, Authorization, and Audit Logging Module for Employee Document Vault
"""
import os
import json
import time
import base64
import urllib.request
import urllib.parse
import uuid
import datetime
import boto3
from botocore.exceptions import ClientError

dynamodb = boto3.resource("dynamodb")
DOCUMENT_TABLE_NAME = os.environ.get("DOCUMENT_TABLE", "document_metadata")
EMPLOYEE_TABLE_NAME = os.environ.get("EMPLOYEE_TABLE", "employee_directory")
AUDIT_TABLE_NAME = os.environ.get("AUDIT_TABLE", "audit_log")
USER_POOL_ID = os.environ.get("COGNITO_USER_POOL_ID", "")
AWS_REGION = os.environ.get("AWS_REGION", "us-east-2")

# In-memory cache for JWKS keys to avoid re-fetching on every request
_JWKS_CACHE = None

def get_jwks():
    global _JWKS_CACHE
    if _JWKS_CACHE:
        return _JWKS_CACHE
    if not USER_POOL_ID:
        return {}
    jwks_url = f"https://cognito-idp.{AWS_REGION}.amazonaws.com/{USER_POOL_ID}/.well-known/jwks.json"
    try:
        req = urllib.request.Request(jwks_url)
        with urllib.request.urlopen(req, timeout=5) as response:
            _JWKS_CACHE = json.loads(response.read().decode("utf-8"))
            return _JWKS_CACHE
    except Exception as e:
        print(f"Warning: Failed to fetch JWKS from {jwks_url}: {e}")
        return {}


def parse_jwt_unverified(token: str):
    """
    Safely decodes JWT header and payload without external library dependencies.
    Used in conjunction with API Gateway authorizer or secondary validation.
    """
    parts = token.split(".")
    if len(parts) != 3:
        raise ValueError("Invalid JWT token format")
    
    def _b64_decode(data):
        rem = len(data) % 4
        if rem > 0:
            data += "=" * (4 - rem)
        return base64.urlsafe_b64decode(data.encode("utf-8"))
    
    header = json.loads(_b64_decode(parts[0]).decode("utf-8"))
    payload = json.loads(_b64_decode(parts[1]).decode("utf-8"))
    return header, payload


def extract_token_from_event(event: dict) -> str:
    headers = event.get("headers") or {}
    auth_header = headers.get("Authorization") or headers.get("authorization") or ""
    if auth_header.startswith("Bearer "):
        return auth_header[7:].strip()
    return auth_header.strip()


def authenticate_request(event: dict) -> dict:
    """
    Extracts and authenticates caller identity from API Gateway requestContext or Authorization header.
    Returns dictionary with:
      - user_id (sub)
      - username
      - employee_id
      - role ('HR_Admin', 'Manager', or 'Employee')
      - groups (list of groups)
      - ip_address
      - user_agent
    """
    request_context = event.get("requestContext") or {}
    identity = request_context.get("identity") or {}
    ip_address = identity.get("sourceIp") or "0.0.0.0"
    user_agent = identity.get("userAgent") or "Unknown"

    # 1. First check if API Gateway Cognito Authorizer has populated claims
    authorizer = request_context.get("authorizer") or {}
    claims = authorizer.get("claims")

    # 2. If claims not present in authorizer context, parse token from header
    if not claims:
        token = extract_token_from_event(event)
        if token:
            try:
                _, payload = parse_jwt_unverified(token)
                claims = payload
            except Exception as e:
                print(f"Token parsing error: {e}")
                claims = {}
        else:
            claims = {}

    if not claims:
        # Unauthenticated request
        return {
            "authenticated": False,
            "user_id": "anonymous",
            "username": "anonymous",
            "employee_id": None,
            "role": "Unknown",
            "groups": [],
            "ip_address": ip_address,
            "user_agent": user_agent,
        }

    # Verify expiration if present in payload
    exp = claims.get("exp")
    if exp:
        try:
            if time.time() > float(exp):
                return {
                    "authenticated": False,
                    "user_id": claims.get("sub", "expired"),
                    "username": claims.get("cognito:username", "expired"),
                    "employee_id": None,
                    "role": "Unknown",
                    "groups": [],
                    "ip_address": ip_address,
                    "user_agent": user_agent,
                    "error": "Token expired"
                }
        except (ValueError, TypeError):
            # API Gateway Cognito Authorizer converts exp to formatted date string
            pass

    user_id = claims.get("sub") or claims.get("username") or "unknown"
    username = claims.get("cognito:username") or claims.get("username") or user_id

    # Groups can be a list or comma-delimited string
    raw_groups = claims.get("cognito:groups") or []
    if isinstance(raw_groups, str):
        groups = [g.strip() for g in raw_groups.split(",") if g.strip()]
    elif isinstance(raw_groups, list):
        groups = raw_groups
    else:
        groups = []

    # Determine highest role
    if "HR_Admin" in groups:
        role = "HR_Admin"
    elif "Manager" in groups:
        role = "Manager"
    elif "Employee" in groups:
        role = "Employee"
    else:
        role = claims.get("custom:role", "Employee")

    # Determine employee_id:
    employee_id = claims.get("custom:employee_id")
    if not employee_id:
        if username.startswith("EMP") or username.startswith("MGR") or username.startswith("HR"):
            employee_id = username
        else:
            employee_id = lookup_employee_id_by_username(username)

    return {
        "authenticated": True,
        "user_id": user_id,
        "username": username,
        "employee_id": employee_id,
        "role": role,
        "groups": groups,
        "ip_address": ip_address,
        "user_agent": user_agent,
    }


def lookup_employee_id_by_username(username: str) -> str:
    """Helper to map a Cognito username to an employee_id from employee_directory"""
    if not username:
        return None
    try:
        table = dynamodb.Table(EMPLOYEE_TABLE_NAME)
        resp = table.get_item(Key={"employee_id": username})
        if "Item" in resp:
            return resp["Item"]["employee_id"]
        
        scan_resp = table.scan(
            FilterExpression="attribute_exists(employee_id) AND (username = :u OR email = :u)",
            ExpressionAttributeValues={":u": username},
            Limit=1
        )
        items = scan_resp.get("Items", [])
        if items:
            return items[0]["employee_id"]
    except Exception as e:
        print(f"Error querying employee directory for {username}: {e}")
    return username


def get_direct_reports(manager_id: str) -> list:
    """
    Retrieves all direct report employee IDs for a given manager_id from employee_directory.
    Uses ManagerIndex GSI if available, or scans table.
    """
    if not manager_id:
        return []
    try:
        table = dynamodb.Table(EMPLOYEE_TABLE_NAME)
        try:
            resp = table.query(
                IndexName="ManagerIndex",
                KeyConditionExpression="manager_id = :m",
                ExpressionAttributeValues={":m": manager_id}
            )
            items = resp.get("Items", [])
            return [item["employee_id"] for item in items if "employee_id" in item]
        except ClientError:
            scan_resp = table.scan(
                FilterExpression="manager_id = :m",
                ExpressionAttributeValues={":m": manager_id}
            )
            items = scan_resp.get("Items", [])
            return [item["employee_id"] for item in items if "employee_id" in item]
    except Exception as e:
        print(f"Error getting direct reports for {manager_id}: {e}")
        return []


def authorize_document_access(caller: dict, target_employee_id: str, action: str = "READ") -> tuple:
    """
    Enforces authorization rules:
      - HR_Admin: Full access to any employee record.
      - Manager: Access to own records and direct reports only.
      - Employee: Access strictly restricted to own employee_id.
    
    Returns: (is_authorized: bool, reason: str)
    """
    if not caller.get("authenticated"):
        return False, "Unauthenticated caller"

    role = caller.get("role")
    caller_emp_id = caller.get("employee_id")

    # 1. HR_Admin has universal access
    if role == "HR_Admin" or "HR_Admin" in caller.get("groups", []):
        return True, "Authorized by HR_Admin role"

    # 2. Caller accessing their own documents
    if caller_emp_id and caller_emp_id == target_employee_id:
        return True, "Authorized access to self documents"

    # 3. Manager accessing direct reports
    if role == "Manager" or "Manager" in caller.get("groups", []):
        direct_reports = get_direct_reports(caller_emp_id)
        if target_employee_id in direct_reports:
            return True, f"Authorized access to direct report {target_employee_id}"
        else:
            return False, f"Manager {caller_emp_id} is not authorized to access documents for employee {target_employee_id}"

    # 4. Standard employee attempting access to someone else's document
    return False, f"Employee {caller_emp_id} cannot access records belonging to employee {target_employee_id}"


def write_audit_log(
    caller: dict,
    action: str,
    target_employee_id: str,
    document_id: str = None,
    s3_key: str = None,
    result: str = "SUCCESS",
    details: str = None
):
    """
    Writes an immutable audit entry to DynamoDB audit_log table.
    Actions include: UPLOAD_REQUEST, UPLOAD_COMPLETE, DOWNLOAD, LIST, DELETE, VERSION_HISTORY, ACCESS_DENIED
    """
    try:
        table = dynamodb.Table(AUDIT_TABLE_NAME)
        audit_id = f"AUDIT-{uuid.uuid4().hex[:12].upper()}"
        timestamp = datetime.datetime.now(datetime.timezone.utc).isoformat()
        
        item = {
            "audit_id": audit_id,
            "timestamp": timestamp,
            "user_id": caller.get("user_id", "unknown"),
            "employee_id": target_employee_id or caller.get("employee_id", "none"),
            "caller_employee_id": caller.get("employee_id", "none"),
            "role": caller.get("role", "Unknown"),
            "action": action,
            "document_id": document_id or "N/A",
            "s3_key": s3_key or "N/A",
            "result": result,
            "ip_address": caller.get("ip_address", "0.0.0.0"),
            "user_agent": caller.get("user_agent", "Unknown"),
            "details": details or ""
        }
        
        table.put_item(Item=item)
        return audit_id
    except Exception as e:
        print(f"CRITICAL: Failed to write audit log: {e}")
        return None


def make_response(status_code: int, body: dict) -> dict:
    """Generates standardized API Gateway JSON response with CORS headers."""
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Headers": "Content-Type,Authorization,X-Amz-Date,X-Api-Key,X-Amz-Security-Token",
            "Access-Control-Allow-Methods": "GET,POST,DELETE,OPTIONS"
        },
        "body": json.dumps(body)
    }


def log_event(
    request_id: str,
    operation: str,
    caller: dict = None,
    status: str = "SUCCESS",
    resource: str = None,
    duration_ms: float = None,
    error_type: str = None,
    error_message: str = None,
    extra: dict = None
):
    """
    Emits structured JSON log to stdout for CloudWatch Logs with strict PII/token redaction.
    """
    log_entry = {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "requestId": request_id or "unknown",
        "userId": caller.get("user_id", "anonymous") if caller else "anonymous",
        "employeeId": caller.get("employee_id", "none") if caller else "none",
        "role": caller.get("role", "Unknown") if caller else "Unknown",
        "operation": operation,
        "resource": resource or "none",
        "status": status,
        "duration_ms": round(duration_ms, 2) if duration_ms is not None else None,
        "error_type": error_type,
        "error_message": error_message,
        "sourceIp": caller.get("ip_address", "0.0.0.0") if caller else "0.0.0.0"
    }
    if extra:
        safe_extra = {}
        for k, v in extra.items():
            k_lower = k.lower()
            if any(term in k_lower for term in ["token", "password", "secret", "url", "key"]):
                safe_extra[k] = "[REDACTED]"
            else:
                safe_extra[k] = v
        log_entry["extra"] = safe_extra

    print(json.dumps(log_entry))

