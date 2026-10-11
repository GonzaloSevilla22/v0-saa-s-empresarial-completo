"""
factura-fiscal-imprimible — grupo 4: la representación impresa de la Factura C.

Tres piezas (D2), cada una con su propio contrato:

  * `build_qr_url` (D4, RG 4892): JSON v1 con los numéricos como NÚMEROS,
    claves en el orden de la especificación, serializado sin espacios, en
    Base64, detrás de `https://www.afip.gob.ar/fe/qr/?p=` (OQ-8). El ejemplo
    oficial de ARCA se reproduce BYTE A BYTE (el literal de abajo es el de la
    especificación "Especificaciones del QR incluido en las facturas
    electrónicas", afip.gob.ar/fe/qr/documentos/QRespecificaciones.pdf,
    verificado contra el PDF en el propose del 2026-09-25).
  * `build_invoice_view` (D2/D6/D8): función PURA que resuelve todos los textos
    desde lo AUTORIZADO (nunca desde la venta actual) y levanta
    `InvoiceNotPrintable` antes que imprimir un dato adivinado.
  * `render_invoice_pdf` (D3/D8): dibuja; se verifica extrayendo el texto con
    `pypdf` (sólo en tests) y espiando `segno.make`.

Caso real: la Factura C 0003-00000501 de Sumar (2026-09-25).
"""
from __future__ import annotations

import base64
import datetime
import io
import json
import pathlib
import re
import uuid
from decimal import Decimal
from unittest.mock import patch

import pytest



def _pypdf():
    """pypdf sólo existe en CI (Backend_Tests.yml), no en requirements.txt. El
    skip vive acá, no a nivel de módulo: si faltara, se saltean SÓLO los tests
    que extraen texto del PDF, nunca los del QR RG 4892 ni los de la vista."""
    return pytest.importorskip("pypdf")

OFFICIAL_EXAMPLE_B64 = (
    "eyJ2ZXIiOjEsImZlY2hhIjoiMjAyMC0xMC0xMyIsImN1aXQiOjMwMDAwMDAwMDA3LCJwdG9WdGEiOjEw"
    "LCJ0aXBvQ21wIjoxLCJucm9DbXAiOjk0LCJpbXBvcnRlIjoxMjEwMCwibW9uZWRhIjoiRE9MIiwiY3R6"
    "Ijo2NSwidGlwb0RvY1JlYyI6ODAsIm5yb0RvY1JlYyI6MjAwMDAwMDAwMDEsInRpcG9Db2RBdXQiOiJF"
    "IiwiY29kQXV0Ijo3MDQxNzA1NDM2NzQ3Nn0="
)

CAE = "71234567890123"

SNAPSHOT = {
    "cuit": "20123456786",
    "razon_social": "PEREZ MARIA LAURA",
    "nombre_fantasia": "Sumar",
    "domicilio_comercial": "Av. San Martín 1234, Mendoza",
    "iva_condition": "monotributista",
    "iibb_condition": None,
    "iibb_numero": "0712345",
    "inicio_actividades": "2019-03-01",
    "ambiente": "produccion",
}

PROFILE = {
    "cuit": "20123456786",
    "razon_social": "PEREZ MARIA LAURA",
    "nombre_fantasia": "Sumar",
    "domicilio_comercial": "Av. San Martín 1234, Mendoza",
    "iva_condition": "monotributista",
    "iibb_condition": None,
    "iibb_numero": "0712345",
    "inicio_actividades": datetime.date(2019, 3, 1),
    "ambiente": "produccion",
}

LINE = {
    "name_snapshot": "Ciclista Lycra con Bolsillos Kaese Talle 2 Negro",
    "quantity": Decimal("1.000"),
    "price": Decimal("32500.00"),
    "subtotal": Decimal("32500.00"),
    "unit_symbol": None,
}


def sumar_doc(**overrides) -> dict:
    base = {
        "id": "caaeccfd-0000-0000-0000-000000000000",
        "account_id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
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
        "client_id": "c1c1c1c1-0000-0000-0000-000000000000",
        "created_at": datetime.datetime(2026, 9, 21, 15, 0, tzinfo=datetime.timezone.utc),
        "emisor_snapshot": dict(SNAPSHOT),
    }
    base.update(overrides)
    return base


def _view(doc=None, profile=PROFILE, lines=(LINE,), kind=None, copy="original"):
    from backend.services.fiscal.invoice_pdf import build_invoice_view

    return build_invoice_view(
        doc if doc is not None else sumar_doc(),
        profile,
        list(lines),
        sale_condition_kind=kind,
        copy=copy,
    )


def _qr_json(url: str) -> tuple[dict, str]:
    from backend.services.fiscal.invoice_pdf import QR_BASE_URL

    assert url.startswith(QR_BASE_URL + "?p=")
    raw = base64.b64decode(url.split("?p=", 1)[1]).decode("utf-8")
    return json.loads(raw), raw


def _pdf_text(pdf_bytes: bytes) -> tuple[str, int]:
    reader = _pypdf().PdfReader(io.BytesIO(pdf_bytes))
    return "\n".join(page.extract_text() or "" for page in reader.pages), len(reader.pages)


# ═══════════════════════════════════════════════════════════════════════════
# 4.2 — QR de ARCA (RG 4892)
# ═══════════════════════════════════════════════════════════════════════════

class TestQR:

    def test_el_ejemplo_oficial_se_reproduce_byte_a_byte(self):
        from backend.services.fiscal.invoice_pdf import QrData, build_qr_url

        url = build_qr_url(QrData(
            fecha=datetime.date(2020, 10, 13),
            cuit=30000000007,
            pto_vta=10,
            tipo_cmp=1,
            nro_cmp=94,
            importe=Decimal("12100"),
            moneda="DOL",
            ctz=Decimal("65"),
            tipo_doc_rec=80,
            nro_doc_rec=20000000001,
            tipo_cod_aut="E",
            cod_aut=70417054367476,
        ))

        assert url == "https://www.afip.gob.ar/fe/qr/?p=" + OFFICIAL_EXAMPLE_B64

    def test_el_qr_de_sumar_codifica_lo_autorizado(self):
        payload, raw = _qr_json(_view().qr_url)

        assert raw == (
            '{"ver":1,"fecha":"2026-09-25","cuit":20123456786,"ptoVta":3,"tipoCmp":11,'
            '"nroCmp":501,"importe":32500,"moneda":"PES","ctz":1,"tipoDocRec":99,'
            f'"nroDocRec":0,"tipoCodAut":"E","codAut":{CAE}}}'
        )
        # numéricos como NÚMEROS, no como texto
        for campo in ("ver", "cuit", "ptoVta", "tipoCmp", "nroCmp", "importe", "ctz",
                      "tipoDocRec", "nroDocRec", "codAut"):
            assert isinstance(payload[campo], int), campo

    def test_importe_con_centavos(self):
        payload, raw = _qr_json(_view(
            sumar_doc(total=Decimal("32500.50")),
            lines=[{**LINE, "price": Decimal("32500.50"), "subtotal": Decimal("32500.50")}],
        ).qr_url)

        assert payload["importe"] == 32500.5
        assert '"importe":32500.5,' in raw

    def test_receptor_identificado_por_cuit(self):
        payload, _ = _qr_json(_view(sumar_doc(
            receptor_doc_tipo=80,
            receptor_doc_nro="30-71234567-8",
            receptor_legal_name="ACME SA",
            receptor_iva_condition="responsable_inscripto",
        )).qr_url)

        assert payload["tipoDocRec"] == 80
        assert payload["nroDocRec"] == 30712345678

    def test_un_doctipo_80_sin_numero_fue_consumidor_final(self):
        """Lo que se mandó a ARCA: el adapter resuelve 80 sin número como 99/0."""
        payload, _ = _qr_json(_view(sumar_doc(receptor_doc_tipo=80, receptor_doc_nro=None)).qr_url)

        assert (payload["tipoDocRec"], payload["nroDocRec"]) == (99, 0)

    def test_dominio_del_ejemplo_oficial(self):
        from backend.services.fiscal.invoice_pdf import QR_BASE_URL

        assert QR_BASE_URL == "https://www.afip.gob.ar/fe/qr/"


# ═══════════════════════════════════════════════════════════════════════════
# 4.4 — Modelo de vista
# ═══════════════════════════════════════════════════════════════════════════

class TestVistaDeSumar:

    def test_textos_de_la_factura(self):
        v = _view()

        assert v.copy_label == "ORIGINAL"
        assert (v.letter, v.code) == ("C", "011")
        assert v.comprobante_number == "0003-00000501"
        assert (v.punto_de_venta, v.numero) == ("0003", "00000501")
        assert v.issue_date == "25/09/2026"
        assert v.issuer_cuit == "20-12345678-6"
        assert v.issuer_iva_legend == "IVA RESPONSABLE MONOTRIBUTO"
        assert v.issuer_iibb == "0712345"
        assert v.issuer_start_date == "01/03/2019"
        assert v.receptor_lines == ("Consumidor Final",)
        assert v.sale_condition == "Contado"
        assert v.total == "$ 32.500,00"
        assert v.cae == CAE
        assert v.cae_due_date == "05/10/2026"
        assert v.filename == "factura-C-0003-00000501.pdf"
        assert v.is_homologacion is False

    def test_la_linea(self):
        (linea,) = _view().lines

        assert linea.description == "Ciclista Lycra con Bolsillos Kaese Talle 2 Negro"
        assert linea.quantity == "1"
        assert linea.unit_price == "$ 32.500,00"
        assert linea.subtotal == "$ 32.500,00"

    def test_cantidad_decimal_con_unidad_y_precio_sub_centavo(self):
        """ventas-unidades-conversion: 450 g a $ 72,22222/g → sin redondeo del
        precio unitario (misma regla que el comprobante interno)."""
        lines = [{
            "name_snapshot": "Queso",
            "quantity": Decimal("450.000"),
            "price": Decimal("72.22222"),
            "subtotal": Decimal("32500.00"),
            "unit_symbol": "g",
        }]
        (linea,) = _view(lines=lines).lines

        assert linea.quantity == "450 g"
        assert linea.unit_price == "$ 72,22222"

    def test_nombre_de_fantasia_grande_y_razon_social_siempre(self):
        """OQ-3: con fantasía, va arriba y la razón social debajo."""
        v = _view()
        assert v.issuer_display_name == "Sumar"
        assert v.issuer_legal_name == "PEREZ MARIA LAURA"

        sin = _view(sumar_doc(emisor_snapshot={**SNAPSHOT, "nombre_fantasia": None}),
                    profile={**PROFILE, "nombre_fantasia": None})
        assert sin.issuer_display_name is None
        assert sin.issuer_legal_name == "PEREZ MARIA LAURA"

    def test_el_nombre_del_cliente_no_aparece(self):
        """OQ-5: consumidor final sin identificar → sólo lo declarado a ARCA."""
        v = _view(sumar_doc(receptor_legal_name=None))

        assert v.receptor_lines == ("Consumidor Final",)
        assert all("cliente" not in line.lower() for line in v.receptor_lines)

    def test_duplicado(self):
        assert _view(copy="duplicado").copy_label == "DUPLICADO"

    def test_copia_invalida(self):
        with pytest.raises(ValueError):
            _view(copy="triplicado")


class TestReceptor:

    def test_receptor_cuit_con_razon_social_y_condicion(self):
        v = _view(sumar_doc(
            receptor_doc_tipo=80,
            receptor_doc_nro="30712345678",
            receptor_legal_name="ACME SA",
            receptor_iva_condition="responsable_inscripto",
        ))

        assert v.receptor_lines == (
            "CUIT: 30-71234567-8",
            "ACME SA",
            "Condición frente al IVA: IVA Responsable Inscripto",
        )

    def test_receptor_dni_sin_condicion_es_consumidor_final(self):
        v = _view(sumar_doc(receptor_doc_tipo=96, receptor_doc_nro="12345678"))

        assert v.receptor_lines == (
            "DNI: 12.345.678",
            "Condición frente al IVA: Consumidor Final",
        )


class TestCondicionDeVenta:

    @pytest.mark.parametrize(
        ("kind", "esperada"),
        [("credit", "Cuenta Corriente"), ("cash", "Contado"), ("transfer", "Contado"), (None, "Contado")],
    )
    def test_condicion(self, kind, esperada):
        assert _view(kind=kind).sale_condition == esperada


class TestFotoDelEmisor:

    def test_sin_foto_usa_el_perfil_actual(self):
        """Comprobantes anteriores al change (emisor_snapshot NULL)."""
        v = _view(sumar_doc(emisor_snapshot=None))

        assert v.issuer_legal_name == "PEREZ MARIA LAURA"
        assert v.issuer_address == "Av. San Martín 1234, Mendoza"

    def test_la_foto_gana_sobre_el_perfil(self):
        v = _view(profile={**PROFILE, "domicilio_comercial": "Calle 2, Mendoza"})

        assert v.issuer_address == "Av. San Martín 1234, Mendoza"

    def test_campo_vacio_en_la_foto_se_completa_del_perfil(self):
        v = _view(sumar_doc(emisor_snapshot={**SNAPSHOT, "domicilio_comercial": None}),
                  profile={**PROFILE, "domicilio_comercial": "Calle 2, Mendoza"})

        assert v.issuer_address == "Calle 2, Mendoza"

    def test_la_foto_llega_como_texto_json_desde_asyncpg(self):
        v = _view(sumar_doc(emisor_snapshot=json.dumps(SNAPSHOT)))

        assert v.issuer_legal_name == "PEREZ MARIA LAURA"

    def test_iibb_por_condicion(self):
        v = _view(sumar_doc(emisor_snapshot={**SNAPSHOT, "iibb_numero": None, "iibb_condition": "Exento"}),
                  profile={**PROFILE, "iibb_numero": None})

        assert v.issuer_iibb == "Exento"

    def test_homologacion(self):
        v = _view(sumar_doc(emisor_snapshot={**SNAPSHOT, "ambiente": "homologacion"}))

        assert v.is_homologacion is True


class TestNoSeImprimeConDatosAdivinados:

    def _code(self, **kwargs):
        from backend.services.fiscal.invoice_pdf import InvoiceNotPrintable

        with pytest.raises(InvoiceNotPrintable) as exc_info:
            _view(**kwargs)
        return exc_info.value

    def test_sin_fecha(self):
        exc = self._code(doc=sumar_doc(fecha_comprobante=None))
        assert exc.code == "invoice_date_unknown"
        # No hay un proceso automático que confirme la fecha (el backfill lo corre
        # el administrador): el texto no promete un reintento.
        assert "falta confirmar con ARCA la fecha" in exc.detail
        assert "administrador" in exc.detail
        assert "Estamos confirmando" not in exc.detail

    def test_emisor_incompleto_lista_los_faltantes(self):
        exc = self._code(
            doc=sumar_doc(emisor_snapshot={**SNAPSHOT, "domicilio_comercial": None, "inicio_actividades": None}),
            profile={**PROFILE, "domicilio_comercial": None, "inicio_actividades": None},
        )
        assert exc.code == "issuer_data_incomplete"
        assert exc.missing == ["domicilio_comercial", "inicio_actividades"]

    def test_sin_foto_ni_perfil_falta_todo(self):
        exc = self._code(doc=sumar_doc(emisor_snapshot=None), profile=None)
        assert exc.code == "issuer_data_incomplete"
        assert exc.missing == ["razon_social", "domicilio_comercial", "cuit", "iva_condition",
                               "iibb", "inicio_actividades"]

    def test_iibb_ni_numero_ni_condicion(self):
        exc = self._code(
            doc=sumar_doc(emisor_snapshot={**SNAPSHOT, "iibb_numero": None, "iibb_condition": None}),
            profile={**PROFILE, "iibb_numero": "  ", "iibb_condition": None},
        )
        assert exc.missing == ["iibb"]

    def test_lineas_que_no_suman_el_total(self):
        exc = self._code(lines=[{**LINE, "subtotal": Decimal("30000.00")}])
        assert exc.code == "invoice_lines_mismatch"

    def test_sin_lineas(self):
        exc = self._code(lines=[])
        assert exc.code == "invoice_lines_mismatch"

    def test_un_centavo_de_redondeo_se_tolera(self):
        v = _view(lines=[
            {**LINE, "subtotal": Decimal("16250.00")},
            {**LINE, "subtotal": Decimal("16250.01")},
        ])
        assert v.total == "$ 32.500,00"

    def test_factura_b_todavia_no(self):
        exc = self._code(doc=sumar_doc(comprobante_type="factura_b"))
        assert exc.code == "invoice_type_not_printable"

    @pytest.mark.parametrize("status", ["pending_cae", "rejected", "voided"])
    def test_no_autorizado(self, status):
        exc = self._code(doc=sumar_doc(status=status))
        assert exc.code == "fiscal_document_not_authorized"


# ═══════════════════════════════════════════════════════════════════════════
# 4.6 — Render
# ═══════════════════════════════════════════════════════════════════════════

class TestRender:

    def test_es_un_pdf_completo(self):
        from backend.services.fiscal.invoice_pdf import render_invoice_pdf

        pdf = render_invoice_pdf(_view())

        assert pdf.startswith(b"%PDF")
        assert pdf.rstrip().endswith(b"%%EOF")

    def test_el_texto_tiene_los_datos_obligatorios(self):
        from backend.services.fiscal.invoice_pdf import render_invoice_pdf

        text, pages = _pdf_text(render_invoice_pdf(_view()))

        assert pages == 1
        for esperado in (
            "ORIGINAL", "FACTURA", "C", "011", "0003", "00000501", "25/09/2026",
            "Sumar", "PEREZ MARIA LAURA", "Av. San Martín 1234, Mendoza", "20-12345678-6",
            "IVA RESPONSABLE MONOTRIBUTO", "0712345", "01/03/2019",
            "Consumidor Final", "Contado",
            "Ciclista Lycra con Bolsillos Kaese Talle 2 Negro", "$ 32.500,00",
            CAE, "05/10/2026", "Comprobante Autorizado",
        ):
            assert esperado in text, esperado
        assert "SIN VALIDEZ FISCAL" not in text

    def test_el_qr_se_construye_con_la_url_exacta(self):
        import segno

        from backend.services.fiscal import invoice_pdf

        view = _view()
        with patch.object(invoice_pdf.segno, "make", wraps=segno.make) as make:
            invoice_pdf.render_invoice_pdf(view)

        make.assert_called_once()
        assert make.call_args.args[0] == view.qr_url

    def test_duplicado(self):
        from backend.services.fiscal.invoice_pdf import render_invoice_pdf

        text, _ = _pdf_text(render_invoice_pdf(_view(copy="duplicado")))

        assert "DUPLICADO" in text
        assert "ORIGINAL" not in text

    def test_homologacion_lleva_la_marca(self):
        from backend.services.fiscal.invoice_pdf import render_invoice_pdf

        view = _view(sumar_doc(emisor_snapshot={**SNAPSHOT, "ambiente": "homologacion"}))
        text, _ = _pdf_text(render_invoice_pdf(view))

        assert "SIN VALIDEZ FISCAL" in text
        assert "HOMOLOGACION" in text

    def test_muchas_lineas_repiten_el_encabezado(self):
        from backend.services.fiscal.invoice_pdf import render_invoice_pdf

        lines = [
            {**LINE, "name_snapshot": f"Producto {i:02d}", "price": Decimal("650.00"),
             "subtotal": Decimal("650.00")}
            for i in range(50)
        ]
        text, pages = _pdf_text(render_invoice_pdf(_view(lines=lines)))

        assert pages >= 2
        assert text.count("00000501") >= pages
        assert "Producto 49" in text
        assert "$ 32.500,00" in text
        # el total y el CAE van juntos en la última página
        ultima = _pypdf().PdfReader(io.BytesIO(render_invoice_pdf(_view(lines=lines)))).pages[-1].extract_text()
        assert "Importe Total" in ultima and "Comprobante Autorizado" in ultima

    def test_una_descripcion_larga_no_rompe(self):
        from backend.services.fiscal.invoice_pdf import render_invoice_pdf

        largo = "Producto con un nombre larguísimo " * 6
        lines = [{**LINE, "name_snapshot": largo}]
        pdf = render_invoice_pdf(_view(lines=lines))

        assert pdf.startswith(b"%PDF")

    def test_el_qr_dibujado_es_modulo_a_modulo_el_de_segno(self):
        """Triangulación del render: el QR se dibuja con rectángulos fusionados
        por corrida; reconstruir la grilla desde el content stream del PDF tiene
        que dar EXACTAMENTE la matriz de segno para la URL (sin decoder de QR
        puro Python, esto prueba el dibujo; el contenido lo prueba el payload)."""
        import re

        import segno

        from backend.services.fiscal import invoice_pdf

        view = _view()
        pdf = invoice_pdf.render_invoice_pdf(view)
        stream = _pypdf().PdfReader(io.BytesIO(pdf)).pages[0].get_contents().get_data().decode("latin-1")

        esperado = [list(row) for row in segno.make(view.qr_url, error="m", micro=False)
                    .matrix_iter(scale=1, border=invoice_pdf._QR_QUIET)]
        n = len(esperado)
        modulo_pt = invoice_pdf._QR_SIZE / n * 72 / 25.4
        x0_pt = invoice_pdf._MARGIN * 72 / 25.4

        rects = [tuple(map(float, m)) for m in
                 re.findall(r"([\d.]+) ([\d.]+) ([\d.]+) ([-\d.]+) re f", stream)]
        qr = [(x, y, w, h) for x, y, w, h in rects
              if abs(abs(h) - modulo_pt) < 0.02 and x0_pt - 0.02 <= x <= x0_pt + 30 * 72 / 25.4]
        assert qr, "no se encontraron los módulos del QR en el PDF"
        top = max(y for _, y, _, _ in qr)

        grilla = [[False] * n for _ in range(n)]
        for x, y, w, _h in qr:
            fila = round((top - y) / modulo_pt)
            desde = round((x - x0_pt) / modulo_pt)
            for col in range(desde, desde + round(w / modulo_pt)):
                grilla[fila + _primera_fila_oscura(esperado)][col] = True

        assert grilla == [[bool(v) for v in row] for row in esperado]


def _primera_fila_oscura(matriz) -> int:
    return next(i for i, row in enumerate(matriz) if any(row))


# ═══════════════════════════════════════════════════════════════════════════
# Los tests del QR NO dependen de pypdf (hallazgo del red team, 2026-09-26)
# ═══════════════════════════════════════════════════════════════════════════

def test_sin_pypdf_los_tests_del_qr_y_de_la_vista_igual_corren(tmp_path):
    """pypdf se instala sólo en CI (Backend_Tests.yml), no en requirements.txt.
    Si faltara, el skip NO puede llevarse puestos los tests del QR RG 4892 (el
    byte a byte contra el ejemplo oficial de ARCA) ni los de la vista pura, que
    no lo usan: sólo se saltean los que extraen texto del PDF. Se corre este
    mismo archivo en un proceso aparte con un `pypdf` que no importa."""
    import os
    import pathlib
    import subprocess
    import sys

    (tmp_path / "pypdf.py").write_text('raise ImportError("pypdf bloqueado por el test")\n', encoding="utf-8")
    repo_root = pathlib.Path(__file__).resolve().parents[2]
    env = {k: v for k, v in os.environ.items() if not k.startswith("COV_CORE")}
    env["PYTHONPATH"] = os.pathsep.join(filter(None, [str(tmp_path), env.get("PYTHONPATH")]))
    selected = [f"{pathlib.Path(__file__).resolve()}::{cls}"
                for cls in ("TestQR", "TestVistaDeSumar", "TestReceptor", "TestCondicionDeVenta",
                            "TestFotoDelEmisor", "TestNoSeImprimeConDatosAdivinados")]

    result = subprocess.run(
        [sys.executable, "-m", "pytest", *selected, "-q", "-rs", "-p", "no:cacheprovider"],
        cwd=repo_root, env=env, capture_output=True, text=True, timeout=180,
    )

    out = result.stdout + result.stderr
    assert result.returncode == 0, out
    assert " passed" in out, out
    assert "skipped" not in out, out


# ═══════════════════════════════════════════════════════════════════════════
# documentos-marca-empresa (tanda B, grupo 13) — la Factura C suma LOGO, CONTACTO
# y COLOR de la marca de la cuenta sin tocar nada fiscal (design D11).
#
# Strict TDD: escritos antes de `render_invoice_pdf(view, branding)`, del recuadro
# del emisor medido (`layout_invoice_header`) y de la marca en
# `invoice_print_service`. Supera OQ-1 y OQ-4 de `factura-fiscal-imprimible` (la
# factura no imprimía teléfono, email ni web): por pedido del PO del 2026-10-11
# ("toda la información de la empresa y el logo" en todos los papeles).
# ═══════════════════════════════════════════════════════════════════════════

_GOLDEN_LAYOUT = json.loads(
    (pathlib.Path(__file__).parent / "fixtures" / "invoice_pdf_sin_marca_layout.json").read_text(encoding="utf-8")
)

_RPC_EMPTY = {
    "nombre_fantasia": None, "razon_social": None, "cuit": None, "domicilio_comercial": None,
    "business_name": None, "phone": None, "iva_condition": None,
    "brand_display_name": None, "brand_legal_name": None, "brand_tax_id": None, "brand_address": None,
    "brand_phone": None, "brand_email": None, "brand_website": None, "brand_footer_note": None,
    "palette_preset": None, "accent_color": None, "logo_sha256": None,
}

BLUE = (29, 78, 216)        # #1d4ed8, el preset "azul"
INK = (30, 41, 59)
MUTED = (100, 116, 139)
SURFACE = (241, 245, 249)
WHITE = (255, 255, 255)
BLACK = (0, 0, 0)
PT = 72 / 25.4              # puntos por milímetro
ACCOUNT = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
HEAD_LABELS = ("Descripci\xf3n", "Cantidad", "Precio unitario", "Subtotal")


def _brand(*, preset=None, accent=None, logo=None, **rpc_over):
    """La marca armada con la cascada REAL a partir de lo que devolvería la RPC."""
    from backend.services.commercial_documents.branding import branding_from_rpc

    raw = dict(_RPC_EMPTY, palette_preset=preset, accent_color=accent)
    raw.update(rpc_over)
    return branding_from_rpc(raw, logo)


def _logo(size=(400, 100)):
    from PIL import Image

    from backend.services.commercial_documents.logo import normalize_logo

    buf = io.BytesIO()
    Image.new("RGBA", size, (200, 30, 30, 255)).save(buf, "PNG")
    return normalize_logo(buf.getvalue())


FULL_CONTACT = dict(brand_phone="2615550101", brand_email="ventas@negocio.com.ar", brand_website="negocio.com.ar")


def _render(view, branding=None) -> bytes:
    from backend.services.fiscal.invoice_pdf import render_invoice_pdf

    return render_invoice_pdf(view) if branding is None else render_invoice_pdf(view, branding)


def _layout(pdf: bytes) -> list[list[list]]:
    """Por página, [texto, x, y, cuerpo] de cada texto dibujado, tal como lo ve un lector."""
    pages = []
    for page in _pypdf().PdfReader(io.BytesIO(pdf)).pages:
        items: list[list] = []

        def visit(text, cm, tm, font, size, items=items):
            if text.strip():
                items.append([text, round(tm[4], 2), round(tm[5], 2), round(size, 2)])

        page.extract_text(visitor_text=visit)
        pages.append(items)
    return pages


def _same_layout(actual, expected) -> bool:
    if len(actual) != len(expected):
        return False
    for page_a, page_e in zip(actual, expected):
        if len(page_a) != len(page_e):
            return False
        for (ta, xa, ya, sa), (te, xe, ye, se) in zip(page_a, page_e):
            if ta != te or abs(xa - xe) > 0.06 or abs(ya - ye) > 0.06 or abs(sa - se) > 0.01:
                return False
    return True


_STREAM_TOKEN = re.compile(
    r"(?P<rgb>[\d.]+ [\d.]+ [\d.]+) rg\b"
    r"|(?P<gray>[\d.]+) g\b"
    r"|\((?P<text>(?:\\.|[^\\)])*)\) Tj"
    r"|(?P<rect>-?[\d.]+ -?[\d.]+ -?[\d.]+ -?[\d.]+) re (?P<paint>[fBS])"
    r"|(?P<iw>[\d.]+) 0 0 (?P<ih>[\d.]+) (?P<ix>[\d.]+) (?P<iy>[\d.]+) cm /I\d+ Do"
    r"|(?<![\w.])(?P<push>q)(?![\w.])"
    r"|(?<![\w.])(?P<pop>Q)(?![\w.])"
)


def _rgb(triplet: str) -> tuple[int, int, int]:
    return tuple(round(float(v) * 255) for v in triplet.split())  # type: ignore[return-value]


def _events(pdf: bytes) -> list[list[tuple]]:
    """Por página, los eventos de dibujo con el color de RELLENO vigente (el de los textos y el
    de los rectángulos): `("text", str, rgb)`, `("rect", (x, y, w, h), paint, rgb)` y
    `("image", (w, h, x, y))` (esquina inferior izquierda, en puntos). Respeta `q`/`Q`: fpdf2
    escribe el color de cada texto dentro de su propio grupo gráfico y, al cerrarlo, el color
    vuelve al anterior."""
    pages = []
    for page in _pypdf().PdfReader(io.BytesIO(pdf)).pages:
        stream = page.get_contents().get_data().decode("latin-1")
        fill, stack, events = BLACK, [], []
        for m in _STREAM_TOKEN.finditer(stream):
            if m.group("rgb"):
                fill = _rgb(m.group("rgb"))
            elif m.group("gray"):
                level = round(float(m.group("gray")) * 255)
                fill = (level, level, level)
            elif m.group("push"):
                stack.append(fill)
            elif m.group("pop"):
                fill = stack.pop() if stack else fill
            elif m.group("text") is not None:
                events.append(("text", m.group("text"), fill))
            elif m.group("rect"):
                events.append(("rect", tuple(float(v) for v in m.group("rect").split()), m.group("paint"), fill))
            elif m.group("iw"):
                events.append(("image", tuple(float(m.group(k)) for k in ("iw", "ih", "ix", "iy"))))
        pages.append(events)
    return pages


def _images(pdf: bytes) -> int:
    return sum(len(page.images) for page in _pypdf().PdfReader(io.BytesIO(pdf)).pages)


def _header_box(events) -> tuple[float, float]:
    """(arriba, abajo) en puntos del recuadro del encabezado: el rectángulo de 186 mm de ancho
    más alto de la página (el del receptor es más bajo)."""
    boxes = [e[1] for e in events if e[0] == "rect" and e[2] == "S" and abs(e[1][2] - 186 * PT) < 0.05]
    top, _x, height = max(((b[1], b[0], abs(b[3])) for b in boxes), key=lambda t: t[2])
    return top, top - height


@pytest.fixture(autouse=True)
def _fresh_logo_cache():
    from backend.services.commercial_documents.branding import clear_logo_cache

    clear_logo_cache()
    yield
    clear_logo_cache()


def _lines(count: int) -> list[dict]:
    return [{**LINE, "name_snapshot": f"Producto {i:02d}", "price": Decimal("650.00"),
             "subtotal": Decimal("650.00")} for i in range(count)]


def _golden_views():
    return {
        "sumar_1_linea": _view(),
        "sumar_homologacion_duplicado": _view(
            sumar_doc(emisor_snapshot={**SNAPSHOT, "ambiente": "homologacion"}), copy="duplicado"),
        "sumar_sin_fantasia_55_lineas": _view(
            sumar_doc(emisor_snapshot={**SNAPSHOT, "nombre_fantasia": None}, total=Decimal("35750.00")),
            lines=_lines(55)),
    }


class TestSinMarcaLaFacturaQuedaComoHoy:
    """Sin marca configurada (o con la marca por defecto) la factura es la de antes de este cambio:
    mismo texto, mismas posiciones, sin imágenes. El dibujo anterior se congeló en
    `fixtures/invoice_pdf_sin_marca_layout.json` desde el render previo al cambio."""

    @pytest.mark.parametrize("name", list(_GOLDEN_LAYOUT))
    def test_el_render_sin_marca_conserva_texto_y_posiciones(self, name):
        assert _same_layout(_layout(_render(_golden_views()[name])), _GOLDEN_LAYOUT[name])

    @pytest.mark.parametrize("name", list(_GOLDEN_LAYOUT))
    def test_una_cuenta_sin_marca_recibe_la_misma_factura(self, name):
        """La marca que resuelve `resolve_document_branding` para una cuenta que nunca la configuró
        (Neutro, sin logo, sin contacto) NO cambia nada, ni siquiera con el teléfono del dueño."""
        branding = _brand(business_name="Almacén Don José", phone="2615550101")
        pdf = _render(_golden_views()[name], branding)

        assert _same_layout(_layout(pdf), _GOLDEN_LAYOUT[name])
        assert _images(pdf) == 0

    def test_el_telefono_del_duenio_no_se_imprime_en_la_factura(self):
        text, _ = _pdf_text(_render(_view(), _brand(business_name="Almacén Don José", phone="2615550101")))

        assert "2615550101" not in text
        assert "Tel:" not in text


class TestConLaMarcaDeLaCuenta:

    def test_logo_y_las_tres_lineas_de_contacto(self):
        pdf = _render(_view(), _brand(logo=_logo(), **FULL_CONTACT))
        text, pages = _pdf_text(pdf)

        assert pages == 1 and _images(pdf) == 1
        for esperado in ("2615550101", "ventas@negocio.com.ar", "negocio.com.ar"):
            assert esperado in text, esperado

    def test_todo_el_contenido_de_la_factura_sin_marca_sigue_estando(self):
        """La marca SUMA (logo y contacto): ningún texto de la factura sin marca desaparece."""
        sin_marca = [item[0] for item in _GOLDEN_LAYOUT["sumar_1_linea"][0]]
        con_marca = {item[0] for item in _layout(_render(_view(), _brand(logo=_logo(), **FULL_CONTACT)))[0]}

        assert set(sin_marca) <= con_marca

    def test_las_lineas_de_contacto_van_debajo_de_la_leyenda_de_iva_en_su_orden(self):
        y_of = {text: y for text, _x, y, _s in _layout(_render(_view(), _brand(**FULL_CONTACT)))[0]}

        assert y_of["IVA RESPONSABLE MONOTRIBUTO"] > y_of["Tel: 2615550101"] > y_of["ventas@negocio.com.ar"] \
            > y_of["negocio.com.ar"]

    def test_solo_email_no_inventa_telefono_ni_web(self):
        items = [t for t, *_ in _layout(_render(_view(), _brand(brand_email="ventas@negocio.com.ar")))[0]]

        assert "ventas@negocio.com.ar" in items
        assert not any(t.startswith("Tel:") or t == "negocio.com.ar" for t in items)

    def test_el_contacto_nuevo_pasa_por_el_sanitizador_cp1252(self):
        """El guion largo de un texto NUEVO se imprime (los textos fiscales existentes conservan `_latin1`)."""
        text, _ = _pdf_text(_render(_view(), _brand(brand_website="negocio.com.ar — Mendoza")))

        assert "negocio.com.ar — Mendoza" in text

    def test_la_leyenda_al_pie_de_la_marca_no_va_en_la_factura(self):
        pdf = _render(_view(), _brand(brand_footer_note="Precios con IVA incluido. Alias: sumar.ropa", **FULL_CONTACT))
        text, _ = _pdf_text(pdf)

        assert "Precios con IVA incluido" not in text and "sumar.ropa" not in text

    def test_una_marca_con_otra_identidad_no_cambia_lo_fiscal_impreso(self):
        """Los datos fiscales salen de la foto congelada, nunca de la marca (design D11)."""
        view = _view(sumar_doc(emisor_snapshot={**SNAPSHOT, "razon_social": "Ropa Deportiva SRL",
                                                "nombre_fantasia": None}),
                     profile={**PROFILE, "razon_social": "Ropa Deportiva SRL", "nombre_fantasia": None})
        branding = _brand(brand_display_name="Sumar", brand_legal_name="Otra SA", brand_tax_id="20111111112",
                          brand_address="Otro domicilio 999", **FULL_CONTACT)
        text, _ = _pdf_text(_render(view, branding))

        assert "Ropa Deportiva SRL" in text
        for ajeno in ("Otra SA", "Otro domicilio 999", "20-11111111-2", "20111111112"):
            assert ajeno not in text, ajeno
        assert "20-12345678-6" in text                        # el CUIT de la foto

    def test_la_vista_fiscal_no_conoce_la_marca(self):
        """`build_invoice_view` no cambia: la marca entra sólo al render y no a la foto del emisor."""
        import dataclasses

        from backend.services.fiscal.invoice_pdf import InvoiceView

        campos = {f.name for f in dataclasses.fields(InvoiceView)}
        assert not {name for name in campos if "brand" in name or "logo" in name or "palette" in name}


class TestPaletaSoloEnLoNoFiscal:

    def _events(self, preset=None, accent=None, **kwargs):
        return _events(_render(_view(**kwargs), _brand(preset=preset, accent=accent) if preset else None))

    def test_el_titulo_y_la_banda_de_la_tabla_usan_el_azul(self):
        events = self._events("azul")[0]

        titulo = [e for e in events if e[0] == "text" and e[1] == "FACTURA"]
        banda = [e for e in events if e[0] == "rect" and e[2] == "f" and e[3] == BLUE]
        assert [t[2] for t in titulo] == [BLUE]
        assert len(banda) == 4                                         # las cuatro columnas de la cabecera
        assert {round(abs(r[1][3]) / PT, 2) for r in banda} == {7.0}   # 7 mm de alto

    def test_el_texto_de_la_banda_es_el_de_mayor_contraste(self):
        rotulos = [(e[1], e[2]) for e in self._events("azul")[0] if e[0] == "text" and e[1] in HEAD_LABELS]

        assert sorted(rotulos) == sorted((label, WHITE) for label in HEAD_LABELS)

    def test_el_azul_aparece_solo_en_el_titulo_y_en_la_banda(self):
        azul = [e for e in self._events("azul")[0] if e[0] != "image" and e[-1] == BLUE]

        assert sorted((e[0], e[1] if e[0] == "text" else e[2]) for e in azul) \
            == sorted([("text", "FACTURA")] + [("rect", "f")] * 4)

    @pytest.mark.parametrize("preset", ["azul", "bordo", "verde", "grafito"])
    def test_lo_fiscal_no_cambia_de_color_con_ninguna_paleta(self, preset):
        """Todo texto que no sea el título ni los rótulos de la banda se dibuja con el MISMO color que
        sin paleta: ni el recuadro de la letra, ni el CAE, ni el receptor, ni los totales se tiñen."""
        def colores(events):
            return [(e[1], e[2]) for e in events[0] if e[0] == "text" and e[1] != "FACTURA" and e[1] not in HEAD_LABELS]

        sin_paleta = colores(self._events())
        con_paleta = colores(self._events(preset))

        assert con_paleta == sin_paleta
        assert {c for _t, c in con_paleta} <= {INK, MUTED, BLACK}

    def test_con_neutro_el_titulo_y_la_banda_quedan_como_hoy(self):
        events = self._events()[0]

        assert [e[2] for e in events if e[0] == "text" and e[1] == "FACTURA"] == [INK]
        assert [e[2] for e in events if e[0] == "text" and e[1] in HEAD_LABELS] == [INK] * 4
        assert len([e for e in events if e[0] == "rect" and e[2] == "f" and e[3] == SURFACE]) == 4

    def test_con_neutro_no_hay_ningun_color_de_acento(self):
        usados = {e[-1] for page in self._events() for e in page if e[0] != "image"}

        assert usados <= {INK, MUTED, SURFACE, WHITE, BLACK}

    def test_el_qr_se_dibuja_siempre_negro_sobre_blanco(self):
        import segno

        from backend.services.fiscal import invoice_pdf

        view = _view()
        pdf = _render(view, _brand(preset="azul"))
        rows = list(segno.make(view.qr_url, error="m", micro=False).matrix_iter(scale=1, border=invoice_pdf._QR_QUIET))
        module_pt = invoice_pdf._QR_SIZE / len(rows) * PT
        rects = [e for e in _events(pdf)[0] if e[0] == "rect" and e[2] == "f"]
        qr = [e for e in rects if abs(abs(e[1][3]) - module_pt) < 0.02]

        assert qr and {e[3] for e in qr} == {BLACK}
        # nada coloreado se superpone al cuadrado del QR (los módulos son los únicos rellenos ahí)
        x0 = min(e[1][0] for e in qr)
        x1 = max(e[1][0] + e[1][2] for e in qr)
        y_top = max(e[1][1] for e in qr)
        y_bottom = min(e[1][1] + e[1][3] for e in qr)
        for e in rects:
            if e in qr:
                continue
            x, y, w, h = e[1]
            solapa = not (x + w <= x0 or x >= x1 or max(y, y + h) <= y_bottom or min(y, y + h) >= y_top)
            assert not solapa, e

    def test_la_banda_de_la_tabla_se_repite_con_la_paleta_en_cada_pagina(self):
        paginas = self._events("azul", lines=_lines(50))

        assert len(paginas) >= 2
        for events in paginas:
            assert len([e for e in events if e[0] == "rect" and e[2] == "f" and e[3] == BLUE]) == 4
            assert [e[2] for e in events if e[0] == "text" and e[1] == "FACTURA"] == [BLUE]
        # el cuerpo de la tabla NO hereda el color del texto de la banda (blanco sobre blanco)
        cuerpo = [e for events in paginas for e in events if e[0] == "text" and e[1].startswith("Producto")]
        assert cuerpo and {e[2] for e in cuerpo} == {INK}
        # los totales y el CAE de la última página, tampoco
        ultima = {e[1]: e[2] for e in paginas[-1] if e[0] == "text"}
        assert ultima["Importe Total:"] == INK and ultima["Comprobante Autorizado"] == INK


def _geometry_pdf(view, branding):
    from backend.services.fiscal import invoice_pdf

    pdf = invoice_pdf._InvoicePDF(view, branding)
    pdf.add_page()
    return pdf, invoice_pdf.layout_invoice_header(pdf, view, branding)


_FANTASIA_LARGA = "Sumar Ropa Deportiva y Accesorios para Toda la Familia"


class TestElRecuadroDelEmisorSeMideAntesDeDibujar:

    def test_sin_logo_ni_contacto_el_recuadro_mide_lo_de_siempre(self):
        _pdf, layout = _geometry_pdf(_view(), None)

        assert layout.box_height == pytest.approx(42.0)
        assert layout.box_top == pytest.approx(19.0)

    def test_crece_con_logo_cuadrado_fantasia_larga_y_tres_lineas_de_contacto(self):
        view = _view(sumar_doc(emisor_snapshot={**SNAPSHOT, "nombre_fantasia": _FANTASIA_LARGA}))
        branding = _brand(logo=_logo((1000, 1000)), **FULL_CONTACT)
        pdf, layout = _geometry_pdf(view, branding)
        left = layout.left

        lx, ly, lw, lh = left.logo_rect
        assert (lw, lh) == (pytest.approx(16.0), pytest.approx(16.0))      # cuadrado: el alto limita
        assert layout.box_height > 42.0 + 10.0
        assert ly >= layout.box_top and lx >= 12.0                          # el logo arranca dentro del recuadro
        assert left.name_y >= ly + lh                                       # el nombre empieza DEBAJO del logo
        assert len(left.items[0].lines) >= 2                                # la fantasía larga se parte en renglones
        assert left.y + left.height <= layout.box_bottom - 3.0 + 1e-6       # todo adentro, con su margen
        assert pdf.get_y() == pytest.approx(layout.box_bottom + 3.0)        # la tabla arranca debajo del recuadro

    def test_logo_horizontal_4_a_1_entra_en_40_mm_de_ancho(self):
        _pdf, layout = _geometry_pdf(_view(), _brand(logo=_logo((1000, 250))))

        _x, _y, w, h = layout.left.logo_rect
        assert (w, h) == (pytest.approx(40.0), pytest.approx(10.0))

    def test_sin_nombre_de_fantasia_el_nombre_es_la_razon_social_en_13_pt(self):
        view = _view(sumar_doc(emisor_snapshot={**SNAPSHOT, "nombre_fantasia": None}),
                     profile={**PROFILE, "nombre_fantasia": None})
        _pdf, layout = _geometry_pdf(view, _brand(logo=_logo(), brand_email="ventas@negocio.com.ar"))
        item_texts = [" ".join(item.lines) for item in layout.left.items]

        assert item_texts[0] == "PEREZ MARIA LAURA"
        assert item_texts.count("PEREZ MARIA LAURA") == 1
        assert layout.left.items[0].size == 13.0
        assert "ventas@negocio.com.ar" in item_texts

    def test_el_recuadro_dibujado_contiene_logo_nombre_iva_y_contacto(self):
        """Verificación independiente del helper: se lee del PDF final."""
        view = _view(sumar_doc(emisor_snapshot={**SNAPSHOT, "nombre_fantasia": _FANTASIA_LARGA}))
        pdf = _render(view, _brand(logo=_logo((1000, 1000)), **FULL_CONTACT))
        events = _events(pdf)[0]
        top, bottom = _header_box(events)

        assert top - bottom > (42.0 + 10) * PT                                  # creció
        w, h, _ix, iy = next(e[1] for e in events if e[0] == "image")
        assert bottom < iy and iy + h < top                                     # el logo está adentro
        textos = {t[0]: t for t in _layout(pdf)[0]}
        for clave in ("IVA RESPONSABLE MONOTRIBUTO", "Tel: 2615550101", "ventas@negocio.com.ar", "negocio.com.ar"):
            assert bottom + 2.0 <= textos[clave][2] <= top, clave
        banda_top = next(e[1][1] for e in events if e[0] == "rect" and e[2] == "f")
        assert banda_top < bottom                                               # la tabla arranca debajo

    def test_con_muchas_lineas_cada_pagina_repite_el_encabezado_con_el_logo(self):
        view = _view(sumar_doc(emisor_snapshot={**SNAPSHOT, "nombre_fantasia": _FANTASIA_LARGA},
                               total=Decimal("39000.00")), lines=_lines(60))
        branding = _brand(logo=_logo((1000, 1000)), **FULL_CONTACT)
        pdf = _render(view, branding)
        paginas, diseno = _events(pdf), _layout(pdf)

        assert len(paginas) >= 3
        for events, items in zip(paginas, diseno):
            imagenes = [e[1] for e in events if e[0] == "image"]
            assert len(imagenes) == 1                                           # el logo, en CADA página
            top, bottom = _header_box(events)
            w, h, _ix, iy = imagenes[0]
            assert bottom < iy and iy + h < top
            textos = {t[0]: t[2] for t in items}
            assert bottom < textos["negocio.com.ar"] < top
            assert bottom < textos["IVA RESPONSABLE MONOTRIBUTO"] < top
            assert max(e[1][1] for e in events if e[0] == "rect" and e[2] == "f") < bottom   # la tabla, debajo
        # el logo se incrusta UNA sola vez aunque se dibuje en cada página
        una_pagina = _render(_view(), branding)
        assert pdf.count(b"/Subtype /Image") == una_pagina.count(b"/Subtype /Image") > 0
        text, pages = _pdf_text(pdf)
        assert "Producto 59" in text and text.count("00000501") >= pages


class TestLaMarcaSeResuelveDeLaCuentaDelComprobante:

    @staticmethod
    def _repos(raw=None, *, error=None):
        from unittest.mock import AsyncMock

        doc_repo = AsyncMock()
        doc_repo.get_by_id.return_value = sumar_doc()
        doc_repo.get_invoice_lines.return_value = {"lines": [LINE], "sale_condition_kind": None}
        profile_repo = AsyncMock()
        profile_repo.get_by_account_id.return_value = PROFILE
        branding_repo = AsyncMock()
        if error is not None:
            branding_repo.get_commercial_issuer.side_effect = error
        else:
            branding_repo.get_commercial_issuer.return_value = raw
        branding_repo.get_document_logo.return_value = None
        return doc_repo, profile_repo, branding_repo

    async def test_pide_la_marca_de_la_cuenta_del_comprobante_y_la_imprime(self):
        from backend.services.fiscal.invoice_print_service import get_invoice_pdf

        raw = dict(_RPC_EMPTY, palette_preset="azul", **FULL_CONTACT)
        doc_repo, profile_repo, branding_repo = self._repos(raw)

        pdf, filename = await get_invoice_pdf(doc_repo, profile_repo, branding_repo, account_id=ACCOUNT,
                                              doc_id=uuid.UUID(sumar_doc()["id"]))

        branding_repo.get_commercial_issuer.assert_awaited_once_with(ACCOUNT)
        text, _ = _pdf_text(pdf)
        assert "ventas@negocio.com.ar" in text and filename == "factura-C-0003-00000501.pdf"
        assert any(e[0] == "rect" and e[3] == BLUE for e in _events(pdf)[0])

    async def test_baja_los_bytes_del_logo_solo_si_la_marca_tiene_huella(self):
        from backend.services.fiscal.invoice_print_service import get_invoice_pdf

        logo = _logo()
        doc_repo, profile_repo, branding_repo = self._repos(dict(_RPC_EMPTY, logo_sha256=logo.sha256))
        branding_repo.get_document_logo.return_value = {"logo_image": logo.data, "logo_mime": logo.mime,
                                                        "logo_sha256": logo.sha256}

        pdf, _ = await get_invoice_pdf(doc_repo, profile_repo, branding_repo, account_id=ACCOUNT,
                                       doc_id=uuid.UUID(sumar_doc()["id"]))

        assert _images(pdf) == 1
        branding_repo.get_document_logo.assert_awaited_once_with(ACCOUNT)

    async def test_una_cuenta_sin_huella_no_baja_ningun_logo(self):
        from backend.services.fiscal.invoice_print_service import get_invoice_pdf

        doc_repo, profile_repo, branding_repo = self._repos(dict(_RPC_EMPTY))

        pdf, _ = await get_invoice_pdf(doc_repo, profile_repo, branding_repo, account_id=ACCOUNT,
                                       doc_id=uuid.UUID(sumar_doc()["id"]))

        branding_repo.get_document_logo.assert_not_awaited()
        assert _images(pdf) == 0

    async def test_si_la_marca_no_se_puede_leer_la_factura_sale_igual_sin_marca(self, caplog):
        """Reimprimir una factura autorizada no puede quedar bloqueado por un detalle de presentación."""
        import logging

        from backend.services.fiscal.invoice_print_service import get_invoice_pdf

        doc_repo, profile_repo, branding_repo = self._repos(error=RuntimeError("la base no contesta"))
        with caplog.at_level(logging.WARNING):
            pdf, _ = await get_invoice_pdf(doc_repo, profile_repo, branding_repo, account_id=ACCOUNT,
                                           doc_id=uuid.UUID(sumar_doc()["id"]))

        assert _same_layout(_layout(pdf), _GOLDEN_LAYOUT["sumar_1_linea"])
        assert any("marca" in r.getMessage().lower() and r.levelno >= logging.WARNING for r in caplog.records)

    async def test_un_error_de_la_factura_no_se_traga_con_la_marca(self):
        """La degradación es SÓLO de la marca: un comprobante inexistente sigue siendo 404."""
        from backend.core.errors import ProblemHTTPException
        from backend.services.fiscal.invoice_print_service import get_invoice_pdf

        doc_repo, profile_repo, branding_repo = self._repos({})
        doc_repo.get_by_id.return_value = None
        with pytest.raises(ProblemHTTPException) as exc:
            await get_invoice_pdf(doc_repo, profile_repo, branding_repo, account_id=ACCOUNT,
                                       doc_id=uuid.UUID(sumar_doc()["id"]))

        assert exc.value.status_code == 404
        branding_repo.get_commercial_issuer.assert_not_awaited()
