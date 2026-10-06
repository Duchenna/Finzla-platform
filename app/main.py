import os
import logging
import sys
from datetime import datetime, timezone

from fastapi import FastAPI, Response, status
from fastapi.responses import JSONResponse

# ---- Logging: JSON to stdout (12-factor) ----
logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format='{"ts":"%(asctime)s","level":"%(levelname)s","msg":"%(message)s"}',
    stream=sys.stdout,
)
logger = logging.getLogger("finzla-app")

APP_ENV = os.getenv("APP_ENV", "dev")
APP_VERSION = os.getenv("APP_VERSION", "0.0.0")
GIT_SHA = os.getenv("GIT_SHA", "unknown")

app = FastAPI(title="Finzla Service", version=APP_VERSION)


@app.get("/health")
def health():
    """Liveness/readiness probe endpoint."""
    logger.info("health check hit env=%s", APP_ENV)
    return JSONResponse(
        status_code=status.HTTP_200_OK,
        content={"status": "ok", "env": APP_ENV, "ts": datetime.now(timezone.utc).isoformat()},
    )


@app.get("/version")
def version():
    logger.info("version check hit")
    return {
        "version": APP_VERSION,
        "git_sha": GIT_SHA,
        "env": APP_ENV,
    }


@app.get("/")
def root():
    return {"service": "finzla-platform", "env": APP_ENV}