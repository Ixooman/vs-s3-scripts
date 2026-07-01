#!/bin/bash

# S3 Complete Cleanup Script - Removes ALL buckets and objects recursively
# Usage: ./cleanup_all.sh [endpoint-url]
# WARNING: This will delete ALL buckets and objects on the specified endpoint!

set -e

# Configuration
ENDPOINT_URL=${1:-"http://192.168.10.81"}
AWS_CMD="aws --no-verify-ssl"

echo "=== S3 Complete Cleanup Script ==="
echo "Endpoint: $ENDPOINT_URL"
echo "WARNING: This will delete ALL buckets and objects!"
echo "Press Ctrl+C within 5 seconds to abort..."
sleep 5

# Get all buckets
echo "=== Listing all buckets ==="
BUCKETS=""
BUCKETS=$($AWS_CMD s3api list-buckets --endpoint-url "$ENDPOINT_URL" --query 'Buckets[].Name' --output text 2>/dev/null || echo "")

if [ -z "$BUCKETS" ]; then
    echo "No buckets found or unable to list buckets"
    exit 0
fi

echo "Found buckets: $BUCKETS"

# Delete each bucket and all its contents
for bucket in $BUCKETS; do
    echo "=== Processing bucket: $bucket ==="
    
    # Try to delete all objects and versions using s3 rb --force
    echo "Deleting all objects and versions from bucket: $bucket"
    $AWS_CMD s3 rb "s3://$bucket" --force --endpoint-url "$ENDPOINT_URL" 2>/dev/null || {
        echo "Force delete failed for $bucket, trying manual cleanup..."
        
        # Manual cleanup for versioned objects
        echo "Listing and deleting object versions..."
        $AWS_CMD s3api list-object-versions --bucket "$bucket" --endpoint-url "$ENDPOINT_URL" --query 'Versions[].{Key:Key,VersionId:VersionId}' --output text 2>/dev/null | while read -r key version_id; do
            if [ -n "$key" ] && [ -n "$version_id" ]; then
                echo "Deleting version: $key ($version_id)"
                $AWS_CMD s3api delete-object --bucket "$bucket" --key "$key" --version-id "$version_id" --endpoint-url "$ENDPOINT_URL" 2>/dev/null || true
            fi
        done
        
        # Delete delete markers
        echo "Deleting delete markers..."
        $AWS_CMD s3api list-object-versions --bucket "$bucket" --endpoint-url "$ENDPOINT_URL" --query 'DeleteMarkers[].{Key:Key,VersionId:VersionId}' --output text 2>/dev/null | while read -r key version_id; do
            if [ -n "$key" ] && [ -n "$version_id" ]; then
                echo "Deleting delete marker: $key ($version_id)"
                $AWS_CMD s3api delete-object --bucket "$bucket" --key "$key" --version-id "$version_id" --endpoint-url "$ENDPOINT_URL" 2>/dev/null || true
            fi
        done
        
        # Delete regular objects (fallback)
        echo "Deleting remaining objects..."
        $AWS_CMD s3api list-objects --bucket "$bucket" --endpoint-url "$ENDPOINT_URL" --query 'Contents[].Key' --output text 2>/dev/null | while read -r key; do
            if [ -n "$key" ]; then
                echo "Deleting object: $key"
                $AWS_CMD s3api delete-object --bucket "$bucket" --key "$key" --endpoint-url "$ENDPOINT_URL" 2>/dev/null || true
            fi
        done
        
        # Finally delete the bucket
        echo "Deleting bucket: $bucket"
        $AWS_CMD s3api delete-bucket --bucket "$bucket" --endpoint-url "$ENDPOINT_URL" 2>/dev/null || echo "Failed to delete bucket: $bucket"
    }
    
    echo "Finished processing bucket: $bucket"
done

echo "=== Cleanup completed ==="
echo "Verifying no buckets remain..."
$AWS_CMD s3api list-buckets --endpoint-url "$ENDPOINT_URL" 2>/dev/null || echo "Cannot list buckets after cleanup"