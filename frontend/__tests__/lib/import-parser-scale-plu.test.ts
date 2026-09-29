/**
 * balanza-etiquetas-pos (task 10.2) — el parser reconoce el encabezado
 * "Código balanza" y su alias "PLU" (D14, OQ-6), sin afectar la detección de
 * las demás columnas conocidas.
 */

import { describe, it, expect } from "vitest"
import { parseImportText } from "@/lib/import/parser"

describe("parseImportText — Código balanza (balanza-etiquetas-pos D14)", () => {
  it("reconoce el encabezado 'Código balanza'", () => {
    const csv = "Nombre;Código balanza\nTomate;509\n"
    const result = parseImportText(csv)
    expect(result.ok).toBe(true)
    if (!result.ok) return
    expect(result.rows[0].codigo_balanza).toBe("509")
  })

  it("reconoce el alias 'PLU'", () => {
    const csv = "Nombre;PLU\nTomate;509\n"
    const result = parseImportText(csv)
    expect(result.ok).toBe(true)
    if (!result.ok) return
    expect(result.rows[0].codigo_balanza).toBe("509")
  })

  it("sin la columna: codigo_balanza queda vacío, el resto se parsea igual", () => {
    const csv = "Nombre;Precio\nTomate;100\n"
    const result = parseImportText(csv)
    expect(result.ok).toBe(true)
    if (!result.ok) return
    expect(result.rows[0].codigo_balanza).toBe("")
    expect(result.rows[0].precio).toBe("100")
  })
})
