import pytest

from noctua.analyst.rules import RuleBasedAnalyst
from noctua.models.bundle import EvidenceBundle, EvidenceItem, EvidenceKind


def _bundle(*items: EvidenceItem) -> EvidenceBundle:
    b = EvidenceBundle(namespace="default", pod="test-pod")
    b.evidence = list(items)
    b.assign_ids()
    return b


def _ps(content: str) -> EvidenceItem:
    return EvidenceItem(kind=EvidenceKind.POD_STATUS, source="pod_status", content=content)


def _log(content: str) -> EvidenceItem:
    return EvidenceItem(kind=EvidenceKind.LOG, source="logs", content=content)


def _ev(content: str) -> EvidenceItem:
    return EvidenceItem(kind=EvidenceKind.EVENT, source="events", content=content)


analyst = RuleBasedAnalyst()


def test_crash_loop_with_keyerror_names_env_var():
    b = analyst.analyse(
        _bundle(
            _ps("State: Waiting (CrashLoopBackOff)\nRestartCount: 5"),
            _log("KeyError: 'DATABASE_URL'\nTraceback (most recent call last):"),
        )
    )
    assert b.hypotheses
    h = b.hypotheses[0]
    assert h.rule == "crash_loop_missing_env"
    assert "DATABASE_URL" in h.description
    assert set(h.evidence_ids) == {"E1", "E2"}
    assert h.confidence == 0.86


def test_crash_loop_without_env_var_has_lower_confidence():
    b = analyst.analyse(
        _bundle(
            _ps("State: Waiting (CrashLoopBackOff)\nRestartCount: 3"),
            _log("panic: runtime error: index out of range"),
        )
    )
    h = b.hypotheses[0]
    assert h.rule == "crash_loop_missing_env"
    assert h.confidence == 0.65


def test_oomkilled_detected():
    b = analyst.analyse(_bundle(_ps("LastState: Terminated (reason=OOMKilled, exitCode=137)")))
    assert b.hypotheses[0].rule == "oomkilled"
    assert b.hypotheses[0].confidence == 0.90


def test_image_pull_backoff_detected():
    b = analyst.analyse(
        _bundle(
            _ps("State: Waiting (ImagePullBackOff)"),
            _ev("Failed to pull image: rpc error: code = NotFound"),
        )
    )
    h = next(h for h in b.hypotheses if h.rule == "image_pull_backoff")
    assert h.confidence == 0.95
    assert "E1" in h.evidence_ids
    assert "E2" in h.evidence_ids


def test_no_match_returns_empty_hypotheses():
    b = analyst.analyse(_bundle(_ps("Phase: Running\nReady: True")))
    assert b.hypotheses == []


def test_hypotheses_ranked_by_descending_confidence():
    b = analyst.analyse(
        _bundle(
            _ps(
                "State: Waiting (CrashLoopBackOff)\n"
                "LastState: Terminated (reason=OOMKilled, exitCode=137)"
            ),
            _log("KeyError: 'SECRET_KEY'"),
        )
    )
    confidences = [h.confidence for h in b.hypotheses]
    assert confidences == sorted(confidences, reverse=True)
    assert [h.rank for h in b.hypotheses] == list(range(1, len(b.hypotheses) + 1))


@pytest.mark.parametrize(
    "log_line,expected_var",
    [
        ("KeyError: 'DATABASE_URL'", "DATABASE_URL"),
        ("missing env var: SECRET_KEY", "SECRET_KEY"),
        ("environment variable: API_TOKEN is not set", "API_TOKEN"),
        ("$DB_PASSWORD is not set", "DB_PASSWORD"),
    ],
)
def test_env_var_extraction_patterns(log_line: str, expected_var: str):
    b = analyst.analyse(
        _bundle(
            _ps("State: Waiting (CrashLoopBackOff)"),
            _log(log_line),
        )
    )
    assert expected_var in b.hypotheses[0].description
