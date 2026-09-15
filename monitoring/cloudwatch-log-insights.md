# CloudWatch Logs Insights Operational Queries

This operational query catalog provides security, performance, and reliability monitoring for the Secure Employee Document Vault. These queries run directly in AWS CloudWatch Logs Insights against the 5 Lambda microservice log groups:
* `/aws/lambda/EmployeeVaultUpload`
* `/aws/lambda/EmployeeVaultDownload`
* `/aws/lambda/EmployeeVaultList`
* `/aws/lambda/EmployeeVaultDelete`
* `/aws/lambda/EmployeeVaultVersion`

---

## 1. Error Rate: 4xx and 5xx Errors by Endpoint Over Time

Tracks operational errors, authentication failures, and access denials grouped by 5-minute bins.

```sql
fields @timestamp, operation, status, error_type, error_message, employeeId
| filter status = "DENIED" or status = "ERROR" or ispresent(error_type)
| stats count(*) as error_count by operation, error_type, bin(5m)
| sort error_count desc
```

**Alternative using Lambda platform logs:**
```sql
fields @timestamp, @logStream, @message
| filter @message like /(?i)(ERROR|Exception|Traceback|AccessDeniedException)/
| stats count(*) as unhandled_exceptions by bin(5m)
| sort unhandled_exceptions desc
```

---

## 2. Latency Analysis: P50, P90, P99 Percentiles per Operation

Calculates exact execution latency distributions across all microservices using the structured `duration_ms` metric.

```sql
fields @timestamp, operation, duration_ms
| filter ispresent(duration_ms) and duration_ms > 0
| stats 
    count(*) as invocation_count,
    pct(duration_ms, 50) as p50_duration_ms,
    pct(duration_ms, 90) as p90_duration_ms,
    pct(duration_ms, 95) as p95_duration_ms,
    pct(duration_ms, 99) as p99_duration_ms,
    max(duration_ms) as max_duration_ms
  by operation
| sort invocation_count desc
```

**Using CloudWatch Lambda REPORT logs:**
```sql
filter @type = "REPORT"
| stats 
    count(*) as invocations,
    pct(@duration, 50) as p50_duration,
    pct(@duration, 90) as p90_duration,
    pct(@duration, 99) as p99_duration,
    max(@maxMemoryUsed / 1000000) as max_mem_mb
  by @log
```

---

## 3. Access Denied & RBAC Violation Events

Detects privilege escalation attempts, horizontal traversal (employees accessing peers), or unauthorized manager attempts.

```sql
fields @timestamp, employeeId, role, operation, resource, error_type, error_message, sourceIp
| filter status = "DENIED" or error_type = "ACCESS_DENIED"
| stats count(*) as denial_count by employeeId, role, operation, resource, sourceIp
| sort denial_count desc
```

---

## 4. Top Active Users & Workload Distribution

Identifies heavy callers by user identity, employee ID, and assigned RBAC role.

```sql
fields @timestamp, employeeId, role, operation, status
| filter ispresent(employeeId)
| stats 
    count(*) as total_requests,
    count_distinct(operation) as distinct_operations,
    sum(status = "SUCCESS") as successful_requests,
    sum(status = "DENIED") as denied_requests
  by employeeId, role
| sort total_requests desc
| limit 20
```

---

## 5. High-Risk / Destructive Actions Audit

Tracks sensitive soft-deletion operations and bulk listing/download activities.

```sql
fields @timestamp, employeeId, role, operation, resource, extra.target_employee_id, extra.s3_key, sourceIp
| filter operation = "DELETE" or operation = "DOWNLOAD"
| stats count(*) as action_count by operation, employeeId, role, resource, sourceIp
| sort action_count desc
```

---

## 6. Cold Start Detection & Initialization Overhead

Tracks frequency and latency impact of Lambda cold starts using CloudWatch Lambda platform events.

```sql
filter @type = "REPORT"
| fields @timestamp, @log, @duration, @initDuration, @memorySize, @maxMemoryUsed
| filter ispresent(@initDuration)
| stats 
    count(*) as cold_start_count,
    avg(@initDuration) as avg_init_ms,
    max(@initDuration) as max_init_ms,
    pct(@initDuration, 95) as p95_init_ms
  by @log
| sort cold_start_count desc
```
