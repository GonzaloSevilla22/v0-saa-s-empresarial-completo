from __future__ import annotations

import asyncpg
import uuid
from decimal import Decimal
from fastapi import HTTPException

from backend.core.errors import ProblemHTTPException
from backend.core.guards import require_account_role, require_role
from backend.core.rbac import CAN_STOCK
from backend.repositories.plan_limits_repository import PlanLimitsRepository
from backend.repositories.product_category_repository import ProductCategoryRepository
from backend.repositories.product_repository import ProductRepository
from backend.schemas.products import ProductCreate, ProductUpdate

# v3-soft-delete-policy (D3): ERRCODE del guard RN-B4
# (fn_guard_product_soft_delete, migración 20260811000001).
_RN_B4_SQLSTATE = "P0B04"

# billing-pro-trial (D5): PLAN_PRODUCT_LIMITS retirado — el diccionario decía
# avanzado=2000 mientras plan_limits en la DB decía 1500 (divergencia real,
# invisible mientras el gating fue fail-open). El límite se lee ahora de
# plan_limits en runtime (spec plan-gating), alineado a 2000 en la misma
# migración que este change trae (20260817000001).

# productos-categorias-sku (D4/D5): nombres de los índices únicos vivos de
# products cuyo 23505 merece un mensaje legible. La restricción de la base es
# la fuente de verdad; acá sólo se traduce.
_SKU_UNIQUE_INDEX = "idx_products_sku_account_lower"
# productos-categorias-sku (task 4.5): el índice de barcode pasa de user_id
# a account_id (idx_products_barcode_account_unique), mismo residuo de
# tenencia que ya se corrigió para el SKU.
_BARCODE_UNIQUE_INDEX = "idx_products_barcode_account_unique"
# balanza-etiquetas-pos (D2): el código de balanza (PLU) es único por cuenta
# sobre filas vivas; y un padre variant_only no lo admite (CHECK en la base).
_SCALE_PLU_UNIQUE_INDEX = "idx_products_scale_plu_account_unique"
_SCALE_PLU_NOT_PARENT_CHECK = "products_scale_plu_not_parent"
_VARIANT_ONLY = "variant_only"
SCALE_PLU_TAKEN_CODE = "scale_plu_taken"
SCALE_PLU_PARENT_CODE = "scale_plu_parent"
_SCALE_PLU_PARENT_DETAIL = (
    "El código de balanza se asigna a cada variante: quitalo antes de "
    "convertir el producto en padre (un producto con variantes no lleva código de balanza)."
)


def _scale_plu_parent_error() -> ProblemHTTPException:
    return ProblemHTTPException(
        status_code=422, detail=_SCALE_PLU_PARENT_DETAIL,
        code=SCALE_PLU_PARENT_CODE, field="scale_plu",
    )


def _translate_check_violation(exc: asyncpg.CheckViolationError) -> HTTPException | None:
    """balanza-etiquetas-pos (D2): la regla del padre vive en la base
    (products_scale_plu_not_parent); si el 23514 llega igual (carrera o un
    camino que el guard previo no cubrió), sale el mismo 422 legible."""
    if getattr(exc, "constraint_name", None) == _SCALE_PLU_NOT_PARENT_CHECK:
        return _scale_plu_parent_error()
    return None


def _guard_scale_plu_not_parent(stock_control_type: str | None, scale_plu: int | None) -> None:
    """balanza-etiquetas-pos (D2): el 422 legible ANTES de escribir. La base
    lo sostiene igual con el CHECK."""
    if scale_plu is not None and stock_control_type == _VARIANT_ONLY:
        raise _scale_plu_parent_error()


def normalize_sku(sku: str | None) -> str | None:
    """productos-categorias-sku (spec product-sku): trim; vacío → None. Un SKU
    en blanco jamás se persiste como cadena vacía."""
    if sku is None:
        return None
    trimmed = sku.strip()
    return trimmed or None


def _translate_unique_violation(
    exc: asyncpg.UniqueViolationError, sku: str | None, scale_plu: int | None = None
) -> HTTPException | None:
    constraint = getattr(exc, "constraint_name", None)
    if constraint == _SCALE_PLU_UNIQUE_INDEX:
        return ProblemHTTPException(
            status_code=409,
            detail=f"El código de balanza {scale_plu} ya lo usa otro producto de tu cuenta.",
            code=SCALE_PLU_TAKEN_CODE,
            field="scale_plu",
        )
    if constraint == _SKU_UNIQUE_INDEX:
        return HTTPException(
            status_code=409,
            detail=f'El SKU "{sku}" ya pertenece a otro producto de tu cuenta (la comparación no distingue mayúsculas). Cambialo o dejalo vacío.',
        )
    if constraint == _BARCODE_UNIQUE_INDEX:
        return HTTPException(status_code=409, detail="Ya existe un producto con ese código de barras.")
    return None


async def _resolve_category_for_account(
    category_repo: ProductCategoryRepository, category_id: str, account_id: str
) -> asyncpg.Record:
    """Spec product-category: una categoría de OTRA cuenta (o borrada) se
    rechaza sin revelar si existe en otro lado — mismo 404 en los tres casos.
    Se acepta una desactivada: un producto puede seguir imputado a ella
    (edición que no cambia la categoría); la UI sólo ofrece activas."""
    category = await category_repo.get_by_id(category_id, account_id)
    if category is None:
        raise HTTPException(status_code=404, detail="Categoría no encontrada")
    return category


async def list_products(repo: ProductRepository, account_id: str) -> list:
    return await repo.list_by_org(account_id)


async def get_product(repo: ProductRepository, account_id: str, product_id: str) -> dict:
    record = await repo.get_by_id(product_id, account_id)
    if record is None:
        raise HTTPException(status_code=404, detail="Producto no encontrado")
    return dict(record)


async def _resolve_base_unit_for_account(
    repo: ProductRepository,
    base_unit_id: uuid.UUID | None,
    account_id: str,
) -> str | None:
    """ventas-unidades-conversion (D10): `None` se conserva (sin unidad base);
    un uuid tiene que ser una unidad del sistema o de la cuenta — el FK a
    units_of_measure no está scopeado por tenant, así que sin este guard un
    uuid ajeno se asignaría igual. 422 con token propio, nunca 500."""
    if base_unit_id is None:
        return None
    if not await repo.unit_visible_to_account(str(base_unit_id), account_id):
        raise HTTPException(
            status_code=422,
            detail="base_unit_not_found: la unidad base no existe o no pertenece a esta cuenta",
        )
    return str(base_unit_id)


# ventas-unidades-conversion — revisión del PR #584, hallazgo BE-1, decisión
# provisoria D-C (opción (a) de la decisión 6 del PO, pendiente de sign-off):
# las cantidades de branch_stock/stock_movements están en la unidad base del
# producto, así que CAMBIARLA (o desasignarla) con stock o historial las
# reinterpretaría en silencio. Asignar a un producto sin unidad y mandar la
# misma que ya tiene no son cambios.
BASE_UNIT_LOCKED_CODE = "base_unit_locked"
_BASE_UNIT_LOCKED_DETAIL = (
    "No se puede cambiar la unidad base de este producto: ya tiene stock o "
    "movimientos registrados en la unidad actual, y cambiarla haría que esas "
    "cantidades se lean en la unidad nueva (12 u pasarían a ser 12 kg). "
    "Dejá la unidad actual, o creá un producto nuevo con la unidad correcta "
    "y pasale el stock con un ajuste."
)
# Cuarta revisión del PR #584: ASIGNAR sobre stock e historia grabados con
# otra unidad explícita es la misma reinterpretación (historia en 'u' + base
# 'kg': "7 u" pasan a leerse "7 kg").
_BASE_UNIT_ASSIGN_LOCKED_DETAIL = (
    "No se puede asignar esa unidad base a este producto: ya tiene stock y "
    "operaciones cargadas en otra unidad, y asignarla haría que esas "
    "cantidades se lean en la unidad nueva (7 u pasarían a ser 7 kg). "
    "Asignale la unidad en la que ya lo venías cargando, o creá un producto "
    "nuevo con la unidad correcta y pasale el stock con un ajuste."
)


def _unit_str(value: object) -> str | None:
    return None if value is None else str(value)


# Segunda revisión del PR #584: este chequeo es el camino rápido con el 409
# tipado (code/field). La regla la hace cumplir la base —
# trg_product_base_unit_guard (P0409 base_unit_locked) evalúa con la fila
# bloqueada y cubre PostgREST, el importador, el re-parent de una variante y
# (cuarta revisión) el DELETE físico del padre y la asignación sobre historia
# en otra unidad; si la gana otro escritor, el asyncpg handler traduce el
# P0409 a 409. La carrera contra una
# compra concurrente la cierran los DOS lados: el trigger y las RPCs de
# venta/compra, que desde la tercera revisión normalizan la cantidad DESPUÉS
# de tomar el producto FOR UPDATE (antes, en tres de los seis caminos, una
# compra podía escribir kg sobre una base ya cambiada a 'u' —
# supabase/tests/test_ventas_unidades_conversion_race.sh).
async def _guard_base_unit_change(
    repo: ProductRepository,
    existing: asyncpg.Record,
    new_base_unit_id: str | None,
    product_id: str,
    account_id: str,
) -> None:
    current = _unit_str(existing["base_unit_id"] if "base_unit_id" in existing.keys() else None)
    if current == new_base_unit_id:
        return
    if current is None:
        # ASIGNAR (cuarta revisión): sólo se traba si alguna línea del grupo se
        # grabó con OTRA unidad explícita Y hay cantidades que reinterpretar.
        # Las líneas se miran primero: sin conflicto, ni se consulta el stock.
        if new_base_unit_id is None or not await repo.has_lines_in_other_unit(
            product_id, account_id, new_base_unit_id
        ):
            return
        if await repo.has_stock_or_movements(product_id, account_id):
            raise ProblemHTTPException(
                status_code=409,
                detail=_BASE_UNIT_ASSIGN_LOCKED_DETAIL,
                code=BASE_UNIT_LOCKED_CODE,
                field="base_unit_id",
            )
        return
    if await repo.has_stock_or_movements(product_id, account_id):
        raise ProblemHTTPException(
            status_code=409,
            detail=_BASE_UNIT_LOCKED_DETAIL,
            code=BASE_UNIT_LOCKED_CODE,
            field="base_unit_id",
        )


# stock-ledger-solo-rpc (D9): `PUT /products/{id}` NO ajusta stock. El formulario
# de edición mandaba SIEMPRE el stock que traía abierto y el backend aplicaba
# `objetivo - saldo actual`: una venta entre que se abría el formulario y se
# guardaba un cambio de PRECIO re-sumaba las unidades vendidas como "Ajuste
# manual de stock" (ajuste fantasma). El ajuste vive en `rpc_stock_adjustment`
# (modal de /stock), con rol y motivo.
STOCK_ADJUST_REQUIRED_CODE = "stock_adjust_required"
_STOCK_ADJUST_REQUIRED_DETAIL = "El stock se ajusta desde «Ajustar stock», con un motivo."


async def create_product(
    repo: ProductRepository,
    auth: dict,
    account_id: str,
    payload: ProductCreate,
    plan_limits_repo: PlanLimitsRepository,
    category_repo: ProductCategoryRepository | None = None,
    conn=None,
) -> dict:
    require_role(auth, ["user", "admin"])
    # stock-ledger-solo-rpc (D9, OQ-2): el stock inicial es un AJUSTE MANUAL, así
    # que exige CAN_STOCK (owner/admin/stock) — y se evalúa ANTES de contar contra
    # el límite del plan o insertar nada: sin el rol, 403 y el producto no se crea.
    # El rol de plataforma de arriba no alcanza (no mira el rol de la cuenta). El
    # mismo conjunto lo exige la base en `_stock_assert_can_adjust`; esto es la
    # defensa en profundidad que evita crear un producto y recién después fallar.
    if payload.stock != 0:
        await require_account_role(conn, auth, CAN_STOCK)
    plan = auth.get("plan", "pro")
    limits = await plan_limits_repo.get_limits(plan)
    limit = limits["max_products"]
    current_count = await repo.count_by_org(account_id)
    if current_count >= limit:
        raise HTTPException(
            status_code=403,
            detail=f"Límite de productos alcanzado para el plan {plan} ({limit} máx.). Borrá productos existentes o subí de plan.",
        )

    # balanza-etiquetas-pos (D2): un padre variant_only no lleva PLU — 422
    # legible antes de contar/escribir nada (la base lo sostiene con el CHECK).
    _guard_scale_plu_not_parent(payload.stock_control_type, payload.scale_plu)

    data = payload.model_dump()
    data["sku"] = normalize_sku(payload.sku)
    # ventas-unidades-conversion (D10): la unidad base viaja como str y tiene
    # que ser visible para la cuenta (del sistema o propia).
    data["base_unit_id"] = await _resolve_base_unit_for_account(repo, payload.base_unit_id, account_id)

    parent_id = data.get("parent_id")
    if parent_id:
        # D11/9.7: la variante hereda la categoría del PADRE resuelta en el
        # servidor — lo que mande el cliente se ignora.
        parent = await repo.get_by_id(parent_id, account_id)
        if parent is None:
            raise HTTPException(status_code=404, detail="Producto padre no encontrado")
        parent_category_id = parent["category_id"] if "category_id" in parent.keys() else None
        data["category_id"] = str(parent_category_id) if parent_category_id else None
    elif payload.category_id is not None:
        if category_repo is None:
            raise HTTPException(status_code=500, detail="Catálogo de categorías no disponible")
        await _resolve_category_for_account(category_repo, str(payload.category_id), account_id)
        data["category_id"] = str(payload.category_id)
    else:
        data["category_id"] = None

    try:
        record = await repo.create(auth["user_id"], account_id, data)
    except asyncpg.UniqueViolationError as exc:
        translated = _translate_unique_violation(exc, data["sku"], data.get("scale_plu"))
        if translated is not None:
            raise translated from exc
        raise
    except asyncpg.CheckViolationError as exc:
        translated = _translate_check_violation(exc)
        if translated is not None:
            raise translated from exc
        raise
    if record is None:
        raise HTTPException(status_code=500, detail="Error al crear el producto")
    return dict(record)


async def update_product(
    repo: ProductRepository,
    auth: dict,
    account_id: str,
    product_id: str,
    payload: ProductUpdate,
    *,
    sku_provided: bool = False,
    category_provided: bool = False,
    cost_provided: bool = False,
    base_unit_provided: bool = False,
    scale_plu_provided: bool = False,
    category_repo: ProductCategoryRepository | None = None,
) -> dict:
    """balanza-etiquetas-pos (D2) extiende el tri-estado a `scale_plu` y lee
    `existing` también cuando se informa el PLU o cambia `stock_control_type`,
    para dar el 422 del padre variant_only antes de escribir.

    productos-categorias-sku (D12): tri-estado por AUSENCIA para `sku` y
    `category_id` (`*_provided` derivado de `model_fields_set` en el router).
    productos-costo-nullable extiende el mismo molde a `cost`: campo ausente
    conserva el costo que el producto tenía, informado en `null` lo
    desasigna (queda sin costo cargado) — nunca por `is None`, porque `None`
    es indistinguible de "no lo mandé" sin `model_fields_set`.
    ventas-unidades-conversion (D10) extiende el molde a `base_unit_id`, con
    el guard de cambio de unidad (D-C, `_guard_base_unit_change`).
    El resto de los campos conserva `exclude_none` (task 9.4)."""
    require_role(auth, ["user", "admin"])
    data = payload.model_dump(
        exclude_none=True,
        exclude={"sku", "category_id", "cost", "base_unit_id", "scale_plu", "stock"},
    )
    changes_stock_control_type = payload.stock_control_type is not None
    stock_informed = payload.stock is not None

    # La fila actual sólo hace falta para los campos que dependen del estado
    # vivo (herencia de categoría, guard de unidad base, guard del PLU en un
    # padre, comparación del stock): una sola lectura.
    existing: asyncpg.Record | None = None
    if (
        category_provided or base_unit_provided or scale_plu_provided
        or changes_stock_control_type or stock_informed
    ):
        existing = await repo.get_by_id(product_id, account_id)
        if existing is None:
            raise HTTPException(status_code=404, detail="Producto no encontrado")

    # stock-ledger-solo-rpc (D9): un `stock` distinto del saldo actual NO se
    # aplica — 422 ANTES de escribir ningún campo. El MISMO valor se ignora
    # (compatibilidad con una pestaña abierta con el bundle anterior, que
    # siempre mandaba `stock`): el resto de la edición sigue su curso.
    if stock_informed and existing is not None:
        current = Decimal(str(existing["stock"])) if existing["stock"] is not None else Decimal("0")
        if Decimal(str(payload.stock)) != current:
            raise ProblemHTTPException(
                status_code=422,
                detail=_STOCK_ADJUST_REQUIRED_DETAIL,
                code=STOCK_ADJUST_REQUIRED_CODE,
                field="stock",
            )

    if existing is not None and (scale_plu_provided or changes_stock_control_type):
        existing_keys = existing.keys()
        effective_plu = (
            payload.scale_plu if scale_plu_provided
            else (existing["scale_plu"] if "scale_plu" in existing_keys else None)
        )
        effective_type = (
            payload.stock_control_type if changes_stock_control_type
            else (existing["stock_control_type"] if "stock_control_type" in existing_keys else None)
        )
        _guard_scale_plu_not_parent(effective_type, effective_plu)

    if scale_plu_provided:
        data["scale_plu"] = payload.scale_plu

    if sku_provided:
        data["sku"] = normalize_sku(payload.sku)

    if cost_provided:
        data["cost"] = payload.cost

    if base_unit_provided and existing is not None:
        new_base_unit = await _resolve_base_unit_for_account(repo, payload.base_unit_id, account_id)
        await _guard_base_unit_change(repo, existing, new_base_unit, product_id, account_id)
        data["base_unit_id"] = new_base_unit

    if category_provided and existing is not None:
        # D11/9.7: una variante hereda del padre — el cliente no puede
        # contradecirlo; se ignora sin validar ni escribir.
        if existing["parent_id"] is None:
            if payload.category_id is None:
                data["category_id"] = None
            else:
                if category_repo is None:
                    raise HTTPException(status_code=500, detail="Catálogo de categorías no disponible")
                await _resolve_category_for_account(category_repo, str(payload.category_id), account_id)
                data["category_id"] = str(payload.category_id)

    try:
        record = await repo.update(product_id, account_id, data)
    except asyncpg.UniqueViolationError as exc:
        translated = _translate_unique_violation(exc, data.get("sku"), data.get("scale_plu"))
        if translated is not None:
            raise translated from exc
        raise
    except asyncpg.CheckViolationError as exc:
        translated = _translate_check_violation(exc)
        if translated is not None:
            raise translated from exc
        raise
    if record is None:
        raise HTTPException(status_code=404, detail="Producto no encontrado")
    return dict(record)


async def bulk_set_category(
    repo: ProductRepository,
    auth: dict,
    account_id: str,
    product_ids: list[str],
    category_id: str,
    category_repo: ProductCategoryRepository,
) -> dict:
    """productos-categorias-sku (D14): recategorización en lote.

    La categoría destino se valida contra la cuenta y contra su estado vivo Y
    activo ANTES del UPDATE — inexistente, ajena, borrada o inactiva → 404 con
    un mensaje que no revela si existe en otra cuenta (criterio P0404 de
    cuenta-corriente-party-guard). Los ids de producto ajenos no producen
    error: quedan fuera del WHERE del repositorio.
    """
    require_role(auth, ["user", "admin"])
    unique_ids = list(dict.fromkeys(product_ids))
    target = await category_repo.get_active_by_id(category_id, account_id)
    if target is None:
        raise HTTPException(status_code=404, detail="Categoría no encontrada o inactiva")
    updated = await repo.bulk_set_category(unique_ids, account_id, category_id)
    return {"requested": len(unique_ids), "updated": updated}


# ── importador-productos-fastapi ────────────────────────────────────────────


async def import_products(
    repo: ProductRepository,
    auth: dict,
    *,
    idempotency_key: str,
    rows_json: str,
    file_name: str,
    file_hash: str,
    dry_run: bool,
) -> dict:
    """Traduce el payload y delega en `rpc_import_products`. CERO reglas de
    dominio nuevas acá (D1 del design) — si aparece un `if` de negocio, está
    en la capa equivocada.

    `require_role` es el guard de PLATAFORMA; el guard de TENANT
    (`is_account_writer`) vive DENTRO de la RPC (P0401) — defensa en
    profundidad, no duplicación. Los errores de FILA nunca escapan como
    excepción (D3 del design): viajan en `errors[]` del retorno normal, así
    que esta llamada responde siempre `200` salvo por un problema real de
    protocolo (payload malformado, tope de filas excedido, sin rol, sin
    clave de idempotencia, o el P0400 del propio upsert por exceder el tope
    de categorías nuevas — un rechazo de FORMA/CUOTA, no de fila).
    """
    require_role(auth, ["user", "admin"])
    return await repo.import_batch(
        idempotency_key=idempotency_key,
        rows_json=rows_json,
        file_name=file_name,
        file_hash=file_hash,
        dry_run=dry_run,
    )


async def delete_product(repo: ProductRepository, auth: dict, account_id: str, product_id: str) -> None:
    """v3-soft-delete-policy: borrado soft (RN-B1/RN-B2). El guard RN-B4 de la
    DB (stock <> 0 o referenciado en documentos draft) se traduce a 409 con
    mensaje de UX en español (D3)."""
    require_role(auth, ["user", "admin"])
    existing = await repo.get_by_id(product_id, account_id)
    if existing is None:
        raise HTTPException(status_code=404, detail="Producto no encontrado")
    try:
        await repo.soft_delete("products", product_id, account_id, auth["user_id"])
    except asyncpg.PostgresError as exc:
        if getattr(exc, "sqlstate", None) == _RN_B4_SQLSTATE:
            detail = getattr(exc, "message", None) or str(exc) or (
                "El producto tiene stock o está incluido en documentos en "
                "borrador; no puede borrarse"
            )
            raise HTTPException(status_code=409, detail=detail) from exc
        raise
