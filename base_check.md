# Base S3 Compatibility Check Script

This document describes `base_check.sh`, a sequential AWS CLI smoke test for basic S3-compatible API behavior. The script is intended for test environments and uses fixed bucket and object names.

## Overview

`base_check.sh` is based on the legacy `S3_compatibility.txt` scenario and intentionally excludes multipart upload tests. It runs a set of bucket, object, versioning, tagging, listing, and basic object-attributes commands against a configured S3 endpoint.

The script prints each AWS CLI command before execution, prints command output directly to the console, and runs cleanup automatically on exit.

## Usage

```bash
./base_check.sh [endpoint-url]
```

If `endpoint-url` is omitted, the script uses:

```text
http://192.168.10.81
```

Examples:

```bash
./base_check.sh
./base_check.sh http://192.168.10.81
./base_check.sh http://your-s3-endpoint:port
./base_check.sh https://s3.example.com
```

## Prerequisites

Required tools:

- `bash`
- AWS CLI available as `aws`
- standard Unix tools: `rm`, `mkdir`, `touch`, `cat`, `echo`

AWS CLI must have credentials that can create, list, tag, version, upload, download, copy, and delete buckets and objects on the target endpoint.

Example AWS CLI configuration:

```bash
aws configure set aws_access_key_id YOUR_ACCESS_KEY
aws configure set aws_secret_access_key YOUR_SECRET_KEY
aws configure set default.region us-east-1
aws configure set default.output json
```

The script invokes AWS CLI through:

```bash
aws --no-verify-ssl
```

This is suitable for test endpoints with self-signed certificates, but should not be treated as a production security posture.

## Important Behavior

### Fixed Resource Names

The script does not generate unique bucket names. It uses these fixed bucket names:

- `new-bucket`
- `versioned-bucket`
- `bucket-for-tag`
- `bucket-for-attrs`
- `bucket-for-delete`

It also uses fixed object keys such as:

- `new-object`
- `simple-object`
- `simple-object-copy`
- `versioned-object`
- `object-for-tag`
- `object-for-attrs`
- `file1.txt`
- `file2.txt`
- `file3.txt`

Run it only against a dedicated test endpoint or an environment where these names cannot collide with useful data.

### Error Handling

`set -e` is intentionally disabled in the script. The helper function runs a command, prints a blank line, and returns the status of the final `echo`, so many command failures do not stop the script.

This means:

- the script is useful as an exploratory compatibility check
- failures must be reviewed in console output
- a final `=== Test Completed! ===` message does not prove that every operation passed
- negative checks such as `head-object` after deletion are expected to fail

### Cleanup

Cleanup is registered with:

```bash
trap cleanup EXIT
```

On exit, the script attempts to delete the fixed test objects, buckets, local files, and local `new-bucket` directory. Cleanup errors are suppressed with `2>/dev/null || true`.

Versioned bucket cleanup is best-effort. The script tries simple object deletion, `aws s3 rm`, `aws s3 rb --force`, and `delete-bucket`, but some versions or delete markers may remain depending on endpoint behavior.

## Test Workflow

### 1. Bucket Creation and Listing

Commands:

- `create-bucket --bucket new-bucket`
- `list-buckets`

Purpose:

- verify that a bucket can be created
- verify that bucket listing returns a response

### 2. Object Creation

Commands:

- create local `data.txt` with `test`
- `put-object --bucket new-bucket --key new-object`
- `head-object --bucket new-bucket --key new-object`

Purpose:

- verify basic object upload
- verify object metadata retrieval

### 3. Directory Sync

Commands:

- create local directory `new-bucket`
- create local files `file1.txt`, `file2.txt`, `file3.txt`
- `aws s3 sync new-bucket s3://new-bucket`
- `list-objects --bucket new-bucket`

Purpose:

- verify high-level `aws s3 sync`
- verify listing after uploading multiple files

### 4. Object Lifecycle

Commands:

- upload `simple-object`
- download it to `data-out.txt`
- print downloaded content with `cat`
- copy to `simple-object-copy`
- download copy to `data-out-copy.txt`
- print copied content with `cat`
- delete original object
- run `head-object` against the deleted key

Purpose:

- exercise put/get/copy/delete flow
- provide manual visibility into downloaded content
- verify that deleted object lookup fails

Note: the script prints downloaded content, but it does not perform an automated expected-vs-actual comparison.

### 5. Object Listing

Commands:

- `list-objects --bucket new-bucket`
- `list-objects-v2 --bucket new-bucket`

Purpose:

- verify both listing API variants

### 6. Versioning

Commands:

- create `versioned-bucket`
- enable versioning
- get bucket versioning status
- upload two versions of `versioned-object`
- list object versions
- delete `versioned-object`
- run `head-object` against the deleted key
- list remaining versions

Purpose:

- verify bucket versioning configuration
- verify multiple object versions are visible
- inspect delete-marker/version behavior after deletion

### 7. Bucket Tagging

Commands:

- create `bucket-for-tag`
- put bucket tag `some-key=some-value`
- get bucket tags
- delete bucket tags
- get bucket tags again

Purpose:

- verify bucket tag put/get/delete behavior

The final `get-bucket-tagging` after deletion is expected to fail on many S3 implementations.

### 8. Object Tagging

Commands:

- upload `object-for-tag`
- put object tag `some-object-key=some-object-value`
- get object tags
- replace tags with `some-new-object-key=some-new-object-value`
- get updated object tags
- delete object tags
- get object tags again

Purpose:

- verify object tag put/get/update/delete behavior

### 9. Object Attributes

Commands:

- create `bucket-for-attrs`
- upload `object-for-attrs`
- request `ETag`
- request `ObjectSize`
- request `StorageClass`

Purpose:

- check basic `get-object-attributes` compatibility

`ObjectSize` and `StorageClass` may not be supported by all S3-compatible endpoints. The script prints a fallback message for these cases.

### 10. Bucket Deletion

Commands:

- create `bucket-for-delete`
- `head-bucket`
- `delete-bucket`
- run `head-bucket` against the deleted bucket

Purpose:

- verify empty bucket deletion
- verify deleted bucket lookup fails

## Output

The script prints:

- section headers for each test category
- each AWS CLI command before execution
- raw AWS CLI output
- selected local file contents
- expected-failure labels for deletion checks
- `=== Test Completed! ===` before the exit trap cleanup runs
- `=== Cleanup ===` from the cleanup handler

Because the script does not aggregate pass/fail state, console output must be reviewed to determine which operations succeeded.

## Limitations

- No multipart upload coverage.
- No generated unique bucket names.
- No automated content checksum or exact content comparison.
- No structured report or machine-readable result file.
- No reliable non-zero exit code for every failed operation.
- No endpoint validation beyond whatever AWS CLI returns.
- Cleanup for versioned buckets is best-effort.
- All operations are sequential; there is no concurrency or load testing.

## Troubleshooting

### AWS CLI Not Found

```text
aws: command not found
```

Install AWS CLI and ensure it is available in `PATH`.

### Authentication Errors

```text
An error occurred (InvalidAccessKeyId)
```

Check AWS CLI credentials and permissions for the target endpoint.

### Connection Refused

```text
Could not connect to the endpoint URL
```

Verify endpoint URL, network connectivity, DNS, firewall rules, and whether the endpoint expects HTTP or HTTPS.

### Bucket Already Exists

The script uses fixed bucket names. If one of them already exists or belongs to another owner, creation may fail and later steps may behave unexpectedly.

Clean the test endpoint first or update the script to use unique bucket names.

### Bucket Not Empty

Versioned buckets may retain versions or delete markers after normal object deletion. Use `list-object-versions` and delete remaining versions/delete markers manually, or use `cleanup_all.sh` only on a dedicated test endpoint.

### Object Attributes Errors

Some S3-compatible implementations do not fully support `get-object-attributes` for every attribute. Errors for `ObjectSize` or `StorageClass` can be endpoint limitations rather than script bugs.

## Related Scripts

Use the other scripts in this directory for coverage that `base_check.sh` intentionally does not provide:

- `spec_methods_tester.sh`: broader API method coverage with explicit pass/fail accounting
- `test_multipart.sh`: minimal multipart initiation/abort check
- `multipart_upload_check.sh`: multipart upload with verification modes
- `max_object_size_probe.sh`: single PUT object size probing
- `max_object_multipart_probe.sh`: multipart size probing
- `put_bunch_objects.sh`: bulk upload testing
- `cleanup_all.sh`: destructive full endpoint cleanup
