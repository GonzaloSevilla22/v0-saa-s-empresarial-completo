/**
 * Parser puro del importador CSV de ajustes de stock.
 *
 * Extraído de `components/stock/stock-import-adjustment-dialog.tsx` para poder
 * testearlo sin montar el diálogo — mismo patrón que `lib/import/validator.ts`
 * (productos) y `lib/bank-statement-parser.ts` (extractos). Sin React ni DOM.
 *
 * La cantidad se lee con `parseAmount` (`lib/excel`), el helper canónico que ya
 * usan los importadores de productos y gastos, con `loneCommaIsDecimal`: en una
 * cantidad física la coma sin punto es SIEMPRE decimal ("1,250" = 1,25 kg),
 * nunca separador de miles como en un importe. Antes se usaba `parseFloat`,
 * que ante "1,5" devolvía 1 en silencio.
 *
 * El divisor de CSV propio (`parseCSVText`) se conserva a propósito: las
 * cabeceras admiten alias por columna ("nombre"/"producto"/"name", …), que el
 * `columnMap` de `excel.parseCSV` no modela.
 */

import { parseQuantity, looksLikeThousandsGrouping as looksLikeThousandsGroupingBase } from "@/lib/excel"
import type { Product, MovementType } from "@/lib/types"

// ── CSV template ───────────────────────────────────────────────────────────────

/** Plantilla descargable — separada por `;` para que la coma decimal sea segura. */
export const TEMPLATE_CSV = [
  "Nombre;Tipo;Cantidad;Motivo",
  "Zapatillas Nike 42;Conteo físico;25;Inventario mensual",
  "Remera básica XL;Ajuste entrada;10;Reposición de proveedor",
  "Pantalón jean 32;Pérdida;3;Robo registrado",
  "Camiseta polo M;Ajuste salida;5;Devolución a depósito",
  "Harina 000;Ajuste salida;2,5;Merma de fraccionado",
].join("\n")

// ── Type aliases (Spanish → internal uiKey) ────────────────────────────────────

export const TYPE_ALIASES: Record<string, string> = {
  // adjustment_in
  "ajuste entrada":    "adjustment_in",
  "ajuste de entrada": "adjustment_in",
  "entrada":           "adjustment_in",
  "ingreso":           "adjustment_in",
  // adjustment_out
  "ajuste salida":     "adjustment_out",
  "ajuste de salida":  "adjustment_out",
  "salida":            "adjustment_out",
  "egreso":            "adjustment_out",
  // physical_count
  "conteo fisico":     "physical_count",
  "conteo físico":     "physical_count",
  "conteo":            "physical_count",
  "inventario":        "physical_count",
  // loss
  "perdida":           "loss",
  "pérdida":           "loss",
  "robo":              "loss",
  "extravío":          "loss",
  "extravio":          "loss",
  // damage
  "daño":              "damage",
  "dano":              "damage",
  "merma":             "damage",
  "deterioro":         "damage",
  // expiry
  "vencimiento":       "expiry",
  "vencido":           "expiry",
  // transfer_in
  "transferencia entrada": "transfer_in",
  "transfer entrada":      "transfer_in",
  "recepcion":             "transfer_in",
  "recepción":             "transfer_in",
  // transfer_out
  "transferencia salida":  "transfer_out",
  "transfer salida":       "transfer_out",
  "envio":                 "transfer_out",
  "envío":                 "transfer_out",
}

export const UI_KEY_TO_DB: Record<string, { type: MovementType; sign: 1 | -1 | 0 }> = {
  adjustment_in:  { type: "adjustment",    sign:  1 },
  adjustment_out: { type: "adjustment",    sign: -1 },
  physical_count: { type: "physical_count", sign:  0 },
  loss:           { type: "loss",           sign: -1 },
  damage:         { type: "damage",         sign: -1 },
  expiry:         { type: "expiry",         sign: -1 },
  transfer_in:    { type: "transfer_in",    sign:  1 },
  transfer_out:   { type: "transfer_out",   sign: -1 },
}

// Friendly label for display
export const UI_KEY_LABEL: Record<string, string> = {
  adjustment_in:  "Ajuste entrada",
  adjustment_out: "Ajuste salida",
  physical_count: "Conteo físico",
  loss:           "Pérdida / Robo",
  damage:         "Daño / Merma",
  expiry:         "Vencimiento",
  transfer_in:    "Transferencia ent.",
  transfer_out:   "Transferencia sal.",
}

export function resolveType(raw: string): string | null {
  const key = raw.trim().toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "")
  // Try normalised version too
  for (const [alias, uiKey] of Object.entries(TYPE_ALIASES)) {
    const normAlias = alias.normalize("NFD").replace(/[̀-ͯ]/g, "")
    if (key === normAlias) return uiKey
  }
  // Direct match against uiKey (e.g. "adjustment_in")
  if (key in UI_KEY_TO_DB) return key
  return null
}

// ── CSV parser ─────────────────────────────────────────────────────────────────

export function parseCSVText(text: string): string[][] {
  const clean = text.replace(/^﻿/, "").replace(/\r\n/g, "\n").replace(/\r/g, "\n")
  const lines = clean.split("\n").filter((l) => l.trim() !== "")
  if (lines.length === 0) return []

  // Auto-detect delimiter: count `;` vs `,` in header row
  const header  = lines[0]
  const delim   = (header.split(";").length - 1) >= (header.split(",").length - 1) ? ";" : ","

  return lines.map((line) => {
    const cells: string[] = []
    let current  = ""
    let inQuotes = false
    for (const ch of line) {
      if      (ch === '"')    { inQuotes = !inQuotes }
      else if (ch === delim && !inQuotes) { cells.push(current.trim()); current = "" }
      else    { current += ch }
    }
    cells.push(current.trim())
    return cells.map((c) => c.replace(/^"|"$/g, "").trim())
  })
}

/**
 * ¿El texto de la cantidad podría leerse también como miles ("1,250", "1.250",
 * "12.345.678")? Sólo en ese caso la vista previa muestra el texto del CSV al
 * lado de la cantidad interpretada: grupos de tres dígitos separados por un
 * único tipo de separador. "2,50", "1,2345" o "1000" no tienen lectura
 * alternativa y mostrarlos sería ruido.
 */
export function looksLikeThousandsGrouping(raw: string): boolean {
  return looksLikeThousandsGroupingBase(raw)
}

// ── Row types ──────────────────────────────────────────────────────────────────

export type RowStatus = "ok" | "warning" | "error"

export interface ParsedImportRow {
  /** Original CSV row index (1-based, after header) */
  rowNum:      number
  /** Raw CSV values */
  rawName:     string
  rawType:     string
  rawQuantity: string
  rawMotivo:   string
  /** Resolution results */
  product:     Product | null
  resolvedName: string | null   // actual product name found (if different from rawName)
  uiKey:       string           // resolved movement uiKey
  quantity:    number           // parsed quantity (0 de relleno si no es legible)
  quantityValid: boolean        // false = el texto de la celda no es un número
  // Validation
  status:      RowStatus
  errors:      string[]         // blocking errors
  warnings:    string[]         // non-blocking warnings
  // Applied result (step 3)
  applied?:    boolean
  applyError?: string
}

// ── Product resolution by name ─────────────────────────────────────────────────

export function resolveProductByName(
  name: string,
  candidates: Product[],
): { product: Product | null; resolvedName: string | null; status: "exact" | "partial" | "ambiguous" | "not_found" } {
  const q = name.trim().toLowerCase()
  if (!q) return { product: null, resolvedName: null, status: "not_found" }

  // Exact match (case-insensitive)
  const exact = candidates.filter((p) => p.name.toLowerCase() === q)
  if (exact.length === 1) return { product: exact[0], resolvedName: exact[0].name, status: "exact" }
  if (exact.length > 1)   return { product: null, resolvedName: null, status: "ambiguous" }

  // Partial match: product name contains query OR query contains product name
  const partial = candidates.filter(
    (p) => p.name.toLowerCase().includes(q) || q.includes(p.name.toLowerCase()),
  )
  if (partial.length === 1) return { product: partial[0], resolvedName: partial[0].name, status: "partial" }
  if (partial.length > 1)   return { product: null, resolvedName: null, status: "ambiguous" }

  return { product: null, resolvedName: null, status: "not_found" }
}

// ── Parse & validate CSV rows ──────────────────────────────────────────────────

export function parseAndValidate(cells: string[][], adjustableProducts: Product[]): ParsedImportRow[] {
  if (cells.length < 2) return []

  // Normalize header keys
  const header  = cells[0].map((h) => h.toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, ""))
  const colIdx  = {
    name:     header.findIndex((h) => h === "nombre" || h === "producto" || h === "name"),
    type:     header.findIndex((h) => h === "tipo"   || h === "type"     || h === "movimiento"),
    quantity: header.findIndex((h) => h === "cantidad" || h === "qty"    || h === "quantity"),
    motivo:   header.findIndex((h) => h === "motivo" || h === "razon"    || h === "razon" || h === "reason" || h === "nota"),
  }

  if (colIdx.name < 0 || colIdx.quantity < 0) return []

  // Columnas reales del encabezado: hasta la última celda con nombre. Las
  // vacías del final (columnas sobrantes que deja Excel) no cuentan — si
  // contaran, una celda partida por una coma sin comillas encontraría lugar
  // en ellas y pasaría desapercibida. Queda fuera, a sabiendas, el caso de una
  // columna extra CON nombre que absorba la celda partida.
  const headerLen = cells[0].reduce((last, h, idx) => (h !== "" ? idx + 1 : last), 0)

  return cells.slice(1).map((row, i) => {
    const rawName     = row[colIdx.name]     ?? ""
    const rawType     = colIdx.type >= 0 ? (row[colIdx.type] ?? "") : ""
    const rawQuantity = row[colIdx.quantity] ?? ""
    const rawMotivo   = colIdx.motivo >= 0  ? (row[colIdx.motivo] ?? "") : ""

    const errors:   string[] = []
    const warnings: string[] = []

    // Resolve product
    const resolution   = resolveProductByName(rawName, adjustableProducts)
    const product      = resolution.product
    const resolvedName = resolution.resolvedName

    if      (resolution.status === "not_found")  errors.push(`Producto "${rawName}" no encontrado`)
    else if (resolution.status === "ambiguous")   errors.push(`El nombre "${rawName}" coincide con múltiples productos — usá el nombre exacto`)
    else if (resolution.status === "partial")     warnings.push(`Coincidencia parcial → asignado a "${resolvedName}"`)

    // Resolve type (default: adjustment_in)
    const uiKey = rawType.trim() === "" ? "adjustment_in" : (resolveType(rawType) ?? "")
    if (rawType.trim() !== "" && !uiKey) {
      errors.push(`Tipo "${rawType}" no reconocido`)
    }
    if (rawType.trim() === "") {
      warnings.push('Tipo no especificado — se usará "Ajuste entrada" por defecto')
    }

    // Desborde de columnas: "1,5" sin comillas en un CSV separado por coma se
    // parte en dos celdas y la cantidad llegaría truncada a 1 (el mismo defecto
    // que este parser corrige, por otro camino); una coma suelta en el motivo
    // desplaza igual. Las celdas vacías sobrantes al final no cuentan.
    if (row.slice(headerLen).some((c) => c !== "")) {
      errors.push(
        `La fila tiene más columnas (${row.length}) que el encabezado (${headerLen}): una coma sin comillas dentro de una celda (cantidad decimal o motivo) la parte en dos — guardá el CSV separado por punto y coma (;) o entrecomillá esa celda`,
      )
    }

    // Resolve quantity — helper canónico compartido con el importador de
    // productos (`lib/import/validator.ts`): "1,5" → 1.5, "1.234,56" →
    // 1234.56, "1.5" → 1.5, coma sin punto SIEMPRE decimal ("1,250" = 1,25
    // kg, nunca miles). `allowNegative`: acá la fila arma su propio error
    // "no puede ser negativa" en vez de reemplazar el valor por 0 en
    // silencio (el negativo real se ve en la vista previa). `silent`: este
    // parser ya tiene su propio canal de errores/warnings por fila — la
    // ambigüedad de miles se muestra aparte en la UI (`looksLikeThousandsGrouping`).
    // Sin `maxDecimals` a propósito: la cantidad de un ajuste no se redondea
    // acá en el cliente — Postgres redondea al guardar (branch_stock.quantity
    // es numeric(15,4)) y la vista previa ya muestra 4 decimales con
    // `formatNumber(q, 4)`, así que redondear antes sería trabajo redundante
    // (y potencialmente inconsistente si el redondeo del cliente difiriera
    // del de la columna).
    const parsedQuantity = parseQuantity(rawQuantity, { label: "Cantidad", allowNegative: true, silent: true })
    const quantity        = parsedQuantity.value ?? 0
    const quantityValid   = rawQuantity.trim() !== "" && !parsedQuantity.invalid
    if (!quantityValid) {
      errors.push("Cantidad inválida")
    } else if (quantity < 0) {
      errors.push("La cantidad no puede ser negativa")
    } else if (uiKey !== "physical_count" && quantity === 0) {
      errors.push("La cantidad debe ser mayor a cero para este tipo de movimiento")
    }

    const status: RowStatus = errors.length > 0 ? "error" : warnings.length > 0 ? "warning" : "ok"

    return {
      rowNum:      i + 2,
      rawName, rawType, rawQuantity, rawMotivo,
      product, resolvedName,
      uiKey:    uiKey || "adjustment_in",
      quantity: quantityValid ? quantity : 0,
      quantityValid,
      status, errors, warnings,
    }
  })
}
