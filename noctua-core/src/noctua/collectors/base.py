from abc import ABC, abstractmethod

from noctua.models.bundle import EvidenceItem


class CollectorBase(ABC):
    @abstractmethod
    def collect(self, namespace: str, pod: str) -> list[EvidenceItem]: ...
