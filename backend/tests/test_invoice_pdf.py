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
