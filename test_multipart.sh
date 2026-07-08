#!/bin/bash

# Simple multipart upload test script
# Usage: ./test_multipart.sh --bucket <bucket-name> [--endpoint <url>]

ENDPOINT="http://192.168.10.81"
BUCKET=""
KEY="test-multipart-object.bin"

usage() {
    cat <<EOF
Usage: $0 --bucket <bucket-name> [options]

Required arguments:
  --bucket <name>       S3 bucket name

Optional arguments:
  --endpoint <url>      S3 endpoint URL (default: http://192.168.10.81)
  -h, --help            Show this help message

Example:
  $0 --bucket test-bucket
  $0 --bucket test-bucket --endpoint http://192.168.10.81

EOF
    exit "${1:-1}"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --endpoint)
            if [[ -z "$2" || "$2" == --* ]]; then
                echo "Error: --endpoint requires a value" >&2
                usage
            fi
            ENDPOINT="$2"
            shift 2
            ;;
        --bucket)
            if [[ -z "$2" || "$2" == --* ]]; then
                echo "Error: --bucket requires a value" >&2
                usage
            fi
            BUCKET="$2"
            shift 2
            ;;
        -h|--help)
            usage 0
            ;;
        *)
            echo "Error: Unknown option $1" >&2
            usage
            ;;
    esac
done

# Validate required arguments
if [[ -z "$BUCKET" ]]; then
    echo "Error: Missing required argument --bucket" >&2
    usage
fi

echo "Testing multipart upload support on $ENDPOINT"
echo "================================================"
echo ""

# Step 1: Initiate multipart upload
echo "Step 1: Initiating multipart upload..."
echo "Command: aws s3api create-multipart-upload --bucket \"$BUCKET\" --key \"$KEY\" --endpoint-url \"$ENDPOINT\" --no-verify-ssl"
echo ""

UPLOAD_OUTPUT=$(aws s3api create-multipart-upload \
    --bucket "$BUCKET" \
    --key "$KEY" \
    --endpoint-url "$ENDPOINT" \
    --no-verify-ssl 2>&1)

EXIT_CODE=$?

echo "Exit code: $EXIT_CODE"
echo "Full output:"
echo "$UPLOAD_OUTPUT"
echo ""

if [ $EXIT_CODE -ne 0 ]; then
    echo "ERROR: Failed to initiate multipart upload"
    echo ""
    echo "Troubleshooting tips:"
    echo "1. Check if the endpoint supports S3 multipart upload API"
    echo "2. Verify network connectivity to $ENDPOINT"
    echo "3. Check AWS credentials are configured correctly"
    echo "4. Try enabling debug mode: aws s3api create-multipart-upload --debug ..."
    exit 1
fi

# Extract Upload ID
UPLOAD_ID=$(echo "$UPLOAD_OUTPUT" | grep -oP '"UploadId":\s*"\K[^"]+')

if [ -z "$UPLOAD_ID" ]; then
    echo "ERROR: Could not extract UploadId from response"
    exit 1
fi

echo "SUCCESS: Upload initiated with ID: $UPLOAD_ID"
echo ""

# Step 2: Abort the upload (cleanup)
echo "Step 2: Aborting multipart upload (cleanup)..."
aws s3api abort-multipart-upload \
    --bucket "$BUCKET" \
    --key "$KEY" \
    --upload-id "$UPLOAD_ID" \
    --endpoint-url "$ENDPOINT" \
    --no-verify-ssl 2>&1

if [ $? -eq 0 ]; then
    echo "SUCCESS: Multipart upload aborted"
else
    echo "WARNING: Failed to abort multipart upload"
fi

echo ""
echo "Multipart upload API appears to be working correctly!"
