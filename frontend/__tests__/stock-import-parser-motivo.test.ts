/**
 * stock-ledger-solo-rpc (tanda B, task 11.4) — el importador CSV de ajustes exige
 * el MOTIVO y ya no acepta transferencias como ajuste.
 *
 * Contrato (spec branch-stock «La superficie de ajuste manual…» + OQ-1):
 *   - la columna «Motivo» es OBLIGATORIA: encabezado ausente = error de archivo
 *     (`hasMotivoColumn` es false y, si igual se parsea, cada fila queda
 *     bloqueada); celda vacía o en blanco = error bloqueante «Falta el motivo»
 *     de esa fila, que no se aplica;
 *   - los alias de transferencia («Transferencia entrada», «recepción», «envío»…)
 *     se RECONOCEN —para dar un mensaje preciso en vez de «Tipo no reconocido»—
 *     pero dan un error bloqueante que deriva a «Transferir stock»; nunca llegan
 *     a la tabla de tipos que viajan al servidor (`UI_KEY_TO_DB`).
 */

import { describe, it, expect } from "vitest"
import {
  parseAndValidate, parseCSVText, hasMotivoColumn, TEMPLATE_CSV, UI_KEY_TO_DB, ADJUSTMENT_TYPE_LABELS,
} from "@/lib/stock-import-parser"
import type { Product } from "@/lib/types"

function makeProduct(name: string): Product {
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
  }
}

const PRODUCTS = [makeProduct("Harina 000"), makeProduct("Aceite 1L")]
const HEADER = "Nombre;Tipo;Cantidad;Motivo"

const parseRows = (csv: string) => parseAndValidate(parseCSVText(csv), PRODUCTS)

describe("parseAndValidate — el motivo es obligatorio por fila", () => {
  it("una celda de motivo vacía deja la fila en error con «Falta el motivo»", () => {
    const [row] = parseRows(`${HEADER}\nHarina 000;Ajuste entrada;10;`)
    expect(row.status).toBe("error")
    expect(row.errors).toContain("Falta el motivo")
  })

  it("un motivo sólo con espacios también falta", () => {
    const [row] = parseRows(`${HEADER}\nHarina 000;Ajuste entrada;10;   `)
    expect(row.status).toBe("error")
    expect(row.errors).toContain("Falta el motivo")
  })

  it("con motivo la fila queda OK y no menciona el motivo", () => {
    const [row] = parseRows(`${HEADER}\nHarina 000;Ajuste entrada;10;Reposición`)
    expect(row.status).toBe("ok")
    expect(row.errors.join(" ")).not.toMatch(/motivo/i)
  })

  it("triangulación: sólo la fila sin motivo se bloquea; la de al lado sigue válida", () => {
    const rows = parseRows(`${HEADER}\nHarina 000;Ajuste entrada;10;Reposición\nAceite 1L;Pérdida;2;`)
    expect(rows.map((r) => r.status)).toEqual(["ok", "error"])
    expect(rows[1].errors).toContain("Falta el motivo")
  })

  it("el conteo físico también exige motivo", () => {
    const [row] = parseRows(`${HEADER}\nHarina 000;Conteo físico;25;`)
    expect(row.errors).toContain("Falta el motivo")
  })
})

describe("hasMotivoColumn / encabezado sin «Motivo»", () => {
  it("el encabezado de la plantilla tiene la columna", () => {
    expect(hasMotivoColumn(parseCSVText(TEMPLATE_CSV))).toBe(true)
  })

  it("sin columna Motivo es false (error de archivo en el diálogo)", () => {
    expect(hasMotivoColumn(parseCSVText("Nombre;Tipo;Cantidad\nHarina 000;Ajuste entrada;10"))).toBe(false)
  })

  it("acepta los alias del encabezado (razón, reason, nota) y los acentos", () => {
    for (const h of ["Razón", "razon", "Reason", "Nota", "MOTIVO"]) {
      expect(hasMotivoColumn(parseCSVText(`Nombre;Cantidad;${h}\nHarina 000;1;x`)), h).toBe(true)
    }
  })

  it("si igual se parsea un archivo sin la columna, TODAS las filas quedan bloqueadas", () => {
    const rows = parseRows("Nombre;Tipo;Cantidad\nHarina 000;Ajuste entrada;10\nAceite 1L;Ajuste entrada;3")
    expect(rows).toHaveLength(2)
    for (const row of rows) {
      expect(row.status).toBe("error")
      expect(row.errors.join(" ")).toMatch(/falta el motivo/i)
    }
  })
})

describe("parseAndValidate — las transferencias no son ajustes (OQ-1)", () => {
  it.each(["Transferencia entrada", "Transferencia salida", "recepción", "envío", "transfer entrada"])(
    "«%s» se reconoce y se bloquea derivando a «Transferir stock»",
    (alias) => {
      const [row] = parseRows(`${HEADER}\nHarina 000;${alias};4;Movimiento de depósito`)
      expect(row.status).toBe("error")
      const msg = row.errors.join(" ")
      expect(msg).toMatch(/transferir stock/i)
      expect(msg).not.toMatch(/no reconocido/i)
    },
  )

  it("un tipo realmente desconocido sigue diciendo «no reconocido» (no se confunde con una transferencia)", () => {
    const [row] = parseRows(`${HEADER}\nHarina 000;Mudanza;4;x`)
    expect(row.errors.join(" ")).toMatch(/no reconocido/i)
    expect(row.errors.join(" ")).not.toMatch(/transferir stock/i)
  })

  it("los tipos de ajuste de verdad siguen sin error de tipo", () => {
    for (const t of ["Ajuste entrada", "Ajuste salida", "Conteo físico", "Pérdida", "Daño", "Vencimiento"]) {
      const [row] = parseRows(`${HEADER}\nHarina 000;${t};4;x`)
      expect(row.errors.filter((e) => /tipo|transferir/i.test(e)), t).toEqual([])
    }
  })

  it("transfer_in y transfer_out no existen en la tabla de tipos que viajan al servidor", () => {
    expect(Object.keys(UI_KEY_TO_DB)).not.toContain("transfer_in")
    expect(Object.keys(UI_KEY_TO_DB)).not.toContain("transfer_out")
    expect(Object.values(UI_KEY_TO_DB).map((v) => v.type)).not.toContain("transfer_in")
    expect(Object.values(UI_KEY_TO_DB).map((v) => v.type)).not.toContain("transfer_out")
  })

  it("la lista de tipos que ofrece el diálogo no incluye transferencias", () => {
    expect(ADJUSTMENT_TYPE_LABELS.length).toBeGreaterThanOrEqual(6)
    for (const label of ADJUSTMENT_TYPE_LABELS) expect(label).not.toMatch(/transfer/i)
  })

  it("la plantilla descargable no ofrece transferencias y su columna Motivo está completa", () => {
    expect(TEMPLATE_CSV).not.toMatch(/transfer/i)
    for (const line of TEMPLATE_CSV.split("\n").slice(1)) {
      expect(line.split(";")[3]?.trim(), line).toBeTruthy()
    }
  })
})
