/**
 * translateFiscalConfigError — fiscal-emision-segura (G9, 2026-09-22).
 *
 * El caso que importa no es el feliz: es que este mapeo corra ANTES de la
 * heurística de `onCreatePv` en FiscalSettings, que reemplaza el mensaje por
 * "El punto de venta N ya existe" cuando el texto contiene "409". Un CUIT puede
 * contener "409" (20-40912345-6), así que sin esta traducción el usuario podía
 * leer "ya existe" cuando el problema real era otro: ese CUIT tiene el punto de
 * venta activo en OTRA cuenta.
 */
import { describe, it, expect } from "vitest"

import { translateFiscalConfigError } from "@/lib/fiscal-config-errors"

const DETAIL_P0435 =
  "cuit_punto_venta_en_otra_cuenta: Ese CUIT ya tiene el punto de venta 3 " +
  "activo en otra cuenta. Ante ARCA la numeración es por CUIT y punto de venta: " +
  "dos cuentas no pueden compartirlo. Revisá el CUIT cargado en Datos fiscales, " +
  "o usá otro número de punto de venta."

describe("translateFiscalConfigError (G9)", () => {
  it("reconoce el conflicto de CUIT + punto de venta y le quita el token de máquina", () => {
    const out = translateFiscalConfigError(DETAIL_P0435)

    expect(out).not.toBeNull()
    expect(out).not.toContain("cuit_punto_venta_en_otra_cuenta")
    expect(out).toContain("punto de venta 3")
    expect(out).toContain("otra cuenta")
  })

  it("devuelve null para un error que esta pantalla no sabe explicar", () => {
    expect(translateFiscalConfigError("Error 500 del servidor")).toBeNull()
    expect(translateFiscalConfigError("")).toBeNull()
  })

  it("gana a la heurística del '409' que vive en el formulario de puntos de venta", () => {
    // Un CUIT con 409 adentro: el detail reconocido tiene que salir por este
    // camino y NO por el de "ya existe".
    const conCuit409 =
      "cuit_punto_venta_en_otra_cuenta: Ese CUIT (20-40912345-6) ya tiene el " +
      "punto de venta 3 activo en otra cuenta."
    const out = translateFiscalConfigError(conCuit409)

    expect(out).not.toBeNull()
    expect(out).toContain("20-40912345-6")
    expect(out).not.toContain("ya existe")
  })
})
