#!/usr/bin/env bash
set -euo pipefail
# stdin or file arg: bundle JSON → stdout: markdown report

bundle=$(cat "${1:-/dev/stdin}")

bundle_id=$(echo "$bundle"  | jq -r '.bundle_id')
namespace=$(echo "$bundle"  | jq -r '.namespace')
pod=$(echo "$bundle"        | jq -r '.pod')
created_at=$(echo "$bundle" | jq -r '.created_at')
sha256=$(echo "$bundle"     | jq -r '.sha256')

echo "# NOCTUA Evidence Report"
echo ""
echo "**Bundle:** \`${bundle_id}\`"
echo "**Pod:** \`${namespace}/${pod}\`"
echo "**Created:** ${created_at}"
echo "**Seal:** \`${sha256:0:16}…\`"
echo ""
echo "## Hypotheses"
echo ""

hyp_count=$(echo "$bundle" | jq '.hypotheses | length')

if [[ "$hyp_count" -eq 0 ]]; then
  echo "_No hypotheses generated. Manual investigation required._"
else
  while IFS= read -r hyp; do
    rank=$(echo "$hyp"    | jq -r '.rank')
    desc=$(echo "$hyp"    | jq -r '.description')
    conf=$(echo "$hyp"    | jq '(.confidence * 100 | round)')
    rule=$(echo "$hyp"    | jq -r '.rule')
    ev_ids=$(echo "$hyp"  | jq -r '.evidence_ids | join(", ")')
    action=$(echo "$hyp"  | jq -r '.action // empty')

    echo "### ${rank}. ${desc}"
    echo ""
    echo "- **Confidence:** ${conf}%"
    echo "- **Rule:** \`${rule}\`"
    echo "- **Evidence:** ${ev_ids}"
    [[ -n "$action" ]] && echo "- **Suggested action:** ${action}"
    echo ""
  done < <(echo "$bundle" | jq -c '.hypotheses[]')
fi

echo "## Evidence"
echo ""

while IFS= read -r item; do
  id=$(echo "$item"      | jq -r '.id')
  kind=$(echo "$item"    | jq -r '.kind')
  source=$(echo "$item"  | jq -r '.source')
  content=$(echo "$item" | jq -r '.content')

  echo "### ${id} — ${kind} (\`${source}\`)"
  echo ""
  echo '```'
  echo "$content"
  echo '```'
  echo ""
done < <(echo "$bundle" | jq -c '.evidence[]')
