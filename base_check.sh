#!/bin/bash

# S3 Basic Compatibility Test Script
# Based on S3_compatibility.txt (excluding multipart upload tests)
# Usage: ./base_check.sh <endpoint-url>

# Remove set -e to allow script to continue on errors
# set -e
# Individual commands will handle errors with || true or explicit error handling

# Configuration
ENDPOINT_URL=${1:-"http://192.168.10.81"}
AWS_CMD="aws --no-verify-ssl"

# Helper function to show command before execution
run_cmd() {
    echo "$ $*"
    "$@"
    echo
}

echo "=== S3 Basic Compatibility Test ==="
echo "Endpoint: $ENDPOINT_URL"
echo "======================================"

# Cleanup function
cleanup() {
    echo "=== Cleanup ==="
    
    # Clean up new-bucket objects
    $AWS_CMD s3api delete-object --bucket new-bucket --key new-object --endpoint-url "$ENDPOINT_URL" 2>/dev/null || true
    $AWS_CMD s3api delete-object --bucket new-bucket --key simple-object --endpoint-url "$ENDPOINT_URL" 2>/dev/null || true
    $AWS_CMD s3api delete-object --bucket new-bucket --key simple-object-copy --endpoint-url "$ENDPOINT_URL" 2>/dev/null || true
    $AWS_CMD s3api delete-object --bucket new-bucket --key file1.txt --endpoint-url "$ENDPOINT_URL" 2>/dev/null || true
    $AWS_CMD s3api delete-object --bucket new-bucket --key file2.txt --endpoint-url "$ENDPOINT_URL" 2>/dev/null || true
    $AWS_CMD s3api delete-object --bucket new-bucket --key file3.txt --endpoint-url "$ENDPOINT_URL" 2>/dev/null || true
    $AWS_CMD s3api delete-bucket --bucket new-bucket --endpoint-url "$ENDPOINT_URL" 2>/dev/null || true
    
    # Clean up versioned-bucket 
    # Note: Version IDs change each run, so some cleanup may fail - this is expected
    # Try simple delete first
    $AWS_CMD s3api delete-object --bucket versioned-bucket --key versioned-object --endpoint-url "$ENDPOINT_URL" 2>/dev/null || true
    # Use s3 rm with --recursive to remove all versions
    $AWS_CMD s3 rm s3://versioned-bucket/versioned-object --recursive --endpoint-url "$ENDPOINT_URL" 2>/dev/null || true
    # Force delete entire bucket content (all versions)
    $AWS_CMD s3 rb s3://versioned-bucket --force --endpoint-url "$ENDPOINT_URL" 2>/dev/null || true
    # If force delete didn't work, try api delete
    $AWS_CMD s3api delete-bucket --bucket versioned-bucket --endpoint-url "$ENDPOINT_URL" 2>/dev/null || true
    
    # Clean up bucket-for-tag
    $AWS_CMD s3api delete-object --bucket bucket-for-tag --key object-for-tag --endpoint-url "$ENDPOINT_URL" 2>/dev/null || true
    $AWS_CMD s3api delete-bucket --bucket bucket-for-tag --endpoint-url "$ENDPOINT_URL" 2>/dev/null || true
    
    # Clean up bucket-for-attrs
    $AWS_CMD s3api delete-object --bucket bucket-for-attrs --key object-for-attrs --endpoint-url "$ENDPOINT_URL" 2>/dev/null || true
    $AWS_CMD s3api delete-bucket --bucket bucket-for-attrs --endpoint-url "$ENDPOINT_URL" 2>/dev/null || true
    
    # Clean up bucket-for-delete (should already be deleted)
    $AWS_CMD s3api delete-bucket --bucket bucket-for-delete --endpoint-url "$ENDPOINT_URL" 2>/dev/null || true
    
    # Clean up local files
    rm -f data.txt data-out.txt data-out-copy.txt file1.txt file2.txt file3.txt data1.txt data2.txt 2>/dev/null || true
    rm -rf new-bucket 2>/dev/null || true
}

# Set trap for cleanup on exit
trap cleanup EXIT

echo "=== 1. Bucket Creation and Listing ==="
run_cmd "$AWS_CMD" s3api create-bucket --bucket new-bucket --endpoint-url "$ENDPOINT_URL"
run_cmd "$AWS_CMD" s3api list-buckets --endpoint-url "$ENDPOINT_URL"

echo -e "\n=== 2. Object Creation ==="
echo "test" > data.txt
run_cmd "$AWS_CMD" s3api put-object --bucket new-bucket --key new-object --body data.txt --endpoint-url "$ENDPOINT_URL"
run_cmd "$AWS_CMD" s3api head-object --bucket new-bucket --key new-object --endpoint-url "$ENDPOINT_URL"

echo -e "\n=== 3. Directory Sync ==="
mkdir -p new-bucket && cd new-bucket && touch file1.txt file2.txt file3.txt && cd ..
run_cmd "$AWS_CMD" s3 sync new-bucket s3://new-bucket --endpoint-url "$ENDPOINT_URL"
run_cmd "$AWS_CMD" s3api list-objects --bucket new-bucket --endpoint-url "$ENDPOINT_URL"

echo -e "\n=== 4. Object Lifecycle ==="
echo 'some data' > data.txt
run_cmd "$AWS_CMD" s3api put-object --bucket new-bucket --key simple-object --body data.txt --endpoint-url "$ENDPOINT_URL"
run_cmd "$AWS_CMD" s3api get-object --bucket new-bucket --key simple-object data-out.txt --endpoint-url "$ENDPOINT_URL"
echo "Downloaded content:"
cat data-out.txt
run_cmd "$AWS_CMD" s3api copy-object --copy-source new-bucket/simple-object --bucket new-bucket --key simple-object-copy --endpoint-url "$ENDPOINT_URL"
run_cmd "$AWS_CMD" s3api get-object --bucket new-bucket --key simple-object-copy data-out-copy.txt --endpoint-url "$ENDPOINT_URL"
echo "Copied content:"
cat data-out-copy.txt
run_cmd "$AWS_CMD" s3api delete-object --bucket new-bucket --key simple-object --endpoint-url "$ENDPOINT_URL"
echo "Checking deleted object (should fail):"
run_cmd "$AWS_CMD" s3api head-object --bucket new-bucket --key simple-object --endpoint-url "$ENDPOINT_URL"

echo -e "\n=== 5. Object Listing ==="
run_cmd "$AWS_CMD" s3api list-objects --bucket new-bucket --endpoint-url "$ENDPOINT_URL"
run_cmd "$AWS_CMD" s3api list-objects-v2 --bucket new-bucket --endpoint-url "$ENDPOINT_URL"

echo -e "\n=== 6. Versioning ==="
run_cmd "$AWS_CMD" s3api create-bucket --bucket versioned-bucket --endpoint-url "$ENDPOINT_URL"
run_cmd "$AWS_CMD" s3api put-bucket-versioning --bucket versioned-bucket --versioning-configuration Status=Enabled --endpoint-url "$ENDPOINT_URL"
run_cmd "$AWS_CMD" s3api get-bucket-versioning --bucket versioned-bucket --endpoint-url "$ENDPOINT_URL"
echo 'version1' > data.txt
run_cmd "$AWS_CMD" s3api put-object --bucket versioned-bucket --key versioned-object --body data.txt --endpoint-url "$ENDPOINT_URL"
echo 'version2' > data.txt
run_cmd "$AWS_CMD" s3api put-object --bucket versioned-bucket --key versioned-object --body data.txt --endpoint-url "$ENDPOINT_URL"
echo "Object versions:"
run_cmd "$AWS_CMD" s3api list-object-versions --bucket versioned-bucket --endpoint-url "$ENDPOINT_URL"
run_cmd "$AWS_CMD" s3api delete-object --bucket versioned-bucket --key versioned-object --endpoint-url "$ENDPOINT_URL"
echo "Checking deleted object (should fail):"
run_cmd "$AWS_CMD" s3api head-object --bucket versioned-bucket --key versioned-object --endpoint-url "$ENDPOINT_URL"
echo "Remaining versions:"
run_cmd "$AWS_CMD" s3api list-object-versions --bucket versioned-bucket --endpoint-url "$ENDPOINT_URL"

echo -e "\n=== 7. Bucket Tagging ==="
run_cmd "$AWS_CMD" s3api create-bucket --bucket bucket-for-tag --endpoint-url "$ENDPOINT_URL"
run_cmd "$AWS_CMD" s3api put-bucket-tagging --bucket bucket-for-tag --tagging '{"TagSet":[{"Key":"some-key","Value":"some-value"}]}' --endpoint-url "$ENDPOINT_URL"
echo "Bucket tags:"
run_cmd "$AWS_CMD" s3api get-bucket-tagging --bucket bucket-for-tag --endpoint-url "$ENDPOINT_URL"
run_cmd "$AWS_CMD" s3api delete-bucket-tagging --bucket bucket-for-tag --endpoint-url "$ENDPOINT_URL"
echo "Bucket tags after deletion (should fail):"
run_cmd "$AWS_CMD" s3api get-bucket-tagging --bucket bucket-for-tag --endpoint-url "$ENDPOINT_URL"

echo -e "\n=== 8. Object Tagging ==="
echo "some data" > data.txt
run_cmd "$AWS_CMD" s3api put-object --bucket bucket-for-tag --key object-for-tag --body data.txt --endpoint-url "$ENDPOINT_URL"
run_cmd "$AWS_CMD" s3api put-object-tagging --bucket bucket-for-tag --key object-for-tag --tagging '{"TagSet":[{"Key":"some-object-key","Value":"some-object-value"}]}' --endpoint-url "$ENDPOINT_URL"
echo "Object tags:"
run_cmd "$AWS_CMD" s3api get-object-tagging --bucket bucket-for-tag --key object-for-tag --endpoint-url "$ENDPOINT_URL"
run_cmd "$AWS_CMD" s3api put-object-tagging --bucket bucket-for-tag --key object-for-tag --tagging '{"TagSet":[{"Key":"some-new-object-key","Value":"some-new-object-value"}]}' --endpoint-url "$ENDPOINT_URL"
echo "Updated object tags:"
run_cmd "$AWS_CMD" s3api get-object-tagging --bucket bucket-for-tag --key object-for-tag --endpoint-url "$ENDPOINT_URL"
run_cmd "$AWS_CMD" s3api delete-object-tagging --bucket bucket-for-tag --key object-for-tag --endpoint-url "$ENDPOINT_URL"
echo "Object tags after deletion (should be empty):"
run_cmd "$AWS_CMD" s3api get-object-tagging --bucket bucket-for-tag --key object-for-tag --endpoint-url "$ENDPOINT_URL"

echo -e "\n=== 9. Object Attributes (Basic) ==="
run_cmd "$AWS_CMD" s3api create-bucket --bucket bucket-for-attrs --endpoint-url "$ENDPOINT_URL"
run_cmd "$AWS_CMD" s3api put-object --key object-for-attrs --body data.txt --bucket bucket-for-attrs --endpoint-url "$ENDPOINT_URL"
echo "Object ETag:"
run_cmd "$AWS_CMD" s3api get-object-attributes --key object-for-attrs --bucket bucket-for-attrs --object-attributes ETag --endpoint-url "$ENDPOINT_URL"
echo "Object Size:"
run_cmd "$AWS_CMD" s3api get-object-attributes --key object-for-attrs --bucket bucket-for-attrs --object-attributes ObjectSize --endpoint-url "$ENDPOINT_URL" || echo "ObjectSize attribute not supported"
echo "Storage Class:"
run_cmd "$AWS_CMD" s3api get-object-attributes --key object-for-attrs --bucket bucket-for-attrs --object-attributes StorageClass --endpoint-url "$ENDPOINT_URL" 2>/dev/null || echo "StorageClass attribute not supported"

echo -e "\n=== 10. Bucket Deletion ==="
run_cmd "$AWS_CMD" s3api create-bucket --bucket bucket-for-delete --endpoint-url "$ENDPOINT_URL"
run_cmd "$AWS_CMD" s3api head-bucket --bucket bucket-for-delete --endpoint-url "$ENDPOINT_URL"
run_cmd "$AWS_CMD" s3api delete-bucket --bucket bucket-for-delete --endpoint-url "$ENDPOINT_URL"
echo "Checking deleted bucket (should fail):"
run_cmd "$AWS_CMD" s3api head-bucket --bucket bucket-for-delete --endpoint-url "$ENDPOINT_URL"

echo -e "\n=== Test Completed! ===\n"