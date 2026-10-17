from __future__ import annotations

import re

from noctua.analyst.base import AnalystProvider
from noctua.models.bundle import EvidenceBundle, EvidenceItem, EvidenceKind, Hypothesis


class RuleBasedAnalyst(AnalystProvider):
    """Deterministic rule-based analyst. Produces cited hypotheses with no LLM calls."""

    def analyse(self, bundle: EvidenceBundle) -> EvidenceBundle:
        hypotheses: list[Hypothesis] = []

        ps_items = [e for e in bundle.evidence if e.kind == EvidenceKind.POD_STATUS]
        log_items = [e for e in bundle.evidence if e.kind == EvidenceKind.LOG]
        ev_items = [e for e in bundle.evidence if e.kind == EvidenceKind.EVENT]

        ps_text = "\n".join(e.content for e in ps_items)
        log_text = "\n".join(e.content for e in log_items)
        ev_text = "\n".join(e.content for e in ev_items)

        # Rule: OOMKilled (high specificity — check before CrashLoop)
        if "OOMKilled" in ps_text:
            hypotheses.append(
                Hypothesis(
                    rank=0,
                    rule="oomkilled",
                    description=(
                        "Container was OOM-killed. "
                        "Memory limit is too low for the current workload."
                    ),
                    evidence_ids=_ids(ps_items),
                    confidence=0.90,
                    action="raise memory limit in Helm values and redeploy",
                )
            )

        # Rule: ImagePullBackOff / ErrImagePull
        if re.search(r"ImagePullBackOff|ErrImagePull", ps_text + ev_text):
            hypotheses.append(
                Hypothesis(
                    rank=0,
                    rule="image_pull_backoff",
                    description=(
                        "Container image cannot be pulled. "
                        "The image tag may not exist or registry credentials are missing."
                    ),
                    evidence_ids=_ids(ps_items + ev_items),
                    confidence=0.95,
                    action="verify image tag exists in registry; check imagePullSecrets",
                )
            )

        # Rule: CrashLoopBackOff (generic or + missing env var)
        if "CrashLoopBackOff" in ps_text:
            env_var = _extract_missing_env_var(log_text + ev_text)
            if env_var:
                description = (
                    f"Container is crash-looping due to missing environment variable '{env_var}'. "
                    "A recent rollout likely removed or renamed it from the Helm values."
                )
                confidence = 0.86
            else:
                description = (
                    "Container is crash-looping. Inspect previous-container logs for startup"
                    " errors; a missing env var or misconfiguration after a recent rollout"
                    " is the most common cause."
                )
                confidence = 0.65
            hypotheses.append(
                Hypothesis(
                    rank=0,
                    rule="crash_loop_missing_env",
                    description=description,
                    evidence_ids=_ids(ps_items + log_items + ev_items),
                    confidence=confidence,
                    action="rollback Helm values to previous revision or restore missing env var",
                )
            )

        # Rank by descending confidence
        hypotheses.sort(key=lambda h: h.confidence, reverse=True)
        for i, h in enumerate(hypotheses, start=1):
            h.rank = i

        bundle.hypotheses = hypotheses
        return bundle


def _ids(items: list[EvidenceItem]) -> list[str]:
    seen: set[str] = set()
    result: list[str] = []
    for item in items:
        if item.id and item.id not in seen:
            seen.add(item.id)
            result.append(item.id)
    return result


_ENV_PATTERNS = [
    re.compile(r"KeyError:\s*['\"]([A-Z][A-Z0-9_]{1,})['\"]"),
    re.compile(
        r"missing\s+(?:env\s+var|environment\s+variable)[:\s]+['\"]?([A-Z][A-Z0-9_]{1,})['\"]?",
        re.IGNORECASE,
    ),
    re.compile(
        r"environment variable[:\s]+['\"]?([A-Z][A-Z0-9_]{1,})['\"]?"
        r"\s+(?:is\s+)?(?:not\s+set|missing|required)",
        re.IGNORECASE,
    ),
    re.compile(
        r"env\s+var\s+not\s+(?:found|set|defined)[:\s]+" r"['\"]?([A-Z][A-Z0-9_]{1,})['\"]?",
        re.IGNORECASE,
    ),
    re.compile(
        r"\$([A-Z][A-Z0-9_]{3,})\s+(?:is\s+)?(?:not\s+set|unset|undefined|missing)",
        re.IGNORECASE,
    ),
]


def _extract_missing_env_var(text: str) -> str | None:
    for pattern in _ENV_PATTERNS:
        m = pattern.search(text)
        if m:
            return m.group(1)
    return None
