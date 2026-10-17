from noctua.analyst.rules import RuleBasedAnalyst
from noctua.models.bundle import EvidenceBundle, EvidenceItem, EvidenceKind
from noctua.report import render_markdown


def _crashloop_bundle() -> EvidenceBundle:
    b = EvidenceBundle(namespace="default", pod="ledger-api-abc-123")
    b.evidence = [
        EvidenceItem(
            kind=EvidenceKind.POD_STATUS,
            source="pod_status",
            content="State: Waiting (CrashLoopBackOff)\nRestartCount: 5",
        ),
        EvidenceItem(
            kind=EvidenceKind.LOG,
            source="previous_container_logs",
            content="KeyError: 'DATABASE_URL'",
        ),
    ]
    b.seal()
    return RuleBasedAnalyst().analyse(b)


def test_report_contains_bundle_id():
    b = _crashloop_bundle()
    assert b.bundle_id in render_markdown(b)


def test_report_contains_env_var_in_hypothesis():
    assert "DATABASE_URL" in render_markdown(_crashloop_bundle())


def test_report_contains_evidence_ids():
    report = render_markdown(_crashloop_bundle())
    assert "E1" in report
    assert "E2" in report


def test_report_contains_evidence_content():
    report = render_markdown(_crashloop_bundle())
    assert "CrashLoopBackOff" in report
    assert "DATABASE_URL" in report


def test_report_contains_seal():
    b = _crashloop_bundle()
    report = render_markdown(b)
    assert b.sha256[:16] in report


def test_empty_hypotheses_message():
    b = EvidenceBundle(namespace="default", pod="healthy-pod")
    b.evidence = [
        EvidenceItem(kind=EvidenceKind.POD_STATUS, source="pod_status", content="Phase: Running")
    ]
    b.seal()
    b = RuleBasedAnalyst().analyse(b)
    assert "Manual investigation required" in render_markdown(b)
