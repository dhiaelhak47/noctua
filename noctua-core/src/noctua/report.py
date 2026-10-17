from noctua.models.bundle import EvidenceBundle


def render_markdown(bundle: EvidenceBundle) -> str:
    lines: list[str] = []

    lines += [
        "# NOCTUA Evidence Report",
        "",
        f"**Bundle:** `{bundle.bundle_id}`",
        f"**Pod:** `{bundle.namespace}/{bundle.pod}`",
        f"**Created:** {bundle.created_at.strftime('%Y-%m-%d %H:%M:%S UTC')}",
        f"**Seal:** `{bundle.sha256[:16]}…`",
        "",
        "## Hypotheses",
        "",
    ]

    if not bundle.hypotheses:
        lines.append("_No hypotheses generated. Manual investigation required._")
    else:
        for h in bundle.hypotheses:
            lines += [
                f"### {h.rank}. {h.description}",
                "",
                f"- **Confidence:** {h.confidence:.0%}",
                f"- **Rule:** `{h.rule}`",
                f"- **Evidence:** {', '.join(h.evidence_ids)}",
            ]
            if h.action:
                lines.append(f"- **Suggested action:** {h.action}")
            lines.append("")

    lines += ["## Evidence", ""]
    for item in bundle.evidence:
        lines += [
            f"### {item.id} — {item.kind.value} (`{item.source}`)",
            "",
            "```",
            item.content,
            "```",
            "",
        ]

    return "\n".join(lines)
