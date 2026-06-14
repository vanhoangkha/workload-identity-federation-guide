"""
FastAPI service demonstrating EKS IRSA → Hub Role → GCP WIF → GCS access.
Designed to run on EKS with IRSA-enabled ServiceAccount.
"""
import os
import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException, UploadFile, File
from fastapi.responses import StreamingResponse
from google.cloud import storage
from google.api_core.exceptions import NotFound, Forbidden

from .auth import get_gcs_client

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

GCS_BUCKET = os.environ["GCS_BUCKET"]
_gcs: storage.Client | None = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    global _gcs
    logger.info("Initialising GCS client via IRSA → hub role → WIF …")
    _gcs = get_gcs_client()
    logger.info("GCS client ready. bucket=%s", GCS_BUCKET)
    yield
    _gcs = None


app = FastAPI(title="gcs-wif-service", lifespan=lifespan)


def _bucket() -> storage.Bucket:
    return _gcs.bucket(GCS_BUCKET)


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/objects")
def list_objects(prefix: str = "", max_results: int = 100):
    """List blobs in the bucket."""
    blobs = _gcs.list_blobs(GCS_BUCKET, prefix=prefix, max_results=max_results)
    return {"objects": [b.name for b in blobs]}


@app.get("/objects/{path:path}")
def download_object(path: str):
    """Download a blob from GCS."""
    blob = _bucket().blob(path)
    try:
        data = blob.download_as_bytes()
    except NotFound:
        raise HTTPException(404, f"{path} not found")
    except Forbidden:
        raise HTTPException(403, "GCS access denied")
    return StreamingResponse(
        iter([data]),
        media_type=blob.content_type or "application/octet-stream",
        headers={"Content-Disposition": f'attachment; filename="{path.split("/")[-1]}"'},
    )


@app.put("/objects/{path:path}")
async def upload_object(path: str, file: UploadFile = File(...)):
    """Upload a file to GCS."""
    blob = _bucket().blob(path)
    try:
        blob.upload_from_file(file.file, content_type=file.content_type)
    except Forbidden:
        raise HTTPException(403, "GCS write access denied")
    return {"uploaded": path, "bucket": GCS_BUCKET}


@app.delete("/objects/{path:path}")
def delete_object(path: str):
    """Delete a blob from GCS."""
    blob = _bucket().blob(path)
    try:
        blob.delete()
    except NotFound:
        raise HTTPException(404, f"{path} not found")
    except Forbidden:
        raise HTTPException(403, "GCS delete access denied")
    return {"deleted": path}
