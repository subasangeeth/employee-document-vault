# Comprehensive Cost Estimation & Sizing Model

## 1. Executive Summary

This cost model provides a detailed, service-by-service monthly expense projection for the **Secure Employee Document Vault** across three realistic enterprise workload profiles:

1. **Scenario A (Small Team)**: 10 users/day, 50 documents/day, ~100 requests/day, 1 GB storage.
2. **Scenario B (Medium Organization)**: 500 users/day, 2,500 documents/day, ~10,000 requests/day, 50 GB storage.
3. **Scenario C (Large Enterprise)**: 5,000 users/day, 25,000 documents/day, ~150,000 requests/day, 500 GB storage.

All pricing reflects current AWS Region **US East (Ohio) `us-east-2`** public pricing without upfront commitments or Enterprise Discount Programs (EDP).

---

## 2. Monthly Cost Summary Matrix

| Service | Small Profile (10 users/day) | Medium Profile (500 users/day) | Large Profile (5,000 users/day) |
|---|---|---|---|
| **Amazon API Gateway** | $0.01 | $1.05 | $15.75 |
| **AWS Lambda** | $0.00 | $0.15 | $2.32 |
| **Amazon DynamoDB** | $0.01 | $0.45 | $6.75 |
| **Amazon S3** | $0.03 | $1.25 | $12.50 |
| **AWS KMS** | $1.00 | $1.00 | $1.45 |
| **Amazon Cognito** | $0.00 | $0.00 | $0.00 |
| **Amazon CloudWatch** | $3.30 | $4.75 | $25.95 |
| **Data Transfer Out** | $0.00 | $0.00 | $9.00 |
| **TOTAL MONTHLY COST** | **$4.35 / mo** | **$8.65 / mo** | **$73.72 / mo** |
| **Annualized Cost** | **$52.20 / yr** | **$103.80 / yr** | **$884.64 / yr** |
| **Cost per Active User / Mo** | **$0.435** | **$0.017** | **$0.015** |

---

## 3. Service-by-Service Breakdown & Pricing Formulas

### 3.1 Amazon API Gateway (REST API)
* **Pricing Formula**: $\text{Monthly Cost} = \left(\frac{\text{Requests}}{1,000,000}\right) \times \$3.50$
* **Small**: $3,000 \text{ req} / 1M \times \$3.50 = \$0.01$
* **Medium**: $300,000 \text{ req} / 1M \times \$3.50 = \$1.05$
* **Large**: $4,500,000 \text{ req} / 1M \times \$3.50 = \$15.75$

### 3.2 AWS Lambda Compute
* **Assumptions**: 256MB allocated memory, average execution duration 75ms.
* **GB-Seconds Formula**: $\text{Duration (s)} \times \left(\frac{\text{Allocated MB}}{1024}\right) \times \text{Invocations} \times \$0.0000166667 + (\text{Invocations} \times \$0.20 / 1M)$
* **Small**: Covered by AWS Lambda Free Tier (1M requests and 400,000 GB-seconds per month free).
* **Medium**: $300,000 \times 0.075 \times 0.25 = 5,625 \text{ GB-s} \times \$0.0000166667 + \$0.06 = \$0.15$
* **Large**: $4,500,000 \times 0.075 \times 0.25 = 84,375 \text{ GB-s} \times \$0.0000166667 + \$0.90 = \$2.32$

### 3.3 Amazon DynamoDB (On-Demand)
* **Pricing**: $1.25 per million Write Request Units (WRU), $0.25 per million Read Request Units (RRU). Storage: $0.25/GB-month (first 25 GB free).
* **Small**: ~$0.01
* **Medium**: 300,000 reads ($0.08) + 300,000 writes ($0.38) = $0.45
* **Large**: 4.5M reads ($1.13) + 4.5M writes ($5.62) = $6.75

### 3.4 Amazon S3 Vault Storage & API Operations
* **Assumptions**: Average document size = 500 KB. S3 Standard: $0.023/GB-month. 90-day transition to Standard-IA: $0.0125/GB-month.
* **Small (1 GB)**: $0.03
* **Medium (50 GB)**: $1.15 storage + $0.10 operations = $1.25
* **Large (500 GB)**: $11.50 storage + $1.00 operations = $12.50

### 3.5 AWS KMS (Customer Managed Key)
* **Pricing**: $1.00/month flat fee per key. $0.03 per 10,000 cryptographic requests (first 20,000 requests/month free).
* **Small**: $1.00 (under 20K requests free tier)
* **Medium**: $1.00 (under 20K requests free tier)
* **Large**: $1.00 base + 150K crypto requests ($0.45) = $1.45

### 3.6 Amazon Cognito
* **Pricing**: First 50,000 Monthly Active Users (MAUs) are **100% free**.
* **Small (10 MAU)**: $0.00
* **Medium (500 MAU)**: $0.00
* **Large (5,000 MAU)**: $0.00

### 3.7 Amazon CloudWatch (Monitoring & Hardening)
* **Fixed Costs**: 1 Unified Dashboard (`SecureEmployeeVault-Production`) = $3.00/month; 2 Metric Alarms (`HighErrorRate`, `HighP95Latency`) = $0.20/month. Total fixed = $3.20/month.
* **Log Ingestion & Storage**: $0.50/GB ingested, $0.03/GB-month stored (with 14-day retention).
  * Small: ~$0.10 logs -> Total = $3.30
  * Medium: ~3 GB logs ($1.55) -> Total = $4.75
  * Large: ~45 GB logs ($22.75) -> Total = $25.95

### 3.8 Data Transfer Out
* **Pricing**: First 100 GB/month egress to Internet is free; $0.09/GB thereafter.
* **Small & Medium**: Well within 100 GB free tier = $0.00.
* **Large (~200 GB egress)**: 100 GB billable @ $0.09/GB = $9.00.

---

## 4. Architectural Cost Drivers & Elastic Scaling Insights

1. **Sub-Linear Cost Scaling**:
   Because compute, database, and auth are entirely serverless, the cost per active user drops drastically from **$0.435/user/month** at small scale down to **$0.015/user/month** at enterprise scale.
2. **KMS & CloudWatch Fixed Base**:
   At low volume (<50 users), CloudWatch dashboards and KMS key flat fees represent over 90% of total spend ($4.20 out of $4.35). As traffic scales, these fixed costs become negligible.
3. **Log Retention Safeguard**:
   Without the 14-day retention rule established in Phase 9, CloudWatch log storage would compound indefinitely, growing by ~$0.45/month every single month at large scale. The 14-day cap keeps monthly log storage strictly bounded.
