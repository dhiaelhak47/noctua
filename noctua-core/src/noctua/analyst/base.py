from abc import ABC, abstractmethod

from noctua.models.bundle import EvidenceBundle


class AnalystProvider(ABC):
    @abstractmethod
    def analyse(self, bundle: EvidenceBundle) -> EvidenceBundle: ...
