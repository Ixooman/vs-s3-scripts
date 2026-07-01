#!/bin/bash

# S3 API Methods Test Script
# Tests all specified S3 API methods using AWS CLI
# Author: Generated for comprehensive S3 API testing
#
# TESTED S3 API METHODS:
# ======================
# Bucket Operations:
#   - CreateBucket
#   - DeleteBucket  
#   - HeadBucket
#   - ListBuckets
#
# Bucket Versioning:
#   - GetBucketVersioning
#   - PutBucketVersioning
#
# Bucket Tagging:
#   - DeleteBucketTagging
#   - GetBucketTagging
#   - PutBucketTagging
#
# Object Operations:
#   - CopyObject
#   - DeleteObject
#   - DeleteObjects (bulk delete)
#   - GetObject
#   - HeadObject
#   - PutObject
#
# Object Tagging:
#   - DeleteObjectTagging
#   - GetObjectTagging
#   - PutObjectTagging
#
# Multipart Upload Operations:
#   - AbortMultipartUpload
#   - CompleteMultipartUpload
#   - CreateMultipartUpload
#   - ListMultipartUploads
#   - ListParts
#   - UploadPart
#
# Additional Features:
#   - Object versioning operations
#   - File integrity verification
#   - Comprehensive error handling
#   - Test timing and statistics
#   - AWS environment validation
#   - System dependency validation

# Default settings
CONTINUE_ON_ERROR=false
VERBOSE=false
ENDPOINT_URL=""
BUCKET_PREFIX="s3-api-test"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BUCKET_NAME="${BUCKET_PREFIX}-${TIMESTAMP}"
TEST_DIR="/tmp/s3-test-${TIMESTAMP}"
LOG_FILE="${TEST_DIR}/test-results.log"

# Test files
SMALL_FILE="${TEST_DIR}/small-test.txt"
MEDIUM_FILE="${TEST_DIR}/medium-test.txt"
LARGE_FILE="${TEST_DIR}/large-test.txt"

# Multipart upload variables
ACTIVE_MULTIPART_UPLOADS=()
PARTS_JSON="${TEST_DIR}/parts.json"

# Test statistics
TEST_START_TIME=""
TEST_STATS_TOTAL=0
TEST_STATS_PASSED=0
TEST_STATS_FAILED=0
TIMING_LOG="${TEST_DIR}/timing.log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Usage function
usage() {
    echo "Usage: $0 -e ENDPOINT_URL [-c] [-v] [-h]"
    echo "  -e    S3 endpoint URL (required) - e.g., http://localhost:9000"
    echo "  -c    Continue on non-critical errors (default: stop on first failure)"
    echo "  -v    Verbose output showing each API call (default: summary only)"
    echo "  -h    Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 -e http://localhost:9000"
    echo "  $0 -e http://minio.example.com:9000 -v -c"
    exit 1
}

# Parse command line arguments
while getopts "e:cvh" opt; do
    case $opt in
        e)
            ENDPOINT_URL="$OPTARG"
            ;;
        c)
            CONTINUE_ON_ERROR=true
            ;;
        v)
            VERBOSE=true
            ;;
        h)
            usage
            ;;
        \?)
            echo "Invalid option: -$OPTARG" >&2
            usage
            ;;
        :)
            echo "Option -$OPTARG requires an argument." >&2
            usage
            ;;
    esac
done

# Check if endpoint is provided
if [ -z "$ENDPOINT_URL" ]; then
    echo "Error: Endpoint URL is required. Use -e option." >&2
    usage
fi

# Set error handling based on continue flag
if [ "$CONTINUE_ON_ERROR" = true ]; then
    set +e  # Don't exit on error
else
    set -e  # Exit on error
fi

# Logging functions
log() {
    local timestamp="[$(date '+%Y-%m-%d %H:%M:%S')]"
    echo "$timestamp $1"
    # Only try to write to log file if the test directory exists
    if [ -d "$TEST_DIR" ]; then
        echo "$timestamp $1" >> "$LOG_FILE"
    fi
}

log_verbose() {
    if [ "$VERBOSE" = true ]; then
        echo -e "${BLUE}[VERBOSE]${NC} $1"
        if [ -d "$TEST_DIR" ]; then
            echo "[VERBOSE] $1" >> "$LOG_FILE"
        fi
    fi
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
    if [ -d "$TEST_DIR" ]; then
        echo "[SUCCESS] $1" >> "$LOG_FILE"
    fi
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    if [ -d "$TEST_DIR" ]; then
        echo "[ERROR] $1" >> "$LOG_FILE"
    fi
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
    if [ -d "$TEST_DIR" ]; then
        echo "[WARNING] $1" >> "$LOG_FILE"
    fi
}

log_timing() {
    if [ -d "$TEST_DIR" ]; then
        echo "$1" >> "$TIMING_LOG"
    fi
}

# Error handling function
handle_error() {
    local exit_code=$?
    local failed_command="${BASH_COMMAND}"
    
    log_error "Command failed: '$failed_command' (exit code: $exit_code)"
    
    if [ "$CONTINUE_ON_ERROR" = false ]; then
        cleanup
        exit $exit_code
    fi
    
    return $exit_code
}

# Set up error trap only if not continuing on error
if [ "$CONTINUE_ON_ERROR" = false ]; then
    trap 'handle_error' ERR
fi

# Validate endpoint URL format
validate_endpoint_url() {
    local endpoint="$1"
    
    # Check if endpoint starts with http:// or https://
    if [[ ! "$endpoint" =~ ^https?:// ]]; then
        log_error "Endpoint URL must start with http:// or https://"
        return 1
    fi
    
    # Check if endpoint has a valid format
    if [[ ! "$endpoint" =~ ^https?://[a-zA-Z0-9.-]+(:[0-9]+)?(/.*)?$ ]]; then
        log_error "Invalid endpoint URL format"
        return 1
    fi
    
    log_verbose "Endpoint URL validation passed: $endpoint"
    return 0
}

# Validate system dependencies
validate_system_dependencies() {
    log "Validating system dependencies..."
    
    local missing_deps=()
    
    # Required dependencies
    local required_commands=("jq" "split" "md5sum" "stat" "dd" "cat")
    
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        else
            local version_info=""
            case "$cmd" in
                "jq")
                    version_info=$(jq --version 2>/dev/null || echo "unknown")
                    ;;
                "md5sum")
                    version_info=$(md5sum --version 2>/dev/null | head -n1 || echo "unknown")
                    ;;
                "stat")
                    # Test stat command with the specific syntax we use
                    if ! stat -c%s /dev/null &>/dev/null; then
                        missing_deps+=("stat (GNU coreutils version required)")
                        continue
                    fi
                    version_info="GNU coreutils"
                    ;;
                "split")
                    version_info=$(split --version 2>/dev/null | head -n1 || echo "unknown")
                    ;;
                *)
                    version_info="available"
                    ;;
            esac
            log_verbose "$cmd: $version_info"
        fi
    done
    
    # Check for alternative commands if primary ones are missing
    local found_md5sum=false
    for dep in "${missing_deps[@]}"; do
        if [[ "$dep" == "md5sum" ]]; then
            found_md5sum=true
            break
        fi
    done
    
    if [[ "$found_md5sum" == "true" ]]; then
        if command -v md5 &> /dev/null; then
            log_warning "md5sum not found, but md5 is available (macOS style)"
            log_error "This script requires GNU md5sum for Ubuntu Linux"
            # Remove md5sum from missing_deps and add GNU version requirement
            local temp_deps=()
            for dep in "${missing_deps[@]}"; do
                if [[ "$dep" != "md5sum" ]]; then
                    temp_deps+=("$dep")
                fi
            done
            temp_deps+=("md5sum (GNU version required)")
            missing_deps=("${temp_deps[@]}")
        fi
    fi
    
    # Report missing dependencies
    if [ ${#missing_deps[@]} -ne 0 ]; then
        log_error "Missing required system dependencies:"
        for dep in "${missing_deps[@]}"; do
            log_error "  - $dep"
        done
        
        log_error ""
        log_error "To install missing dependencies on Ubuntu/Debian:"
        
        # Provide installation instructions
        local install_packages=()
        for dep in "${missing_deps[@]}"; do
            case "$dep" in
                "jq")
                    install_packages+=("jq")
                    ;;
                "split"|"stat"|*"coreutils"*)
                    local found_coreutils=false
                    for pkg in "${install_packages[@]}"; do
                        if [[ "$pkg" == "coreutils" ]]; then
                            found_coreutils=true
                            break
                        fi
                    done
                    if [[ "$found_coreutils" == "false" ]]; then
                        install_packages+=("coreutils")
                    fi
                    ;;
                "md5sum"*)
                    local found_coreutils=false
                    for pkg in "${install_packages[@]}"; do
                        if [[ "$pkg" == "coreutils" ]]; then
                            found_coreutils=true
                            break
                        fi
                    done
                    if [[ "$found_coreutils" == "false" ]]; then
                        install_packages+=("coreutils")
                    fi
                    ;;
            esac
        done
        
        if [ ${#install_packages[@]} -ne 0 ]; then
            log_error "  sudo apt-get update && sudo apt-get install ${install_packages[*]}"
        fi
        
        return 1
    fi
    
    # Test critical functionality
    log_verbose "Testing critical command functionality..."
    
    # Test jq JSON parsing
    if ! echo '{"test": "value"}' | jq -r '.test' &>/dev/null; then
        log_error "jq command exists but cannot parse JSON properly"
        return 1
    fi
    
    # Test stat command with our specific usage
    if ! stat -c%s /dev/null &>/dev/null; then
        log_error "stat command exists but does not support -c%s format (GNU version required)"
        return 1
    fi
    
    # Test md5sum functionality
    if ! echo "test" | md5sum | cut -d' ' -f1 &>/dev/null; then
        log_error "md5sum command exists but cannot generate checksums properly"
        return 1
    fi
    
    # Test split functionality
    local temp_test_file="/tmp/split-test-$"
    echo "test data" > "$temp_test_file"
    if ! split -b 5 "$temp_test_file" "${temp_test_file}_part_" &>/dev/null; then
        log_error "split command exists but cannot split files properly"
        rm -f "$temp_test_file" "${temp_test_file}_part_"* 2>/dev/null
        return 1
    fi
    rm -f "$temp_test_file" "${temp_test_file}_part_"* 2>/dev/null
    
    log_success "All system dependencies validated successfully"
    return 0
}

# Validate AWS CLI and credentials
validate_aws_environment() {
    log "Validating AWS environment..."
    
    # Validate endpoint URL first
    if ! validate_endpoint_url "$ENDPOINT_URL"; then
        return 1
    fi
    
    # Check if AWS CLI is available
    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI is not installed or not in PATH"
        return 1
    fi
    
    # Check AWS CLI version
    local aws_version
    aws_version=$(aws --version 2>&1 | head -n1)
    log_verbose "AWS CLI version: $aws_version"
    
    # Check AWS credentials and connectivity with S3-specific validation
    # Use list-buckets instead of STS as it works with all S3-compatible services
    if ! aws s3api list-buckets --endpoint-url "$ENDPOINT_URL" --no-verify-ssl &>/dev/null; then
        log_error "Cannot connect to S3 endpoint or credentials are invalid: $ENDPOINT_URL"
        log_error "Please configure AWS credentials (access key, secret key) or check endpoint connectivity"
        return 1
    fi
    
    local bucket_count
    bucket_count=$(aws s3api list-buckets --endpoint-url "$ENDPOINT_URL" --no-verify-ssl --query 'length(Buckets)' --output text 2>/dev/null || echo "0")
    log_verbose "Successfully connected to S3 endpoint"
    log_verbose "Existing buckets found: $bucket_count"
    log_verbose "Using endpoint: $ENDPOINT_URL"
    
    log_success "AWS environment validation completed"
    return 0
}

# Validate bucket name according to AWS rules
validate_bucket_name() {
    local bucket_name="$1"
    
    # Check length (3-63 characters)
    if [ ${#bucket_name} -lt 3 ] || [ ${#bucket_name} -gt 63 ]; then
        log_error "Bucket name must be between 3 and 63 characters long"
        return 1
    fi
    
    # Check for valid characters and format
    if [[ ! "$bucket_name" =~ ^[a-z0-9][a-z0-9.-]*[a-z0-9]$ ]]; then
        log_error "Bucket name contains invalid characters"
        return 1
    fi
    
    # Check for consecutive periods
    if [[ "$bucket_name" =~ \.\. ]]; then
        log_error "Bucket name cannot contain consecutive periods"
        return 1
    fi
    
    # Check for IP address format
    if [[ "$bucket_name" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        log_error "Bucket name cannot be formatted as an IP address"
        return 1
    fi
    
    log_verbose "Bucket name validation passed: $bucket_name"
    return 0
}

# Check disk space
check_disk_space() {
    local required_space=100  # MB
    local available_space
    available_space=$(df /tmp | awk 'NR==2 {print int($4/1024)}')
    
    if [ "$available_space" -lt "$required_space" ]; then
        log_error "Insufficient disk space. Required: ${required_space}MB, Available: ${available_space}MB"
        return 1
    fi
    
    log_verbose "Disk space check passed: ${available_space}MB available"
    return 0
}

# File verification function
verify_file_integrity() {
    local original_file="$1"
    local downloaded_file="$2"
    
    if [ ! -f "$original_file" ] || [ ! -f "$downloaded_file" ]; then
        log_error "File verification failed: One or both files do not exist"
        return 1
    fi
    
    local original_hash
    local downloaded_hash
    original_hash=$(md5sum "$original_file" | cut -d' ' -f1)
    downloaded_hash=$(md5sum "$downloaded_file" | cut -d' ' -f1)
    
    if [ "$original_hash" != "$downloaded_hash" ]; then
        log_error "File verification failed: Checksums do not match"
        log_error "Original: $original_hash, Downloaded: $downloaded_hash"
        return 1
    fi
    
    log_verbose "File verification passed: Checksums match ($original_hash)"
    return 0
}

# Cleanup function
cleanup() {
    log "Starting cleanup..."
    
    # Abort any ongoing multipart uploads
    for upload_info in "${ACTIVE_MULTIPART_UPLOADS[@]}"; do
        IFS='|' read -r bucket key upload_id <<< "$upload_info"
        if [ -n "$upload_id" ]; then
            log_verbose "Aborting multipart upload: $upload_id for key: $key"
            aws s3api abort-multipart-upload \
                --bucket "$bucket" \
                --key "$key" \
                --upload-id "$upload_id" \
                --endpoint-url "$ENDPOINT_URL" --no-verify-ssl 2>/dev/null || log_warning "Failed to abort multipart upload: $upload_id"
        fi
    done
    
    # Delete all objects in bucket
    if aws s3api head-bucket --bucket "$BUCKET_NAME" --endpoint-url "$ENDPOINT_URL" --no-verify-ssl 2>/dev/null; then
        log_verbose "Deleting all objects from bucket: $BUCKET_NAME"
        
        # Delete all versions and delete markers if versioning is enabled
        aws s3api list-object-versions --bucket "$BUCKET_NAME" --endpoint-url "$ENDPOINT_URL" --no-verify-ssl --output json 2>/dev/null | \
        jq -r '.Versions[]?, .DeleteMarkers[]? | "\(.Key)\t\(.VersionId)"' 2>/dev/null | while IFS=$'\t' read -r key version_id; do
            if [ -n "$key" ] && [ -n "$version_id" ]; then
                aws s3api delete-object --bucket "$BUCKET_NAME" --key "$key" --version-id "$version_id" --endpoint-url "$ENDPOINT_URL" --no-verify-ssl 2>/dev/null || true
            fi
        done
        
        # Delete remaining objects
        aws s3 rm "s3://${BUCKET_NAME}" --recursive --endpoint-url "$ENDPOINT_URL" --no-verify-ssl 2>/dev/null || true
        
        # Delete bucket
        log_verbose "Deleting bucket: $BUCKET_NAME"
        aws s3api delete-bucket --bucket "$BUCKET_NAME" --endpoint-url "$ENDPOINT_URL" --no-verify-ssl 2>/dev/null || log_warning "Failed to delete bucket: $BUCKET_NAME"
    fi
    
    # Remove test directory
    if [ -d "$TEST_DIR" ]; then
        log_verbose "Removing test directory: $TEST_DIR"
        rm -rf "$TEST_DIR"
    fi
    
    log "Cleanup completed"
}

# Setup function
setup() {
    log "Setting up test environment..."
    
    # Validate system dependencies first
    if ! validate_system_dependencies; then
        exit 1
    fi
    
    # Validate AWS environment
    if ! validate_aws_environment; then
        exit 1
    fi
    
    # Validate bucket name
    if ! validate_bucket_name "$BUCKET_NAME"; then
        exit 1
    fi
    
    # Check disk space
    if ! check_disk_space; then
        exit 1
    fi
    
    # Create test directory
    mkdir -p "$TEST_DIR"
    
    # Initialize timing log
    echo "# S3 API Test Timing Log - $(date)" > "$TIMING_LOG"
    echo "# Format: TestName,StartTime,EndTime,Duration(seconds)" >> "$TIMING_LOG"
    
    # Create test files
    log_verbose "Creating test files..."
    
    # Small file (~1KB)
    echo "This is a small test file for S3 API testing." > "$SMALL_FILE"
    for i in {1..50}; do
        echo "Line $i: Some test data for small file testing" >> "$SMALL_FILE"
    done
    
    # Medium file (~10MB)
    log_verbose "Creating medium test file (10MB)..."
    dd if=/dev/zero of="$MEDIUM_FILE" bs=1024 count=10240 2>/dev/null
    
    # Large file (~50MB)
    log_verbose "Creating large test file (50MB)..."
    dd if=/dev/zero of="$LARGE_FILE" bs=1024 count=51200 2>/dev/null
    
    # Initialize parts JSON for multipart upload
    echo '{"Parts": []}' > "$PARTS_JSON"
    
    # Record test start time
    TEST_START_TIME=$(date +%s)
    
    log_success "Test environment setup completed"
}

# Test function wrapper with timing
run_test() {
    local test_name="$1"
    local test_function="$2"
    local start_time
    local start_time_readable
    start_time=$(date +%s)
    start_time_readable=$(date '+%Y-%m-%d %H:%M:%S')
    
    log "Running test: $test_name"
    TEST_STATS_TOTAL=$((TEST_STATS_TOTAL + 1))
    
    local result=0
    if $test_function; then
        TEST_STATS_PASSED=$((TEST_STATS_PASSED + 1))
        log_success "$test_name completed"
        result=0
    else
        TEST_STATS_FAILED=$((TEST_STATS_FAILED + 1))
        log_error "$test_name failed"
        result=1
    fi
    
    local end_time
    local end_time_readable
    end_time=$(date +%s)
    end_time_readable=$(date '+%Y-%m-%d %H:%M:%S')
    local duration=$((end_time - start_time))
    
    log_timing "$test_name,$start_time_readable,$end_time_readable,$duration"
    log_verbose "Test duration: ${duration} seconds"
    
    if [ $result -ne 0 ] && [ "$CONTINUE_ON_ERROR" = false ]; then
        return 1
    fi
    
    return 0
}

# Bucket Operations Tests
test_bucket_operations() {
    log_verbose "Testing CreateBucket..."
    # Remove --region parameter to avoid conflicts with custom endpoints
    aws s3api create-bucket --bucket "$BUCKET_NAME" --endpoint-url "$ENDPOINT_URL" --no-verify-ssl
    
    log_verbose "Testing HeadBucket..."
    aws s3api head-bucket --bucket "$BUCKET_NAME" --endpoint-url "$ENDPOINT_URL" --no-verify-ssl
    
    log_verbose "Testing ListBuckets..."
    local bucket_found
    bucket_found=$(aws s3api list-buckets --endpoint-url "$ENDPOINT_URL" --no-verify-ssl --query "Buckets[?Name=='$BUCKET_NAME'].Name" --output text)
    if [ "$bucket_found" != "$BUCKET_NAME" ]; then
        log_error "Bucket not found in list-buckets output"
        return 1
    fi
    
    return 0
}

test_bucket_versioning() {
    log_verbose "Testing PutBucketVersioning..."
    aws s3api put-bucket-versioning \
        --bucket "$BUCKET_NAME" \
        --versioning-configuration Status=Enabled \
        --endpoint-url "$ENDPOINT_URL" --no-verify-ssl
    
    log_verbose "Testing GetBucketVersioning..."
    local versioning_status
    versioning_status=$(aws s3api get-bucket-versioning --bucket "$BUCKET_NAME" --endpoint-url "$ENDPOINT_URL" --no-verify-ssl --query 'Status' --output text)
    if [ "$versioning_status" != "Enabled" ]; then
        log_error "Bucket versioning not enabled properly"
        return 1
    fi
    
    return 0
}

test_bucket_tagging() {
    log_verbose "Testing PutBucketTagging..."
    aws s3api put-bucket-tagging \
        --bucket "$BUCKET_NAME" \
        --tagging 'TagSet=[{Key=Environment,Value=Test},{Key=Purpose,Value=S3-API-Testing}]' \
        --endpoint-url "$ENDPOINT_URL" --no-verify-ssl
    
    log_verbose "Testing GetBucketTagging..."
    local tag_count
    tag_count=$(aws s3api get-bucket-tagging --bucket "$BUCKET_NAME" --endpoint-url "$ENDPOINT_URL" --no-verify-ssl --query 'length(TagSet)' --output text)
    if [ "$tag_count" != "2" ]; then
        log_error "Expected 2 bucket tags, found $tag_count"
        return 1
    fi
    
    log_verbose "Testing DeleteBucketTagging..."
    aws s3api delete-bucket-tagging --bucket "$BUCKET_NAME" --endpoint-url "$ENDPOINT_URL" --no-verify-ssl
    
    # Verify tags are deleted
    if aws s3api get-bucket-tagging --bucket "$BUCKET_NAME" --endpoint-url "$ENDPOINT_URL" --no-verify-ssl &>/dev/null; then
        log_error "Bucket tags were not deleted properly"
        return 1
    fi
    
    return 0
}

# Object Operations Tests
test_object_operations() {
    log_verbose "Testing PutObject (small file)..."
    aws s3api put-object \
        --bucket "$BUCKET_NAME" \
        --key "small-test.txt" \
        --body "$SMALL_FILE" \
        --endpoint-url "$ENDPOINT_URL" --no-verify-ssl
    
    log_verbose "Testing PutObject (medium file)..."
    aws s3api put-object \
        --bucket "$BUCKET_NAME" \
        --key "medium-test.txt" \
        --body "$MEDIUM_FILE" \
        --endpoint-url "$ENDPOINT_URL" --no-verify-ssl
    
    log_verbose "Testing HeadObject..."
    local object_size
    local expected_size
    object_size=$(aws s3api head-object \
        --bucket "$BUCKET_NAME" \
        --key "small-test.txt" \
        --endpoint-url "$ENDPOINT_URL" --no-verify-ssl \
        --query 'ContentLength' --output text)
    
    expected_size=$(stat -c%s "$SMALL_FILE")
    if [ "$object_size" != "$expected_size" ]; then
        log_error "Object size mismatch: expected $expected_size, got $object_size"
        return 1
    fi
    
    log_verbose "Testing GetObject..."
    aws s3api get-object \
        --bucket "$BUCKET_NAME" \
        --key "small-test.txt" \
        --endpoint-url "$ENDPOINT_URL" --no-verify-ssl \
        "${TEST_DIR}/downloaded-small.txt"
    
    # Verify file integrity
    if ! verify_file_integrity "$SMALL_FILE" "${TEST_DIR}/downloaded-small.txt"; then
        return 1
    fi
    
    log_verbose "Testing CopyObject..."
    aws s3api copy-object \
        --bucket "$BUCKET_NAME" \
        --copy-source "${BUCKET_NAME}/small-test.txt" \
        --key "copied-small-test.txt" \
        --endpoint-url "$ENDPOINT_URL" --no-verify-ssl
    
    # Verify copied object exists
    if ! aws s3api head-object --bucket "$BUCKET_NAME" --key "copied-small-test.txt" --endpoint-url "$ENDPOINT_URL" --no-verify-ssl &>/dev/null; then
        log_error "Copied object does not exist"
        return 1
    fi
    
    return 0
}

test_object_versioning() {
    
    # Upload initial version
    echo "Version 1 content" > "${TEST_DIR}/version-test.txt"
    aws s3api put-object \
        --bucket "$BUCKET_NAME" \
        --key "version-test.txt" \
        --body "${TEST_DIR}/version-test.txt" \
        --endpoint-url "$ENDPOINT_URL" --no-verify-ssl
    
    local version1
    version1=$(aws s3api head-object \
        --bucket "$BUCKET_NAME" \
        --key "version-test.txt" \
        --endpoint-url "$ENDPOINT_URL" --no-verify-ssl \
        --query 'VersionId' --output text)
    
    # Upload second version
    echo "Version 2 content" > "${TEST_DIR}/version-test.txt"
    aws s3api put-object \
        --bucket "$BUCKET_NAME" \
        --key "version-test.txt" \
        --body "${TEST_DIR}/version-test.txt" \
        --endpoint-url "$ENDPOINT_URL" --no-verify-ssl
    
    local version2
    version2=$(aws s3api head-object \
        --bucket "$BUCKET_NAME" \
        --key "version-test.txt" \
        --endpoint-url "$ENDPOINT_URL" --no-verify-ssl \
        --query 'VersionId' --output text)
    
    if [ "$version1" = "$version2" ]; then
        log_error "Object versions are the same, versioning may not be working"
        return 1
    fi
    
    # Test getting specific version
    aws s3api get-object \
        --bucket "$BUCKET_NAME" \
        --key "version-test.txt" \
        --version-id "$version1" \
        --endpoint-url "$ENDPOINT_URL" --no-verify-ssl \
        "${TEST_DIR}/version1-download.txt"
    
    local downloaded_content
    downloaded_content=$(cat "${TEST_DIR}/version1-download.txt")
    if [ "$downloaded_content" != "Version 1 content" ]; then
        log_error "Downloaded version 1 content doesn't match expected content"
        return 1
    fi
    
    log_verbose "Object versioning test completed successfully"
    return 0
}

test_object_tagging() {
    log_verbose "Testing PutObjectTagging..."
    aws s3api put-object-tagging \
        --bucket "$BUCKET_NAME" \
        --key "small-test.txt" \
        --tagging 'TagSet=[{Key=Type,Value=TestFile},{Key=Size,Value=Small}]' \
        --endpoint-url "$ENDPOINT_URL" --no-verify-ssl
    
    log_verbose "Testing GetObjectTagging..."
    local tag_count
    tag_count=$(aws s3api get-object-tagging \
        --bucket "$BUCKET_NAME" \
        --key "small-test.txt" \
        --endpoint-url "$ENDPOINT_URL" --no-verify-ssl \
        --query 'length(TagSet)' --output text)
    
    if [ "$tag_count" != "2" ]; then
        log_error "Expected 2 object tags, found $tag_count"
        return 1
    fi
    
    log_verbose "Testing DeleteObjectTagging..."
    aws s3api delete-object-tagging \
        --bucket "$BUCKET_NAME" \
        --key "small-test.txt" \
        --endpoint-url "$ENDPOINT_URL" --no-verify-ssl
    
    # Verify tags are deleted
    local remaining_tags
    remaining_tags=$(aws s3api get-object-tagging \
        --bucket "$BUCKET_NAME" \
        --key "small-test.txt" \
        --endpoint-url "$ENDPOINT_URL" --no-verify-ssl \
        --query 'length(TagSet)' --output text)
    
    if [ "$remaining_tags" != "0" ]; then
        log_error "Object tags were not deleted properly"
        return 1
    fi
    
    return 0
}

# Multipart Upload Tests
test_multipart_upload() {
    log_verbose "Testing CreateMultipartUpload..."
    local multipart_upload_id
    multipart_upload_id=$(aws s3api create-multipart-upload \
        --bucket "$BUCKET_NAME" \
        --key "large-multipart-test.txt" \
        --endpoint-url "$ENDPOINT_URL" --no-verify-ssl \
        --query 'UploadId' --output text)
    
    # Track active upload
    ACTIVE_MULTIPART_UPLOADS+=("$BUCKET_NAME|large-multipart-test.txt|$multipart_upload_id")
    
    log_verbose "Created multipart upload with ID: $multipart_upload_id"
    
    log_verbose "Testing ListMultipartUploads..."
    local upload_found
    upload_found=$(aws s3api list-multipart-uploads \
        --bucket "$BUCKET_NAME" \
        --endpoint-url "$ENDPOINT_URL" --no-verify-ssl \
        --query "Uploads[?UploadId=='$multipart_upload_id'].UploadId" --output text)
    
    if [ "$upload_found" != "$multipart_upload_id" ]; then
        log_error "Multipart upload not found in list"
        return 1
    fi
    
    # Split large file into parts for multipart upload
    log_verbose "Splitting large file into parts..."
    split -b 10485760 "$LARGE_FILE" "${TEST_DIR}/part_"  # 10MB parts
    
    # Upload parts
    local part_number=1
    local parts_list="["
    
    for part_file in "${TEST_DIR}"/part_*; do
        if [ -f "$part_file" ]; then
            log_verbose "Testing UploadPart (part $part_number)..."
            
            local etag
            etag=$(aws s3api upload-part \
                --bucket "$BUCKET_NAME" \
                --key "large-multipart-test.txt" \
                --part-number $part_number \
                --upload-id "$multipart_upload_id" \
                --body "$part_file" \
                --endpoint-url "$ENDPOINT_URL" --no-verify-ssl \
                --query 'ETag' --output text)
            
            # Add to parts list
            if [ $part_number -gt 1 ]; then
                parts_list+=","
            fi
            parts_list+="{\"ETag\":$etag,\"PartNumber\":$part_number}"
            
            ((part_number++))
        fi
    done
    parts_list+="]"
    
    if [ "$part_number" -eq 1 ]; then
        log_error "No parts were uploaded"
        return 1
    fi
    
    log_verbose "Testing ListParts..."
    local parts_count
    parts_count=$(aws s3api list-parts \
        --bucket "$BUCKET_NAME" \
        --key "large-multipart-test.txt" \
        --upload-id "$multipart_upload_id" \
        --endpoint-url "$ENDPOINT_URL" --no-verify-ssl \
        --query 'length(Parts)' --output text)
    
    local expected_parts=$((part_number - 1))
    if [ "$parts_count" != "$expected_parts" ]; then
        log_error "Expected $expected_parts parts, found $parts_count"
        return 1
    fi
    
    # Create parts JSON for completion
    echo "{\"Parts\":$parts_list}" > "$PARTS_JSON"
    
    log_verbose "Testing CompleteMultipartUpload..."
    aws s3api complete-multipart-upload \
        --bucket "$BUCKET_NAME" \
        --key "large-multipart-test.txt" \
        --upload-id "$multipart_upload_id" \
        --multipart-upload "file://$PARTS_JSON" \
        --endpoint-url "$ENDPOINT_URL" --no-verify-ssl
    
    # Remove from active uploads list
    local temp_array=()
    for upload_info in "${ACTIVE_MULTIPART_UPLOADS[@]}"; do
        if [[ "$upload_info" != *"|$multipart_upload_id" ]]; then
            temp_array+=("$upload_info")
        fi
    done
    ACTIVE_MULTIPART_UPLOADS=("${temp_array[@]}")
    
    # Verify object was created
    if ! aws s3api head-object --bucket "$BUCKET_NAME" --key "large-multipart-test.txt" --endpoint-url "$ENDPOINT_URL" --no-verify-ssl &>/dev/null; then
        log_error "Multipart upload completed but object not found"
        return 1
    fi
    
    return 0
}

test_abort_multipart_upload() {
    log_verbose "Testing AbortMultipartUpload..."
    
    # Create another multipart upload to abort
    local abort_upload_id
    abort_upload_id=$(aws s3api create-multipart-upload \
        --bucket "$BUCKET_NAME" \
        --key "abort-test.txt" \
        --endpoint-url "$ENDPOINT_URL" --no-verify-ssl \
        --query 'UploadId' --output text)
    
    # Track active upload
    ACTIVE_MULTIPART_UPLOADS+=("$BUCKET_NAME|abort-test.txt|$abort_upload_id")
    
    # Upload one part
    aws s3api upload-part \
        --bucket "$BUCKET_NAME" \
        --key "abort-test.txt" \
        --part-number 1 \
        --upload-id "$abort_upload_id" \
        --body "$SMALL_FILE" \
        --endpoint-url "$ENDPOINT_URL" --no-verify-ssl > /dev/null
    
    # Now abort it
    aws s3api abort-multipart-upload \
        --bucket "$BUCKET_NAME" \
        --key "abort-test.txt" \
        --upload-id "$abort_upload_id" \
        --endpoint-url "$ENDPOINT_URL" --no-verify-ssl
    
    # Remove from active uploads list
    local temp_array=()
    for upload_info in "${ACTIVE_MULTIPART_UPLOADS[@]}"; do
        if [[ "$upload_info" != *"|$abort_upload_id" ]]; then
            temp_array+=("$upload_info")
        fi
    done
    ACTIVE_MULTIPART_UPLOADS=("${temp_array[@]}")
    
    # Verify upload was aborted
    local remaining_uploads
    remaining_uploads=$(aws s3api list-multipart-uploads \
        --bucket "$BUCKET_NAME" \
        --endpoint-url "$ENDPOINT_URL" --no-verify-ssl \
        --query "Uploads[?UploadId=='$abort_upload_id'].UploadId" --output text)
    
    if [ -n "$remaining_uploads" ]; then
        log_error "Multipart upload was not properly aborted"
        return 1
    fi
    
    return 0
}

# Delete Operations Tests
test_delete_operations() {
    log_verbose "Testing DeleteObject..."
    aws s3api delete-object \
        --bucket "$BUCKET_NAME" \
        --key "copied-small-test.txt" \
        --endpoint-url "$ENDPOINT_URL" --no-verify-ssl
    
    # Verify object was deleted
    if aws s3api head-object --bucket "$BUCKET_NAME" --key "copied-small-test.txt" --endpoint-url "$ENDPOINT_URL" --no-verify-ssl &>/dev/null; then
        log_error "Object was not deleted properly"
        return 1
    fi
    
    log_verbose "Testing DeleteObjects (bulk delete)..."
    # Create objects JSON for bulk delete
    local delete_objects_json="${TEST_DIR}/delete-objects.json"
    cat > "$delete_objects_json" << EOF
{
    "Objects": [
        {"Key": "small-test.txt"},
        {"Key": "medium-test.txt"},
        {"Key": "large-multipart-test.txt"}
    ],
    "Quiet": true
}
EOF
    
    aws s3api delete-objects \
        --bucket "$BUCKET_NAME" \
        --delete "file://$delete_objects_json" \
        --endpoint-url "$ENDPOINT_URL" --no-verify-ssl
    
    # Verify objects were deleted
    for key in "small-test.txt" "medium-test.txt" "large-multipart-test.txt"; do
        if aws s3api head-object --bucket "$BUCKET_NAME" --key "$key" --endpoint-url "$ENDPOINT_URL" --no-verify-ssl &>/dev/null; then
            log_error "Object $key was not deleted properly"
            return 1
        fi
    done
    
    return 0
}

# Print test statistics
print_test_statistics() {
    local test_end_time
    test_end_time=$(date +%s)
    local total_duration
    total_duration=$((test_end_time - TEST_START_TIME))
    
    echo ""
    echo "=========================================="
    echo "           TEST STATISTICS"
    echo "=========================================="
    echo "Total Tests:    $TEST_STATS_TOTAL"
    echo "Passed:         $TEST_STATS_PASSED"
    echo "Failed:         $TEST_STATS_FAILED"
    echo "Success Rate:   $(( (TEST_STATS_PASSED * 100) / TEST_STATS_TOTAL ))%"
    echo "Total Duration: ${total_duration} seconds"
    echo "=========================================="
    
    if [ -f "$TIMING_LOG" ]; then
        echo ""
        echo "Individual Test Timings:"
        echo "------------------------"
        tail -n +3 "$TIMING_LOG" | while IFS=',' read -r test_name start_time end_time duration; do
            printf "%-30s %3s seconds\n" "$test_name:" "$duration"
        done
    fi
}

# Main execution
main() {
    log "Starting S3 API Methods Test Script"
    log "Endpoint: $ENDPOINT_URL"
    log "Bucket: $BUCKET_NAME"
    log "Continue on error: $CONTINUE_ON_ERROR"
    log "Verbose output: $VERBOSE"
    log "Test directory: $TEST_DIR"
    
    # Setup
    setup
    
    # Run tests
    run_test "Bucket Operations" test_bucket_operations
    run_test "Bucket Versioning" test_bucket_versioning
    run_test "Bucket Tagging" test_bucket_tagging
    run_test "Object Operations" test_object_operations
    run_test "Object Versioning" test_object_versioning
    run_test "Object Tagging" test_object_tagging
    run_test "Multipart Upload" test_multipart_upload
    run_test "Abort Multipart Upload" test_abort_multipart_upload
    run_test "Delete Operations" test_delete_operations
    
    # Print statistics
    print_test_statistics
    
    if [ $TEST_STATS_FAILED -eq 0 ]; then
        log_success "All tests completed successfully!"
    else
        log_warning "$TEST_STATS_FAILED out of $TEST_STATS_TOTAL tests failed"
    fi
    
    log "Test results saved to: $LOG_FILE"
    log "Timing details saved to: $TIMING_LOG"
    
    # Cleanup
    cleanup
    
    # Exit with error code if any tests failed and not continuing on error
    if [ $TEST_STATS_FAILED -gt 0 ] && [ "$CONTINUE_ON_ERROR" = false ]; then
        exit 1
    fi
}

# Register cleanup on script exit
trap cleanup EXIT

# Run main function
main "$@"