"""
documentos-marca-empresa — task 5.4: `resolve_document_branding` y su caché del
logo.

Un repositorio falso que CUENTA las llamadas prueba que:
  (i)   sólo se llama a la RPC del emisor cuando no hay huella de logo;
  (ii)  los bytes del logo se piden SÓLO con huella;
  (iii) el segundo pedido con la misma huella sale del caché y uno con huella
        nueva no;
  (iv)  un logo ilegible deja `logo = None` (y el papel sale igual);
  (v)   las claves nuevas ausentes (RPC anterior a este cambio) -> Neutro y sin
        logo, sin tocar la tabla (la ventana de despliegue de D12).

Run: python -m pytest backend/tests/test_document_branding_resolve.py -q -p no:cacheprovider
"""
from __future__ import annotations

import io

import pytest
from PIL import Image

from backend.services.commercial_documents import branding as branding_module
from backend.services.commercial_documents.branding import (
    LOGO_CACHE_SIZE,
    DocumentBranding,
    clear_logo_cache,
    resolve_document_branding,
)
from backend.services.commercial_documents.logo import normalize_logo
from backend.services.commercial_documents.palette import NEUTRAL

ACCOUNT = "11111111-1111-1111-1111-111111111111"
OTHER_ACCOUNT = "22222222-2222-2222-2222-222222222222"

_RPC_BASE = {
    "nombre_fantasia": None, "razon_social": None, "cuit": None, "domicilio_comercial": None,
    "business_name": "Almacén Don José", "phone": "2615550101", "iva_condition": None,
    "brand_display_name": None, "brand_legal_name": None, "brand_tax_id": None, "brand_address": None,
    "brand_phone": None, "brand_email": None, "brand_website": None, "brand_footer_note": None,
    "palette_preset": None, "accent_color": None, "logo_sha256": None,
}


def _png(color=(200, 30, 30, 255), size=(300, 100)) -> bytes:
    buf = io.BytesIO()
    Image.new("RGBA", size, color).save(buf, "PNG")
    return buf.getvalue()


def _stored_logo(color=(200, 30, 30, 255)):
    return normalize_logo(_png(color))


class FakeRepo:
    def __init__(self, raw, logo_rows=None):
        self.raw = raw
        self.logo_rows = logo_rows if logo_rows is not None else {}
        self.calls: list[tuple[str, str]] = []

    async def get_commercial_issuer(self, account_id):
        self.calls.append(("issuer", account_id))
        return self.raw

    async def get_document_logo(self, account_id):
        self.calls.append(("logo", account_id))
        return self.logo_rows.get(account_id)


def _row(stored):
    return {"logo_image": stored.data, "logo_mime": stored.mime, "logo_sha256": stored.sha256}


@pytest.fixture(autouse=True)
def _fresh_cache():
    clear_logo_cache()
    yield
    clear_logo_cache()


# ── (i) sólo la RPC, sin huella ──────────────────────────────────────────────

async def test_without_a_logo_fingerprint_only_the_rpc_is_called():
    repo = FakeRepo({**_RPC_BASE, "brand_display_name": "Sumar", "palette_preset": "azul"})

    branding = await resolve_document_branding(repo, ACCOUNT)

    assert repo.calls == [("issuer", ACCOUNT)]
    assert isinstance(branding, DocumentBranding)
    assert branding.logo is None
    assert branding.issuer.name == "Sumar"
    assert branding.palette.key == "azul"


async def test_the_footer_note_and_the_brand_contact_travel_with_the_branding():
    repo = FakeRepo({**_RPC_BASE, "brand_footer_note": "Alias: sumar.ropa", "brand_phone": "2615550999",
                     "brand_email": "ventas@sumar.com.ar", "brand_website": "sumar.com.ar"})

    branding = await resolve_document_branding(repo, ACCOUNT)

    assert branding.footer_note == "Alias: sumar.ropa"
    assert (branding.brand_contact.phone, branding.brand_contact.email, branding.brand_contact.website) == (
        "2615550999", "ventas@sumar.com.ar", "sumar.com.ar")


# ── (ii)(iii) los bytes se piden sólo con huella y se cachean por (cuenta, huella) ──

async def test_the_logo_bytes_are_requested_only_when_there_is_a_fingerprint():
    stored = _stored_logo()
    repo = FakeRepo({**_RPC_BASE, "logo_sha256": stored.sha256}, {ACCOUNT: _row(stored)})

    branding = await resolve_document_branding(repo, ACCOUNT)

    assert repo.calls == [("issuer", ACCOUNT), ("logo", ACCOUNT)]
    assert branding.logo is not None
    assert branding.logo.sha256 == stored.sha256
    assert (branding.logo.width, branding.logo.height) == (stored.width, stored.height)
    assert branding.logo.data == stored.data and branding.logo.mime == "image/png"


async def test_the_second_request_with_the_same_fingerprint_comes_from_the_cache():
    stored = _stored_logo()
    repo = FakeRepo({**_RPC_BASE, "logo_sha256": stored.sha256}, {ACCOUNT: _row(stored)})

    first = await resolve_document_branding(repo, ACCOUNT)
    second = await resolve_document_branding(repo, ACCOUNT)

    assert [c[0] for c in repo.calls] == ["issuer", "logo", "issuer"]       # el segundo NO pidió los bytes
    assert second.logo is first.logo


async def test_a_new_fingerprint_invalidates_by_itself():
    old, new = _stored_logo((200, 30, 30, 255)), _stored_logo((20, 60, 160, 255))
    assert old.sha256 != new.sha256
    repo = FakeRepo({**_RPC_BASE, "logo_sha256": old.sha256}, {ACCOUNT: _row(old)})
    await resolve_document_branding(repo, ACCOUNT)

    repo.raw = {**_RPC_BASE, "logo_sha256": new.sha256}                      # la cuenta cambió el logo
    repo.logo_rows = {ACCOUNT: _row(new)}
    branding = await resolve_document_branding(repo, ACCOUNT)

    assert [c[0] for c in repo.calls] == ["issuer", "logo", "issuer", "logo"]
    assert branding.logo is not None and branding.logo.sha256 == new.sha256   # nunca el viejo


async def test_the_cache_is_per_account_even_with_the_same_fingerprint():
    stored = _stored_logo()
    repo = FakeRepo({**_RPC_BASE, "logo_sha256": stored.sha256}, {ACCOUNT: _row(stored), OTHER_ACCOUNT: _row(stored)})

    await resolve_document_branding(repo, ACCOUNT)
    await resolve_document_branding(repo, OTHER_ACCOUNT)

    assert [c for c in repo.calls if c[0] == "logo"] == [("logo", ACCOUNT), ("logo", OTHER_ACCOUNT)]


async def test_the_cache_is_bounded_and_evicts_the_oldest():
    stored = _stored_logo()
    accounts = [f"{i:08d}-0000-0000-0000-000000000000" for i in range(LOGO_CACHE_SIZE + 1)]
    repo = FakeRepo({**_RPC_BASE, "logo_sha256": stored.sha256}, {a: _row(stored) for a in accounts})

    for account in accounts:
        await resolve_document_branding(repo, account)
    repo.calls.clear()
    await resolve_document_branding(repo, accounts[0])        # el más viejo fue desalojado: vuelve a pedir
    assert ("logo", accounts[0]) in repo.calls
    repo.calls.clear()
    await resolve_document_branding(repo, accounts[-1])       # el más nuevo sigue en el caché
    assert ("logo", accounts[-1]) not in repo.calls


async def test_a_cache_hit_refreshes_the_entry():
    stored = _stored_logo()
    accounts = [f"{i:08d}-0000-0000-0000-000000000000" for i in range(LOGO_CACHE_SIZE)]
    repo = FakeRepo({**_RPC_BASE, "logo_sha256": stored.sha256}, {a: _row(stored) for a in accounts})
    for account in accounts:
        await resolve_document_branding(repo, account)
    await resolve_document_branding(repo, accounts[0])         # lo toca: pasa a ser el más reciente
    extra = "99999999-0000-0000-0000-000000000000"
    repo.logo_rows[extra] = _row(stored)
    await resolve_document_branding(repo, extra)               # desaloja al más viejo (accounts[1]), no a accounts[0]
    repo.calls.clear()
    await resolve_document_branding(repo, accounts[0])
    assert ("logo", accounts[0]) not in repo.calls


# ── (iv) un logo ilegible deja logo = None ───────────────────────────────────

async def test_an_unreadable_stored_logo_leaves_the_paper_without_one():
    repo = FakeRepo(
        {**_RPC_BASE, "brand_display_name": "Sumar", "logo_sha256": "a" * 64},
        {ACCOUNT: {"logo_image": b"\x89PNG\r\n\x1a\nbasura", "logo_mime": "image/png", "logo_sha256": "a" * 64}},
    )

    branding = await resolve_document_branding(repo, ACCOUNT)

    assert branding.logo is None
    assert branding.issuer.name == "Sumar"                      # el papel se arma igual


async def test_an_unreadable_logo_is_remembered_so_it_does_not_hit_the_database_every_time():
    repo = FakeRepo({**_RPC_BASE, "logo_sha256": "a" * 64},
                    {ACCOUNT: {"logo_image": b"no es una imagen", "logo_mime": "image/png", "logo_sha256": "a" * 64}})

    await resolve_document_branding(repo, ACCOUNT)
    await resolve_document_branding(repo, ACCOUNT)

    assert [c[0] for c in repo.calls].count("logo") == 1


async def test_a_fingerprint_without_a_stored_row_leaves_the_paper_without_a_logo():
    repo = FakeRepo({**_RPC_BASE, "logo_sha256": "b" * 64}, {})

    branding = await resolve_document_branding(repo, ACCOUNT)

    assert branding.logo is None


async def test_the_logo_used_is_the_one_in_the_row_even_if_it_changed_between_the_two_reads():
    old, new = _stored_logo((200, 30, 30, 255)), _stored_logo((20, 60, 160, 255))
    repo = FakeRepo({**_RPC_BASE, "logo_sha256": old.sha256}, {ACCOUNT: _row(new)})   # la RPC vio el viejo; la fila ya es el nuevo

    branding = await resolve_document_branding(repo, ACCOUNT)

    assert branding.logo is not None
    assert branding.logo.sha256 == new.sha256 and branding.logo.data == new.data


# ── (v) RPC anterior a este cambio / respuesta vacía ─────────────────────────

async def test_an_old_rpc_with_only_the_six_legacy_keys_gives_neutral_and_no_logo():
    legacy = {"nombre_fantasia": "Sumar", "razon_social": "PEREZ MARIA LAURA", "cuit": "20123456786",
              "domicilio_comercial": "Av. San Martín 1234", "business_name": "Almacén Don José", "phone": "2615550101"}
    repo = FakeRepo(legacy)

    branding = await resolve_document_branding(repo, ACCOUNT)

    assert repo.calls == [("issuer", ACCOUNT)]                  # jamás consulta la tabla nueva
    assert branding.palette is NEUTRAL
    assert branding.logo is None and branding.footer_note is None
    assert branding.issuer.name == "Sumar" and branding.issuer.cuit == "20-12345678-6"


async def test_an_empty_rpc_answer_degrades_to_the_neutral_default():
    branding = await resolve_document_branding(FakeRepo(None), ACCOUNT)
    assert branding.issuer.name == "Mi Negocio" and branding.palette is NEUTRAL and branding.logo is None


async def test_an_illegible_saved_palette_resolves_to_neutral():
    repo = FakeRepo({**_RPC_BASE, "palette_preset": "personalizado", "accent_color": "#10b981"})
    assert (await resolve_document_branding(repo, ACCOUNT)).palette is NEUTRAL


def test_the_resolver_has_no_database_access_of_its_own():
    """`resolve_document_branding` lee SÓLO por el repositorio (la RPC y el logo): ninguna
    consulta propia a la tabla de la marca, que es lo que hace segura la ventana de despliegue."""
    from pathlib import Path

    source = Path(branding_module.__file__).read_text(encoding="utf-8")
    for needle in ("fetchval", "fetchrow", "fetch(", "execute(", "SELECT ", "asyncpg"):
        assert needle not in source, needle
