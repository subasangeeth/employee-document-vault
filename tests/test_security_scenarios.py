"""
Comprehensive 7 Security Test Scenarios Runner
Tests real API Gateway endpoints, Cognito authorizer, S3 pre-signed URLs, and S3 bucket security.
Outputs complete raw request/response details for security audit reports.
"""
import os
import sys
import time
import json
import urllib.request
import urllib.parse
import urllib.error
import boto3
from botocore.config import Config

# Read environment from .env
env_path = os.path.join(os.path.dirname(__file__), "..", ".env")
env_vars = {}
if os.path.exists(env_path):
    with open(env_path, "r") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env_vars[k.strip()] = v.strip()

REGION = os.environ.get("AWS_REGION") or env_vars.get("AWS_REGION") or "us-east-2"
API_URL = os.environ.get("API_GATEWAY_URL") or env_vars.get("API_GATEWAY_URL")
USER_POOL_ID = os.environ.get("COGNITO_USER_POOL_ID") or env_vars.get("COGNITO_USER_POOL_ID")
CLIENT_ID = os.environ.get("COGNITO_CLIENT_ID") or env_vars.get("COGNITO_CLIENT_ID")
DOC_BUCKET = os.environ.get("S3_BUCKET") or env_vars.get("S3_BUCKET")

cognito_client = boto3.client("cognito-idp", region_name=REGION)
dynamodb = boto3.resource("dynamodb", region_name=REGION)
s3_client = boto3.client(
    "s3",
    region_name=REGION,
    endpoint_url=f"https://s3.{REGION}.amazonaws.com",
    config=Config(signature_version="s3v4")
)

DEFAULT_PASSWORD = "TempPass123!"


def get_jwt(username):
    resp = cognito_client.initiate_auth(
        AuthFlow="USER_PASSWORD_AUTH",
        ClientId=CLIENT_ID,
        AuthParameters={"USERNAME": username, "PASSWORD": DEFAULT_PASSWORD}
    )
    return resp["AuthenticationResult"]["IdToken"]


def http_call(method, url, headers=None, body=None):
    headers = headers or {}
    data = json.dumps(body).encode("utf-8") if body else None
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    start = time.time()
    try:
        with urllib.request.urlopen(req) as resp:
            content = resp.read().decode("utf-8")
            latency = (time.time() - start) * 1000
            try:
                parsed = json.loads(content)
            except Exception:
                parsed = content
            return resp.status, parsed, latency, dict(resp.headers)
    except urllib.error.HTTPError as he:
        latency = (time.time() - start) * 1000
        content = he.read().decode("utf-8")
        try:
            parsed = json.loads(content)
        except Exception:
            parsed = content
        return he.code, parsed, latency, dict(he.headers)
    except Exception as e:
        latency = (time.time() - start) * 1000
        return 500, {"error": str(e)}, latency, {}


def main():
    print("Fetching documents and credentials...")
    t_emp001 = get_jwt("EMP001")
    t_mgr001 = get_jwt("MGR001")
    t_hr001 = get_jwt("HR001")

    meta_table = dynamodb.Table("document_metadata")
    items = meta_table.scan().get("Items", [])

    emp001_doc = next(i for i in items if i.get("employee_id") == "EMP001" and not i.get("deleted"))
    emp002_doc = next(i for i in items if i.get("employee_id") == "EMP002" and not i.get("deleted"))
    emp999_doc = next(i for i in items if i.get("employee_id") == "EMP999" and not i.get("deleted"))

    results = []

    # Scenario 1: Cross-user isolation
    print("\n--- Scenario 1: Cross-User Isolation (EMP001 -> EMP002 document) ---")
    url = f"{API_URL}/download/{emp002_doc['document_id']}"
    status, body, latency, _ = http_call("GET", url, headers={"Authorization": f"Bearer {t_emp001}"})
    print(f"Status: {status} (Expected: 403), Latency: {latency:.2f}ms")
    print(f"Body: {body}")
    results.append({
        "scenario": 1,
        "name": "Cross-user isolation: Employee A accesses Employee B's document",
        "expected": 403,
        "got": status,
        "latency_ms": latency,
        "passed": status == 403,
        "details": body
    })

    # Scenario 2: Manager boundary isolation
    print("\n--- Scenario 2: Manager Boundary (MGR001 -> EMP999 document) ---")
    url = f"{API_URL}/download/{emp999_doc['document_id']}"
    status, body, latency, _ = http_call("GET", url, headers={"Authorization": f"Bearer {t_mgr001}"})
    print(f"Status: {status} (Expected: 403), Latency: {latency:.2f}ms")
    print(f"Body: {body}")
    results.append({
        "scenario": 2,
        "name": "Manager boundary: Manager accesses non-reporting employee document",
        "expected": 403,
        "got": status,
        "latency_ms": latency,
        "passed": status == 403,
        "details": body
    })

    # Scenario 3: Employee attempts to list another employee's files
    print("\n--- Scenario 3: Unauthorized Document Listing (EMP001 lists EMP002) ---")
    url = f"{API_URL}/files?employee_id=EMP002"
    status, body, latency, _ = http_call("GET", url, headers={"Authorization": f"Bearer {t_emp001}"})
    print(f"Status: {status} (Expected: 403), Latency: {latency:.2f}ms")
    print(f"Body: {body}")
    results.append({
        "scenario": 3,
        "name": "Role boundary: Employee attempts to list documents of another employee",
        "expected": 403,
        "got": status,
        "latency_ms": latency,
        "passed": status == 403,
        "details": body
    })

    # Scenario 4: Tampered JWT token
    print("\n--- Scenario 4: Tampered JWT Token Rejected by API Gateway Authorizer ---")
    parts = t_emp001.split(".")
    # Tamper payload by replacing signature
    tampered_token = f"{parts[0]}.{parts[1]}.INVALID_SIGNATURE_TAMPERED"
    url = f"{API_URL}/download/{emp001_doc['document_id']}"
    status, body, latency, _ = http_call("GET", url, headers={"Authorization": f"Bearer {tampered_token}"})
    print(f"Status: {status} (Expected: 401 or 403), Latency: {latency:.2f}ms")
    print(f"Body: {body}")
    tampered_pass = (status in [401, 403] and ("Access Denied" in str(body) or "Unauthorized" in str(body)))
    results.append({
        "scenario": 4,
        "name": "Tampered JWT signature rejected at API Gateway authorizer layer",
        "expected": "401/403",
        "got": status,
        "latency_ms": latency,
        "passed": tampered_pass,
        "details": body
    })

    # Scenario 5: Direct S3 access without pre-signed URL
    print("\n--- Scenario 5: Direct Unauthenticated S3 Access Rejected ---")
    s3_raw_url = f"https://{DOC_BUCKET}.s3.{REGION}.amazonaws.com/{emp001_doc['s3_key']}"
    status, body, latency, _ = http_call("GET", s3_raw_url)
    print(f"Status: {status} (Expected: 403), Latency: {latency:.2f}ms")
    print(f"Body: {body}")
    results.append({
        "scenario": 5,
        "name": "Direct S3 access without pre-signed URL rejected by S3 bucket policy",
        "expected": 403,
        "got": status,
        "latency_ms": latency,
        "passed": status == 403,
        "details": body
    })

    # Scenario 6: Expired Pre-signed URL rejected
    print("\n--- Scenario 6: Expired Pre-Signed URL Rejected by S3 ---")
    # Generate an intentionally short pre-signed URL with 1-second expiry
    short_url = s3_client.generate_presigned_url(
        ClientMethod="get_object",
        Params={"Bucket": DOC_BUCKET, "Key": emp001_doc["s3_key"]},
        ExpiresIn=1
    )
    print("Generated 1-second pre-signed URL. Waiting 3 seconds for expiration...")
    time.sleep(3)
    status, body, latency, _ = http_call("GET", short_url)
    print(f"Status: {status} (Expected: 403), Latency: {latency:.2f}ms")
    print(f"Body: {body}")
    expired_pass = (status == 403 and "Request has expired" in str(body))
    results.append({
        "scenario": 6,
        "name": "Expired pre-signed URL rejected by Amazon S3 storage layer",
        "expected": 403,
        "got": status,
        "latency_ms": latency,
        "passed": expired_pass,
        "details": str(body)
    })

    # Scenario 7: Soft Delete Immutability (Physical S3 object retained)
    print("\n--- Scenario 7: Soft-Delete Immutability & Retention Verification ---")
    # Verify a soft-deleted item
    deleted_item = next((i for i in items if i.get("deleted")), None)
    if not deleted_item:
        # Perform soft delete on EMP001 test document or EMP003
        del_item_doc = emp002_doc
    else:
        del_item_doc = deleted_item

    # Verify physical S3 object existence
    try:
        head_resp = s3_client.head_object(Bucket=DOC_BUCKET, Key=del_item_doc["s3_key"])
        s3_exists = True
        s3_version_id = head_resp.get("VersionId", "N/A")
    except Exception as e:
        s3_exists = False
        s3_version_id = None

    # Now verify that attempting GET on soft deleted doc via API returns 404
    url = f"{API_URL}/download/{del_item_doc['document_id']}"
    status, body, latency, _ = http_call("GET", url, headers={"Authorization": f"Bearer {t_hr001}"})
    print(f"Soft delete check - API Download Status: {status} (Expected: 404), S3 Object Exists: {s3_exists}")
    s7_pass = (status == 404 and s3_exists)
    results.append({
        "scenario": 7,
        "name": "Soft-deleted document inaccessible via API but physically retained in S3",
        "expected": 404,
        "got": status,
        "latency_ms": latency,
        "passed": s7_pass,
        "details": {"s3_physically_retained": s3_exists, "s3_version_id": s3_version_id, "api_response": body}
    })

    print("\n========================================================")
    print("              SECURITY SCENARIO TEST RESULTS            ")
    print("========================================================")
    all_pass = True
    for r in results:
        status_str = "PASS" if r["passed"] else "FAIL"
        if not r["passed"]:
            all_pass = False
        print(f"Scenario {r['scenario']}: {r['name']}")
        print(f"  Expected: {r['expected']} | Got: {r['got']} | Latency: {r['latency_ms']:.1f}ms | Result: {status_str}\n")

    # Save results as JSON
    with open("security/security-test-output.json", "w") as f:
        json.dump(results, f, indent=2)
    print("Raw results saved to security/security-test-output.json")

    return 0 if all_pass else 1


if __name__ == "__main__":
    sys.exit(main())
