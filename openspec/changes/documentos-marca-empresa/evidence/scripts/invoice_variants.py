"""documentos-marca-empresa, tanda B, checkpoint 13.4: baja del stack LOCAL las facturas C reales (autorizadas por el
STUB en homologacion, por la misma cadena que la UI: promote-to-order -> emit-invoice -> relay) con distintas marcas
de cuenta, para revisarlas a ojo.

Se corre con el venv del backend, con el entorno de `env.sh` (todo host tiene que ser local) y el backend arriba
(`start-backend.sh`):

    source evidence/scripts/env.sh && backend/.venv/Scripts/python evidence/scripts/invoice_variants.py <directorio de salida>

Usa la cuenta del usuario QA local (`qa.e2e@local.test`, sembrada por `seed-users.mjs`). Los datos del emisor son
SINTETICOS (el molde del caso Sumar de los tests, CUIT de la allow-list sintetica): no se baja ningun dato real de
produccion. Deja `manifest.json` (documento -> variante -> archivo) para el paso 2 (`rasterize_check.py`).
"""
from __future__ import annotations

import io
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

SUPABASE_URL = os.environ["SUPABASE_URL"]
SERVICE_KEY = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
ANON_KEY = os.environ["NEXT_PUBLIC_SUPABASE_ANON_KEY_LOCAL"]
BACKEND = os.environ.get("NEXT_PUBLIC_BACKEND_URL_LOCAL", "http://localhost:8000")
RELAY_SECRET = os.environ["RELAY_SECRET"]
QA_EMAIL = os.environ["QA_TEST_USER_EMAIL"]
QA_PASSWORD = os.environ["QA_TEST_USER_PASSWORD"]

for url in (SUPABASE_URL, BACKEND):
    if urllib.parse.urlparse(url).hostname not in ("localhost", "127.0.0.1"):
        sys.exit(f"{url} no es local: abortando")

E2E_CUIT = "20-12345678-6"      # allow-list sintetica (backend/tests/test_fixtures_sin_cuit_real.py)
E2E_PV = 9911
OWNER_PHONE = "2615550199"      # teléfono del PERFIL del dueño: la factura NO lo tiene que imprimir
LONG_FANTASY = "Sumar Ropa Deportiva y Accesorios para Toda la Familia"
LINE_NAME = "Ciclista Lycra con Bolsillos Kaese Talle 2 Negro"


# ── HTTP ─────────────────────────────────────────────────────────────────────

def http(method: str, url: str, *, headers: dict | None = None, body: bytes | None = None, ok=(200, 201, 204)):
    request = urllib.request.Request(url, data=body, method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            status, data = response.status, response.read()
    except urllib.error.HTTPError as exc:
        status, data = exc.code, exc.read()
    if status not in ok:
        raise RuntimeError(f"{method} {url} -> {status} {data[:300]!r}")
    return status, data


def rest(method: str, path: str, body=None, *, prefer: str = "return=representation"):
    headers = {"apikey": SERVICE_KEY, "Authorization": f"Bearer {SERVICE_KEY}", "Content-Type": "application/json",
               "Prefer": prefer}
    _, data = http(method, f"{SUPABASE_URL}/rest/v1/{path}", headers=headers,
                   body=None if body is None else json.dumps(body).encode())
    return json.loads(data) if data else []


def login() -> tuple[str, str]:
    _, data = http("POST", f"{SUPABASE_URL}/auth/v1/token?grant_type=password",
                   headers={"apikey": ANON_KEY, "Content-Type": "application/json"},
                   body=json.dumps({"email": QA_EMAIL, "password": QA_PASSWORD}).encode())
    session = json.loads(data)
    return session["access_token"], session["user"]["id"]


def api(jwt: str, method: str, path: str, *, body: bytes | None = None, content_type: str | None = None, ok=(200, 201, 204),
        extra: dict | None = None):
    headers = {"Authorization": f"Bearer {jwt}", **(extra or {})}
    if content_type:
        headers["Content-Type"] = content_type
    return http(method, f"{BACKEND}{path}", headers=headers, body=body, ok=ok)


# ── Logos de prueba (reconocibles: si se deforman o se recortan se nota a simple vista) ─────────────────────

def _font(size: int):
    try:
        return ImageFont.load_default(size=size)
    except TypeError:
        return ImageFont.load_default()


def logo_horizontal() -> bytes:
    """4:1 — franja teal con el nombre en blanco y un marco de 6 px."""
    w, h = 1000, 250
    img = Image.new("RGBA", (w, h), (13, 148, 136, 255))
    draw = ImageDraw.Draw(img)
    draw.rectangle([0, 0, w - 1, h - 1], outline=(255, 255, 255, 255), width=6)
    draw.text((w // 2, h // 2), "SUMAR", fill=(255, 255, 255, 255), font=_font(150), anchor="mm")
    buf = io.BytesIO()
    img.save(buf, "PNG")
    return buf.getvalue()


def logo_cuadrado() -> bytes:
    """1:1 — círculo naranja con una S y un marco: una imagen cuadrada de 1000 px, el peor caso del recuadro."""
    size = 1000
    img = Image.new("RGBA", (size, size), (255, 255, 255, 0))
    draw = ImageDraw.Draw(img)
    draw.ellipse([20, 20, size - 20, size - 20], fill=(234, 88, 12, 255), outline=(30, 41, 59, 255), width=24)
    draw.text((size // 2, size // 2), "S", fill=(255, 255, 255, 255), font=_font(620), anchor="mm")
    buf = io.BytesIO()
    img.save(buf, "PNG")
    return buf.getvalue()


# ── Siembra fiscal (molde de e2e/fixtures/fiscal-e2e.ts) ─────────────────────────────────────────────────

def ensure_setup(user_id: str) -> dict:
    account = rest("GET", f"account_members?user_id=eq.{user_id}&select=account_id&order=created_at.asc&limit=1")[0]["account_id"]
    branch = rest("GET", f"branches?account_id=eq.{account}&is_active=eq.true&select=id&order=created_at.asc&limit=1")[0]["id"]
    profiles = rest("GET", f"fiscal_profiles?account_id=eq.{account}&select=id,ambiente,iva_condition,cuit")
    if not profiles:
        profiles = rest("POST", "fiscal_profiles", {
            "account_id": account, "cuit": E2E_CUIT, "iva_condition": "monotributista",
            "ambiente": "homologacion", "delegacion_autorizada": True,
        })
    profile = profiles[0]
    if profile["ambiente"] != "homologacion" or profile["iva_condition"] != "monotributista":
        sys.exit("el perfil fiscal local no esta en homologacion/monotributo: abortando")
    if not rest("GET", f"points_of_sale?account_id=eq.{account}&is_active=eq.true&select=id"):
        rest("POST", "points_of_sale", {"fiscal_profile_id": profile["id"], "account_id": account, "numero": E2E_PV,
                                        "is_active": True})
    rest("PATCH", f"profiles?id=eq.{user_id}", {"phone": OWNER_PHONE})
    return {"account": account, "branch": branch, "profile": profile["id"], "user": user_id}


def authorize_invoice(ctx: dict, jwt: str, *, fantasy: str | None, lines: int) -> str:
    """Una venta de `lines` renglones -> orden -> factura -> CAE por el stub. Devuelve el id del comprobante."""
    rest("PATCH", f"fiscal_profiles?id=eq.{ctx['profile']}", {
        "razon_social": "PEREZ MARIA LAURA", "nombre_fantasia": fantasy,
        "domicilio_comercial": "Av. San Martín 1234, Mendoza", "iibb_numero": "0712345", "inicio_actividades": "2019-03-01",
    })
    stamp = int(time.time() * 1000)
    names = [LINE_NAME] if lines == 1 else [f"Producto {i + 1:02d} de la lista de precios" for i in range(lines)]
    products = rest("POST", "products", [
        {"user_id": ctx["user"], "account_id": ctx["account"], "name": name, "sku": f"FAC-B-{stamp}-{i}", "cost": 500,
         "price": 32500 if lines == 1 else 650}
        for i, name in enumerate(names)
    ])
    operation = str(uuid.uuid4())
    price = 32500 if lines == 1 else 650
    rest("POST", "sales", [
        {"user_id": ctx["user"], "account_id": ctx["account"], "client_id": None, "product_id": p["id"], "amount": price,
         "quantity": 1, "total": price, "currency": "ARS", "date": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
         "operation_id": operation, "branch_id": ctx["branch"], "canal": "visual-factura-b"}
        for p in products
    ])
    _, data = api(jwt, "POST", f"/sales/{operation}/promote-to-order")
    order = json.loads(data)["sales_order_id"]
    api(jwt, "POST", f"/sales-orders/{order}/emit-invoice", body=b"{}", content_type="application/json",
        extra={"Idempotency-Key": str(uuid.uuid4())})
    http("POST", f"{BACKEND}/fiscal/documents/process-pending-cron", headers={"Authorization": f"Bearer {RELAY_SECRET}"})
    for _ in range(30):
        doc_id = rest("GET", f"sales_orders?id=eq.{order}&select=fiscal_document_id")[0]["fiscal_document_id"]
        if doc_id:
            doc = rest("GET", f"fiscal_documents?id=eq.{doc_id}&select=status,number,punto_de_venta")
            if doc and doc[0]["status"] == "authorized":
                return doc_id
        time.sleep(1)
    sys.exit("el comprobante no llego a authorized")


# ── Marcas de la cuenta ──────────────────────────────────────────────────────────────────────────────────

CONTACT = {"phone": "2617175072", "email": "ventas@sumar.com.ar", "website": "sumar.com.ar"}
FOOTER = "Alias para transferencias: sumar.ropa  (esta leyenda NO va en la factura)"
BRANDS = {
    "neutro-logo-horizontal": (dict(display_name="Sumar Ropa Deportiva", **CONTACT, footer_note=FOOTER, palette_preset="neutro"), "horizontal"),
    "azul-logo-cuadrado": (dict(display_name="Sumar Ropa Deportiva", **CONTACT, footer_note=FOOTER, palette_preset="azul"), "cuadrado"),
    "bordo-logo-horizontal": (dict(display_name="Sumar Ropa Deportiva", **CONTACT, footer_note=FOOTER, palette_preset="bordo"), "horizontal"),
    "grafito-solo-email": (dict(display_name="Sumar Ropa Deportiva", email="ventas@sumar.com.ar", palette_preset="grafito"), None),
}


def apply_brand(jwt: str, key: str) -> None:
    data, logo = BRANDS[key]
    api(jwt, "PUT", "/document-branding", body=json.dumps(data).encode(), content_type="application/json")
    if logo:
        png = logo_horizontal() if logo == "horizontal" else logo_cuadrado()
        api(jwt, "PUT", "/document-branding/logo", body=png, content_type="application/octet-stream")
    else:
        api(jwt, "DELETE", "/document-branding/logo")


# ── Matriz ───────────────────────────────────────────────────────────────────────────────────────────────

DOCUMENTS = {
    # nombre: (fantasia, renglones, marcas a probar)
    "sumar-1-linea": ("Sumar", 1, ["neutro-logo-horizontal", "azul-logo-cuadrado", "bordo-logo-horizontal", "grafito-solo-email"]),
    "fantasia-larga-1-linea": (LONG_FANTASY, 1, ["neutro-logo-horizontal", "azul-logo-cuadrado"]),
    "fantasia-larga-60-lineas": (LONG_FANTASY, 60, ["neutro-logo-horizontal", "azul-logo-cuadrado"]),
    "sin-fantasia-1-linea": (None, 1, ["azul-logo-cuadrado"]),
}


def main() -> None:
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    jwt, user_id = login()
    ctx = ensure_setup(user_id)

    # La cuenta empieza SIN marca: se baja primero la factura "sin marca" de cada documento.
    existing = rest("GET", f"account_branding?account_id=eq.{ctx['account']}&select=account_id")
    if existing:
        rest("DELETE", f"account_branding?account_id=eq.{ctx['account']}", prefer="return=minimal")

    doc_ids = {name: authorize_invoice(ctx, jwt, fantasy=fantasy, lines=lines) for name, (fantasy, lines, _b) in DOCUMENTS.items()}
    manifest: list[dict] = []

    def download(doc_name: str, variant: str, copia: str = "original") -> None:
        _, pdf = api(jwt, "GET", f"/fiscal/documents/{doc_ids[doc_name]}/pdf?copia={copia}")
        target = out / f"{doc_name}__{variant}.pdf"
        target.write_bytes(pdf)
        manifest.append({"document": doc_name, "variant": variant, "file": target.name, "doc_id": doc_ids[doc_name]})
        print("ok", target.name, len(pdf), "bytes")

    for name in DOCUMENTS:
        download(name, "sin-marca")
    for brand in BRANDS:
        apply_brand(jwt, brand)
        for name, (_f, _n, brands) in DOCUMENTS.items():
            if brand in brands:
                download(name, brand)
    (out / "manifest.json").write_text(json.dumps(manifest, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    print("manifest:", len(manifest), "pdfs")


if __name__ == "__main__":
    main()
