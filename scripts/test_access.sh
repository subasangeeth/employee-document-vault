#!/usr/bin/env bash
# Bash wrapper to run the access control integration test suite

set -euo pipefail

echo "Running Employee Document Vault Access Control Tests..."

python tests/test_access_control.py

echo ""
echo "All 10 Access Control Scenarios Verified Successfully."
