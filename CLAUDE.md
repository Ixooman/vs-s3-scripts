# CLAUDE.md

Instructions for Claude Code when working in this repository.

## Project Overview

This repository contains bash scripts for semi-automated testing of vitiscale S3-compatible storage behavior. The scripts use AWS CLI to test connectivity, basic S3 API compatibility, multipart upload behavior, object size limits, bulk object upload, and test-environment cleanup.

The project is script-focused. There is no application build system, package manager, or automated test framework in the repository.

Primary documentation:

- `README.md`: repository-level overview and usage matrix for all scripts.
- `base_check.md`: detailed notes for `base_check.sh`.

## Repository Contents

- `check_connection.sh`: minimal `list-buckets` connectivity check.
- `base_check.sh`: basic S3 compatibility smoke test with fixed bucket names.
- `spec_methods_tester.sh`: broader API method test with pass/fail accounting.
- `test_multipart.sh`: minimal hard-coded multipart initiation/abort check.
- `multipart_upload_check.sh`: single multipart upload with ETag or full MD5 verification.
- `max_object_size_probe.sh`: probes single PUT object size limits.
- `max_object_multipart_probe.sh`: probes multipart upload size limits.
- `put_bunch_objects.sh`: sequential bulk upload of many objects.
- `cleanup_all.sh`: destructive full cleanup of all buckets on an endpoint.

## Safety Rules

Do not run S3-facing scripts unless the user explicitly asks for that specific run and provides or confirms the endpoint and bucket context.

Treat these as especially risky:

- `cleanup_all.sh`: deletes all buckets and objects on the target endpoint.
- `base_check.sh`: uses fixed bucket names such as `new-bucket`, `versioned-bucket`, and `bucket-for-tag`.
- `put_bunch_objects.sh`: can create many objects and consume storage.
- `max_object_size_probe.sh` and `max_object_multipart_probe.sh`: can generate large local files and upload large objects.
- `multipart_upload_check.sh`: can generate large local files and upload large objects.

Before suggesting or running any S3-facing command:

- call out the target endpoint
- call out the target bucket if applicable
- call out whether cleanup is enabled
- call out expected local disk and remote storage impact for large object tests

Do not run `cleanup_all.sh` unless the user clearly confirms that the endpoint is a dedicated disposable test environment.

## Local Verification Commands

Safe local checks:

```bash
bash -n *.sh
git status --short
```

Use `bash -n` after editing shell scripts. If `shellcheck` is installed, it is useful but not required:

```bash
shellcheck *.sh
```

Do not install tools or dependencies without asking first.

## Coding Style

Follow the existing style unless there is a clear reason to change it:

- bash scripts with `#!/bin/bash`
- AWS CLI commands using `--endpoint-url` and `--no-verify-ssl`
- explicit argument parsing through `case`
- readable console output with section headers
- cleanup handlers via `trap` where temporary files, multipart uploads, or test objects are created
- conservative changes scoped to one script or document at a time

For shell changes:

- quote variables unless arithmetic or pattern matching requires otherwise
- prefer arrays for command construction when adding complex commands
- keep destructive commands visibly documented
- avoid changing default endpoint behavior unless the user asks
- preserve current CLI flags where possible
- update `README.md` when script usage, options, defaults, size units, or cleanup behavior changes
- update script-specific docs such as `base_check.md` when relevant

## Documentation Rules

Documentation must reflect the actual script behavior, not intended future behavior.

Be precise about:

- required and optional arguments
- default endpoint
- supported size units
- whether bucket creation is automatic
- whether cleanup removes only objects or also buckets
- whether a script has true pass/fail accounting
- hard-coded endpoint, bucket, or key values
- destructive behavior

Avoid claiming that a script verifies data integrity unless the script actually compares checksums or expected content.

## Git Workflow

The repository is initialized as git. Current default branch is `master` unless changed by the user.

Before edits:

```bash
git status --short
```

After edits:

```bash
git status --short
git diff -- <files>
```

Commit only when the user explicitly asks. Use concise commit messages in imperative or descriptive style, for example:

```text
Update documentation for S3 test scripts
Fix multipart upload argument parsing
```

Never revert user changes unless explicitly requested.

## Common Task Guidance

When asked to analyze a script:

- read the script and the relevant documentation
- compare documented CLI options against actual parsing
- check default values and cleanup behavior
- identify destructive or hard-coded behavior
- recommend documentation updates if behavior is intentional

When asked to modify a script:

- keep backward-compatible CLI behavior where practical
- add or update `usage()` output
- update `README.md` and any script-specific docs
- run `bash -n` for changed shell files
- do not run S3 operations unless explicitly requested

When asked to run a test against S3:

- confirm endpoint and bucket if missing
- prefer the smallest useful object size first
- use `--cleanup` where supported unless the user wants objects retained
- avoid `cleanup_all.sh` unless explicitly confirmed

## Current Project Assumptions

- Default endpoint in most scripts: `http://192.168.10.81`.
- Scripts are intended for test environments, not production endpoints.
- Credentials are resolved by AWS CLI through environment variables or AWS config files.
- Some scripts create buckets automatically; others use fixed or hard-coded names.
- Large-object scripts may use significant local disk space and remote storage.
