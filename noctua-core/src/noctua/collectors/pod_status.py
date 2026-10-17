from kubernetes import client

from noctua.collectors.base import CollectorBase
from noctua.models.bundle import EvidenceItem, EvidenceKind


class PodStatusCollector(CollectorBase):
    def __init__(self, v1: client.CoreV1Api) -> None:
        self._v1 = v1

    def collect(self, namespace: str, pod: str) -> list[EvidenceItem]:
        pod_obj = self._v1.read_namespaced_pod(name=pod, namespace=namespace)
        lines: list[str] = [
            f"Pod: {namespace}/{pod}",
            f"Phase: {pod_obj.status.phase}",
        ]
        for cs in pod_obj.status.container_statuses or []:
            lines.append(f"Container: {cs.name}")
            lines.append(f"  Ready: {cs.ready}")
            lines.append(f"  RestartCount: {cs.restart_count}")
            lines.append(f"  Image: {cs.image}")
            if cs.state.waiting:
                lines.append(f"  State: Waiting ({cs.state.waiting.reason})")
                if cs.state.waiting.message:
                    lines.append(f"  Message: {cs.state.waiting.message}")
            elif cs.state.running:
                lines.append(f"  State: Running (started {cs.state.running.started_at})")
            elif cs.state.terminated:
                t = cs.state.terminated
                lines.append(f"  State: Terminated (reason={t.reason}, exitCode={t.exit_code})")
            if cs.last_state and cs.last_state.terminated:
                lt = cs.last_state.terminated
                lines.append(
                    f"  LastState: Terminated (reason={lt.reason}, exitCode={lt.exit_code})"
                )
        return [
            EvidenceItem(
                kind=EvidenceKind.POD_STATUS,
                source="pod_status",
                content="\n".join(lines),
            )
        ]
