"""
factura-fiscal-imprimible — grupo 3: los datos del emisor en el perfil fiscal.

RG 1415 exige en la factura la razón social, el domicilio comercial, el número
de Ingresos Brutos (o su condición) y la fecha de inicio de actividades, y
`fiscal_profiles` no tenía ninguno. Este archivo fija:

  * schemas: `FiscalProfileCreate`/`Out` con los 5 campos nuevos, largos
    máximos (120/120/200/30) e `inicio_actividades` no futura → 422;
  * upsert TRI-ESTADO (patrón `edicion-preserva-contexto`) para los 5 campos y
    para `iibb_condition`: ausente = conservar, `null` explícito = borrar,
    valor = reemplazar. Hasta ahora `iibb_condition` se pisaba con NULL cada
    vez que el payload no lo traía;
  * la atestación de delegación (#583) sigue igual.

Spec: fiscal-profile/spec.md §"API del perfil fiscal" (delta del change).
"""
from __future__ import annotations

import datetime
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from pydantic import ValidationError

from backend.tests.conftest import TEST_ACCOUNT_ID, make_token

ACCOUNT_ID = str(TEST_ACCOUNT_ID)

_TRI_ESTADO = (
    "iibb_condition",
    "razon_social",
    "nombre_fantasia",
    "domicilio_comercial",
    "iibb_numero",
    "inicio_actividades",
)

BASE = {"cuit": "27213790337", "iva_condition": "monotributista", "ambiente": "produccion"}

PROFILE_ROW = {
    "id": "ffffffff-ffff-ffff-ffff-ffffffffffff",
    "account_id": ACCOUNT_ID,
    "cuit": "27213790337",
    "iva_condition": "monotributista",
    "iibb_condition": None,
    "certificado_afip_path": None,
    "ambiente": "produccion",
    "created_at": "2026-06-27T00:00:00+00:00",
    "delegacion_autorizada": True,
    "razon_social": "PEREZ MARIA LAURA",
    "nombre_fantasia": "Sumar",
    "domicilio_comercial": "Av. San Martín 1234, Mendoza",
    "iibb_numero": "0712345",
    "inicio_actividades": datetime.date(2019, 3, 1),
}


def _manana_en_argentina() -> datetime.date:
    from backend.core.timezone import today_in_argentina

    return today_in_argentina() + datetime.timedelta(days=1)


# ═══════════════════════════════════════════════════════════════════════════
# 3.1 — Schemas
# ═══════════════════════════════════════════════════════════════════════════

class TestSchemas:

    def test_create_acepta_los_datos_del_emisor(self):
        from backend.schemas.fiscal import FiscalProfileCreate

        p = FiscalProfileCreate(
            **BASE,
            razon_social="PEREZ MARIA LAURA",
            nombre_fantasia="Sumar",
            domicilio_comercial="Av. San Martín 1234, Mendoza",
            iibb_numero="0712345",
            inicio_actividades="2019-03-01",
        )

        assert p.razon_social == "PEREZ MARIA LAURA"
        assert p.inicio_actividades == datetime.date(2019, 3, 1)

    @pytest.mark.parametrize(
        ("campo", "maximo"),
        [("razon_social", 120), ("nombre_fantasia", 120), ("domicilio_comercial", 200), ("iibb_numero", 30)],
    )
    def test_largo_maximo(self, campo, maximo):
        from backend.schemas.fiscal import FiscalProfileCreate

        FiscalProfileCreate(**BASE, **{campo: "x" * maximo})
        with pytest.raises(ValidationError):
            FiscalProfileCreate(**BASE, **{campo: "x" * (maximo + 1)})

    def test_inicio_de_actividades_futuro_se_rechaza(self):
        from backend.schemas.fiscal import FiscalProfileCreate

        with pytest.raises(ValidationError):
            FiscalProfileCreate(**BASE, inicio_actividades=_manana_en_argentina())

    def test_inicio_de_actividades_hoy_se_acepta(self):
        from backend.core.timezone import today_in_argentina
        from backend.schemas.fiscal import FiscalProfileCreate

        hoy = today_in_argentina()
        assert FiscalProfileCreate(**BASE, inicio_actividades=hoy).inicio_actividades == hoy

    @pytest.mark.parametrize("vacio", ["", "   "])
    def test_un_texto_en_blanco_es_borrar(self, vacio):
        """Un campo "lleno de espacios" no puede contar como cargado para imprimir."""
        from backend.schemas.fiscal import FiscalProfileCreate

        p = FiscalProfileCreate(**BASE, domicilio_comercial=vacio)

        assert p.domicilio_comercial is None
        assert "domicilio_comercial" in p.model_fields_set

    def test_los_textos_se_recortan(self):
        from backend.schemas.fiscal import FiscalProfileCreate

        p = FiscalProfileCreate(**BASE, razon_social="  PEREZ MARIA LAURA  ")

        assert p.razon_social == "PEREZ MARIA LAURA"

    def test_out_expone_los_datos_del_emisor(self):
        from backend.schemas.fiscal import FiscalProfileOut

        out = FiscalProfileOut(**PROFILE_ROW).model_dump()

        for campo in ("razon_social", "nombre_fantasia", "domicilio_comercial",
                      "iibb_numero", "inicio_actividades"):
            assert out[campo] == PROFILE_ROW[campo]

    def test_out_de_un_perfil_viejo_sin_los_campos(self):
        """Una fila sin las columnas (deploy del backend antes que la migración)
        no rompe la respuesta."""
        from backend.schemas.fiscal import FiscalProfileOut

        viejo = {k: v for k, v in PROFILE_ROW.items()
                 if k not in ("razon_social", "nombre_fantasia", "domicilio_comercial",
                              "iibb_numero", "inicio_actividades")}
        out = FiscalProfileOut(**viejo)

        assert out.razon_social is None
        assert out.inicio_actividades is None


# ═══════════════════════════════════════════════════════════════════════════
# 3.1 — Service: qué campos viajan al repositorio
# ═══════════════════════════════════════════════════════════════════════════

async def _data_que_llega_al_repo(payload_dict: dict) -> dict:
    from backend.schemas.fiscal import FiscalProfileCreate
    from backend.services.fiscal import fiscal_profile_service as svc

    repo = MagicMock()
    repo.upsert = AsyncMock(return_value=PROFILE_ROW)
    await svc.upsert_fiscal_profile(
        repo, {"role": "user"}, ACCOUNT_ID, FiscalProfileCreate(**payload_dict),
    )
    args = repo.upsert.call_args.args
    return args[1]


class TestServiceTriEstado:

    @pytest.mark.asyncio
    async def test_un_campo_ausente_no_viaja(self):
        data = await _data_que_llega_al_repo(BASE)

        for campo in _TRI_ESTADO:
            assert campo not in data, campo

    @pytest.mark.asyncio
    async def test_un_null_explicito_viaja_como_none(self):
        data = await _data_que_llega_al_repo({**BASE, "nombre_fantasia": None, "iibb_condition": None})

        assert "nombre_fantasia" in data and data["nombre_fantasia"] is None
        assert "iibb_condition" in data and data["iibb_condition"] is None
        assert "domicilio_comercial" not in data

    @pytest.mark.asyncio
    async def test_un_valor_viaja(self):
        data = await _data_que_llega_al_repo({
            **BASE,
            "domicilio_comercial": "Av. San Martín 1234, Mendoza",
            "inicio_actividades": "2019-03-01",
        })

        assert data["domicilio_comercial"] == "Av. San Martín 1234, Mendoza"
        assert data["inicio_actividades"] == datetime.date(2019, 3, 1)

    @pytest.mark.asyncio
    async def test_la_delegacion_sigue_igual(self):
        """#583: la atestación sólo viaja cuando vino, incluso en False."""
        data = await _data_que_llega_al_repo({**BASE, "delegacion_autorizada": False})
        assert data["delegacion_autorizada"] is False

        data = await _data_que_llega_al_repo(BASE)
        assert "delegacion_autorizada" not in data


# ═══════════════════════════════════════════════════════════════════════════
# 3.1 — Repositorio: el ON CONFLICT respeta el tri-estado
# ═══════════════════════════════════════════════════════════════════════════

async def _upsert(data: dict):
    from backend.repositories.fiscal_profile_repository import FiscalProfileRepository

    conn = AsyncMock()
    conn.fetchrow = AsyncMock(return_value=PROFILE_ROW)
    await FiscalProfileRepository(conn).upsert(ACCOUNT_ID, data)
    args = conn.fetchrow.call_args.args
    return " ".join(args[0].split()), args[1:]


class TestRepositorioTriEstado:

    @pytest.mark.asyncio
    async def test_el_insert_incluye_las_columnas_nuevas(self):
        query, _ = await _upsert(dict(BASE))
        columnas = query.lower().split("values")[0]

        for campo in ("razon_social", "nombre_fantasia", "domicilio_comercial",
                      "iibb_numero", "inicio_actividades"):
            assert campo in columnas, campo

    @pytest.mark.asyncio
    async def test_cada_campo_tri_estado_se_actualiza_solo_si_vino(self):
        query, _ = await _upsert(dict(BASE))

        for campo in _TRI_ESTADO:
            assert (
                f"{campo} = CASE WHEN '{campo}' = ANY($13::text[]) "
                f"THEN EXCLUDED.{campo} ELSE fiscal_profiles.{campo} END"
            ) in query, campo

    @pytest.mark.asyncio
    async def test_la_lista_de_presentes_refleja_el_payload(self):
        _, args = await _upsert({
            **BASE,
            "domicilio_comercial": "Av. San Martín 1234, Mendoza",
            "nombre_fantasia": None,
        })

        presentes = args[12]
        assert sorted(presentes) == ["domicilio_comercial", "nombre_fantasia"]
        assert args[9] == "Av. San Martín 1234, Mendoza"   # $10 domicilio_comercial
        assert args[8] is None                              # $9 nombre_fantasia

    @pytest.mark.asyncio
    async def test_sin_campos_tri_estado_la_lista_va_vacia(self):
        """Triangulación: el caso de hoy (formulario viejo) no toca nada."""
        _, args = await _upsert(dict(BASE))

        assert args[12] == []

    @pytest.mark.asyncio
    async def test_la_delegacion_conserva_su_contrato(self):
        query, args = await _upsert({**BASE, "delegacion_autorizada": True})

        assert "delegacion_autorizada = COALESCE($7::boolean, fiscal_profiles.delegacion_autorizada)" in query
        assert args[6] is True


# ═══════════════════════════════════════════════════════════════════════════
# 3.1 — Endpoint: 422 antes de tocar la DB
# ═══════════════════════════════════════════════════════════════════════════

class TestEndpoint:

    async def test_inicio_futuro_es_422_sin_tocar_la_db(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(return_value=PROFILE_ROW)
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/fiscal/profile",
                json={**BASE, "inicio_actividades": _manana_en_argentina().isoformat()},
                headers={"Authorization": f"Bearer {make_token({'role': 'user'})}"},
            )

        assert resp.status_code == 422
        conn.fetchrow.assert_not_awaited()

    async def test_razon_social_larga_es_422(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(return_value=PROFILE_ROW)
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/fiscal/profile",
                json={**BASE, "razon_social": "x" * 121},
                headers={"Authorization": f"Bearer {make_token({'role': 'user'})}"},
            )

        assert resp.status_code == 422
        conn.fetchrow.assert_not_awaited()

    async def test_get_devuelve_los_datos_del_emisor(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(return_value=PROFILE_ROW)
        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/fiscal/profile",
                headers={"Authorization": f"Bearer {make_token({'role': 'user'})}"},
            )

        assert resp.status_code == 200
        body = resp.json()
        assert body["razon_social"] == "PEREZ MARIA LAURA"
        assert body["domicilio_comercial"] == "Av. San Martín 1234, Mendoza"
        assert body["inicio_actividades"] == "2019-03-01"
