from __future__ import annotations

from fastapi import HTTPException


def require_role(auth: dict, allowed: list[str]) -> None:
    if auth.get("role") not in allowed:
        raise HTTPException(
            status_code=403,
            detail=f"Rol insuficiente: se requiere {' o '.join(allowed)}",
        )


def require_plan(auth: dict, allowed_plans: list[str]) -> None:
    plan = auth.get("plan", "gratis")
    if plan not in allowed_plans:
        raise HTTPException(status_code=403, detail="Límite de plan alcanzado")
