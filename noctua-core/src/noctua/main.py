from fastapi import FastAPI
from noctua.api.health import router as health_router

app = FastAPI(
    title="Noctua",
    description="Evidence-first incident investigation for Kubernetes",
    version="0.1.0",
)

app.include_router(health_router)
