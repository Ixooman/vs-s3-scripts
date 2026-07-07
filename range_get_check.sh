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
GETS=100
MULTIPART=false
RANGE_MAX="16mb"
RANDOM_ONLY=false
CLEANUP=false
DEBUG=false
MAX_RETRIES=3

# Arrays to track resources
declare -a TEMP_FILES=()
declare -a ACTIVE_UPLOADS=()

# Arrays describing multipart part layout (populated only when --multipart is used)
declare -a PART_OFFSETS=()
declare -a PART_SIZES=()

# Arrays describing range test cases (label, start, end)
declare -a CASE_LABELS=()
declare -a CASE_STARTS=()
declare -a CASE_ENDS=()

# Test accounting
TEST_COUNT=0
PASS_COUNT=0
FAIL_COUNT=0
declare -a FAILED_CASES=()

S3_KEY=""
DATA_FILE=""
UPLOADED=false

# Usage function
usage() {
    local exit_code=${1:-1}

    cat <<EOF
Usage: $0 --bucket <bucket-name> --size <size> [options]

Required arguments:
  --bucket <name>       S3 bucket name (created if it doesn't exist)
  --size <size>         Object size to upload (e.g., 100mb, 1gb)

Optional arguments:
  --gets <count>        Number of random ranged GetObject calls (default: 100)
  --multipart           Upload the object using multipart upload
  --range-max <size>    Maximum size of a random range (e.g., 64kb, 1mb, 16mb) (default: 16mb)
  --random-only         Skip deterministic boundary tests, run only random ranges
  --endpoint <url>      S3 endpoint URL (default: http://192.168.10.81)
  --cleanup             Delete uploaded object after testing
  --debug               Show full AWS CLI commands and responses
  -h, --help            Show this help message

Size units:
  --size: mb (MiB), gb (GiB)
  --range-max: kb (KiB), mb (MiB), gb (GiB)

Description:
  Uploads a single test object (regular put-object, or multipart upload with
  --multipart), then issues ranged GetObject requests against it and verifies
  that the returned bytes match the corresponding slice of the original data.

  For each successful ranged GetObject, the response's ContentLength and
  ContentRange metadata (from the AWS CLI JSON output) are validated against
  the requested range. AcceptRanges is checked when present, but a missing
  AcceptRanges only prints a warning and does not fail the test.

  Deterministic boundary cases are always tested first: first byte, a small
  prefix, the last byte, and a tail range. When --multipart is used, boundary
  cases for part boundaries are added too: a range fully inside a part, a
  range ending exactly at a part boundary, a range starting exactly at a part
  boundary, a range crossing one part boundary, and (if there are at least 3
  parts) a range crossing multiple part boundaries.

  After the deterministic cases, --gets random ranges are tested. Each random
  range starts at a random offset within the object, has a length between 1
  byte and --range-max, and never extends past the end of the object.

  --random-only skips all deterministic boundary cases (including multipart
  part-boundary cases) and runs only the --gets random ranges.

Examples:
  $0 --bucket test-bucket --size 100mb
  $0 --bucket test-bucket --size 500mb --multipart --gets 200 --cleanup
  $0 --bucket test-bucket --size 1gb --multipart --range-max 32mb --debug
  $0 --bucket test-bucket --size 100mb --range-max 64kb --gets 300
  $0 --bucket test-bucket --size 200mb --random-only --gets 500

AWS Credentials:
  The script uses AWS CLI's standard credential resolution:
  - Environment variables: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
  - AWS credentials file: ~/.aws/credentials
  - AWS config file: ~/.aws/config
  - IAM roles (if running on EC2/ECS)

EOF
    exit "$exit_code"
}

# Parse size with unit (mb, gb) and convert to bytes
parse_size() {
    local size_str=$1
    local value
    local unit

    if [[ $size_str =~ ^([0-9]+)(mb|gb)$ ]]; then
        value="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[2]}"
    else
        echo -e "${RED}Error: Invalid size format '$size_str'. Use format: <number><unit> (e.g., 100mb, 1gb)${NC}" >&2
        exit 1
    fi

    case $unit in
        mb)
            echo $((value * 1024 * 1024))
            ;;
        gb)
            echo $((value * 1024 * 1024 * 1024))
            ;;
    esac
}

# Parse size with unit (kb, mb, gb) and convert to bytes; used for
# --range-max, which additionally accepts kb (KiB) unlike --size
parse_range_size() {
    local size_str=$1
    local value
    local unit

    if [[ $size_str =~ ^([0-9]+)(kb|mb|gb)$ ]]; then
        value="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[2]}"
    else
        echo -e "${RED}Error: Invalid --range-max format '$size_str'. Use format: <number><unit> (e.g., 64kb, 1mb, 16mb). Accepted units: kb, mb, gb${NC}" >&2
        exit 1
    fi

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
    else
        echo "$(awk "BEGIN {printf \"%.2f\", $bytes/1048576}")mb"
    fi
}

# Generate random suffix
generate_random_suffix() {
    od -An -N4 -tx1 /dev/urandom | tr -d ' \n'
}

# Generate a random unsigned integer with up to 56 bits of entropy
random_uint() {
    local hex
    hex=$(od -An -N7 -tx1 /dev/urandom | tr -d ' \n')
    echo $((16#$hex))
}

# Compute part size for multipart upload: a handful of parts so that part
# boundary tests are meaningful, while respecting the S3 multipart rules
# (parts must be at least 5MiB except the final part, and there can be at
# most 10,000 parts).
calculate_part_size() {
    local object_size=$1
    local mib=$((1024 * 1024))
    local min_part=$((5 * mib))
    local max_parts=10000
    local part_size
    local min_for_max_parts

    part_size=$((object_size / 8))
    if ((part_size < min_part)); then
        part_size=$min_part
    fi

    # Round up to a whole MiB so part offsets stay block-aligned
    part_size=$(( ( (part_size + mib - 1) / mib ) * mib ))

    min_for_max_parts=$(( (object_size + max_parts - 1) / max_parts ))
    if ((part_size < min_for_max_parts)); then
        part_size=$(( ( (min_for_max_parts + mib - 1) / mib ) * mib ))
    fi

    echo "$part_size"
}

# Create local test data file with random content
create_test_data() {
    local size_bytes=$1
    local filename=$2

    TEMP_FILES+=("$filename")

    if ! dd if=/dev/urandom of="$filename" bs=1M count=$((size_bytes / 1048576)) iflag=fullblock 2>/dev/null; then
        echo -e "${RED}Error: Failed to create test data file${NC}" >&2
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
    local result
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
    result=$?

    if [[ "$DEBUG" == true ]]; then
        echo -e "${YELLOW}[DEBUG] Exit code: $result${NC}" >&2
        echo -e "${YELLOW}[DEBUG] Response:${NC}" >&2
        echo "$output" >&2
    fi

    return $result
}

# Abort multipart upload
abort_multipart_upload() {
    local s3_key=$1
    local upload_id=$2
    local output
    local result=0
    local cmd="aws s3api abort-multipart-upload --bucket \"$BUCKET\" --key \"$s3_key\" --upload-id \"$upload_id\" --endpoint-url \"$ENDPOINT\" --no-verify-ssl"

    if [[ "$DEBUG" == true ]]; then
        echo -e "${YELLOW}[DEBUG] Command: $cmd${NC}" >&2
        output=$(aws s3api abort-multipart-upload \
            --bucket "$BUCKET" \
            --key "$s3_key" \
            --upload-id "$upload_id" \
            --endpoint-url "$ENDPOINT" \
            --no-verify-ssl 2>&1) || result=$?
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

# Upload object using a regular put-object call
upload_regular() {
    local data_file=$1
    local s3_key=$2
    local output
    local result=0
    local cmd="aws s3api put-object --bucket \"$BUCKET\" --key \"$s3_key\" --body \"$data_file\" --endpoint-url \"$ENDPOINT\" --no-verify-ssl"

    if [[ "$DEBUG" == true ]]; then
        echo -e "${YELLOW}[DEBUG] Command: $cmd${NC}" >&2
    fi

    output=$(aws s3api put-object \
        --bucket "$BUCKET" \
        --key "$s3_key" \
        --body "$data_file" \
        --endpoint-url "$ENDPOINT" \
        --no-verify-ssl 2>&1) || result=$?

    if [[ "$DEBUG" == true ]]; then
        echo -e "${YELLOW}[DEBUG] Exit code: $result${NC}" >&2
        echo -e "${YELLOW}[DEBUG] Response:${NC}" >&2
        echo "$output" >&2
    fi

    if ((result != 0)); then
        echo -e "${RED}Failed to upload object${NC}" >&2
        echo "$output" >&2
        return 1
    fi
}

# Upload object using multipart upload, recording part offsets/sizes for
# boundary test case generation
upload_multipart() {
    local data_file=$1
    local object_size=$2
    local s3_key=$3
    local part_size part_count upload_id parts_json
    local -a etags=()

    part_size=$(calculate_part_size "$object_size")
    part_count=$(( (object_size + part_size - 1) / part_size ))

    echo -e "${BLUE}Part size: $(format_size "$part_size"), Part count: $part_count${NC}"

    echo -e "${BLUE}Initiating multipart upload...${NC}"
    upload_id=$(initiate_multipart_upload "$s3_key") || {
        echo -e "${RED}Failed to initiate multipart upload${NC}"
        return 1
    }

    echo -e "${GREEN}✓ Upload ID: $upload_id${NC}"
    ACTIVE_UPLOADS+=("$s3_key:$upload_id")

    for ((part_num=1; part_num<=part_count; part_num++)); do
        local part_offset=$(( (part_num - 1) * part_size ))
        local remaining_bytes=$((object_size - part_offset))
        local current_part_size=$part_size

        if ((remaining_bytes < part_size)); then
            current_part_size=$remaining_bytes
        fi

        PART_OFFSETS+=("$part_offset")
        PART_SIZES+=("$current_part_size")

        echo -e "${BLUE}Uploading part $part_num/$part_count ($(format_size $current_part_size))...${NC}"

        local part_file
        part_file="/tmp/part_${part_num}_$(generate_random_suffix).data"
        TEMP_FILES+=("$part_file")

        # Part offsets/sizes are always whole-MiB aligned, so a 1M block size
        # can be used for fast, exact extraction from the source file.
        if ! dd if="$data_file" of="$part_file" bs=1M skip=$((part_offset / 1048576)) count=$((current_part_size / 1048576)) 2>/dev/null; then
            echo -e "${RED}Failed to extract part from data file${NC}"
            rm -f "$part_file"
            abort_multipart_upload "$s3_key" "$upload_id"
            return 1
        fi

        local attempt=1
        local etag=""

        while ((attempt <= MAX_RETRIES)); do
            if etag=$(upload_part "$part_file" "$s3_key" "$upload_id" "$part_num"); then
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
                    rm -f "$part_file"
                    abort_multipart_upload "$s3_key" "$upload_id"
                    return 1
                fi
            fi
        done

        rm -f "$part_file"
    done

    parts_json='{"Parts":['
    for ((i=0; i<${#etags[@]}; i++)); do
        if ((i > 0)); then
            parts_json+=','
        fi
        parts_json+="{\"ETag\":\"${etags[$i]}\",\"PartNumber\":$((i+1))}"
    done
    parts_json+=']}'

    echo -e "${BLUE}Completing multipart upload...${NC}"
    if ! complete_multipart_upload "$s3_key" "$upload_id" "$parts_json"; then
        echo -e "${RED}Failed to complete multipart upload${NC}"
        abort_multipart_upload "$s3_key" "$upload_id"
        return 1
    fi

    echo -e "${GREEN}✓ Multipart upload completed${NC}"

    local -a new_uploads=()
    for upload_info in "${ACTIVE_UPLOADS[@]}"; do
        if [[ "$upload_info" != "$s3_key:$upload_id" ]]; then
            new_uploads+=("$upload_info")
        fi
    done
    ACTIVE_UPLOADS=("${new_uploads[@]}")
}

# Append a range test case
add_case() {
    CASE_LABELS+=("$1")
    CASE_STARTS+=("$2")
    CASE_ENDS+=("$3")
}

# Build the deterministic boundary test cases
generate_deterministic_cases() {
    local size=$OBJECT_SIZE_BYTES
    local prefix_end tail_start

    add_case "first-byte" 0 0

    if ((size > 4096)); then
        prefix_end=4095
    else
        prefix_end=$((size - 1))
    fi
    add_case "small-prefix" 0 "$prefix_end"

    add_case "last-byte" $((size - 1)) $((size - 1))

    if ((size > 8192)); then
        tail_start=$((size - 8192))
    else
        tail_start=0
    fi
    add_case "tail-range" "$tail_start" $((size - 1))

    if [[ "$MULTIPART" == true ]] && ((${#PART_OFFSETS[@]} > 0)); then
        local part_count=${#PART_OFFSETS[@]}
        local p1_off=${PART_OFFSETS[0]}
        local p1_size=${PART_SIZES[0]}
        local p1_end=$((p1_off + p1_size - 1))
        local inner_start

        if ((p1_size > 200)); then
            add_case "inside-part-1" $((p1_off + 50)) $((p1_off + 150))
        fi

        if ((p1_end - 99 > p1_off)); then
            inner_start=$((p1_end - 99))
        else
            inner_start=$p1_off
        fi
        add_case "part-boundary-end" "$inner_start" "$p1_end"

        if ((part_count >= 2)); then
            local p2_off=${PART_OFFSETS[1]}
            local p2_size=${PART_SIZES[1]}
            local p2_end=$((p2_off + p2_size - 1))
            local p2_inner_end cross_start cross_end

            if ((p2_off + 99 < p2_end)); then
                p2_inner_end=$((p2_off + 99))
            else
                p2_inner_end=$p2_end
            fi
            add_case "part-boundary-start" "$p2_off" "$p2_inner_end"

            if ((p1_end - 50 > p1_off)); then
                cross_start=$((p1_end - 50))
            else
                cross_start=$p1_off
            fi
            if ((p2_off + 50 < p2_end)); then
                cross_end=$((p2_off + 50))
            else
                cross_end=$p2_end
            fi
            add_case "cross-part-boundary" "$cross_start" "$cross_end"
        fi

        if ((part_count >= 3)); then
            local p3_off=${PART_OFFSETS[2]}
            local p3_size=${PART_SIZES[2]}
            local p3_end=$((p3_off + p3_size - 1))
            local multi_end

            if ((p3_off + 50 < p3_end)); then
                multi_end=$((p3_off + 50))
            else
                multi_end=$p3_end
            fi
            add_case "cross-multiple-parts" $((p1_off + 50)) "$multi_end"
        fi
    fi
}

# Compute a random range: start in [0, size-1], length in [1, range_max],
# and never extending past the end of the object
random_range() {
    local size=$1
    local range_max=$2
    local start max_len length

    start=$(( $(random_uint) % size ))
    max_len=$((size - start))
    if ((max_len > range_max)); then
        max_len=$range_max
    fi
    length=$(( ($(random_uint) % max_len) + 1 ))

    echo "$start $((start + length - 1))"
}

# Run a single ranged GetObject and verify metadata + size + content
run_range_test() {
    local label=$1
    local start=$2
    local end=$3
    local expected_len=$((end - start + 1))
    local download_file
    local expected_file
    local stderr_file
    download_file="/tmp/range_dl_$(generate_random_suffix).data"
    expected_file="/tmp/range_exp_$(generate_random_suffix).data"
    stderr_file="/tmp/range_stderr_$(generate_random_suffix).log"
    local output stderr_output result actual_len

    TEMP_FILES+=("$download_file" "$expected_file" "$stderr_file")
    TEST_COUNT=$((TEST_COUNT + 1))

    local cmd="aws s3api get-object --bucket \"$BUCKET\" --key \"$S3_KEY\" --range \"bytes=${start}-${end}\" --endpoint-url \"$ENDPOINT\" --no-verify-ssl \"$download_file\""
    if [[ "$DEBUG" == true ]]; then
        echo -e "${YELLOW}[DEBUG] Command: $cmd${NC}" >&2
    fi

    # Stdout and stderr are captured separately (rather than merged) so that
    # $output stays clean JSON that can be parsed with jq for metadata
    # validation, even if the CLI writes warnings (e.g. for --no-verify-ssl)
    # to stderr.
    result=0
    output=$(aws s3api get-object \
        --bucket "$BUCKET" \
        --key "$S3_KEY" \
        --range "bytes=${start}-${end}" \
        --endpoint-url "$ENDPOINT" \
        --no-verify-ssl \
        "$download_file" 2>"$stderr_file") || result=$?

    stderr_output=""
    if [[ -s "$stderr_file" ]]; then
        stderr_output=$(cat "$stderr_file")
    fi

    if [[ "$DEBUG" == true ]]; then
        echo -e "${YELLOW}[DEBUG] Exit code: $result${NC}" >&2
        echo -e "${YELLOW}[DEBUG] Response: $output${NC}" >&2
        if [[ -n "$stderr_output" ]]; then
            echo -e "${YELLOW}[DEBUG] Stderr: $stderr_output${NC}" >&2
        fi
    fi

    if ((result != 0)); then
        echo -e "${RED}✗ FAIL${NC} [$label] bytes=${start}-${end} (expected ${expected_len}B) - GetObject request failed"
        echo "$output" >&2
        if [[ -n "$stderr_output" ]]; then
            echo "$stderr_output" >&2
        fi
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_CASES+=("$label (bytes=${start}-${end})")
        rm -f "$download_file" "$expected_file" "$stderr_file"
        return 1
    fi

    # Validate first-level response metadata from the JSON returned on stdout
    local expected_content_range="bytes ${start}-${end}/${OBJECT_SIZE_BYTES}"
    local content_length_actual content_range_actual accept_ranges_actual

    content_length_actual=$(echo "$output" | jq -r '.ContentLength // empty' 2>/dev/null) || content_length_actual=""
    content_range_actual=$(echo "$output" | jq -r '.ContentRange // empty' 2>/dev/null) || content_range_actual=""
    accept_ranges_actual=$(echo "$output" | jq -r '.AcceptRanges // empty' 2>/dev/null) || accept_ranges_actual=""

    if [[ -z "$content_length_actual" ]]; then
        echo -e "${RED}✗ FAIL${NC} [$label] bytes=${start}-${end} - ContentLength missing in response (expected: ${expected_len})"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_CASES+=("$label (bytes=${start}-${end}) - ContentLength missing")
        rm -f "$download_file" "$expected_file" "$stderr_file"
        return 1
    fi

    if ! [[ "$content_length_actual" =~ ^[0-9]+$ ]] || ((content_length_actual != expected_len)); then
        echo -e "${RED}✗ FAIL${NC} [$label] bytes=${start}-${end} - ContentLength mismatch (expected: ${expected_len}, actual: ${content_length_actual})"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_CASES+=("$label (bytes=${start}-${end}) - ContentLength mismatch")
        rm -f "$download_file" "$expected_file" "$stderr_file"
        return 1
    fi

    if [[ -z "$content_range_actual" ]]; then
        echo -e "${RED}✗ FAIL${NC} [$label] bytes=${start}-${end} - ContentRange missing in response (expected: ${expected_content_range})"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_CASES+=("$label (bytes=${start}-${end}) - ContentRange missing")
        rm -f "$download_file" "$expected_file" "$stderr_file"
        return 1
    fi

    if [[ "$content_range_actual" != "$expected_content_range" ]]; then
        echo -e "${RED}✗ FAIL${NC} [$label] bytes=${start}-${end} - ContentRange mismatch (expected: ${expected_content_range}, actual: ${content_range_actual})"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_CASES+=("$label (bytes=${start}-${end}) - ContentRange mismatch")
        rm -f "$download_file" "$expected_file" "$stderr_file"
        return 1
    fi

    if [[ -z "$accept_ranges_actual" ]]; then
        echo -e "${YELLOW}⚠ WARN${NC} [$label] bytes=${start}-${end} - AcceptRanges missing"
    elif [[ "$accept_ranges_actual" != "bytes" ]]; then
        echo -e "${RED}✗ FAIL${NC} [$label] bytes=${start}-${end} - AcceptRanges mismatch (expected: bytes, actual: ${accept_ranges_actual})"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_CASES+=("$label (bytes=${start}-${end}) - AcceptRanges mismatch")
        rm -f "$download_file" "$expected_file" "$stderr_file"
        return 1
    fi

    actual_len=0
    if [[ -f "$download_file" ]]; then
        actual_len=$(stat -c%s "$download_file")
    fi

    if ((actual_len != expected_len)); then
        echo -e "${RED}✗ FAIL${NC} [$label] bytes=${start}-${end} expected ${expected_len}B, got ${actual_len}B (size mismatch)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_CASES+=("$label (bytes=${start}-${end})")
        rm -f "$download_file" "$expected_file" "$stderr_file"
        return 1
    fi

    if ! dd if="$DATA_FILE" of="$expected_file" bs=1M skip="$start" count="$expected_len" iflag=skip_bytes,count_bytes 2>/dev/null; then
        echo -e "${RED}✗ FAIL${NC} [$label] bytes=${start}-${end} - failed to extract expected data for comparison"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_CASES+=("$label (bytes=${start}-${end})")
        rm -f "$download_file" "$expected_file" "$stderr_file"
        return 1
    fi

    if ! cmp -s "$download_file" "$expected_file"; then
        local diff_info
        diff_info=$(cmp "$download_file" "$expected_file" 2>&1)
        echo -e "${RED}✗ FAIL${NC} [$label] bytes=${start}-${end} expected ${expected_len}B, got ${actual_len}B - content mismatch ($diff_info)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_CASES+=("$label (bytes=${start}-${end})")
        rm -f "$download_file" "$expected_file" "$stderr_file"
        return 1
    fi

    echo -e "${GREEN}✓ PASS${NC} [$label] bytes=${start}-${end} (${expected_len}B)"
    PASS_COUNT=$((PASS_COUNT + 1))
    rm -f "$download_file" "$expected_file" "$stderr_file"
}

# Cleanup S3 object
cleanup_s3_object() {
    echo -e "\n${BLUE}Cleaning up S3 object...${NC}"
    echo -e "${BLUE}Deleting s3://$BUCKET/$S3_KEY...${NC}"

    if aws s3api delete-object \
        --bucket "$BUCKET" \
        --key "$S3_KEY" \
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
        --gets)
            GETS="$2"
            shift 2
            ;;
        --multipart)
            MULTIPART=true
            shift
            ;;
        --range-max)
            RANGE_MAX="$2"
            shift 2
            ;;
        --random-only)
            RANDOM_ONLY=true
            shift
            ;;
        --endpoint)
            ENDPOINT="$2"
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
            usage 0
            ;;
        *)
            echo -e "${RED}Error: Unknown option $1${NC}" >&2
            usage
            ;;
    esac
done

# Validate required arguments
if [[ -z "$BUCKET" ]] || [[ -z "$OBJECT_SIZE" ]]; then
    echo -e "${RED}Error: Missing required arguments${NC}" >&2
    usage
fi

# Validate --gets
if ! [[ "$GETS" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}Error: --gets must be a non-negative integer${NC}" >&2
    exit 1
fi

# Check AWS CLI
if ! command -v aws &> /dev/null; then
    echo -e "${RED}Error: AWS CLI is not installed${NC}" >&2
    exit 1
fi

# Check jq (used to parse GetObject response metadata for validation)
if ! command -v jq &> /dev/null; then
    echo -e "${RED}Error: jq is not installed${NC}" >&2
    exit 1
fi

# Parse sizes
OBJECT_SIZE_BYTES=$(parse_size "$OBJECT_SIZE")
RANGE_MAX_BYTES=$(parse_range_size "$RANGE_MAX")

if ((OBJECT_SIZE_BYTES <= 0)); then
    echo -e "${RED}Error: Object size must be greater than 0${NC}" >&2
    exit 1
fi

if ((RANGE_MAX_BYTES <= 0)); then
    echo -e "${RED}Error: --range-max must be greater than 0${NC}" >&2
    exit 1
fi

# Print configuration
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}S3 Ranged GetObject Check${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "Endpoint:        $ENDPOINT"
echo -e "Bucket:          $BUCKET"
echo -e "Object size:     $(format_size "$OBJECT_SIZE_BYTES")"
echo -e "Upload mode:     $([ "$MULTIPART" = true ] && echo "multipart" || echo "put-object")"
echo -e "Random GETs:     $GETS"
echo -e "Max range size:  $(format_size "$RANGE_MAX_BYTES")"
echo -e "Random only:     $RANDOM_ONLY"
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
        --no-verify-ssl 2>&1) || true

    if aws s3api head-bucket --bucket "$BUCKET" --endpoint-url "$ENDPOINT" --no-verify-ssl 2>/dev/null; then
        echo -e "${GREEN}✓ Bucket '$BUCKET' created successfully${NC}"
        echo ""
    else
        echo -e "${RED}Error: Failed to create bucket '$BUCKET' at $ENDPOINT${NC}" >&2
        echo "Output: $create_output" >&2
        exit 1
    fi
fi

# Generate object name and local data file
random_suffix=$(generate_random_suffix)
S3_KEY="range_check_${OBJECT_SIZE}_${random_suffix}.data"
DATA_FILE="/tmp/range_data_$(generate_random_suffix).data"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Creating test data${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Generating $(format_size "$OBJECT_SIZE_BYTES") of random test data...${NC}"

create_test_data "$OBJECT_SIZE_BYTES" "$DATA_FILE" || {
    echo -e "${RED}Failed to create test data${NC}" >&2
    exit 1
}

echo -e "${GREEN}✓ Test data created${NC}"
echo ""

# Upload the object
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Uploading object${NC}"
echo -e "${BLUE}========================================${NC}"

if [[ "$MULTIPART" == true ]]; then
    if ! upload_multipart "$DATA_FILE" "$OBJECT_SIZE_BYTES" "$S3_KEY"; then
        echo -e "${RED}Upload failed${NC}"
        exit 1
    fi
else
    if ! upload_regular "$DATA_FILE" "$S3_KEY"; then
        echo -e "${RED}Upload failed${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ Object uploaded${NC}"
fi

UPLOADED=true
echo ""

# Build and run range test cases
if [[ "$RANDOM_ONLY" == true ]]; then
    echo -e "${YELLOW}Skipping deterministic boundary tests (--random-only)${NC}"
else
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}Deterministic boundary tests${NC}"
    echo -e "${BLUE}========================================${NC}"

    generate_deterministic_cases

    for ((i=0; i<${#CASE_LABELS[@]}; i++)); do
        run_range_test "${CASE_LABELS[$i]}" "${CASE_STARTS[$i]}" "${CASE_ENDS[$i]}" || true
    done
fi

echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Random range tests ($GETS)${NC}"
echo -e "${BLUE}========================================${NC}"

for ((i=1; i<=GETS; i++)); do
    read -r rand_start rand_end <<< "$(random_range "$OBJECT_SIZE_BYTES" "$RANGE_MAX_BYTES")"
    run_range_test "random-$i" "$rand_start" "$rand_end" || true
done

# Print summary
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Test Summary${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "Total tests:  $TEST_COUNT"
echo -e "Passed:       ${GREEN}$PASS_COUNT${NC}"
echo -e "Failed:       ${RED}$FAIL_COUNT${NC}"

if ((FAIL_COUNT > 0)); then
    echo ""
    echo -e "${RED}Failed cases:${NC}"
    for failed in "${FAILED_CASES[@]}"; do
        echo -e "${RED}✗${NC} $failed"
    done
fi

# Cleanup S3 object if requested
if [[ "$CLEANUP" == true ]] && [[ "$UPLOADED" == true ]]; then
    cleanup_s3_object
fi

echo ""
if ((FAIL_COUNT == 0)); then
    echo -e "${GREEN}Testing complete! All ranged GetObject checks passed.${NC}"
    exit 0
else
    echo -e "${RED}Testing complete with $FAIL_COUNT failed range check(s).${NC}"
    exit 1
fi
