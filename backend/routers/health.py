from fastapi import APIRouter

router = APIRouter()


@router.get("/health")
async def health():
    """Health check endpoint. No authentication required."""
    return {"status": "ok"}
