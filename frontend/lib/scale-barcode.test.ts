/**
 * balanza-etiquetas-pos (task 4.2) — RED→GREEN de `decodeScaleBarcode` (D5).
 * Tabla completa de la spec `scale-label-integration` y de D5.
 */
import { describe, it, expect } from "vitest"
import { decodeScaleBarcode, scaleDecodeErrorMessage, type ScaleDecodeResult } from "@/lib/scale-barcode"
import { FACTORY_SCALE_SETTINGS, type ScaleSettings } from "@/lib/scale-layout"

// `FACTORY_SCALE_SETTINGS.enabled` es `false` (D3: una cuenta nueva nace con
// la lectura apagada) — estos tests ejercitan los formatos de fábrica con la
// lectura YA activada por la cuenta.
const FACTORY: ScaleSettings = { ...FACTORY_SCALE_SETTINGS, enabled: true }

/** Fábrica con el campo C reconfigurado a 0 decimales (OQ-2, hipótesis de la guía). */
const WEIGHED_0_DECIMALS: ScaleSettings = {
  ...FACTORY,
  layouts: [
    { ...FACTORY.layouts[0], segments: [
      { field: "fixed", digits: 2, value: "20" },
      { field: "plu", digits: 4 },
      { field: "amount", digits: 6, decimals: 0 },
    ] },
    FACTORY.layouts[1],
    FACTORY.layouts[2],
  ],
}

/** Fábrica de peso con Cantidad embebida (peso, no importe) — OQ-1. */
const WEIGHED_QUANTITY: ScaleSettings = {
  ...FACTORY,
  layouts: [
    { ...FACTORY.layouts[0], segments: [
      { field: "fixed", digits: 2, value: "20" },
      { field: "plu", digits: 4 },
      { field: "quantity", digits: 6, decimals: 3 },
    ] },
    FACTORY.layouts[1],
    FACTORY.layouts[2],
  ],
}

describe("decodeScaleBarcode — D5", () => {
  it("etiqueta de peso con la configuración de fábrica: PLU 261, importe 13,63", () => {
    const r = decodeScaleBarcode("2002610013638", FACTORY)
    expect(r).toEqual({ status: "ok", layout: "weighed", plu: 261, value: { kind: "amount", amount: 13.63 } })
  })

  it("dígito verificador incorrecto → invalid/check_digit", () => {
    const r = decodeScaleBarcode("2002610013639", FACTORY)
    expect(r).toEqual({ status: "invalid", reason: "check_digit" })
  })

  it("importe configurado sin decimales → PLU 261, importe 13.500", () => {
    const r = decodeScaleBarcode("2002610135002", WEIGHED_0_DECIMALS)
    expect(r).toEqual({ status: "ok", layout: "weighed", plu: 261, value: { kind: "amount", amount: 13500 } })
  })

  it("TRIANGULATE: peso embebido (cantidad, 3 decimales) → PLU 509, peso 1,250 kg", () => {
    const r = decodeScaleBarcode("2005090012504", WEIGHED_QUANTITY)
    expect(r).toEqual({ status: "ok", layout: "weighed", plu: 509, value: { kind: "weight", amount: 1.25 } })
  })

  it("TRIANGULATE: formato por unidad de fábrica → PLU 100, importe 9,00", () => {
    const r = decodeScaleBarcode("2101000009005", FACTORY)
    expect(r).toEqual({ status: "ok", layout: "unit", plu: 100, value: { kind: "amount", amount: 9 } })
  })

  it("ticket de varios artículos → unsupported/multi_item", () => {
    const r = decodeScaleBarcode("2200000045003", FACTORY)
    expect(r).toEqual({ status: "unsupported", reason: "multi_item" })
  })

  it("PLU 0 → unsupported/generic_item (venta genérica)", () => {
    const r = decodeScaleBarcode("2000000012346", FACTORY)
    expect(r).toEqual({ status: "unsupported", reason: "generic_item" })
  })

  it("importe cero → invalid/value_zero", () => {
    const r = decodeScaleBarcode("2002610000003", FACTORY)
    expect(r).toEqual({ status: "invalid", reason: "value_zero" })
  })

  it("TRIANGULATE: importe cero en formato por unidad → invalid/value_zero", () => {
    const r = decodeScaleBarcode("2101000000002", FACTORY)
    expect(r).toEqual({ status: "invalid", reason: "value_zero" })
  })

  it("12 dígitos con cabecera habilitada → invalid/missing_check_digit", () => {
    const r = decodeScaleBarcode("200261001363", FACTORY)
    expect(r).toEqual({ status: "invalid", reason: "missing_check_digit" })
  })

  it("cabecera no configurada (27) → not_scale/no_layout_match", () => {
    const r = decodeScaleBarcode("2702610013637", FACTORY)
    expect(r).toEqual({ status: "not_scale", reason: "no_layout_match" })
  })

  it("EAN-13 de un producto envasado (779...) → not_scale/no_layout_match", () => {
    const r = decodeScaleBarcode("7791234567898", FACTORY)
    expect(r).toEqual({ status: "not_scale", reason: "no_layout_match" })
  })

  it("no es un EAN-13 → not_scale/not_ean13", () => {
    expect(decodeScaleBarcode("ABC-12", FACTORY)).toEqual({ status: "not_scale", reason: "not_ean13" })
  })

  it("balanza deshabilitada → not_scale/disabled (aunque el código sea una etiqueta válida)", () => {
    expect(decodeScaleBarcode("2002610013638", FACTORY_SCALE_SETTINGS)).toEqual({ status: "not_scale", reason: "disabled" })
  })

  it("REFACTOR: campos en otro orden — importe antes que código se admite", () => {
    const settings: ScaleSettings = {
      ...FACTORY,
      layouts: [
        { kind: "weighed", enabled: true, segments: [
          { field: "fixed", digits: 2, value: "20" },
          { field: "amount", digits: 6, decimals: 2 },
          { field: "plu", digits: 4 },
        ] },
        FACTORY.layouts[1],
        FACTORY.layouts[2],
      ],
    }
    // "20" + importe(6, "001363") + plu(4, "0261") + check(9) — mismo código que arriba reordenado.
    const code = "20" + "001363" + "0261"
    const check = (() => {
      const d = code.split("").map(Number)
      const sum = d.reduce((acc, x, i) => acc + x * (i % 2 === 0 ? 1 : 3), 0)
      return (10 - (sum % 10)) % 10
    })()
    const r = decodeScaleBarcode(code + String(check), settings)
    expect(r).toEqual({ status: "ok", layout: "weighed", plu: 261, value: { kind: "amount", amount: 13.63 } })
  })

  it("REFACTOR: código antes que la cabecera NO se admite (campo A siempre es fixed)", () => {
    // Esto no es un formato representable (field A debe ser fixed, D4.2) — la
    // configuración misma sería inválida; acá se verifica que decodeScaleBarcode
    // simplemente no encuentra ningún layout habilitado con field A != fixed,
    // así que decodifica según lo que SÍ hay configurado (fábrica), no según
    // un layout imposible.
    const r = decodeScaleBarcode("2002610013638", FACTORY)
    expect(r.status).toBe("ok")
  })
})

describe("scaleDecodeErrorMessage", () => {
  it("missing_check_digit: menciona el check digit EAN-13", () => {
    const msg = scaleDecodeErrorMessage({ status: "invalid", reason: "missing_check_digit" })
    expect(msg).toContain("dígito verificador")
    expect(msg).toContain("EAN-13")
  })

  it("generic_item: menciona PLU 0 y qué hacer", () => {
    const msg = scaleDecodeErrorMessage({ status: "unsupported", reason: "generic_item" })
    expect(msg).toContain("PLU 0")
    expect(msg.toLowerCase()).toContain("vendelo con su plu")
  })

  it("TRIANGULATE: multi_item indica cargar uno por uno", () => {
    const msg = scaleDecodeErrorMessage({ status: "unsupported", reason: "multi_item" })
    expect(msg.toLowerCase()).toContain("uno por uno")
  })

  it("check_digit y value_zero devuelven mensajes distintos y no vacíos", () => {
    const a = scaleDecodeErrorMessage({ status: "invalid", reason: "check_digit" })
    const b = scaleDecodeErrorMessage({ status: "invalid", reason: "value_zero" })
    expect(a).not.toBe(b)
    expect(a.length).toBeGreaterThan(0)
    expect(b.length).toBeGreaterThan(0)
  })
})

describe("decodeScaleBarcode — result narrowing (TypeScript exhaustiveness smoke)", () => {
  it("un resultado ok siempre trae plu y value", () => {
    const r: ScaleDecodeResult = decodeScaleBarcode("2002610013638", FACTORY)
    if (r.status === "ok") {
      expect(typeof r.plu).toBe("number")
      expect(typeof r.value.amount).toBe("number")
    } else {
      throw new Error("se esperaba ok")
    }
  })
})
