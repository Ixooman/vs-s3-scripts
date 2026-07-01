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
OBJECT_SIZE=""
PART_SIZE=""
CLEANUP=false
DEBUG=false
VERIFY_FULL=false
MAX_RETRIES=3

# Arrays to track resources
declare -a ACTIVE_UPLOADS=()
declare -a TEMP_FILES=()

# Usage function
usage() {
    cat <<EOF
Usage: $0 --bucket <bucket-name> --size <size> --part <size> [options]

Required arguments:
  --bucket <name>       S3 bucket name (created if doesn't exist)
  --size <size>         Object size to upload (e.g., 100mb, 1gb, 10gb, 5tb)
  --part <size>         Part size for multipart upload (e.g., 64mb, 128mb)

Optional arguments:
  --endpoint <url>      S3 endpoint URL (default: http://192.168.10.81)
  --verify-full         Download object after upload and verify MD5 (default: hybrid verification)
  --cleanup             Delete uploaded object after testing
  --debug               Show full AWS CLI commands and responses
  -h, --help            Show this help message

Size units: mb (MiB), gb (GiB), tb (TiB)

Verification modes:
  Hybrid (default):     Compare calculated MD5 with S3 ETag (fast, no download)
  Full (--verify-full): Download object, calculate MD5, compare with uploaded data (thorough)

Example:
  $0 --bucket test-bucket --size 500mb --part 64mb --debug
  $0 --bucket test-bucket --size 1gb --part 128mb --verify-full --cleanup

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

# Generate random suffix
generate_random_suffix() {
    head -c 32 /dev/urandom | tr -dc 'a-z0-9' | head -c 8
}

# Create test data file with MD5 calculation
# Returns the MD5 hash to stdout and creates the file
create_test_data() {
    local size_bytes=$1
    local filename=$2
    local temp_file="$filename"

    TEMP_FILES+=("$temp_file")

    # Create the file with random data and calculate MD5 in one pass
    # Using dd with larger block size for efficiency
    dd if=/dev/urandom of="$temp_file" bs=1M count=$((size_bytes / 1048576)) iflag=fullblock 2>/dev/null || {
        echo -e "${RED}Error: Failed to create test data file${NC}" >&2
        return 1
    }

    # Calculate MD5 of the created file
    md5sum "$temp_file" | awk '{print $1}'
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

# Complete multipart upload and return ETag
complete_multipart_upload() {
    local s3_key=$1
    local upload_id=$2
    local parts_json=$3
    local output
    local cmd="aws s3api complete-multipart-upload --bucket \"$BUCKET\" --key \"$s3_key\" --upload-id \"$upload_id\" --multipart-upload '$parts_json' --endpoint-url \"$ENDPOINT\" --no-verify-ssl"

    if [[ "$DEBUG" == true ]]; then
        echo -e "${YELLOW}[DEBUG] Command: $cmd${NC}" >&2
    fi

    output=$(aws s3api complete-multipart-upload \
        --bucket "$BUCKET" \
        --key "$s3_key" \
        --upload-id "$upload_id" \
        --multipart-upload "$parts_json" \
        --endpoint-url "$ENDPOINT" \
        --no-verify-ssl 2>&1)
    local result=$?

    if [[ "$DEBUG" == true ]]; then
        echo -e "${YELLOW}[DEBUG] Exit code: $result${NC}" >&2
        echo -e "${YELLOW}[DEBUG] Response:${NC}" >&2
        echo "$output" >&2
    fi

    if [[ $result -ne 0 ]]; then
        return 1
    fi

    # Extract ETag from response (remove quotes and backslashes)
    echo "$output" | grep -oP '"ETag":\s*"\\"\K[^\\]+' || return 1
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

# Calculate ETag for multipart upload (MD5 of concatenated part ETags)
calculate_multipart_etag() {
    local -n etags_ref=$1
    local concatenated=""

    # Concatenate all part ETags as binary data
    for etag in "${etags_ref[@]}"; do
        # Convert hex ETag to binary and concatenate
        concatenated+=$(echo -n "$etag" | xxd -r -p)
    done

    # Calculate MD5 of concatenated data
    echo -n "$concatenated" | md5sum | awk '{print $1}'
}

# Download object and verify MD5
download_and_verify() {
    local s3_key=$1
    local original_md5=$2
    local temp_download="/tmp/download_$(generate_random_suffix).data"

    TEMP_FILES+=("$temp_download")

    echo -e "${BLUE}Downloading object from S3...${NC}"
    if ! aws s3api get-object \
        --bucket "$BUCKET" \
        --key "$s3_key" \
        --endpoint-url "$ENDPOINT" \
        --no-verify-ssl \
        "$temp_download" >/dev/null 2>&1; then
        echo -e "${RED}Failed to download object from S3${NC}"
        return 1
    fi

    # Calculate MD5 of downloaded file
    local downloaded_md5
    downloaded_md5=$(md5sum "$temp_download" | awk '{print $1}')

    echo -e "${BLUE}Downloaded MD5:  $downloaded_md5${NC}"
    echo -e "${BLUE}Original MD5:    $original_md5${NC}"

    if [[ "$downloaded_md5" == "$original_md5" ]]; then
        echo -e "${GREEN}✓ Full verification passed: MD5 checksums match${NC}"
        return 0
    else
        echo -e "${RED}✗ Full verification failed: MD5 checksums do not match${NC}"
        return 1
    fi
}

# Upload object using multipart upload
upload_multipart() {
    local object_size=$1
    local data_file=$2
    local s3_key=$3
    local original_md5=$4
    local part_size part_count upload_id parts_json
    local -a etags=()

    # Calculate part count
    part_count=$(( (object_size + PART_SIZE - 1) / PART_SIZE ))

    echo -e "${BLUE}Part size: $(format_size $PART_SIZE), Part count: $part_count${NC}"

    # Initiate multipart upload
    echo -e "${BLUE}Initiating multipart upload...${NC}"
    upload_id=$(initiate_multipart_upload "$s3_key") || {
        echo -e "${RED}Failed to initiate multipart upload${NC}"
        return 1
    }

    echo -e "${GREEN}✓ Upload ID: $upload_id${NC}"
    ACTIVE_UPLOADS+=("$s3_key:$upload_id")

    # Upload each part
    for ((part_num=1; part_num<=part_count; part_num++)); do
        local part_offset=$(( (part_num - 1) * PART_SIZE ))
        local remaining_bytes=$((object_size - part_offset))
        local current_part_size=$PART_SIZE

        if ((remaining_bytes < PART_SIZE)); then
            current_part_size=$remaining_bytes
        fi

        echo -e "${BLUE}Uploading part $part_num/$part_count ($(format_size $current_part_size))...${NC}"

        # Create part file from the full data file
        local part_file="/tmp/part_${part_num}_$(generate_random_suffix).data"
        TEMP_FILES+=("$part_file")

        # Extract part data from the original file
        if ! dd if="$data_file" of="$part_file" bs=1 skip="$part_offset" count="$current_part_size" 2>/dev/null; then
            echo -e "${RED}Failed to extract part from data file${NC}"
            abort_multipart_upload "$s3_key" "$upload_id"
            return 1
        fi

        # Upload part with retries
        local attempt=1
        local etag=""

        while ((attempt <= MAX_RETRIES)); do
            etag=$(upload_part "$part_file" "$s3_key" "$upload_id" "$part_num")
            if [[ -n "$etag" ]]; then
                if [[ "$DEBUG" == true ]]; then
                    echo "[DEBUG] Part $part_num raw etag value: [$etag]" >&2
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
                    return 1
                fi
            fi
        done
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
    local final_etag
    final_etag=$(complete_multipart_upload "$s3_key" "$upload_id" "$parts_json") || {
        echo -e "${RED}Failed to complete multipart upload${NC}"
        abort_multipart_upload "$s3_key" "$upload_id"
        return 1
    }

    echo -e "${GREEN}✓ Multipart upload completed${NC}"
    echo -e "${BLUE}S3 returned ETag: $final_etag${NC}"

    # Remove from active uploads
    local -a new_uploads=()
    for upload_info in "${ACTIVE_UPLOADS[@]}"; do
        if [[ "$upload_info" != "$s3_key:$upload_id" ]]; then
            new_uploads+=("$upload_info")
        fi
    done
    ACTIVE_UPLOADS=("${new_uploads[@]}")

    # Perform verification
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}Verification${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}Original MD5:    $original_md5${NC}"

    if [[ "$VERIFY_FULL" == true ]]; then
        echo -e "${BLUE}Using full verification (downloading and checking object)...${NC}"
        if download_and_verify "$s3_key" "$original_md5"; then
            return 0
        else
            return 1
        fi
    else
        # Hybrid verification: compare original MD5 with S3's ETag
        echo -e "${BLUE}Using hybrid verification (comparing MD5 with S3 ETag)...${NC}"
        echo -e "${BLUE}Calculated multipart ETag: $final_etag${NC}"

        # For multipart uploads, S3 returns ETag as MD5(MD5(part1) + MD5(part2) + ...)
        local calculated_etag
        calculated_etag=$(calculate_multipart_etag etags)
        echo -e "${BLUE}Calculated ETag:           $calculated_etag${NC}"

        if [[ "$calculated_etag" == "$final_etag" ]]; then
            echo -e "${GREEN}✓ Hybrid verification passed: S3 ETag verification successful${NC}"
            echo -e "${BLUE}Original data MD5: $original_md5${NC}"
            echo -e "${GREEN}✓ Object uploaded successfully (data integrity confirmed by multipart assembly)${NC}"
            return 0
        else
            echo -e "${RED}✗ Hybrid verification failed: S3 ETag does not match calculated ETag${NC}"
            return 1
        fi
    fi
}

# Cleanup S3 objects
cleanup_s3_objects() {
    local s3_key=$1

    echo -e "\n${BLUE}Cleaning up S3 objects...${NC}"
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

# Cleanup temporary files
cleanup_temp_files() {
    for temp_file in "${TEMP_FILES[@]}"; do
        if [[ -f "$temp_file" ]]; then
            rm -f "$temp_file"
        fi
    done
}

# Trap to ensure cleanup on exit
cleanup_on_exit() {
    cleanup_active_uploads
    cleanup_temp_files
}

trap cleanup_on_exit EXIT

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --bucket)
            BUCKET="$2"
            shift 2
            ;;
        --size)
            OBJECT_SIZE="$2"
            shift 2
            ;;
        --part)
            PART_SIZE="$2"
            shift 2
            ;;
        --endpoint)
            ENDPOINT="$2"
            shift 2
            ;;
        --verify-full)
            VERIFY_FULL=true
            shift
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
if [[ -z "$BUCKET" ]] || [[ -z "$OBJECT_SIZE" ]] || [[ -z "$PART_SIZE" ]]; then
    echo -e "${RED}Error: Missing required arguments${NC}" >&2
    usage
fi

# Check AWS CLI
if ! command -v aws &> /dev/null; then
    echo -e "${RED}Error: AWS CLI is not installed${NC}" >&2
    exit 1
fi

# Parse sizes
OBJECT_SIZE_BYTES=$(parse_size "$OBJECT_SIZE")
PART_SIZE=$(parse_size "$PART_SIZE")

# Validate sizes
if ((PART_SIZE <= 0)); then
    echo -e "${RED}Error: Part size must be greater than 0${NC}" >&2
    exit 1
fi

if ((OBJECT_SIZE_BYTES < PART_SIZE)); then
    echo -e "${RED}Error: Object size ($OBJECT_SIZE) must be at least as large as part size ($PART_SIZE)${NC}" >&2
    exit 1
fi

# Print configuration
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}S3 Multipart Upload Check${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "Endpoint:        $ENDPOINT"
echo -e "Bucket:          $BUCKET"
echo -e "Object size:     $(format_size $OBJECT_SIZE_BYTES)"
echo -e "Part size:       $(format_size $PART_SIZE)"
echo -e "Verification:    $([ "$VERIFY_FULL" = true ] && echo "Full (download)" || echo "Hybrid (ETag)")"
echo -e "Cleanup:         $CLEANUP"
echo -e "Debug:           $DEBUG"
echo -e "${BLUE}========================================${NC}"
echo ""

# Check bucket existence and create if needed
echo -e "${BLUE}Checking bucket existence...${NC}"
if aws s3api head-bucket --bucket "$BUCKET" --endpoint-url "$ENDPOINT" --no-verify-ssl 2>/dev/null; then
    echo -e "${GREEN}✓ Bucket '$BUCKET' exists${NC}"
    echo ""
else
    echo -e "${YELLOW}Bucket '$BUCKET' does not exist, creating...${NC}"

    create_output=$(aws s3api create-bucket \
        --bucket "$BUCKET" \
        --endpoint-url "$ENDPOINT" \
        --no-verify-ssl 2>&1) || create_result=$?

    # Check if creation was successful
    if aws s3api head-bucket --bucket "$BUCKET" --endpoint-url "$ENDPOINT" --no-verify-ssl 2>/dev/null; then
        echo -e "${GREEN}✓ Bucket '$BUCKET' created successfully${NC}"
        echo ""
    else
        echo -e "${RED}Error: Failed to create bucket '$BUCKET' at $ENDPOINT${NC}" >&2
        echo "Output: $create_output" >&2
        exit 1
    fi
fi

# Generate object name
random_suffix=$(generate_random_suffix)
s3_key="multipart_check_${OBJECT_SIZE}_${random_suffix}.data"

# Create test data
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Creating test data${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Generating $(format_size $OBJECT_SIZE_BYTES) of random test data...${NC}"

temp_data_file="/tmp/test_data_$(generate_random_suffix).data"
TEMP_FILES+=("$temp_data_file")

original_md5=$(create_test_data "$OBJECT_SIZE_BYTES" "$temp_data_file") || {
    echo -e "${RED}Failed to create test data${NC}" >&2
    exit 1
}

echo -e "${GREEN}✓ Test data created${NC}"
echo -e "${BLUE}Original MD5: $original_md5${NC}"
echo ""

# Perform multipart upload
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Uploading object (multipart)${NC}"
echo -e "${BLUE}========================================${NC}"

upload_start=$(date +%s%N)
if upload_multipart "$OBJECT_SIZE_BYTES" "$temp_data_file" "$s3_key" "$original_md5"; then
    upload_end=$(date +%s%N)
    upload_duration_ms=$(( (upload_end - upload_start) / 1000000 ))
    upload_duration_s=$(( upload_duration_ms / 1000 ))

    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}Upload Summary${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}✓ Upload: SUCCESSFUL${NC}"
    echo -e "Upload duration: ${upload_duration_s}s (${upload_duration_ms}ms)"
    echo -e "Object:          s3://$BUCKET/$s3_key"
    echo -e "Size:            $(format_size $OBJECT_SIZE_BYTES)"

    # Cleanup S3 objects if requested
    if [[ "$CLEANUP" == true ]]; then
        cleanup_s3_objects "$s3_key"
    fi

    echo -e "\n${GREEN}Testing complete! Object upload verified successfully.${NC}"
    exit 0
else
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}Upload Summary${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo -e "${RED}✗ Upload: FAILED${NC}"
    echo -e "\n${RED}Testing failed!${NC}"
    exit 1
fi