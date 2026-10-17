from kubernetes import client

from noctua.collectors.base import CollectorBase
from noctua.models.bundle import EvidenceItem, EvidenceKind


class EventsCollector(CollectorBase):
    def __init__(self, v1: client.CoreV1Api, limit: int = 50) -> None:
        self._v1 = v1
        self._limit = limit

    def collect(self, namespace: str, pod: str) -> list[EvidenceItem]:
        events = self._v1.list_namespaced_event(
            namespace=namespace,
            field_selector=f"involvedObject.name={pod}",
            limit=self._limit,
        )
        if not events.items:
            return [
                EvidenceItem(
                    kind=EvidenceKind.EVENT,
                    source="events",
                    content="No events found.",
                )
            ]
        lines = [f"{'Last Seen':<20} {'Type':<10} {'Reason':<25} Message"]
        lines.append("-" * 80)
        for e in sorted(events.items, key=lambda x: x.last_timestamp or x.event_time or ""):
            last = str(e.last_timestamp or e.event_time or "")[:19]
            etype = e.type or ""
            reason = e.reason or ""
            message = (e.message or "")[:100]
            lines.append(f"{last:<20} {etype:<10} {reason:<25} {message}")
        return [
            EvidenceItem(
                kind=EvidenceKind.EVENT,
                source="events",
                content="\n".join(lines),
            )
        ]
