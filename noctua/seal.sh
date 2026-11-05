#!/usr/bin/env bash
set -euo pipefail
# stdin: evidence JSON array → stdout: sha256 hex string
# jq -cS sorts keys deterministically before hashing
jq -cS '.' | sha256sum | awk '{print $1}'
