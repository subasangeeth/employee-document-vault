"""
Seed Data Script: Populates employee_directory and uploads demo documents to S3 and DynamoDB.
"""
import os
import datetime
import boto3
from botocore.config import Config

# Read environment variables
env_file = os.path.join(os.path.dirname(__file__), "..", ".env")
env_vars = {}
if os.path.exists(env_file):
    with open(env_file, "r") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env_vars[k.strip()] = v.strip()

REGION = os.environ.get("AWS_REGION") or env_vars.get("AWS_REGION") or "us-east-2"
ACCOUNT_ID = os.environ.get("AWS_ACCOUNT_ID") or env_vars.get("AWS_ACCOUNT_ID")
DOC_BUCKET = os.environ.get("S3_BUCKET") or env_vars.get("S3_BUCKET") or f"employee-document-vault-{ACCOUNT_ID}-{REGION}"
DOC_TABLE = os.environ.get("DOCUMENT_TABLE") or env_vars.get("DOCUMENT_TABLE") or "document_metadata"
EMPLOYEE_TABLE = os.environ.get("EMPLOYEE_TABLE") or env_vars.get("EMPLOYEE_TABLE") or "employee_directory"
KMS_KEY_ID = os.environ.get("KMS_KEY_ID") or env_vars.get("KMS_KEY_ID")

s3_client = boto3.client("s3", region_name=REGION)
dynamodb = boto3.resource("dynamodb", region_name=REGION)

print(f"Seeding Employee Vault in Region: {REGION}")
print(f"S3 Bucket: {DOC_BUCKET}")
print(f"Document Table: {DOC_TABLE}")
print(f"Employee Table: {EMPLOYEE_TABLE}\n")

# 1. Seed Employee Directory
employees = [
    {"employee_id": "EMP001", "name": "Alice Chen", "manager_id": "MGR001", "department": "Engineering", "email": "emp001@example.com", "role": "Employee"},
    {"employee_id": "EMP002", "name": "Bob Smith", "manager_id": "MGR001", "department": "Engineering", "email": "emp002@example.com", "role": "Employee"},
    {"employee_id": "EMP003", "name": "Charlie Davis", "manager_id": "MGR001", "department": "Engineering", "email": "emp003@example.com", "role": "Employee"},
    {"employee_id": "EMP999", "name": "Zoe Vance", "manager_id": "MGR999", "department": "Legal", "email": "emp999@example.com", "role": "Employee"},
    {"employee_id": "MGR001", "name": "Marcus Miller", "manager_id": "EXEC", "department": "Engineering", "email": "mgr001@example.com", "role": "Manager"},
    {"employee_id": "HR001", "name": "Helen Ross", "manager_id": "EXEC", "department": "Human Resources", "email": "hr001@example.com", "role": "HR_Admin"}
]

emp_table = dynamodb.Table(EMPLOYEE_TABLE)
print("Populating employee_directory...")
for emp in employees:
    emp_table.put_item(Item=emp)
    print(f"  -> Added {emp['employee_id']}: {emp['name']} ({emp['role']})")

# 2. Upload Demo Documents
demo_docs = [
    # EMP001
    {"employee_id": "EMP001", "document_type": "offer-letter", "filename": "offer-letter.pdf", "content": b"%PDF-1.4 Offer of Employment for Alice Chen - Senior Staff Engineer", "tags": ["offer", "onboarding", "2026"]},
    {"employee_id": "EMP001", "document_type": "contract", "filename": "employment-contract.pdf", "content": b"%PDF-1.4 Employment Agreement v1 for Alice Chen", "tags": ["contract", "legal", "confidential"]},
    {"employee_id": "EMP001", "document_type": "payslip", "filename": "payslip-2026-08.pdf", "content": b"%PDF-1.4 Salary Payslip August 2026 for Alice Chen - Net Pay: $12,500", "tags": ["salary", "payroll", "2026"]},
    {"employee_id": "EMP001", "document_type": "appraisal", "filename": "appraisal-2026.pdf", "content": b"%PDF-1.4 Performance Appraisal 2026: Exceeds Expectations Rating: 4.8/5.0", "tags": ["appraisal", "review"]},
    {"employee_id": "EMP001", "document_type": "compliance", "filename": "first-aid-certificate.pdf", "content": b"%PDF-1.4 Standard First Aid & CPR Level C Certificate - Valid through 2029", "tags": ["compliance", "safety"]},

    # EMP002
    {"employee_id": "EMP002", "document_type": "offer-letter", "filename": "offer-letter.pdf", "content": b"%PDF-1.4 Offer of Employment for Bob Smith - DevOps Engineer", "tags": ["offer", "onboarding"]},
    {"employee_id": "EMP002", "document_type": "contract", "filename": "employment-contract.pdf", "content": b"%PDF-1.4 Employment Contract for Bob Smith", "tags": ["contract", "legal"]},
    {"employee_id": "EMP002", "document_type": "payslip", "filename": "payslip-2026-08.pdf", "content": b"%PDF-1.4 Salary Payslip August 2026 for Bob Smith - Net Pay: $9,200", "tags": ["salary", "payroll"]},

    # EMP003
    {"employee_id": "EMP003", "document_type": "offer-letter", "filename": "offer-letter.pdf", "content": b"%PDF-1.4 Offer of Employment for Charlie Davis - Frontend Engineer", "tags": ["offer", "onboarding"]},
    {"employee_id": "EMP003", "document_type": "contract", "filename": "employment-contract.pdf", "content": b"%PDF-1.4 Employment Contract for Charlie Davis", "tags": ["contract", "legal"]},

    # EMP999 (Unrelated employee outside MGR001's reporting line)
    {"employee_id": "EMP999", "document_type": "contract", "filename": "legal-confidentiality-contract.pdf", "content": b"%PDF-1.4 Confidentiality Agreement for Zoe Vance (Legal Dept)", "tags": ["legal", "privileged"]}
]

meta_table = dynamodb.Table(DOC_TABLE)
print("\nUploading demo documents to S3 and recording metadata...")

counter = 100
versioned_doc_id = None
versioned_s3_key = None

for doc in demo_docs:
    counter += 1
    doc_id = f"DOC-{doc['employee_id']}-{counter}"
    s3_key = f"documents/{doc['employee_id']}/{doc['document_type']}/{doc['filename']}"
    timestamp = datetime.datetime.now(datetime.timezone.utc).isoformat()

    if doc["employee_id"] == "EMP001" and doc["document_type"] == "contract":
        versioned_doc_id = doc_id
        versioned_s3_key = s3_key

    # Upload to S3
    put_params = {
        "Bucket": DOC_BUCKET,
        "Key": s3_key,
        "Body": doc["content"],
        "ContentType": "application/pdf"
    }
    if KMS_KEY_ID:
        put_params["ServerSideEncryption"] = "aws:kms"
        put_params["SSEKMSKeyId"] = KMS_KEY_ID

    resp = s3_client.put_object(**put_params)
    v_id = resp.get("VersionId", "none")

    # Record in DynamoDB
    meta_item = {
        "document_id": doc_id,
        "employee_id": doc["employee_id"],
        "uploaded_by": doc["employee_id"],
        "document_type": doc["document_type"],
        "filename": doc["filename"],
        "s3_key": s3_key,
        "upload_timestamp": timestamp,
        "tags": doc["tags"],
        "current_version_id": v_id,
        "deleted": False
    }
    meta_table.put_item(Item=meta_item)
    print(f"  -> Uploaded {doc_id}: {s3_key} (Version: {v_id[:12]}...)")

# 3. Create Version 2 for EMP001 Contract
print("\nCreating Version 2 for EMP001's contract (to demonstrate S3 versioning)...")
v2_content = b"%PDF-1.4 Employment Agreement v2 (Amended Compensation & Title: Principal Architect) for Alice Chen"
v2_put_params = {
    "Bucket": DOC_BUCKET,
    "Key": versioned_s3_key,
    "Body": v2_content,
    "ContentType": "application/pdf"
}
if KMS_KEY_ID:
    v2_put_params["ServerSideEncryption"] = "aws:kms"
    v2_put_params["SSEKMSKeyId"] = KMS_KEY_ID

v2_resp = s3_client.put_object(**v2_put_params)
v2_version_id = v2_resp.get("VersionId")

# Update DynamoDB with latest version ID
meta_table.update_item(
    Key={"document_id": versioned_doc_id},
    UpdateExpression="SET current_version_id = :v",
    ExpressionAttributeValues={":v": v2_version_id}
)
print(f"  -> Created Version 2 for {versioned_doc_id}: {v2_version_id[:12]}...")

print("\nSeed data completed successfully!")
