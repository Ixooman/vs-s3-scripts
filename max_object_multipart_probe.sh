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
DEBUG=false
MAX_RETRIES=3

# Arrays to track results
declare -a UPLOADED_FILES=()
declare -a TEST_RESULTS=()
declare -a ACTIVE_UPLOADS=()

# Usage function
usage() {
    cat <<EOF
Usage: $0 --bucket <bucket-name> --min <size> --max <size> --step <size> [options]

Required arguments:
  --bucket <name>       S3 bucket name
  --min <size>          Minimum object size (e.g., 100mb, 1gb, 10gb, 1tb) - must be >= 100mb
  --max <size>          Maximum object size (e.g., 1gb, 10gb, 100gb, 5tb)
  --step <size>         Size increment step (e.g., 100mb, 1gb, 500gb, 1tb)

Optional arguments:
  --endpoint <url>      S3 endpoint URL (default: http://192.168.10.81)
  --cleanup             Delete uploaded objects after testing
  --debug               Show full AWS CLI commands and responses
  -h, --help            Show this help message

Size units: mb (MiB), gb (GiB), tb (TiB)

Multipart Part Sizing Rules:
  Object < 1GB    → 64MB parts
  Object < 10GB   → 128MB parts
  Object < 100GB  → 256MB parts
  Object < 500GB  → 512MB parts
  Object < 1TB    → 1024MB parts
  Object < 5TB    → 2048MB parts
  Object >= 5TB   → 4096MB parts

Examples:
  $0 --bucket test-bucket --min 100mb --max 1gb --step 100mb --cleanup
  $0 --bucket test-bucket --min 1gb --max 10tb --step 1gb --debug

AWS Credentials:
  The script uses AWS CLI's standard credential resolution:
  - Environment variables: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
  - AWS credentials file: ~/.aws/credentials
  - AWS config file: ~/.aws/config
  - IAM roles (if running on EC2/ECS)

EOF
    exit 1
}

# Parse size with unit (mb, gb, tb) and convert to bytes
parse_size() {
    local size_str=$1
    local value
    local unit

    # Extract numeric value and unit
    if [[ $size_str =~ ^([0-9]+)(mb|gb|tb)$ ]]; then
        value="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[2]}"
    else
        echo -e "${RED}Error: Invalid size format '$size_str'. Use format: <number><unit> (e.g., 100mb, 1gb, 10tb)${NC}" >&2
        exit 1
    fi

    # Convert to bytes
    case $unit in
        mb)
            echo $((value * 1024 * 1024))
            ;;
        gb)
            echo $((value * 1024 * 1024 * 1024))
            ;;
        tb)
            echo $((value * 1024 * 1024 * 1024 * 1024))
            ;;
    esac
}

# Get the smallest unit from min, max, step
get_smallest_unit() {
    local min_unit max_unit step_unit

    [[ $MIN_SIZE =~ (mb|gb|tb)$ ]] && min_unit="${BASH_REMATCH[1]}"
    [[ $MAX_SIZE =~ (mb|gb|tb)$ ]] && max_unit="${BASH_REMATCH[1]}"
    [[ $STEP =~ (mb|gb|tb)$ ]] && step_unit="${BASH_REMATCH[1]}"

    # mb is smallest, then gb, then tb
    if [[ "$min_unit" == "mb" ]] || [[ "$max_unit" == "mb" ]] || [[ "$step_unit" == "mb" ]]; then
        echo "mb"
    elif [[ "$min_unit" == "gb" ]] || [[ "$max_unit" == "gb" ]] || [[ "$step_unit" == "gb" ]]; then
        echo "gb"
    else
        echo "tb"
    fi
}

# Convert bytes to display unit
bytes_to_unit() {
    local bytes=$1
    local unit=$2

    case $unit in
        mb)
            echo $((bytes / 1024 / 1024))
            ;;
        gb)
            echo $((bytes / 1024 / 1024 / 1024))
            ;;
        tb)
            echo $((bytes / 1024 / 1024 / 1024 / 1024))
            ;;
    esac
}

# Format size for human-readable display
format_size() {
    local bytes=$1

    if ((bytes >= 1099511627776)); then
        echo "$(awk "BEGIN {printf \"%.2f\", $bytes/1099511627776}")tb"
    elif ((bytes >= 1073741824)); then
        echo "$(awk "BEGIN {printf \"%.2f\", $bytes/1073741824}")gb"
    else
        echo "$(awk "BEGIN {printf \"%.2f\", $bytes/1048576}")mb"
    fi
}

# Calculate part size based on object size
calculate_part_size() {
    local object_size=$1
    local part_size

    if ((object_size < 107374182400)); then
        # < 100GB: keep existing rules (64MB-256MB based on size)
        if ((object_size < 1073741824)); then
            # < 1GB: use 64MB parts
            part_size=$((64 * 1024 * 1024))
        elif ((object_size < 10737418240)); then
            # < 10GB: use 128MB parts
            part_size=$((128 * 1024 * 1024))
        else
            # < 100GB: use 256MB parts
            part_size=$((256 * 1024 * 1024))
        fi
    elif ((object_size < 536870912000)); then
        # < 500GB: use 512MB parts
        part_size=$((512 * 1024 * 1024))
    elif ((object_size < 1099511627776)); then
        # < 1TB: use 1024MB parts
        part_size=$((1024 * 1024 * 1024))
    elif ((object_size < 5497558138880)); then
        # < 5TB: use 2048MB parts
        part_size=$((2048 * 1024 * 1024))
    else
        # >= 5TB: use 4096MB parts
        part_size=$((4096 * 1024 * 1024))
    fi

    echo "$part_size"
}

# Generate random suffix
generate_random_suffix() {
    head -c 32 /dev/urandom | tr -dc 'a-z0-9' | head -c 8
}

# Create part file with random data
create_part_file() {
    local size_bytes=$1
    local filename=$2

    if ! dd if=/dev/urandom of="$filename" bs=1M count=$((size_bytes / 1048576)) iflag=fullblock 2>/dev/null; then
        echo -e "${RED}Error: Failed to create part file${NC}" >&2
        return 1
    fi

    if [[ ! -f "$filename" ]]; then
        echo -e "${RED}Error: Part file was not created${NC}" >&2
        return 1
    fi
}

# Initiate multipart upload
initiate_multipart_upload() {
    local s3_key=$1
    local output
    local result
    local cmd="aws s3api create-multipart-upload --bucket \"$BUCKET\" --key \"$s3_key\" --endpoint-url \"$ENDPOINT\" --no-verify-ssl"

    if [[ "$DEBUG" == true ]]; then
        echo -e "${YELLOW}[DEBUG] Command: $cmd${NC}" >&2
    fi

    output=$(aws s3api create-multipart-upload \
        --bucket "$BUCKET" \
        --key "$s3_key" \
        --endpoint-url "$ENDPOINT" \
        --no-verify-ssl 2>&1)
    result=$?

    if [[ "$DEBUG" == true ]]; then
        echo -e "${YELLOW}[DEBUG] Exit code: $result${NC}" >&2
        echo -e "${YELLOW}[DEBUG] Response:${NC}" >&2
        echo "$output" >&2
    fi

    if [[ $result -ne 0 ]]; then
        return 1
    fi

    echo "$output" | grep -oP '"UploadId":\s*"\K[^"]+' || return 1
}

# Upload a single part
upload_part() {
    local filename=$1
    local s3_key=$2
    local upload_id=$3
    local part_number=$4
    local output
    local result
    local cmd="aws s3api upload-part --bucket \"$BUCKET\" --key \"$s3_key\" --part-number $part_number --body \"$filename\" --upload-id \"$upload_id\" --endpoint-url \"$ENDPOINT\" --no-verify-ssl"

    if [[ "$DEBUG" == true ]]; then
        echo -e "${YELLOW}[DEBUG] Command: $cmd${NC}" >&2
    fi

    output=$(aws s3api upload-part \
        --bucket "$BUCKET" \
        --key "$s3_key" \
        --part-number "$part_number" \
        --body "$filename" \
        --upload-id "$upload_id" \
        --endpoint-url "$ENDPOINT" \
        --no-verify-ssl 2>&1)
    result=$?

    if [[ "$DEBUG" == true ]]; then
        echo -e "${YELLOW}[DEBUG] Exit code: $result${NC}" >&2
        echo -e "${YELLOW}[DEBUG] Response:${NC}" >&2
        echo "$output" >&2
    fi

    if [[ $result -ne 0 ]]; then
        return 1
    fi

    echo "$output" | grep -oP '"ETag":\s*"\\"\K[^\\]+' || return 1
}

# Complete multipart upload
complete_multipart_upload() {
    local s3_key=$1
    local upload_id=$2
    local parts_json=$3
    local output
    local cmd="aws s3api complete-multipart-upload --bucket \"$BUCKET\" --key \"$s3_key\" --upload-id \"$upload_id\" --multipart-upload '$parts_json' --endpoint-url \"$ENDPOINT\" --no-verify-ssl"

    if [[ "$DEBUG" == true ]]; then
        echo -e "${YELLOW}[DEBUG] Command: $cmd${NC}" >&2
    fi

    if [[ "$DEBUG" == true ]]; then
        output=$(aws s3api complete-multipart-upload \
            --bucket "$BUCKET" \
            --key "$s3_key" \
            --upload-id "$upload_id" \
            --multipart-upload "$parts_json" \
            --endpoint-url "$ENDPOINT" \
            --no-verify-ssl 2>&1)
        local result=$?
        echo -e "${YELLOW}[DEBUG] Response: $output${NC}" >&2
        return $result
    else
        aws s3api complete-multipart-upload \
            --bucket "$BUCKET" \
            --key "$s3_key" \
            --upload-id "$upload_id" \
            --multipart-upload "$parts_json" \
            --endpoint-url "$ENDPOINT" \
            --no-verify-ssl \
            >/dev/null 2>&1
    fi
}

# Abort multipart upload
abort_multipart_upload() {
    local s3_key=$1
    local upload_id=$2
    local output
    local cmd="aws s3api abort-multipart-upload --bucket \"$BUCKET\" --key \"$s3_key\" --upload-id \"$upload_id\" --endpoint-url \"$ENDPOINT\" --no-verify-ssl"

    if [[ "$DEBUG" == true ]]; then
        echo -e "${YELLOW}[DEBUG] Command: $cmd${NC}" >&2
    fi

    if [[ "$DEBUG" == true ]]; then
        output=$(aws s3api abort-multipart-upload \
            --bucket "$BUCKET" \
            --key "$s3_key" \
            --upload-id "$upload_id" \
            --endpoint-url "$ENDPOINT" \
            --no-verify-ssl 2>&1)
        local result=$?
        echo -e "${YELLOW}[DEBUG] Response: $output${NC}" >&2
        return $result
    else
        aws s3api abort-multipart-upload \
            --bucket "$BUCKET" \
            --key "$s3_key" \
            --upload-id "$upload_id" \
            --endpoint-url "$ENDPOINT" \
            --no-verify-ssl \
            >/dev/null 2>&1
    fi
}

# Upload object using multipart upload
upload_multipart() {
    local object_size=$1
    local s3_key=$2
    local part_size part_count upload_id parts_json part_file
    local -a etags=()

    # Calculate part size and count
    part_size=$(calculate_part_size "$object_size")
    part_count=$(( (object_size + part_size - 1) / part_size ))

    echo -e "${BLUE}Part size: $(format_size $part_size), Part count: $part_count${NC}"

    # Initiate multipart upload
    echo -e "${BLUE}Initiating multipart upload...${NC}"
    upload_id=$(initiate_multipart_upload "$s3_key") || {
        echo -e "${RED}Failed to initiate multipart upload${NC}"
        return 1
    }

    echo -e "${GREEN}✓ Upload ID: $upload_id${NC}"
    ACTIVE_UPLOADS+=("$s3_key:$upload_id")

    # Create temporary part file
    part_file="/tmp/part_$(generate_random_suffix).data"

    # Upload each part
    for ((part_num=1; part_num<=part_count; part_num++)); do
        local current_part_size=$part_size
        local remaining_bytes=$((object_size - (part_num - 1) * part_size))

        if ((remaining_bytes < part_size)); then
            current_part_size=$remaining_bytes
        fi

        echo -e "${BLUE}Uploading part $part_num/$part_count ($(format_size $current_part_size))...${NC}"

        # Create part file
        if ! create_part_file "$current_part_size" "$part_file"; then
            echo -e "${RED}Failed to create part file${NC}"
            abort_multipart_upload "$s3_key" "$upload_id"
            rm -f "$part_file"
            return 1
        fi

        # Upload part with retries
        local attempt=1
        local etag=""

        while ((attempt <= MAX_RETRIES)); do
            etag=$(upload_part "$part_file" "$s3_key" "$upload_id" "$part_num")
            if [[ -n "$etag" ]]; then
                # Debug: show raw etag value
                if [[ "$DEBUG" == true ]]; then
                    echo "[DEBUG] Raw etag value: [$etag]" >&2
                    echo "[DEBUG] etag length: ${#etag}" >&2
                fi
                printf "${GREEN}✓ Part %d uploaded (ETag: %s)${NC}\n" "$part_num" "$etag"
                etags+=("$etag")
                break
            else
                if ((attempt < MAX_RETRIES)); then
                    echo -e "${YELLOW}✗ Part upload failed, retrying...${NC}"
                    ((attempt++))
                    sleep 2
                else
                    echo -e "${RED}✗ Part upload failed after $MAX_RETRIES attempts${NC}"
                    abort_multipart_upload "$s3_key" "$upload_id"
                    rm -f "$part_file"
                    return 1
                fi
            fi
        done

        # Clean up part file after upload
        rm -f "$part_file"
    done

    # Build parts JSON
    parts_json='{"Parts":['
    for ((i=0; i<${#etags[@]}; i++)); do
        if ((i > 0)); then
            parts_json+=','
        fi
        parts_json+="{\"ETag\":\"${etags[$i]}\",\"PartNumber\":$((i+1))}"
    done
    parts_json+=']}'

    # Complete multipart upload
    echo -e "${BLUE}Completing multipart upload...${NC}"
    if complete_multipart_upload "$s3_key" "$upload_id" "$parts_json"; then
        echo -e "${GREEN}✓ Multipart upload completed${NC}"
        # Remove from active uploads by rebuilding array without this entry
        local -a new_uploads=()
        for upload_info in "${ACTIVE_UPLOADS[@]}"; do
            if [[ "$upload_info" != "$s3_key:$upload_id" ]]; then
                new_uploads+=("$upload_info")
            fi
        done
        ACTIVE_UPLOADS=("${new_uploads[@]}")
        return 0
    else
        echo -e "${RED}✗ Failed to complete multipart upload${NC}"
        abort_multipart_upload "$s3_key" "$upload_id"
        return 1
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

# Cleanup active multipart uploads
cleanup_active_uploads() {
    if [[ ${#ACTIVE_UPLOADS[@]} -eq 0 ]]; then
        return
    fi

    echo -e "\n${YELLOW}Aborting active multipart uploads...${NC}"

    for upload_info in "${ACTIVE_UPLOADS[@]}"; do
        IFS=':' read -r s3_key upload_id <<< "$upload_info"
        echo -e "${BLUE}Aborting upload for $s3_key (ID: $upload_id)...${NC}"
        if abort_multipart_upload "$s3_key" "$upload_id"; then
            echo -e "${GREEN}✓ Aborted${NC}"
        else
            echo -e "${YELLOW}✗ Failed to abort${NC}"
        fi
    done
}

# Trap to ensure cleanup on exit
cleanup_on_exit() {
    cleanup_active_uploads
}

trap cleanup_on_exit EXIT

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
        --debug)
            DEBUG=true
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

# Parse sizes
MIN_BYTES=$(parse_size "$MIN_SIZE")
MAX_BYTES=$(parse_size "$MAX_SIZE")
STEP_BYTES=$(parse_size "$STEP")

# Validate minimum size (must be >= 100MB)
MIN_REQUIRED=$((100 * 1024 * 1024))
if ((MIN_BYTES < MIN_REQUIRED)); then
    echo -e "${RED}Error: Minimum size must be at least 100mb (got $MIN_SIZE)${NC}" >&2
    exit 1
fi

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
echo -e "${BLUE}S3 Multipart Upload Maximum Size Probe${NC}"
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
    filename="multipart_${size_in_unit}${DISPLAY_UNIT}_${random_suffix}.data"
    s3_key="$filename"

    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}Test $test_count: $(format_size $current_bytes)${NC}"
    echo -e "${BLUE}========================================${NC}"

    # Upload using multipart
    upload_start=$(date +%s)
    if upload_multipart "$current_bytes" "$s3_key"; then
        upload_end=$(date +%s)
        upload_duration=$((upload_end - upload_start))

        max_successful_bytes=$current_bytes
        UPLOADED_FILES+=("$s3_key")
        TEST_RESULTS+=("$(format_size $current_bytes): SUCCESS (${upload_duration}s)")
    else
        TEST_RESULTS+=("$(format_size $current_bytes): FAILED")
        echo -e "${RED}Upload failed, stopping tests${NC}"
        break
    fi

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
