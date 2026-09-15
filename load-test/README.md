# Load Testing Guide: Secure Employee Document Vault

This directory contains the load testing configuration, scripts, and benchmarking framework for evaluating the scalability and latency of the Secure Employee Document Vault under sustained enterprise concurrency.

---

## 1. Test Architecture & Load Profile

The test simulates realistic employee portal usage using [Artillery.io](https://www.artillery.io):

```text
Phase 1: Warm Up      (15s @ 5 virtual users/sec)
Phase 2: Ramp Up      (20s ramping from 5 to 25 virtual users/sec)
Phase 3: Peak Load    (60s sustained @ 25 arrivals/sec, capped at 50 concurrent VUs)
Total Test Duration:  95 seconds
```

### Scenario Distribution
* **70% Weight**: Document Listing & Download Flow (`GET /files` -> Think 1s -> `GET /download/{doc_id}`).
* **30% Weight**: Document Upload Initiation Flow (`POST /upload` with metadata payload).

---

## 2. Prerequisites

1. **Node.js**: Version 18+ or 20+ installed.
2. **Artillery CLI**:
   ```bash
   npm install -g artillery
   # Or run on-demand via npx:
   npx --yes artillery -v
   ```
3. **Valid Cognito ID Token**:
   Run the helper script to authenticate as `EMP001` and export `ID_TOKEN`:
   ```powershell
   # PowerShell
   $token = python -c "from tests.test_access_control import get_jwt_token; print(get_jwt_token('EMP001'))"
   $env:ID_TOKEN = $token
   ```
   Or bash:
   ```bash
   export ID_TOKEN=$(python -c "from tests.test_access_control import get_jwt_token; print(get_jwt_token('EMP001'))")
   ```

---

## 3. Running the Load Test

Execute the test suite with JSON and HTML report output:

```powershell
# Run with live console telemetry
artillery run load-test/employee-vault-load-test.yml --output load-test/artillery-report.json

# Generate HTML report
artillery report load-test/artillery-report.json --output load-test/artillery-report.html
```

---

## 4. Performance Targets & SLA Gates

| Metric | Pass Target | SLA Failure Gate |
|---|---|---|
| **P95 Latency** | < 250ms | > 1000ms |
| **P99 Latency** | < 500ms | > 3000ms |
| **HTTP 5XX Server Errors** | 0.0% | > 1.0% |
| **HTTP 4XX (unexpected)** | 0.0% | > 2.0% |
| **Lambda Concurrency Throttles** | 0 throttles | > 0 throttles |
