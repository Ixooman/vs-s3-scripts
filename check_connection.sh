#!/bin/bash

# S3 Simple check connection script
# Usage: ./check_connection.sh [endpoint-url]

# Configuration
ENDPOINT_URL=${1:-"http://192.168.10.81"}
AWS_CMD="aws --no-verify-ssl"

echo "=== S3 Checking Connection ==="
echo "Endpoint: $ENDPOINT_URL"
echo "======================================"

echo "=== Bucket Listing ==="
$AWS_CMD s3api list-buckets --endpoint-url "$ENDPOINT_URL"

echo -e "\n=== Test Completed ==="