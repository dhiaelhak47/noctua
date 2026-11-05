#!/usr/bin/env bash
set -euo pipefail
# stdin: text → stdout: redacted text
# Extend patterns as more evidence sources are added.
sed \
  -e 's/[A-Za-z0-9._%+-]\+@[A-Za-z0-9.-]\+\.[A-Za-z]\{2,\}/[REDACTED_EMAIL]/g' \
  -e 's/\b[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\b/[REDACTED_IP]/g' \
  -e 's/Bearer [A-Za-z0-9._-]\+/Bearer [REDACTED_TOKEN]/g' \
  -e 's/password[[:space:]]*=[[:space:]]*[^[:space:]]\+/password=[REDACTED]/gi' \
  -e 's/secret[[:space:]]*=[[:space:]]*[^[:space:]]\+/secret=[REDACTED]/gi' \
  -e 's/token[[:space:]]*=[[:space:]]*[^[:space:]]\+/token=[REDACTED]/gi'
