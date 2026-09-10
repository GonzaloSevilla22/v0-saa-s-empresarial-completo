/**
 * resolveHierarchy — Producto Padre por nombre (Strategy 2), resolución
 * case-insensitive DENTRO del mismo archivo.
 *
 * Corrección de finding (revisión importador-productos-fastapi, ronda 1):
 * el resolver viejo (C-21) construía `batchParentByName` con clave
 * `name.trim().toLowerCase()`, así que una Variante cuyo `nameParent`
 * difería sólo en mayúsculas/minúsculas de una fila Padre DEL MISMO ARCHIVO
 * resolvía igual. La reescritura de este change (D9: retirar las consultas
 * a la base) dejó de resolver TAMBIÉN el caso in-batch — `resolvedParentName`
 * pasó a viajar `row.nameParent` verbatim, y el servidor hace un lookup
 * EXACTO (`WHERE name = v_row->>'parent_name'`, sin `lower()`). Con el
 * todo-o-nada (D3), un solo tipeo de capitalización pasó a rechazar el
 * archivo ENTERO en vez de resolver como antes.
 *
 * Este archivo fija el contrato: el resolver sigue resolviendo por nombre
 * DENTRO DEL LOTE (es una operación pura, no un round-trip a Supabase —
 * D9 sólo pedía retirar la consulta a la base, no la resolución in-batch).
 */

import { describe, it, expect } from "vitest"
import { resolveHierarchy } from "@/lib/import/resolver"
import type { ValidatedImportRow } from "@/lib/import/types"

function makeRow(
  overrides: Partial<ValidatedImportRow> &
    Pick<ValidatedImportRow, "lineNumber" | "rowType" | "name">,
): ValidatedImportRow {
  return {
    sku: null,
    skuParent: null,
    nameParent: null,
    price: 0,
    cost: null,
    category: "",
    categoryIsNew: false,
    stock: 0,
    minStock: 0,
    barcode: null,
    attributes: [],
    warnings: [],
    errors: [],
    ...overrides,
  }
}

describe("resolveHierarchy — Producto Padre por nombre (Strategy 2)", () => {
  it("resuelve un nameParent que difiere sólo en mayúsculas/minúsculas de un Padre del MISMO archivo", () => {
    const rows: ValidatedImportRow[] = [
      makeRow({ lineNumber: 1, rowType: "Padre", name: "Remera Basica" }),
      makeRow({
        lineNumber: 2,
        rowType: "Variante",
        name: "Remera Basica - Talle M",
        nameParent: "remera basica",
      }),
    ]

    const { rows: resolved, orphanCount } = resolveHierarchy(rows)
    const variant = resolved.find((r) => r.lineNumber === 2)!

    expect(orphanCount).toBe(0)
    expect(variant.isVariant).toBe(true)
    expect(variant.resolvedParentName).toBe("Remera Basica")
    expect(variant.warnings).toEqual([])
  })

  it("cuando el Padre del archivo tiene SKU, emite skuParent (canónico) en vez de resolvedParentName", () => {
    const rows: ValidatedImportRow[] = [
      makeRow({ lineNumber: 1, rowType: "Padre", name: "Buzo Basico", sku: "BUZO-001" }),
      makeRow({
        lineNumber: 2,
        rowType: "Variante",
        name: "Buzo Basico - Talle L",
        nameParent: "BUZO BASICO",
      }),
    ]

    const { rows: resolved } = resolveHierarchy(rows)
    const variant = resolved.find((r) => r.lineNumber === 2)!

    expect(variant.skuParent).toBe("BUZO-001")
    expect(variant.resolvedParentName).toBeNull()
  })

  it("sin match en el archivo, sigue mandando la referencia TAL CUAL (el servidor la resuelve contra la cuenta)", () => {
    const rows: ValidatedImportRow[] = [
      makeRow({
        lineNumber: 1,
        rowType: "Variante",
        name: "Gorra - Talle Único",
        nameParent: "Gorra Deportiva",
      }),
    ]

    const { rows: resolved } = resolveHierarchy(rows)
    const variant = resolved[0]

    expect(variant.resolvedParentName).toBe("Gorra Deportiva")
    expect(variant.skuParent).toBeNull()
  })
})
