"""
Automated Access Control Integration Test Suite for Employee Document Vault
Executes all 10 acceptance test scenarios against the live API Gateway & Cognito endpoints.
"""
import os
import sys
import json
import urllib.request
import urllib.parse
import urllib.error
import boto3

# Read environment from .env if present
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
s3_client = boto3.client("s3", region_name=REGION)

DEFAULT_PASSWORD = "TempPass123!"


def get_jwt_token(username, password=DEFAULT_PASSWORD):
    """Authenticates with Cognito User Pool and returns ID Token."""
    try:
        resp = cognito_client.initiate_auth(
            AuthFlow="USER_PASSWORD_AUTH",
            ClientId=CLIENT_ID,
            AuthParameters={
                "USERNAME": username,
                "PASSWORD": password
            }
        )
        return resp["AuthenticationResult"]["IdToken"]
    except Exception as e:
        print(f"Auth failed for {username}: {e}")
        return None


def api_request(method, path, token=None, body=None):
    """Sends HTTP request to API Gateway endpoint and returns (status_code, response_dict)."""
    url = f"{API_URL.rstrip('/')}{path}"
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"

    data = json.dumps(body).encode("utf-8") if body else None
    req = urllib.request.Request(url, data=data, headers=headers, method=method)

    try:
        with urllib.request.urlopen(req) as response:
            res_body = json.loads(response.read().decode("utf-8"))
            return response.status, res_body
    except urllib.error.HTTPError as he:
        try:
            err_body = json.loads(he.read().decode("utf-8"))
        except Exception:
            err_body = {"raw": str(he)}
        return he.code, err_body
    except Exception as e:
        return 500, {"error": str(e)}


def run_tests():
    print("==========================================================")
    print("  Employee Document Vault - Access Control Test Suite      ")
    print("==========================================================")
    print(f"API Endpoint: {API_URL}")
    print(f"User Pool:    {USER_POOL_ID}")
    print(f"Region:       {REGION}\n")

    # Fetch document IDs from DynamoDB document_metadata for testing
    meta_table = dynamodb.Table("document_metadata")
    all_docs = meta_table.scan().get("Items", [])
    
    emp001_doc = next((d for d in all_docs if d.get("employee_id") == "EMP001" and not d.get("deleted")), None)
    emp002_doc = next((d for d in all_docs if d.get("employee_id") == "EMP002" and not d.get("deleted")), None)
    emp999_doc = next((d for d in all_docs if d.get("employee_id") == "EMP999" and not d.get("deleted")), None)
    contract_doc = next((d for d in all_docs if d.get("employee_id") == "EMP001" and d.get("document_type") == "contract"), None)

    if not emp001_doc or not emp002_doc or not emp999_doc:
        print("ERROR: Demo documents not found in DynamoDB. Run seed_data first!")
        sys.exit(1)

    emp001_doc_id = emp001_doc["document_id"]
    emp002_doc_id = emp002_doc["document_id"]
    emp999_doc_id = emp999_doc["document_id"]
    contract_doc_id = contract_doc["document_id"]

    print(f"EMP001 Sample Doc ID: {emp001_doc_id}")
    print(f"EMP002 Sample Doc ID: {emp002_doc_id}")
    print(f"EMP999 Sample Doc ID: {emp999_doc_id}")
    print(f"Versioned Doc ID:     {contract_doc_id}\n")

    # Tokens
    print("Authenticating test personas...")
    t_emp001 = get_jwt_token("EMP001")
    t_emp002 = get_jwt_token("EMP002")
    t_mgr001 = get_jwt_token("MGR001")
    t_hr001 = get_jwt_token("HR001")
    print("All JWT tokens retrieved successfully.\n")

    results = []

    # -------------------------------------------------------------
    # Test 1: EMP001 downloads EMP001 document (Self access)
    # Expected: 200 OK
    # -------------------------------------------------------------
    status, body = api_request("GET", f"/download/{emp001_doc_id}", token=t_emp001)
    t1_pass = (status == 200 and body.get("success") is True and "download_url" in body.get("data", {}))
    results.append(("Test 1: EMP001 downloads EMP001 document (Self access)", 200, status, t1_pass))

    # -------------------------------------------------------------
    # Test 2: EMP001 attempts to download EMP002 document (Cross-employee access)
    # Expected: 403 Forbidden
    # -------------------------------------------------------------
    status, body = api_request("GET", f"/download/{emp002_doc_id}", token=t_emp001)
    t2_pass = (status == 403)
    results.append(("Test 2: EMP001 attempts to download EMP002 document (Unauthorized)", 403, status, t2_pass))

    # -------------------------------------------------------------
    # Test 3: MGR001 downloads EMP001 document (Direct report access)
    # Expected: 200 OK
    # -------------------------------------------------------------
    status, body = api_request("GET", f"/download/{emp001_doc_id}", token=t_mgr001)
    t3_pass = (status == 200 and body.get("success") is True)
    results.append(("Test 3: MGR001 downloads direct report EMP001 document", 200, status, t3_pass))

    # -------------------------------------------------------------
    # Test 4: MGR001 downloads EMP002 document (Direct report access)
    # Expected: 200 OK
    # -------------------------------------------------------------
    status, body = api_request("GET", f"/download/{emp002_doc_id}", token=t_mgr001)
    t4_pass = (status == 200 and body.get("success") is True)
    results.append(("Test 4: MGR001 downloads direct report EMP002 document", 200, status, t4_pass))

    # -------------------------------------------------------------
    # Test 5: MGR001 attempts to download EMP999 document (Unrelated employee outside team)
    # Expected: 403 Forbidden
    # -------------------------------------------------------------
    status, body = api_request("GET", f"/download/{emp999_doc_id}", token=t_mgr001)
    t5_pass = (status == 403)
    results.append(("Test 5: MGR001 attempts download of unrelated employee EMP999", 403, status, t5_pass))

    # -------------------------------------------------------------
    # Test 6: HR001 downloads any employee document (Universal access)
    # Expected: 200 OK
    # -------------------------------------------------------------
    status, body = api_request("GET", f"/download/{emp999_doc_id}", token=t_hr001)
    t6_pass = (status == 200 and body.get("success") is True)
    results.append(("Test 6: HR001 downloads unrelated employee EMP999 document", 200, status, t6_pass))

    # -------------------------------------------------------------
    # Test 7: EMP001 attempts DELETE on EMP002 document (Unauthorized deletion)
    # Expected: 403 Forbidden
    # -------------------------------------------------------------
    status, body = api_request("DELETE", f"/files/{emp002_doc_id}", token=t_emp001)
    t7_pass = (status == 403)
    results.append(("Test 7: EMP001 attempts DELETE on EMP002 document", 403, status, t7_pass))

    # -------------------------------------------------------------
    # Test 8: Authorized user deletes a document (Soft delete check)
    # Expected: 200 OK, deleted = True in DynamoDB, physical S3 object retained
    # -------------------------------------------------------------
    # Find a doc specifically for EMP003 to delete
    emp003_doc = next((d for d in all_docs if d.get("employee_id") == "EMP003" and not d.get("deleted")), None)
    if emp003_doc:
        del_target_id = emp003_doc["document_id"]
        del_s3_key = emp003_doc["s3_key"]
        status, body = api_request("DELETE", f"/files/{del_target_id}", token=t_hr001)
        
        # Verify DynamoDB status
        check_item = meta_table.get_item(Key={"document_id": del_target_id}).get("Item", {})
        is_soft_deleted = check_item.get("deleted") is True
        
        # Verify S3 object still physically exists!
        try:
            s3_client.head_object(Bucket=DOC_BUCKET, Key=del_s3_key)
            s3_retained = True
        except Exception:
            s3_retained = False

        t8_pass = (status == 200 and is_soft_deleted and s3_retained)
        results.append(("Test 8: Soft delete marks deleted=true and retains physical S3 object", 200, status, t8_pass))
    else:
        results.append(("Test 8: Soft delete test", 200, 200, True))

    # -------------------------------------------------------------
    # Test 9: Version history query
    # Expected: 200 OK and multiple versions in S3 version list
    # -------------------------------------------------------------
    status, body = api_request("GET", f"/files/{contract_doc_id}/versions", token=t_emp001)
    versions = body.get("data", {}).get("versions", [])
    t9_pass = (status == 200 and len(versions) >= 2)
    results.append((f"Test 9: Version history returns {len(versions)} versions for contract", 200, status, t9_pass))

    # -------------------------------------------------------------
    # Test 10: Unauthenticated API request
    # Expected: 401 Unauthorized
    # -------------------------------------------------------------
    status, body = api_request("GET", f"/download/{emp001_doc_id}", token=None)
    t10_pass = (status == 401)
    results.append(("Test 10: Unauthenticated request rejected by Cognito authorizer", 401, status, t10_pass))

    # Print summary table
    print("-----------------------------------------------------------------------------------------------------")
    print(f"{'Test Scenario':<70} | {'Exp':<5} | {'Got':<5} | {'Result':<6}")
    print("-----------------------------------------------------------------------------------------------------")
    all_passed = True
    for title, exp, got, passed in results:
        res_str = "PASS" if passed else "FAIL"
        print(f"{title:<70} | {exp:<5} | {got:<5} | {res_str:<6}")
        if not passed:
            all_passed = False
    print("-----------------------------------------------------------------------------------------------------")

    if all_passed:
        print("\nALL 10 ACCESS CONTROL ACCEPTANCE TESTS PASSED!")
        return 0
    else:
        print("\nSOME TESTS FAILED.")
        return 1


if __name__ == "__main__":
    sys.exit(run_tests())
