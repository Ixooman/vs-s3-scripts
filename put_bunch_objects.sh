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
SIZE=""
COUNT=""
UNIQUE=1
CLEANUP=false
DEBUG=false
MAX_RETRIES=3

# Arrays to track resources
declare -a TEMPLATE_FILES=()
declare -a UPLOADED_OBJECTS=()

# Usage function
usage() {
    cat <<EOF
Usage: $0 --bucket <bucket-name> --size <size> --count <number> [options]

Required arguments:
  --bucket <name>       S3 bucket name
  --size <size>         Size of each object (e.g., 16kb, 1mb, 1gb)
  --count/-n <number>   Number of objects to upload

Optional arguments:
  --unique <number>     Number of unique template files (default: 1)
  --endpoint <url>      S3 endpoint URL (default: http://192.168.10.81)
  --cleanup             Delete uploaded objects after testing
  --debug               Show full AWS CLI commands and responses
  -h, --help            Show this help message

Size units: kb (KiB), mb (MiB), gb (GiB)

Examples:
  $0 --bucket test-bucket --size 10mb --count 100
  $0 --bucket test-bucket --size 5mb -n 50 --unique 5 --cleanup
  $0 --bucket test-bucket --size 1gb --count 10 --unique 3 --debug

Description:
  This script generates a specified number of template files with random data
  and uses them to upload objects to S3. When uploading multiple objects with
  fewer unique templates, the script cycles through the template files.

  Example: --unique 3 --count 10 creates 3 template files and uploads 10 objects
  by cycling through templates: file1, file2, file3, file1, file2, file3, ...

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

# Create template file with random data
create_template_file() {
    local size_bytes=$1
    local filename=$2

    echo -e "${BLUE}Generating template $filename ($(format_size $size_bytes))...${NC}"

    if ((size_bytes >= 1048576)); then
        # For files >= 1MB, use 1MB blocks for efficiency
        if ! dd if=/dev/urandom of="$filename" bs=1M count=$((size_bytes / 1048576)) iflag=fullblock 2>/dev/null; then
            echo -e "${RED}Error: Failed to create template file${NC}" >&2
            return 1
        fi
    else
        # For smaller files, use exact byte count
        if ! dd if=/dev/urandom of="$filename" bs=1 count="$size_bytes" 2>/dev/null; then
            echo -e "${RED}Error: Failed to create template file${NC}" >&2
            return 1
        fi
    fi

    if [[ ! -f "$filename" ]]; then
        echo -e "${RED}Error: Template file not created${NC}" >&2
        return 1
    fi

    echo -e "${GREEN}✓ Template created${NC}"
}

# Upload file to S3 with retries
upload_to_s3() {
    local filename=$1
    local s3_key=$2
    local attempt=1

    while ((attempt <= MAX_RETRIES)); do
        if [[ "$DEBUG" == true ]]; then
            echo -e "${BLUE}Upload attempt $attempt/$MAX_RETRIES...${NC}"
        fi

        local start_time=$(date +%s)

        if [[ "$DEBUG" == true ]]; then
            echo -e "${YELLOW}Command: aws s3api put-object --bucket \"$BUCKET\" --key \"$s3_key\" --body \"$filename\" --endpoint-url \"$ENDPOINT\" --no-verify-ssl${NC}"
        fi

        local upload_output
        local upload_result=0

        if [[ "$DEBUG" == true ]]; then
            upload_output=$(aws s3api put-object \
                --bucket "$BUCKET" \
                --key "$s3_key" \
                --body "$filename" \
                --endpoint-url "$ENDPOINT" \
                --no-verify-ssl 2>&1) || upload_result=$?

            if ((upload_result == 0)); then
                echo -e "${YELLOW}Response: $upload_output${NC}"
            else
                echo -e "${RED}Error: $upload_output${NC}"
            fi
        else
            aws s3api put-object \
                --bucket "$BUCKET" \
                --key "$s3_key" \
                --body "$filename" \
                --endpoint-url "$ENDPOINT" \
                --no-verify-ssl \
                >/dev/null 2>&1 || upload_result=$?
        fi

        if ((upload_result == 0)); then
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

# Cleanup template files
cleanup_template_files() {
    if [[ ${#TEMPLATE_FILES[@]} -eq 0 ]]; then
        return
    fi

    echo -e "\n${BLUE}Cleaning up template files...${NC}"

    for filename in "${TEMPLATE_FILES[@]}"; do
        if [[ -f "$filename" ]]; then
            rm -f "$filename"
            echo -e "${GREEN}✓ Deleted $filename${NC}"
        fi
    done
}

# Cleanup S3 objects
cleanup_s3_objects() {
    if [[ ${#UPLOADED_OBJECTS[@]} -eq 0 ]]; then
        return
    fi

    echo -e "\n${BLUE}Cleaning up S3 objects...${NC}"

    for s3_key in "${UPLOADED_OBJECTS[@]}"; do
        echo -e "${BLUE}Deleting s3://$BUCKET/$s3_key...${NC}"

        if [[ "$DEBUG" == true ]]; then
            echo -e "${YELLOW}Command: aws s3api delete-object --bucket \"$BUCKET\" --key \"$s3_key\" --endpoint-url \"$ENDPOINT\" --no-verify-ssl${NC}"
        fi

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

# Trap to ensure cleanup on exit
trap 'cleanup_template_files' EXIT

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
        --size)
            SIZE="$2"
            shift 2
            ;;
        --count|-n)
            COUNT="$2"
            shift 2
            ;;
        --unique)
            UNIQUE="$2"
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
if [[ -z "$BUCKET" ]] || [[ -z "$SIZE" ]] || [[ -z "$COUNT" ]]; then
    echo -e "${RED}Error: Missing required arguments${NC}" >&2
    usage
fi

# Validate numeric arguments
if ! [[ "$COUNT" =~ ^[0-9]+$ ]] || ((COUNT <= 0)); then
    echo -e "${RED}Error: --count must be a positive integer${NC}" >&2
    exit 1
fi

if ! [[ "$UNIQUE" =~ ^[0-9]+$ ]] || ((UNIQUE <= 0)); then
    echo -e "${RED}Error: --unique must be a positive integer${NC}" >&2
    exit 1
fi

if ((UNIQUE > COUNT)); then
    echo -e "${YELLOW}Warning: --unique ($UNIQUE) is greater than --count ($COUNT). Setting --unique to $COUNT${NC}"
    UNIQUE=$COUNT
fi

# Check AWS CLI
if ! command -v aws &> /dev/null; then
    echo -e "${RED}Error: AWS CLI is not installed${NC}" >&2
    exit 1
fi

# Parse size
SIZE_BYTES=$(parse_size "$SIZE")

# Print configuration
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}S3 Bulk Object Upload${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "Endpoint:        $ENDPOINT"
echo -e "Bucket:          $BUCKET"
echo -e "Object size:     $(format_size $SIZE_BYTES)"
echo -e "Object count:    $COUNT"
echo -e "Unique files:    $UNIQUE"
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

    if [[ "$DEBUG" == true ]]; then
        echo -e "${YELLOW}Command: aws s3api create-bucket --bucket \"$BUCKET\" --endpoint-url \"$ENDPOINT\" --no-verify-ssl${NC}"
    fi

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

# Generate template files
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Creating Template Files${NC}"
echo -e "${BLUE}========================================${NC}"

for ((i=1; i<=UNIQUE; i++)); do
    random_suffix=$(generate_random_suffix)
    template_name="template_${i}_${random_suffix}.data"

    if ! create_template_file "$SIZE_BYTES" "$template_name"; then
        echo -e "${RED}Failed to create template files, aborting${NC}"
        exit 1
    fi

    TEMPLATE_FILES+=("$template_name")
done

echo -e "${GREEN}✓ All template files created${NC}"
echo ""

# Upload objects
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Uploading Objects${NC}"
echo -e "${BLUE}========================================${NC}"

successful_uploads=0
failed_uploads=0
total_upload_time=0

for ((i=1; i<=COUNT; i++)); do
    # Calculate which template file to use (cycle through templates)
    template_index=$(((i - 1) % UNIQUE))
    template_file="${TEMPLATE_FILES[$template_index]}"

    # Generate unique S3 key
    random_suffix=$(generate_random_suffix)
    s3_key="object_${i}_${random_suffix}.data"

    echo -e "\n${BLUE}Object $i/$COUNT (using template $((template_index + 1))/$UNIQUE)${NC}"
    echo -e "${BLUE}Key: $s3_key${NC}"

    # Upload to S3
    upload_start=$(date +%s)
    if upload_to_s3 "$template_file" "$s3_key"; then
        upload_end=$(date +%s)
        upload_duration=$((upload_end - upload_start))
        total_upload_time=$((total_upload_time + upload_duration))

        successful_uploads=$((successful_uploads + 1))
        UPLOADED_OBJECTS+=("$s3_key")
    else
        failed_uploads=$((failed_uploads + 1))
        echo -e "${RED}Upload failed for object $i${NC}"
    fi
done

# Print summary
echo -e "\n${BLUE}========================================${NC}"
echo -e "${BLUE}Upload Summary${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "Total objects:       $COUNT"
echo -e "Successful uploads:  ${GREEN}$successful_uploads${NC}"
echo -e "Failed uploads:      ${RED}$failed_uploads${NC}"
echo -e "Template files used: $UNIQUE"
echo -e "Total upload time:   ${total_upload_time}s"

if ((successful_uploads > 0)); then
    avg_time=$((total_upload_time / successful_uploads))
    echo -e "Average time/object: ${avg_time}s"
fi

echo ""

# Cleanup S3 objects if requested
if [[ "$CLEANUP" == true ]]; then
    cleanup_s3_objects
fi

# Template files are automatically cleaned up by trap

if ((failed_uploads == 0)); then
    echo -e "${GREEN}All uploads completed successfully!${NC}"
    exit 0
else
    echo -e "${YELLOW}Completed with $failed_uploads failed upload(s)${NC}"
    exit 1
fi