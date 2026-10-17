from noctua.models.bundle import EvidenceBundle, EvidenceItem, EvidenceKind


def _item(kind: EvidenceKind, content: str) -> EvidenceItem:
    return EvidenceItem(kind=kind, source="test", content=content)


def test_assign_ids_sequential():
    bundle = EvidenceBundle(namespace="default", pod="test-pod")
    bundle.evidence = [
        _item(EvidenceKind.POD_STATUS, "Phase: Running"),
        _item(EvidenceKind.EVENT, "BackOff"),
        _item(EvidenceKind.LOG, "some log"),
    ]
    bundle.assign_ids()
    assert [e.id for e in bundle.evidence] == ["E1", "E2", "E3"]


def test_seal_sets_sha256():
    bundle = EvidenceBundle(namespace="default", pod="test-pod")
    bundle.evidence = [_item(EvidenceKind.LOG, "hello")]
    bundle.seal()
    assert len(bundle.sha256) == 64
    assert bundle.evidence[0].id == "E1"


def test_seal_is_deterministic():
    def make() -> str:
        b = EvidenceBundle(namespace="default", pod="test-pod", bundle_id="fixed-id")
        b.evidence = [_item(EvidenceKind.LOG, "hello")]
        b.seal()
        return b.sha256

    assert make() == make()


def test_seal_changes_on_content_change():
    def make(content: str) -> str:
        b = EvidenceBundle(namespace="default", pod="test-pod", bundle_id="fixed-id")
        b.evidence = [_item(EvidenceKind.LOG, content)]
        b.seal()
        return b.sha256

    assert make("hello") != make("world")
