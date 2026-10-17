from __future__ import annotations

import hashlib
import json
import uuid
from datetime import UTC, datetime
from enum import StrEnum

from pydantic import BaseModel, Field


class EvidenceKind(StrEnum):
    POD_STATUS = "pod_status"
    EVENT = "event"
    LOG = "log"
    ROLLOUT = "rollout"


class EvidenceItem(BaseModel):
    id: str = ""
    kind: EvidenceKind
    source: str
    content: str
    collected_at: datetime = Field(default_factory=lambda: datetime.now(UTC))


class Hypothesis(BaseModel):
    rank: int
    rule: str
    description: str
    evidence_ids: list[str]
    confidence: float
    action: str | None = None


class EvidenceBundle(BaseModel):
    bundle_id: str = Field(default_factory=lambda: str(uuid.uuid4()))
    schema_version: str = "0.1"
    created_at: datetime = Field(default_factory=lambda: datetime.now(UTC))
    namespace: str
    pod: str
    evidence: list[EvidenceItem] = []
    hypotheses: list[Hypothesis] = []
    sha256: str = ""

    def assign_ids(self) -> EvidenceBundle:
        for i, item in enumerate(self.evidence, start=1):
            item.id = f"E{i}"
        return self

    def seal(self) -> EvidenceBundle:
        self.assign_ids()
        payload = json.dumps(
            [e.model_dump(mode="json") for e in self.evidence],
            sort_keys=True,
            default=str,
        )
        self.sha256 = hashlib.sha256(payload.encode()).hexdigest()
        return self
