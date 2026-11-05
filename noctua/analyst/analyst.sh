#!/usr/bin/env bash
set -euo pipefail
# stdin: bundle JSON → stdout: hypotheses JSON array
# --mode rules (default) | llm | hybrid

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mode="${NOCTUA_ANALYST:-rules}"

while [[ $# -gt 0 ]]; do
  case $1 in
    --mode) mode="$2"; shift 2 ;;
    *)      break ;;
  esac
done

bundle=$(cat "${1:-/dev/stdin}")

case "$mode" in
  rules)
    echo "$bundle" | bash "$SCRIPT_DIR/rules.sh"
    ;;

  llm)
    echo "$bundle" | bash "$SCRIPT_DIR/llm.sh"
    ;;

  hybrid)
    # Run both analysts, merge results, deduplicate by rule (keep highest confidence).
    rules_h=$(echo "$bundle" | bash "$SCRIPT_DIR/rules.sh")
    llm_h=$(echo "$bundle"   | bash "$SCRIPT_DIR/llm.sh")
    # jq -s slurps the two JSON arrays into [[...],[...]], then add flattens them.
    printf '%s\n%s\n' "$rules_h" "$llm_h" | jq -s '
      add |
      sort_by(-.confidence) |
      unique_by(.rule) |
      to_entries |
      map(.value + {rank: (.key + 1)})'
    ;;

  *)
    echo "Unknown analyst mode: ${mode}. Use rules|llm|hybrid." >&2
    exit 1
    ;;
esac
