/**
 * Parser del importador CSV de ajustes de stock (`lib/stock-import-parser`).
 *
 * Defecto que cubre: la cantidad se leía con `parseFloat`, que ante un decimal
 * con coma (formato es-AR, el que produce Excel al guardar como CSV) truncaba en
 * silencio — `parseFloat("1,5") === 1` — en vez de leer 1.5 o rechazar la fila.
 * El ajuste llegaba al servidor con una cantidad distinta a la cargada.
 *
 * La cantidad pasa por el helper canónico `parseAmount` (`lib/excel`) con
 * `loneCommaIsDecimal`: en una cantidad física la coma sin punto es SIEMPRE
 * decimal ("1,250" = 1,25 kg), nunca separador de miles como en un importe.
 */

import { describe, it, expect } from "vitest"
import { parseAndValidate, parseCSVText, TEMPLATE_CSV } from "@/lib/stock-import-parser"
import type { Product } from "@/lib/types"

function makeProduct(name: string, overrides: Partial<Product> = {}): Product {
  return {
    id: `id-${name.toLowerCase().replace(/\s+/g, "-")}`,
    name,
    category: "Otros",
    cost: 0,
    price: 0,
    margin: 0,
    stock: 0,
    minStock: 0,
    isVariant: false,
    stockControlType: "tracked",
    ...overrides,
  }
}

const PRODUCTS: Product[] = [makeProduct("Harina 000"), makeProduct("Aceite 1L")]

const HEADER = "Nombre;Tipo;Cantidad;Motivo"

function parseRows(csv: string, products: Product[] = PRODUCTS) {
  return parseAndValidate(parseCSVText(csv), products)
}

function parseOne(quantity: string, type = "Ajuste entrada") {
  const [row] = parseRows(`${HEADER}\nHarina 000;${type};${quantity};Reposición`)
  return row
}

describe("parseAndValidate — cantidad con coma decimal (es-AR)", () => {
  it('"1,5" se lee como 1.5 y la fila queda OK', () => {
    const row = parseOne("1,5")
    expect(row.quantity).toBe(1.5)
    expect(row.status).toBe("ok")
    expect(row.errors).toEqual([])
  })

  it('"2,50" (dos decimales) se lee como 2.5', () => {
    const row = parseOne("2,50")
    expect(row.quantity).toBe(2.5)
    expect(row.status).toBe("ok")
  })

  it('"1.234,56" (miles con punto + coma decimal) se lee como 1234.56', () => {
    const row = parseOne("1.234,56")
    expect(row.quantity).toBe(1234.56)
    expect(row.status).toBe("ok")
  })

  it("la coma decimal dentro de comillas sobrevive en un CSV delimitado por coma", () => {
    // Excel en-US / exportadores que citan la celda porque contiene el delimitador.
    const [row] = parseRows('Nombre,Tipo,Cantidad,Motivo\nHarina 000,Ajuste entrada,"1,5",Reposición')
    expect(row.rawQuantity).toBe("1,5")
    expect(row.quantity).toBe(1.5)
    expect(row.status).toBe("ok")
  })

  it("BOM + CRLF (archivo guardado por Excel) no alteran la lectura de la cantidad", () => {
    const [row] = parseRows(`﻿${HEADER}\r\nHarina 000;Ajuste entrada;3,25;Reposición\r\n`)
    expect(row.quantity).toBe(3.25)
    expect(row.status).toBe("ok")
  })
})

describe("parseAndValidate — coma sin punto es SIEMPRE decimal en una cantidad (nunca miles)", () => {
  it.each([
    ["1,250", 1.25],
    ["3,999", 3.999],
    ["0,750", 0.75],
    ["1,2345", 1.2345],
  ])('"%s" → %s (el default de parseAmount lo leería como miles)', (raw, expected) => {
    const row = parseOne(raw)
    expect(row.quantity).toBe(expected)
    expect(row.status).toBe("ok")
  })

  it('"0,750" en un conteo físico se lee como 0.75', () => {
    const row = parseOne("0,750", "Conteo físico")
    expect(row.quantity).toBe(0.75)
    expect(row.status).toBe("ok")
  })

  it('"1,5,2" (dos comas) es inválida, no 152', () => {
    const row = parseOne("1,5,2")
    expect(row.status).toBe("error")
    expect(row.errors).toContain("Cantidad inválida")
    expect(row.quantity).toBe(0)
  })
})

describe("parseAndValidate — CSV separado por coma con coma decimal sin comillas", () => {
  it("la fila con más columnas que el encabezado se rechaza en vez de truncar la cantidad", () => {
    // "1,5" sin comillas se parte en dos celdas: cantidad "1" y motivo "5".
    const [row] = parseRows("Nombre,Tipo,Cantidad,Motivo\nHarina 000,Ajuste entrada,1,5,Reposición")
    expect(row.status).toBe("error")
    expect(row.errors.some((e) => /más columnas/.test(e))).toBe(true)
  })

  it("celdas vacías sobrantes al final (columnas vacías de Excel) no cuentan como desborde", () => {
    const [row] = parseRows(`${HEADER}\nHarina 000;Ajuste entrada;2;Reposición;;`)
    expect(row.status).toBe("ok")
    expect(row.quantity).toBe(2)
  })
})

describe("parseAndValidate — quantityValid distingue cantidad ilegible de cantidad cero", () => {
  it.each([
    ["1,5", true],
    ["0", true],
    ["abc", false],
    ["", false],
  ])('"%s" → quantityValid %s', (raw, valid) => {
    expect(parseOne(raw).quantityValid).toBe(valid)
  })
})

describe("parseAndValidate — cantidades que ya funcionaban siguen igual (regresión)", () => {
  it.each([
    ["10", 10],
    ["1.5", 1.5],
    ["0.25", 0.25],
    ["25", 25],
  ])('"%s" → %d', (raw, expected) => {
    const row = parseOne(raw)
    expect(row.quantity).toBe(expected)
    expect(row.status).toBe("ok")
  })
})

describe("parseAndValidate — cantidades inválidas se rechazan (no se truncan)", () => {
  it.each([["abc"], [""], ["   "]])('"%s" → error "Cantidad inválida" con quantity 0', (raw) => {
    const row = parseOne(raw)
    expect(row.status).toBe("error")
    expect(row.errors).toContain("Cantidad inválida")
    expect(row.quantity).toBe(0)
  })

  it('"-1,5" se lee como -1.5 y se rechaza por negativa (antes parseFloat daba -1)', () => {
    const row = parseOne("-1,5")
    expect(row.quantity).toBe(-1.5)
    expect(row.status).toBe("error")
    expect(row.errors).toContain("La cantidad no puede ser negativa")
  })

  it('"0" se rechaza para un ajuste de entrada', () => {
    const row = parseOne("0", "Ajuste entrada")
    expect(row.status).toBe("error")
    expect(row.errors).toContain("La cantidad debe ser mayor a cero para este tipo de movimiento")
  })

  it('"0" es válido para un conteo físico (stock objetivo cero)', () => {
    const row = parseOne("0", "Conteo físico")
    expect(row.quantity).toBe(0)
    expect(row.uiKey).toBe("physical_count")
    expect(row.status).toBe("ok")
  })

  it('"0,5" para un conteo físico se lee como 0.5 (no como 0)', () => {
    const row = parseOne("0,5", "Conteo físico")
    expect(row.quantity).toBe(0.5)
    expect(row.status).toBe("ok")
  })
})

describe("parseAndValidate — el resto de la fila no cambia con el parser nuevo", () => {
  it("varias filas conservan rowNum, producto resuelto y tipo", () => {
    const rows = parseRows(
      `${HEADER}\nHarina 000;Ajuste entrada;1,5;a\nAceite 1L;Pérdida;2;b\nInexistente;Ajuste salida;3,5;c`,
    )
    expect(rows.map((r) => r.rowNum)).toEqual([2, 3, 4])
    expect(rows.map((r) => r.quantity)).toEqual([1.5, 2, 3.5])
    expect(rows.map((r) => r.uiKey)).toEqual(["adjustment_in", "loss", "adjustment_out"])
    expect(rows[0].product?.name).toBe("Harina 000")
    expect(rows[1].product?.name).toBe("Aceite 1L")
    expect(rows[2].status).toBe("error")
    expect(rows[2].errors).toContain('Producto "Inexistente" no encontrado')
  })
})

describe("TEMPLATE_CSV — la plantilla descargable es el contrato que copia el usuario", () => {
  const templateProducts = [
    "Zapatillas Nike 42",
    "Remera básica XL",
    "Pantalón jean 32",
    "Camiseta polo M",
    "Harina 000",
  ].map((n) => makeProduct(n))

  it("todas sus filas parsean OK (sin errores ni advertencias) contra productos con esos nombres", () => {
    const rows = parseRows(TEMPLATE_CSV, templateProducts)
    expect(rows.length).toBeGreaterThanOrEqual(4)
    expect(rows.map((r) => r.status)).toEqual(rows.map(() => "ok"))
  })

  it("incluye al menos una cantidad con coma decimal, que se lee como fracción", () => {
    const rows = parseRows(TEMPLATE_CSV, templateProducts)
    const decimalRow = rows.find((r) => r.rawQuantity.includes(","))
    expect(decimalRow).toBeDefined()
    expect(Number.isInteger(decimalRow?.quantity)).toBe(false)
  })
})
