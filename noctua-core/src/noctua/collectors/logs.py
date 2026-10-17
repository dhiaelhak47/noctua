from kubernetes import client
from kubernetes.client.rest import ApiException

from noctua.collectors.base import CollectorBase
from noctua.models.bundle import EvidenceItem, EvidenceKind


class LogsCollector(CollectorBase):
    def __init__(self, v1: client.CoreV1Api, tail_lines: int = 50) -> None:
        self._v1 = v1
        self._tail_lines = tail_lines

    def collect(self, namespace: str, pod: str) -> list[EvidenceItem]:
        try:
            logs = self._v1.read_namespaced_pod_log(
                name=pod,
                namespace=namespace,
                previous=True,
                tail_lines=self._tail_lines,
            )
            return [
                EvidenceItem(
                    kind=EvidenceKind.LOG,
                    source="previous_container_logs",
                    content=logs or "(empty)",
                )
            ]
        except ApiException as e:
            # 400 = no previous container; not a fatal error
            if e.status == 400:
                return [
                    EvidenceItem(
                        kind=EvidenceKind.LOG,
                        source="previous_container_logs",
                        content="No previous container logs available.",
                    )
                ]
            raise
