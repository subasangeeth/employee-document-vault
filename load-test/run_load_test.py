"""
Artillery Load Test Automation Runner
Fetches fresh Cognito JWT for EMP001, injects ID_TOKEN into environment,
executes Artillery load test, generates HTML report, and outputs summary statistics.
"""
import os
import sys
import json
import subprocess
import boto3

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
CLIENT_ID = os.environ.get("COGNITO_CLIENT_ID") or env_vars.get("COGNITO_CLIENT_ID")

cognito_client = boto3.client("cognito-idp", region_name=REGION)


def get_token():
    print("Authenticating EMP001 against Cognito...")
    resp = cognito_client.initiate_auth(
        AuthFlow="USER_PASSWORD_AUTH",
        ClientId=CLIENT_ID,
        AuthParameters={"USERNAME": "EMP001", "PASSWORD": "TempPass123!"}
    )
    return resp["AuthenticationResult"]["IdToken"]


def main():
    token = get_token()
    print("Acquired JWT ID token successfully.")

    # Inject into environment for Artillery
    env = dict(os.environ)
    env["ID_TOKEN"] = token

    config_path = os.path.join("load-test", "employee-vault-load-test.yml")
    report_json = os.path.join("load-test", "artillery-report.json")
    report_html = os.path.join("load-test", "artillery-report.html")

    print(f"Launching Artillery load test ({config_path})...")
    cmd = f"npx artillery run {config_path} --output {report_json}"
    proc = subprocess.run(cmd, shell=True, env=env)

    if proc.returncode != 0:
        print(f"Artillery execution exited with code {proc.returncode}")
        return proc.returncode

    print("\nGenerating Artillery HTML visual report...")
    report_cmd = f"npx artillery report {report_json} --output {report_html}"
    subprocess.run(report_cmd, shell=True, env=env)

    # Parse and display metrics
    if os.path.exists(report_json):
        try:
            with open(report_json, "r") as f:
                data = json.load(f)
            aggregate = data.get("aggregate", {})
            counters = aggregate.get("counters", {})
            summaries = aggregate.get("summaries", {})
            http_codes = aggregate.get("rates", {})

            print("\n========================================================")
            print("             ARTILLERY LOAD TEST SUMMARY                ")
            print("========================================================")
            print(f"Virtual Users Created:    {counters.get('vusers.created', 'N/A')}")
            print(f"Virtual Users Completed:  {counters.get('vusers.completed', 'N/A')}")
            print(f"Virtual Users Failed:     {counters.get('vusers.failed', 0)}")
            print(f"Total HTTP Requests:      {counters.get('http.requests', 'N/A')}")
            print(f"HTTP 200 Responses:       {counters.get('http.codes.200', 0)}")
            print(f"HTTP 4xx Responses:       {sum(v for k, v in counters.items() if k.startswith('http.codes.4'))}")
            print(f"HTTP 5xx Responses:       {sum(v for k, v in counters.items() if k.startswith('http.codes.5'))}")

            latencies = summaries.get("http.response_time", {})
            if latencies:
                print(f"Latency Median (P50):     {latencies.get('median', 'N/A')} ms")
                print(f"Latency P95:              {latencies.get('p95', 'N/A')} ms")
                print(f"Latency P99:              {latencies.get('p99', 'N/A')} ms")
                print(f"Latency Max:              {latencies.get('max', 'N/A')} ms")
        except Exception as e:
            print(f"Error parsing report JSON: {e}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
