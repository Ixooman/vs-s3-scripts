#!/bin/bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
ENDPOINT="http://192.168.10.81"
BUCKET=""
MIN_SIZE=""
MAX_SIZE=""
STEP=""
CLEANUP=false
MAX_RETRIES=3

# Arrays to track results
declare -a UPLOADED_FILES=()
declare -a TEST_RESULTS=()

# Usage function
usage() {
    cat <<EOF
Usage: $0 --bucket <bucket-name> --min <size> --max <size> --step <size> [options]

Required arguments:
  --bucket <name>       S3 bucket name
  --min <size>          Minimum object size (e.g., 16kb, 1mb, 1gb)
  --max <size>          Maximum object size (e.g., 100mb, 10gb)
  --step <size>         Size increment step (e.g., 32kb, 1mb)

Optional arguments:
  --endpoint <url>      S3 endpoint URL (default: http://192.168.10.81)
  --cleanup             Delete uploaded objects after testing
  -h, --help            Show this help message

Size units: kb (KiB), mb (MiB), gb (GiB)

Example:
  $0 --bucket test-bucket --min 1mb --max 100mb --step 5mb --cleanup

AWS Credentials:
  The script uses AWS CLI's standard credential resolution:
  - Environment variables: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
  - AWS credentials file: ~/.aws/credentials
  - AWS config file: ~/.aws/config
  - IAM roles (if running on EC2/ECS)

EOF
    exit 1
}

# Parse size with unit (kb, mb, gb) and convert to bytes
parse_size() {
    local size_str=$1
    local value
    local unit

    # Extract numeric value and unit
    if [[ $size_str =~ ^([0-9]+)(kb|mb|gb)$ ]]; then
        value="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[2]}"
    else
        echo -e "${RED}Error: Invalid size format '$size_str'. Use format: <number><unit> (e.g., 16kb, 1mb, 10gb)${NC}" >&2
        exit 1
    fi

    # Convert to bytes
    case $unit in
        kb)
            echo $((value * 1024))
            ;;
        mb)
            echo $((value * 1024 * 1024))
            ;;
        gb)
            echo $((value * 1024 * 1024 * 1024))
            ;;
    esac
}

# Get the smallest unit from min, max, step
get_smallest_unit() {
    local min_unit max_unit step_unit

    [[ $MIN_SIZE =~ (kb|mb|gb)$ ]] && min_unit="${BASH_REMATCH[1]}"
    [[ $MAX_SIZE =~ (kb|mb|gb)$ ]] && max_unit="${BASH_REMATCH[1]}"
    [[ $STEP =~ (kb|mb|gb)$ ]] && step_unit="${BASH_REMATCH[1]}"

    # kb is smallest, then mb, then gb
    if [[ "$min_unit" == "kb" ]] || [[ "$max_unit" == "kb" ]] || [[ "$step_unit" == "kb" ]]; then
        echo "kb"
    elif [[ "$min_unit" == "mb" ]] || [[ "$max_unit" == "mb" ]] || [[ "$step_unit" == "mb" ]]; then
        echo "mb"
    else
        echo "gb"
    fi
}

# Convert bytes to display unit
bytes_to_unit() {
    local bytes=$1
    local unit=$2

    case $unit in
        kb)
            echo $((bytes / 1024))
            ;;
        mb)
            echo $((bytes / 1024 / 1024))
            ;;
        gb)
            echo $((bytes / 1024 / 1024 / 1024))
            ;;
    esac
}

# Format size for human-readable display
format_size() {
    local bytes=$1

    if ((bytes >= 1073741824)); then
        echo "$(awk "BEGIN {printf \"%.2f\", $bytes/1073741824}")gb"
    elif ((bytes >= 1048576)); then
        echo "$(awk "BEGIN {printf \"%.2f\", $bytes/1048576}")mb"
    else
        echo "$(awk "BEGIN {printf \"%.2f\", $bytes/1024}")kb"
    fi
}

# Generate random suffix
generate_random_suffix() {
    head -c 32 /dev/urandom | tr -dc 'a-z0-9' | head -c 8
}

# Create test file with random data
create_test_file() {
    local size_bytes=$1
    local filename=$2

    echo -e "${BLUE}Generating $filename ($(format_size $size_bytes))...${NC}"

    if ! dd if=/dev/urandom of="$filename" bs=1M count=$((size_bytes / 1048576)) iflag=fullblock 2>/dev/null; then
        # Fallback for sizes smaller than 1MB or exact byte sizes
        dd if=/dev/urandom of="$filename" bs=1 count="$size_bytes" 2>/dev/null
    fi

    if [[ ! -f "$filename" ]]; then
        echo -e "${RED}Error: Failed to create test file${NC}" >&2
        return 1
    fi
}

# Upload file to S3 with retries
upload_to_s3() {
    local filename=$1
    local s3_key=$2
    local attempt=1

    while ((attempt <= MAX_RETRIES)); do
        echo -e "${BLUE}Upload attempt $attempt/$MAX_RETRIES...${NC}"

        local start_time=$(date +%s)

        if aws s3api put-object \
            --bucket "$BUCKET" \
            --key "$s3_key" \
            --body "$filename" \
            --endpoint-url "$ENDPOINT" \
            --no-verify-ssl \
            >/dev/null 2>&1; then

            local end_time=$(date +%s)
            local duration=$((end_time - start_time))

            echo -e "${GREEN}✓ Upload successful (${duration}s)${NC}"
            return 0
        else
            if ((attempt < MAX_RETRIES)); then
                echo -e "${YELLOW}✗ Upload failed, retrying...${NC}"
                ((attempt++))
                sleep 2
            else
                echo -e "${RED}✗ Upload failed after $MAX_RETRIES attempts${NC}"
                return 1
            fi
        fi
    done

    return 1
}

# Cleanup function
cleanup_local_file() {
    local filename=$1
    if [[ -f "$filename" ]]; then
        rm -f "$filename"
    fi
}

# Cleanup S3 objects
cleanup_s3_objects() {
    if [[ ${#UPLOADED_FILES[@]} -eq 0 ]]; then
        return
    fi

    echo -e "\n${BLUE}Cleaning up S3 objects...${NC}"

    for s3_key in "${UPLOADED_FILES[@]}"; do
        echo -e "${BLUE}Deleting s3://$BUCKET/$s3_key...${NC}"
        if aws s3api delete-object \
            --bucket "$BUCKET" \
            --key "$s3_key" \
            --endpoint-url "$ENDPOINT" \
            --no-verify-ssl \
            >/dev/null 2>&1; then
            echo -e "${GREEN}✓ Deleted${NC}"
        else
            echo -e "${YELLOW}✗ Failed to delete${NC}"
        fi
    done
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --bucket)
            BUCKET="$2"
            shift 2
            ;;
        --endpoint)
            ENDPOINT="$2"
            shift 2
            ;;
        --min)
            MIN_SIZE="$2"
            shift 2
            ;;
        --max)
            MAX_SIZE="$2"
            shift 2
            ;;
        --step)
            STEP="$2"
            shift 2
            ;;
        --cleanup)
            CLEANUP=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo -e "${RED}Error: Unknown option $1${NC}" >&2
            usage
            ;;
    esac
done

# Validate required arguments
if [[ -z "$BUCKET" ]] || [[ -z "$MIN_SIZE" ]] || [[ -z "$MAX_SIZE" ]] || [[ -z "$STEP" ]]; then
    echo -e "${RED}Error: Missing required arguments${NC}" >&2
    usage
fi

# Check AWS CLI
if ! command -v aws &> /dev/null; then
    echo -e "${RED}Error: AWS CLI is not installed${NC}" >&2
    exit 1
fi

# Note: AWS credentials will be automatically resolved by AWS CLI from:
# - Environment variables (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY)
# - AWS credentials file (~/.aws/credentials)
# - AWS config file (~/.aws/config)
# - IAM roles (if running on EC2/ECS)
# Credentials will be validated when testing bucket access

# Parse sizes
MIN_BYTES=$(parse_size "$MIN_SIZE")
MAX_BYTES=$(parse_size "$MAX_SIZE")
STEP_BYTES=$(parse_size "$STEP")

# Validate size range
if ((MIN_BYTES > MAX_BYTES)); then
    echo -e "${RED}Error: Minimum size ($MIN_SIZE) is greater than maximum size ($MAX_SIZE)${NC}" >&2
    exit 1
fi

if ((STEP_BYTES <= 0)); then
    echo -e "${RED}Error: Step size must be greater than 0${NC}" >&2
    exit 1
fi

# Get the smallest unit for filename generation
DISPLAY_UNIT=$(get_smallest_unit)

# Print configuration
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}S3 Maximum Object Size Probe${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "Endpoint:    $ENDPOINT"
echo -e "Bucket:      $BUCKET"
echo -e "Min size:    $(format_size $MIN_BYTES)"
echo -e "Max size:    $(format_size $MAX_BYTES)"
echo -e "Step:        $(format_size $STEP_BYTES)"
echo -e "Cleanup:     $CLEANUP"
echo -e "${BLUE}========================================${NC}"
echo ""

# Check bucket existence and create if needed
echo -e "${BLUE}Checking bucket existence...${NC}"
if aws s3api head-bucket --bucket "$BUCKET" --endpoint-url "$ENDPOINT" --no-verify-ssl 2>/dev/null; then
    echo -e "${GREEN}✓ Bucket '$BUCKET' exists${NC}"
    echo ""
else
    echo -e "${YELLOW}Bucket '$BUCKET' does not exist, creating...${NC}"

    # Create bucket and capture output
    create_output=$(aws s3api create-bucket \
        --bucket "$BUCKET" \
        --endpoint-url "$ENDPOINT" \
        --no-verify-ssl 2>&1) || create_result=$?

    # Check if creation was successful by verifying bucket now exists
    if aws s3api head-bucket --bucket "$BUCKET" --endpoint-url "$ENDPOINT" --no-verify-ssl 2>/dev/null; then
        echo -e "${GREEN}✓ Bucket '$BUCKET' created successfully${NC}"
        echo ""
    else
        echo -e "${RED}Error: Failed to create bucket '$BUCKET' at $ENDPOINT${NC}" >&2
        echo "Output: $create_output" >&2
        echo "Please verify your credentials and permissions" >&2
        exit 1
    fi
fi

# Main testing loop
current_bytes=$MIN_BYTES
max_successful_bytes=0
test_count=0

while ((current_bytes <= MAX_BYTES)); do
    test_count=$((test_count + 1))

    # Generate filename
    size_in_unit=$(bytes_to_unit "$current_bytes" "$DISPLAY_UNIT")
    random_suffix=$(generate_random_suffix)
    filename="file_${size_in_unit}${DISPLAY_UNIT}_${random_suffix}.data"
    s3_key="$filename"

    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}Test $test_count: $(format_size $current_bytes)${NC}"
    echo -e "${BLUE}========================================${NC}"

    # Create test file
    if ! create_test_file "$current_bytes" "$filename"; then
        echo -e "${RED}Failed to create test file, aborting${NC}"
        break
    fi

    # Upload to S3
    upload_start=$(date +%s)
    if upload_to_s3 "$filename" "$s3_key"; then
        upload_end=$(date +%s)
        upload_duration=$((upload_end - upload_start))

        max_successful_bytes=$current_bytes
        UPLOADED_FILES+=("$s3_key")
        TEST_RESULTS+=("$(format_size $current_bytes): SUCCESS (${upload_duration}s)")
    else
        TEST_RESULTS+=("$(format_size $current_bytes): FAILED")
        cleanup_local_file "$filename"
        echo -e "${RED}Upload failed, stopping tests${NC}"
        break
    fi

    # Cleanup local file
    cleanup_local_file "$filename"

    # Increment size
    current_bytes=$((current_bytes + STEP_BYTES))
done

# Print summary
echo -e "\n${BLUE}========================================${NC}"
echo -e "${BLUE}Test Summary${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "Total tests: $test_count"
echo -e "Maximum successful size: ${GREEN}$(format_size $max_successful_bytes)${NC}\n"

echo -e "${BLUE}Detailed Results:${NC}"
for result in "${TEST_RESULTS[@]}"; do
    if [[ $result == *"SUCCESS"* ]]; then
        echo -e "${GREEN}✓${NC} $result"
    else
        echo -e "${RED}✗${NC} $result"
    fi
done

# Cleanup S3 objects if requested
if [[ "$CLEANUP" == true ]]; then
    cleanup_s3_objects
fi

echo -e "\n${GREEN}Testing complete!${NC}"

exit 0
