"""
edicion-operaciones-con-dinero (tanda B, grupo 10) — el BACKEND de la edición con dinero.

  · tri-estado por `model_fields_set` de `cash_session_id`, `bank_account_id` y `due_date` (y `reason`, `dry_run`) en
    los tres esquemas: ausente = conservar, presente (incluso null) = intención explícita;
  · `POST .../edit-preview` en los tres dominios: la misma RPC con `p_dry_run => true`, el plan devuelto TIPADO;
  · `GET .../edits`: el historial de ediciones, filtrado por la cuenta del usuario;
  · las proyecciones de los tres listados: sin `is_payment_locked`, con `edit_locked_reason` y los datos vigentes que el
    formulario precarga (huella neta: `op_money_footprint_state`);
  · la capacidad `CAN_CORRECT_MONEY` (OQ-4) y el guard del servicio, espejo de la RPC;
  · el mapeo RFC 7807 de los tokens nuevos con el `code` estable.

La capa unitaria usa dobles de asyncpg que replican el TRANSPORTE real (jsonb como `str`); la de integración
(`-m integration`, Postgres local) ejecuta las proyecciones de verdad.
"""
from __future__ import annotations

import inspect
import json
import re
from pathlib import Path
from unittest.mock import AsyncMock, patch

import asyncpg
import pytest

from backend.core import rbac
from backend.repositories import expense_repository, purchase_repository, sales_repository
from backend.schemas.expenses import ExpenseOut, ExpenseUpdate
from backend.schemas.purchases import PurchaseItemOut, PurchaseOperationUpdateIn
from backend.schemas.sales import SaleItemOut, SaleOperationUpdateIn
from backend.tests.conftest import named_rpc_arg, tenant_token

SALE_ID = "11111111-1111-1111-1111-111111111111"
PURCHASE_ID = "22222222-2222-2222-2222-222222222222"
EXPENSE_ID = "33333333-3333-3333-3333-333333333333"
OP_ID = "66666666-6666-6666-6666-666666666666"
SESSION_ID = "44444444-4444-4444-4444-444444444444"
BANK_ID = "55555555-5555-5555-5555-555555555555"
ACCOUNT_ID = "99999999-9999-9999-9999-999999999999"

ITEM = {"product_id": "77777777-7777-7777-7777-777777777777", "quantity": "1", "amount": "100.00"}
SALE_PUT = {"sale_ids": [SALE_ID], "client_id": None, "date": "2026-11-04", "currency": "ARS", "items": [ITEM]}
PURCHASE_PUT = {"purchase_ids": [PURCHASE_ID], "date": "2026-11-04", "items": [ITEM]}
EXPENSE_PUT = {"amount": "250"}

_PLAN = {
    "writes_money": True,
    "blocks": [],
    "account": {"action": "both", "party_kind": "customer", "party_id": None, "target_ledger": None,
                "register": {"party_id": None, "amount": 1200, "due_date": None, "reference_id": OP_ID},
                "reverse": [{"ledger_id": BANK_ID, "net": 1000, "reference_id": OP_ID}],
                "current_balance": 800, "projected_balance": 1000, "current_due_date": None},
    "cash": {"action": "none", "register": None, "reverse": []},
    "bank": {"action": "none", "register": None, "reverse": []},
}
_UPDATE_RESULT = json.dumps({"operation_id": OP_ID, "items": [], "voided_fiscal_document": None, "money": _PLAN})
_PREVIEW_RESULT = json.dumps({"dry_run": True, "plan": _PLAN, "voided_fiscal_document": None})
_EXPENSE_UPDATE_RESULT = json.dumps({"expense_id": EXPENSE_ID, "payment_method_id": None, "branch_id": None,
                                     "cost_center_id": None, "money": _PLAN})

_EXPENSE_ROW = {
    "id": EXPENSE_ID, "user_id": "88888888-8888-8888-8888-888888888888", "account_id": ACCOUNT_ID,
    "category": "otros", "amount": 250, "description": None, "date": "2026-11-04T00:00:00+00:00",
    "created_at": "2026-11-04T00:00:00+00:00", "cost_center_id": None, "branch_id": None,
    "payment_method_id": None, "payment_method_name": None, "payment_method_kind": None,
    "has_cash_movement": False, "has_bank_movement": False, "is_delete_blocked": False,
    "has_journal_entry": False, "journal_pending": False,
}


def _fetchval(roles, result):
    """`conn.fetchval` que distingue el guard de rol, la RPC de edición y la resolución de la cuenta."""
    captured: dict = {"calls": []}

    async def _f(query, *args, **kwargs):
        if "rpc_my_active_account_roles" in query:
            return roles
        if "current_account_ids" in query:
            return ACCOUNT_ID
        if "rpc_atomic_update_" in query or "rpc_update_expense" in query:
            captured["calls"].append({"query": query, "args": args})
            captured["query"], captured["args"] = query, args
            return result
        return None

    return AsyncMock(side_effect=_f), captured


# ═════════════════════ 10.1 — esquemas: tri-estado por model_fields_set ═════════════════════
@pytest.mark.parametrize("model, base", [
    (SaleOperationUpdateIn, SALE_PUT),
    (PurchaseOperationUpdateIn, PURCHASE_PUT),
])
def test_tri_estado_de_caja_banco_y_vencimiento(model, base) -> None:
    ausente = model(**base)
    assert not ({"cash_session_id", "bank_account_id", "due_date", "reason"} & ausente.model_fields_set)
    explicito = model(**base, cash_session_id=None, bank_account_id=None, due_date=None)
    assert {"cash_session_id", "bank_account_id", "due_date"} <= explicito.model_fields_set
    con_valor = model(**base, cash_session_id=SESSION_ID, bank_account_id=BANK_ID, due_date="2026-12-01", reason="x")
    assert str(con_valor.cash_session_id) == SESSION_ID and str(con_valor.bank_account_id) == BANK_ID
    assert str(con_valor.due_date) == "2026-12-01" and con_valor.reason == "x"


def test_el_gasto_tiene_caja_banco_y_motivo_pero_no_vencimiento() -> None:
    assert not ({"cash_session_id", "bank_account_id", "reason"} & ExpenseUpdate(**EXPENSE_PUT).model_fields_set)
    e = ExpenseUpdate(**EXPENSE_PUT, cash_session_id=None, bank_account_id=BANK_ID, reason="x")
    assert {"cash_session_id", "bank_account_id", "reason"} <= e.model_fields_set
    assert "due_date" not in ExpenseUpdate.model_fields


def test_el_motivo_es_opcional_y_acotado() -> None:
    with pytest.raises(Exception):
        SaleOperationUpdateIn(**SALE_PUT, reason="x" * 501)


# ═════════════════════ 10.2 — PUT: la RPC recibe la intención ═════════════════════
async def test_put_venta_pasa_el_tri_estado_a_la_rpc(async_client, mock_pool) -> None:
    pool, conn = mock_pool
    conn.fetchval, captured = _fetchval(["owner"], _UPDATE_RESULT)
    body = {**SALE_PUT, "cash_session_id": SESSION_ID, "bank_account_id": None, "reason": "corregi el precio"}
    with patch("backend.core.database.pool", pool):
        resp = await async_client.put("/sales/operation", json=body,
                                      headers={"Authorization": f"Bearer {tenant_token(['owner'])}"})
    assert resp.status_code == 200, resp.text
    assert named_rpc_arg(captured, "p_cash_provided") is True
    assert named_rpc_arg(captured, "p_cash_session_id") == SESSION_ID
    assert named_rpc_arg(captured, "p_bank_account_provided") is True      # presente con null = intención explícita
    assert named_rpc_arg(captured, "p_bank_account_id") is None
    assert named_rpc_arg(captured, "p_due_date_provided") is False         # ausente = conservar
    assert named_rpc_arg(captured, "p_reason") == "corregi el precio"
    assert named_rpc_arg(captured, "p_dry_run") is False
    assert resp.json()["money"]["writes_money"] is True                     # el servidor dicta el resultado


async def test_put_venta_sin_las_claves_conserva(async_client, mock_pool) -> None:
    pool, conn = mock_pool
    conn.fetchval, captured = _fetchval(["owner"], _UPDATE_RESULT)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.put("/sales/operation", json=SALE_PUT,
                                      headers={"Authorization": f"Bearer {tenant_token(['owner'])}"})
    assert resp.status_code == 200, resp.text
    for name in ("p_cash_provided", "p_bank_account_provided", "p_due_date_provided", "p_dry_run"):
        assert named_rpc_arg(captured, name) is False


async def test_put_compra_pasa_el_tri_estado(async_client, mock_pool) -> None:
    pool, conn = mock_pool
    conn.fetchval, captured = _fetchval(["owner"], _UPDATE_RESULT)
    body = {**PURCHASE_PUT, "due_date": "2026-12-15", "cash_session_id": None}
    with patch("backend.core.database.pool", pool):
        resp = await async_client.put("/purchases/operation", json=body,
                                      headers={"Authorization": f"Bearer {tenant_token(['owner'])}"})
    assert resp.status_code == 200, resp.text
    assert named_rpc_arg(captured, "p_due_date_provided") is True
    assert named_rpc_arg(captured, "p_cash_provided") is True
    assert named_rpc_arg(captured, "p_cash_session_id") is None
    assert named_rpc_arg(captured, "p_bank_account_provided") is False
    assert resp.json()["money"]["account"]["action"] == "both"


async def test_put_gasto_pasa_el_tri_estado_y_devuelve_el_plan(async_client, mock_pool) -> None:
    pool, conn = mock_pool
    conn.fetchval, _ = _fetchval(["owner"], _EXPENSE_UPDATE_RESULT)
    captured: dict = {}

    async def fetchrow(query, *args):
        if "rpc_update_expense" in query:
            captured["query"], captured["args"] = query, args
            return {"result": _EXPENSE_UPDATE_RESULT}
        return _EXPENSE_ROW

    conn.fetchrow = AsyncMock(side_effect=fetchrow)
    body = {**EXPENSE_PUT, "bank_account_id": BANK_ID, "cash_session_id": None, "reason": "motivo"}
    with patch("backend.core.database.pool", pool):
        resp = await async_client.put(f"/expenses/{EXPENSE_ID}", json=body,
                                      headers={"Authorization": f"Bearer {tenant_token(['owner'])}"})
    assert resp.status_code == 200, resp.text
    assert named_rpc_arg(captured, "p_bank_account_provided") is True
    assert named_rpc_arg(captured, "p_bank_account_id") == BANK_ID
    assert named_rpc_arg(captured, "p_cash_provided") is True
    assert named_rpc_arg(captured, "p_cash_session_id") is None
    assert named_rpc_arg(captured, "p_reason") == "motivo"
    assert named_rpc_arg(captured, "p_dry_run") is False
    assert resp.json()["money"]["writes_money"] is True


# ═════════════════════ 10.2 — vista previa ═════════════════════
async def test_preview_venta_es_la_misma_rpc_en_seco(async_client, mock_pool) -> None:
    pool, conn = mock_pool
    conn.fetchval, captured = _fetchval(["owner"], _PREVIEW_RESULT)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post("/sales/operation/edit-preview", json=SALE_PUT,
                                       headers={"Authorization": f"Bearer {tenant_token(['owner'])}"})
    assert resp.status_code == 200, resp.text
    assert "rpc_atomic_update_sale_operation" in captured["query"]
    assert named_rpc_arg(captured, "p_dry_run") is True
    body = resp.json()
    assert body["dry_run"] is True and float(body["plan"]["account"]["projected_balance"]) == 1000
    assert body["plan"]["blocks"] == []


async def test_preview_compra_y_gasto(async_client, mock_pool) -> None:
    pool, conn = mock_pool
    conn.fetchval, captured = _fetchval(["owner"], _PREVIEW_RESULT)
    conn.fetchrow = AsyncMock(return_value={"result": _PREVIEW_RESULT})
    with patch("backend.core.database.pool", pool):
        r1 = await async_client.post("/purchases/operation/edit-preview", json=PURCHASE_PUT,
                                     headers={"Authorization": f"Bearer {tenant_token(['owner'])}"})
        assert r1.status_code == 200, r1.text
        assert named_rpc_arg(captured, "p_dry_run") is True
        r2 = await async_client.post(f"/expenses/{EXPENSE_ID}/edit-preview", json=EXPENSE_PUT,
                                     headers={"Authorization": f"Bearer {tenant_token(['owner'])}"})
        assert r2.status_code == 200, r2.text
    assert r1.json()["dry_run"] is True and r2.json()["dry_run"] is True


async def test_preview_devuelve_los_bloqueos_como_datos(async_client, mock_pool) -> None:
    pool, conn = mock_pool
    plan = {**_PLAN, "blocks": [{"book": "cash", "code": "P0426", "token": "no_open_session_for_reversal",
                                 "message": "no_open_session_for_reversal: abrí la caja"}]}
    conn.fetchval, _ = _fetchval(["owner"], json.dumps({"dry_run": True, "plan": plan}))
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post("/sales/operation/edit-preview", json=SALE_PUT,
                                       headers={"Authorization": f"Bearer {tenant_token(['owner'])}"})
    assert resp.status_code == 200, resp.text
    assert resp.json()["plan"]["blocks"][0]["code"] == "P0426"


async def test_preview_exige_el_rol_de_dominio(async_client, mock_pool) -> None:
    pool, conn = mock_pool
    conn.fetchval, _ = _fetchval(["viewer"], _PREVIEW_RESULT)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post("/sales/operation/edit-preview", json=SALE_PUT,
                                       headers={"Authorization": f"Bearer {tenant_token(['viewer'])}"})
    assert resp.status_code == 403


# ═════════════════════ 10.2 — historial de ediciones ═════════════════════
_AUDIT_ROW = {
    "id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", "created_at": "2026-11-04T12:00:00+00:00",
    "user_id": "88888888-8888-8888-8888-888888888888", "user_name": "Ana", "action": "sale_operation.edited",
    "entity_type": "sale_operation", "entity_id": OP_ID,
    "metadata": json.dumps({"before": {"total": "1000.00"}, "after": {"total": "1200.00"}, "money": _PLAN,
                            "voided_fiscal_document": None, "reason": "factura corregida"}),
}


@pytest.mark.parametrize("path, action", [
    (f"/sales/operation/{OP_ID}/edits", "sale_operation.edited"),
    (f"/purchases/operation/{OP_ID}/edits", "purchase_operation.edited"),
    (f"/expenses/{EXPENSE_ID}/edits", "expense.edited"),
])
async def test_historial_de_ediciones_filtra_por_cuenta_y_accion(async_client, mock_pool, path, action) -> None:
    pool, conn = mock_pool
    conn.fetchval, _ = _fetchval(["owner"], None)
    captured: dict = {}

    async def fetch(query, *args):
        captured["query"], captured["args"] = query, args
        return [{**_AUDIT_ROW, "action": action}]

    conn.fetch = AsyncMock(side_effect=fetch)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(path, headers={"Authorization": f"Bearer {tenant_token(['owner'])}"})
    assert resp.status_code == 200, resp.text
    # La lectura va por rpc_operation_edits (SECURITY DEFINER): audit_logs no tiene policy por cuenta, y la RPC filtra por la
    # cuenta ACTIVA de la sesión —nunca por un parámetro—. El repositorio no recibe ni manda un account_id.
    assert "rpc_operation_edits" in captured["query"]
    assert action in captured["args"] and (OP_ID in captured["args"] or EXPENSE_ID in captured["args"])
    item = resp.json()[0]
    assert item["reason"] == "factura corregida" and item["user_name"] == "Ana"
    assert item["before"]["total"] == "1000.00" and item["after"]["total"] == "1200.00"
    assert item["money"]["writes_money"] is True


async def test_historial_vacio_sin_ediciones(async_client, mock_pool) -> None:
    pool, conn = mock_pool
    conn.fetchval, _ = _fetchval(["owner"], None)
    conn.fetch = AsyncMock(return_value=[])
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(f"/sales/operation/{OP_ID}/edits",
                                      headers={"Authorization": f"Bearer {tenant_token(['owner'])}"})
    assert resp.status_code == 200 and resp.json() == []


# ═════════════════════ 10.3 — proyecciones ═════════════════════
@pytest.mark.parametrize("model", [SaleItemOut, PurchaseItemOut, ExpenseOut])
def test_los_esquemas_de_lectura_no_exponen_is_payment_locked(model) -> None:
    assert "is_payment_locked" not in model.model_fields
    assert "edit_locked_reason" in model.model_fields
    for campo in ("charge_due_date", "charge_party_id", "cash_cashbox_id", "cash_open_session_id", "bank_account_id"):
        assert campo in model.model_fields, f"{model.__name__} no expone {campo}"


@pytest.mark.parametrize("module", [sales_repository, purchase_repository, expense_repository])
def test_ningun_repositorio_calcula_is_payment_locked(module) -> None:
    src = inspect.getsource(module)
    assert not re.search(r"\bAS\s+is_payment_locked\b", src), f"{module.__name__} sigue calculando is_payment_locked"
    assert "op_money_footprint_state" in src, "la proyección debe consumir la función única de la huella neta"


def test_el_listado_de_ventas_deriva_el_motivo_del_servidor() -> None:
    src = inspect.getsource(sales_repository)
    assert "delivery_note_sale_locked" in src and "service_lines_locked" in src


def test_el_listado_de_compras_deriva_el_motivo_del_servidor() -> None:
    assert "delivery_note_purchase_locked" in inspect.getsource(purchase_repository)


# ═════════════════════ 10.4 — capacidad CAN_CORRECT_MONEY (OQ-4) ═════════════════════
def test_can_correct_money_es_dueno_o_administrador() -> None:
    assert rbac.CAN_CORRECT_MONEY == frozenset({"owner", "admin"})
    assert rbac.is_sensitive_capability(rbac.CAN_CORRECT_MONEY)   # la autoridad es la base, no el claim


def test_can_correct_money_espeja_la_base_y_el_frontend() -> None:
    """Ata las tres fuentes: el rol que la RPC exige en el plan, la constante del backend y la del frontend."""
    root = Path(__file__).resolve().parents[2]
    migration = next((root / "supabase" / "migrations").glob("*edicion_operaciones_dinero.sql")).read_text(encoding="utf-8")
    m = re.search(r"account_user_active_roles\(p_account_id, auth\.uid\(\)\) && ARRAY\[([^\]]+)\]", migration)
    assert m, "no se encontró el rol que _op_edit_plan exige para escribir dinero"
    assert set(re.findall(r"'([a-z_]+)'", m.group(1))) == set(rbac.CAN_CORRECT_MONEY)
    front = (root / "frontend" / "lib" / "rbac-capabilities.ts").read_text(encoding="utf-8")
    f = re.search(r"CAN_CORRECT_MONEY[^=]*=\s*(?:new Set\()?\[([^\]]+)\]", front)
    assert f, "frontend/lib/rbac-capabilities.ts no declara CAN_CORRECT_MONEY"
    assert set(re.findall(r"['\"]([a-z_]+)['\"]", f.group(1))) == set(rbac.CAN_CORRECT_MONEY)


async def test_el_cajero_no_corrige_dinero_en_el_servicio(async_client, mock_pool) -> None:
    """Guard del servicio (espejo de la RPC): un rol sin CAN_CORRECT_MONEY cuya edición ESCRIBE dinero se corta antes de
    la edición real; la vista previa que lo decide corre en seco y no escribe."""
    pool, conn = mock_pool
    conn.fetchval, captured = _fetchval(["cashier"], _PREVIEW_RESULT)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.put("/sales/operation", json=SALE_PUT,
                                      headers={"Authorization": f"Bearer {tenant_token(['cashier'])}"})
    assert resp.status_code == 403
    assert resp.json()["code"] == "money_edit_requires_admin"
    assert [named_rpc_arg(c, "p_dry_run") for c in captured["calls"]] == [True]   # sólo la vista previa: nada se escribió


async def test_el_cajero_edita_sin_dinero(async_client, mock_pool) -> None:
    plan = {**_PLAN, "writes_money": False}
    pool, conn = mock_pool

    async def _f(query, *args, **kwargs):
        if "rpc_my_active_account_roles" in query:
            return ["cashier"]
        if "rpc_atomic_update_sale_operation" in query:
            dry = named_rpc_arg({"query": query, "args": args}, "p_dry_run")
            return json.dumps({"dry_run": True, "plan": plan} if dry else
                              {"operation_id": OP_ID, "items": [], "voided_fiscal_document": None, "money": plan})
        return None

    conn.fetchval = AsyncMock(side_effect=_f)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.put("/sales/operation", json=SALE_PUT,
                                      headers={"Authorization": f"Bearer {tenant_token(['cashier'])}"})
    assert resp.status_code == 200, resp.text


# ═════════════════════ 10.5 — mapeo RFC 7807 de los tokens nuevos ═════════════════════
class _PgError(asyncpg.PostgresError):
    def __init__(self, sqlstate: str, message: str) -> None:
        super().__init__(message)
        self.sqlstate = sqlstate


@pytest.mark.parametrize("sqlstate, message, status, code", [
    ("P0422", "cash_intent_required: la sucursal cambió", 422, "cash_intent_required"),
    ("P0403", "money_edit_requires_admin: solo el dueño", 403, "money_edit_requires_admin"),
    ("P0425", "reversal_would_go_negative: el saldo quedaría en -1", 409, "reversal_would_go_negative"),
    ("P0426", "no_open_session_for_reversal: abrí la caja", 409, "no_open_session_for_reversal"),
    ("P0424", "bank_period_reconciled: período conciliado", 409, "bank_period_reconciled"),
])
async def test_los_tokens_de_edicion_viajan_como_code_estable(async_client, mock_pool, sqlstate, message, status, code) -> None:
    pool, conn = mock_pool

    async def _f(query, *args, **kwargs):
        if "rpc_my_active_account_roles" in query:
            return ["owner"]
        if "rpc_atomic_update_sale_operation" in query:
            raise _PgError(sqlstate, message)
        return None

    conn.fetchval = AsyncMock(side_effect=_f)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.put("/sales/operation", json=SALE_PUT,
                                      headers={"Authorization": f"Bearer {tenant_token(['owner'])}"})
    assert resp.status_code == status, resp.text
    assert resp.json()["code"] == code


async def test_el_gasto_tambien_traduce_los_tokens_de_edicion(async_client, mock_pool) -> None:
    pool, conn = mock_pool
    conn.fetchval, _ = _fetchval(["owner"], None)
    conn.fetchrow = AsyncMock(side_effect=_PgError("P0426", "no_open_session_for_reversal: abrí la caja"))
    with patch("backend.core.database.pool", pool):
        resp = await async_client.put(f"/expenses/{EXPENSE_ID}", json=EXPENSE_PUT,
                                      headers={"Authorization": f"Bearer {tenant_token(['owner'])}"})
    assert resp.status_code == 409
    assert resp.json()["code"] == "no_open_session_for_reversal"
