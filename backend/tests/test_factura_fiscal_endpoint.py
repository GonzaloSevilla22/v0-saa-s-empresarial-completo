"""
factura-fiscal-imprimible — grupo 5: `GET /fiscal/documents/{id}/pdf`.

3 capas (D9): router sólo DI + `Response`; service con las reglas; repositorio
con filtro EXPLÍCITO por `account_id` además de la RLS.

  * 200 `application/pdf` sólo para un `authorized` de la cuenta;
    `Content-Disposition` inline por defecto o attachment, con el nombre
    `factura-C-0003-00000501.pdf`;
  * 404 IDÉNTICO para uno de otra cuenta y para uno inexistente (no se filtra
    la existencia de comprobantes ajenos);
  * 409 RFC 7807 con `code` estable: no autorizado, emisor incompleto (con la
    lista `missing`), fecha desconocida, líneas que no suman;
  * 422 id no-UUID o `copia`/`disposition` inválidos; 401 sin sesión.
"""
from __future__ import annotations

import datetime
import io
import uuid
from decimal import Decimal
from unittest.mock import AsyncMock, patch

import pytest

from backend.tests.conftest import TEST_ACCOUNT_ID, make_token


DOC_ID = uuid.UUID("caaeccfd-1111-4111-8111-111111111111")
CAE = "71234567890123"

PROFILE = {
    "cuit": "27213790337",
    "razon_social": "PEREZ MARIA LAURA",
    "nombre_fantasia": "Sumar",
    "domicilio_comercial": "Av. San Martín 1234, Mendoza",
    "iva_condition": "monotributista",
    "iibb_condition": None,
    "iibb_numero": "0712345",
    "inicio_actividades": datetime.date(2019, 3, 1),
    "ambiente": "produccion",
}

INVOICE = {
    "lines": [{
        "name_snapshot": "Ciclista Lycra con Bolsillos Kaese Talle 2 Negro",
        "quantity": Decimal("1"),
        "price": Decimal("32500.00"),
        "subtotal": Decimal("32500.00"),
        "unit_symbol": None,
    }],
    "sale_condition_kind": None,
}


def doc(**overrides) -> dict:
    base = {
        "id": DOC_ID,
        "account_id": TEST_ACCOUNT_ID,
        "status": "authorized",
        "comprobante_type": "factura_c",
        "punto_de_venta": 3,
        "number": 501,
        "total": Decimal("32500.00"),
        "cae": CAE,
        "cae_due_date": datetime.date(2026, 10, 5),
        "fecha_comprobante": datetime.date(2026, 9, 25),
        "receptor_doc_tipo": None,
        "receptor_doc_nro": None,
        "receptor_legal_name": None,
        "receptor_iva_condition": None,
        "emisor_snapshot": None,
    }
    base.update(overrides)
    return base


def _auth():
    return {"Authorization": f"Bearer {make_token({'role': 'user'})}"}


async def _get(async_client, mock_pool, *, document, profile=PROFILE, invoice=INVOICE,
               path=None, headers=None):
    pool, _conn = mock_pool
    with (
        patch("backend.core.database.pool", pool),
        patch("backend.repositories.fiscal_document_repository.FiscalDocumentRepository.get_by_id",
              AsyncMock(return_value=document)) as get_by_id,
        patch("backend.repositories.fiscal_document_repository.FiscalDocumentRepository.get_invoice_lines",
              AsyncMock(return_value=invoice)),
        patch("backend.repositories.fiscal_profile_repository.FiscalProfileRepository.get_by_account_id",
              AsyncMock(return_value=profile)),
    ):
        resp = await async_client.get(
            path or f"/fiscal/documents/{DOC_ID}/pdf",
            headers=_auth() if headers is None else headers,
        )
    return resp, get_by_id


class TestEndpoint:

    async def test_el_duenio_descarga_su_factura(self, async_client, mock_pool):
        resp, get_by_id = await _get(
            async_client, mock_pool, document=doc(),
            path=f"/fiscal/documents/{DOC_ID}/pdf?disposition=attachment",
        )

        assert resp.status_code == 200
        assert resp.headers["content-type"] == "application/pdf"
        assert resp.headers["content-disposition"] == 'attachment; filename="factura-C-0003-00000501.pdf"'
        assert resp.headers["cache-control"] == "private, no-store"
        assert resp.content.startswith(b"%PDF")
        # tenencia: la lectura se hace con el account_id del request
        assert get_by_id.await_args.args == (str(DOC_ID), str(TEST_ACCOUNT_ID))

    async def test_inline_por_defecto(self, async_client, mock_pool):
        resp, _ = await _get(async_client, mock_pool, document=doc())

        assert resp.status_code == 200
        assert resp.headers["content-disposition"] == 'inline; filename="factura-C-0003-00000501.pdf"'

    async def test_duplicado(self, async_client, mock_pool):
        resp, _ = await _get(async_client, mock_pool, document=doc(),
                             path=f"/fiscal/documents/{DOC_ID}/pdf?copia=duplicado")

        assert resp.status_code == 200
        # pypdf sólo en CI: el skip alcanza a este test, no a todo el módulo.
        pypdf = pytest.importorskip("pypdf")
        text = "".join(p.extract_text() for p in pypdf.PdfReader(io.BytesIO(resp.content)).pages)
        assert "DUPLICADO" in text and "ORIGINAL" not in text

    async def test_otra_cuenta_e_inexistente_responden_igual(self, async_client, mock_pool):
        """Contrato HTTP: un comprobante ajeno llega del repositorio como None,
        igual que uno inexistente, y la respuesta es byte a byte la misma. QUE
        el repositorio devuelva None para uno ajeno lo fijan
        TestRepositorio.test_get_by_id_filtra_por_cuenta_en_el_sql (SQL y
        parámetros) y test_factura_fiscal_tenencia_integration.py (Postgres real
        como postgres, sin RLS)."""
        ajeno, _ = await _get(async_client, mock_pool, document=None)
        inexistente, _ = await _get(async_client, mock_pool, document=None,
                                    path=f"/fiscal/documents/{uuid.uuid4()}/pdf")

        assert ajeno.status_code == inexistente.status_code == 404
        assert ajeno.json() == inexistente.json()
        assert ajeno.json()["code"] == "fiscal_document_not_found"
        assert ajeno.headers["content-type"].startswith("application/problem+json")

    @pytest.mark.parametrize("status", ["pending_cae", "rejected", "voided"])
    async def test_un_comprobante_no_autorizado_no_es_una_factura(self, async_client, mock_pool, status):
        resp, _ = await _get(async_client, mock_pool, document=doc(status=status, cae=None))

        assert resp.status_code == 409
        assert resp.json()["code"] == "fiscal_document_not_authorized"

    async def test_emisor_incompleto_lista_los_faltantes(self, async_client, mock_pool):
        resp, _ = await _get(async_client, mock_pool, document=doc(),
                             profile={**PROFILE, "domicilio_comercial": None, "inicio_actividades": None})

        assert resp.status_code == 409
        body = resp.json()
        assert body["code"] == "issuer_data_incomplete"
        assert body["missing"] == ["domicilio_comercial", "inicio_actividades"]
        assert body["status"] == 409 and body["title"]

    async def test_sin_fecha_confirmada(self, async_client, mock_pool):
        resp, _ = await _get(async_client, mock_pool, document=doc(fecha_comprobante=None))

        assert resp.status_code == 409
        assert resp.json()["code"] == "invoice_date_unknown"
        assert "missing" not in resp.json()

    async def test_lineas_que_no_suman(self, async_client, mock_pool):
        invoice = {**INVOICE, "lines": [{**INVOICE["lines"][0], "subtotal": Decimal("100")}]}
        resp, _ = await _get(async_client, mock_pool, document=doc(), invoice=invoice)

        assert resp.status_code == 409
        assert resp.json()["code"] == "invoice_lines_mismatch"

    async def test_id_no_uuid_es_422(self, async_client, mock_pool):
        resp, get_by_id = await _get(async_client, mock_pool, document=doc(),
                                     path="/fiscal/documents/no-es-un-uuid/pdf")

        assert resp.status_code == 422
        get_by_id.assert_not_awaited()

    @pytest.mark.parametrize("query", ["copia=triplicado", "disposition=download"])
    async def test_parametro_invalido_es_422(self, async_client, mock_pool, query):
        resp, get_by_id = await _get(async_client, mock_pool, document=doc(),
                                     path=f"/fiscal/documents/{DOC_ID}/pdf?{query}")

        assert resp.status_code == 422
        get_by_id.assert_not_awaited()

    async def test_sin_sesion_es_401(self, async_client, mock_pool):
        resp, get_by_id = await _get(async_client, mock_pool, document=doc(), headers={})

        assert resp.status_code == 401
        get_by_id.assert_not_awaited()


# ═══════════════════════════════════════════════════════════════════════════
# 5.2 — Repositorio: líneas y condición de venta con tenencia explícita
# ═══════════════════════════════════════════════════════════════════════════

class TestRepositorio:

    async def test_get_by_id_filtra_por_cuenta_en_el_sql(self):
        """La única capa de tenencia explícita del endpoint (la RLS es red, no
        guard único): el WHERE exige id Y account_id, con el account_id del
        request como segundo parámetro. Sin esto, el 404 idéntico ajeno/
        inexistente de TestEndpoint sería verdad sólo por el mock."""
        from backend.repositories.fiscal_document_repository import FiscalDocumentRepository

        conn = AsyncMock()
        conn.fetchrow = AsyncMock(return_value=None)

        result = await FiscalDocumentRepository(conn).get_by_id(str(DOC_ID), str(TEST_ACCOUNT_ID))

        query, *args = conn.fetchrow.await_args.args
        normalized = " ".join(query.split())
        assert args == [str(DOC_ID), str(TEST_ACCOUNT_ID)]
        assert "FROM public.fiscal_documents" in normalized
        assert "WHERE id = $1 AND account_id = $2" in normalized
        assert result is None

    async def test_get_by_id_devuelve_la_fila_como_dict(self):
        from backend.repositories.fiscal_document_repository import FiscalDocumentRepository

        conn = AsyncMock()
        conn.fetchrow = AsyncMock(return_value={"id": DOC_ID, "account_id": TEST_ACCOUNT_ID})

        result = await FiscalDocumentRepository(conn).get_by_id(str(DOC_ID), str(TEST_ACCOUNT_ID))

        assert result == {"id": DOC_ID, "account_id": TEST_ACCOUNT_ID}

    async def test_get_invoice_lines_filtra_por_cuenta_y_ordena(self):
        from backend.repositories.fiscal_document_repository import FiscalDocumentRepository

        conn = AsyncMock()
        conn.fetch = AsyncMock(return_value=[
            {"name_snapshot": "A", "quantity": Decimal("1"), "price": Decimal("10"),
             "subtotal": Decimal("10"), "unit_symbol": "u"},
            {"name_snapshot": "B", "quantity": Decimal("2"), "price": Decimal("5"),
             "subtotal": Decimal("10"), "unit_symbol": None},
        ])
        conn.fetchval = AsyncMock(return_value="credit")

        result = await FiscalDocumentRepository(conn).get_invoice_lines(str(DOC_ID), str(TEST_ACCOUNT_ID))

        lines_query, *lines_args = conn.fetch.await_args.args
        normalized = " ".join(lines_query.split())
        assert lines_args == [str(DOC_ID), str(TEST_ACCOUNT_ID)]
        assert "so.fiscal_document_id = $1" in normalized
        assert "so.account_id = $2" in normalized
        assert "soi.account_id = so.account_id" in normalized
        assert "ORDER BY soi.id" in normalized
        for col in ("soi.quantity", "soi.price", "soi.subtotal"):
            assert col in normalized
        # Sin snapshot del nombre (231 líneas en prod, medido 2026-09-26: órdenes
        # viejas y ventas promovidas), la descripción es el nombre del producto
        # — nunca "Sin descripción" en una factura.
        assert ("COALESCE(NULLIF(btrim(soi.name_snapshot), ''), p.name) AS name_snapshot") in normalized
        assert "LEFT JOIN public.products p ON p.id = soi.product_id" in normalized

        kind_query, *kind_args = conn.fetchval.await_args.args
        normalized_kind = " ".join(kind_query.split())
        assert kind_args == [str(DOC_ID), str(TEST_ACCOUNT_ID)]
        assert "so.account_id = $2" in normalized_kind
        # la forma de pago de la orden gana; si no, la de la operación de venta
        assert "COALESCE(opm.kind" in normalized_kind
        assert "s.operation_id = so.sale_operation_id" in normalized_kind

        assert [line["name_snapshot"] for line in result["lines"]] == ["A", "B"]
        assert result["sale_condition_kind"] == "credit"

    async def test_sin_orden_vinculada_no_hay_lineas(self):
        from backend.repositories.fiscal_document_repository import FiscalDocumentRepository

        conn = AsyncMock()
        conn.fetch = AsyncMock(return_value=[])
        conn.fetchval = AsyncMock(return_value=None)

        result = await FiscalDocumentRepository(conn).get_invoice_lines(str(DOC_ID), str(TEST_ACCOUNT_ID))

        assert result == {"lines": [], "sale_condition_kind": None}
