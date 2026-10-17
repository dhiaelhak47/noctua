from kubernetes import client
from kubernetes.client.rest import ApiException

from noctua.collectors.base import CollectorBase
from noctua.models.bundle import EvidenceItem, EvidenceKind

_REVISION_ANNOTATION = "deployment.kubernetes.io/revision"


class RolloutCollector(CollectorBase):
    def __init__(self, v1: client.CoreV1Api, apps_v1: client.AppsV1Api) -> None:
        self._v1 = v1
        self._apps_v1 = apps_v1

    def collect(self, namespace: str, pod: str) -> list[EvidenceItem]:
        try:
            pod_obj = self._v1.read_namespaced_pod(name=pod, namespace=namespace)
        except ApiException:
            return []

        rs_name = next(
            (r.name for r in (pod_obj.metadata.owner_references or []) if r.kind == "ReplicaSet"),
            None,
        )
        if not rs_name:
            return [
                EvidenceItem(
                    kind=EvidenceKind.ROLLOUT,
                    source="rollout_history",
                    content="Pod has no ReplicaSet owner (not managed by a Deployment).",
                )
            ]

        try:
            rs = self._apps_v1.read_namespaced_replica_set(name=rs_name, namespace=namespace)
        except ApiException:
            return []

        dep_name = next(
            (r.name for r in (rs.metadata.owner_references or []) if r.kind == "Deployment"),
            None,
        )
        if not dep_name:
            return [
                EvidenceItem(
                    kind=EvidenceKind.ROLLOUT,
                    source="rollout_history",
                    content=f"ReplicaSet {rs_name} has no Deployment owner.",
                )
            ]

        try:
            dep = self._apps_v1.read_namespaced_deployment(name=dep_name, namespace=namespace)
        except ApiException:
            return []

        selector = dep.spec.selector.match_labels or {}
        label_sel = ",".join(f"{k}={v}" for k, v in selector.items())
        all_rs = self._apps_v1.list_namespaced_replica_set(
            namespace=namespace, label_selector=label_sel
        )

        revisions: list[tuple[int, str, str]] = []
        for r in all_rs.items:
            rev = (r.metadata.annotations or {}).get(_REVISION_ANNOTATION)
            if rev:
                containers = r.spec.template.spec.containers
                image = containers[0].image if containers else "unknown"
                revisions.append((int(rev), r.metadata.name, image))
        revisions.sort(key=lambda x: x[0])

        ready = dep.status.ready_replicas or 0
        total = dep.status.replicas or 0
        lines = [
            f"Deployment: {namespace}/{dep_name}",
            f"Ready replicas: {ready}/{total}",
            "",
            f"{'Rev':<6} {'ReplicaSet':<45} Image",
            "-" * 90,
        ]
        for rev, rs_n, image in revisions:
            marker = " ← current" if rs_n == rs_name else ""
            lines.append(f"{rev:<6} {rs_n:<45} {image}{marker}")

        return [
            EvidenceItem(
                kind=EvidenceKind.ROLLOUT,
                source="rollout_history",
                content="\n".join(lines),
            )
        ]
