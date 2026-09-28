/**
 * lib/scale-export.ts
 * ─────────────────────────────────────────────────────────────────────────────
 * balanza-etiquetas-pos (D12) — exportación del catálogo al Formato 1 de
 * importación de Systel Suite Neo. Pura: sin fetch, sin cuota, sin
 * `export_logs` (D12: "es un archivo de configuración de un dispositivo, no
 * un reporte").
 */

import { getCanonicalLabel } from "@/lib/product-labels"
import { convertUnitPrice, isBaseUnit, isProductoPorUnidades, resolveUnit } from "@/lib/unit-utils"
import type { Product, ProductCategory, UnitOfMeasure } from "@/lib/types"
import type { ScaleSettings } from "@/lib/scale-layout"

// ─── Tipos ──────────────────────────────────────────────────────────────────

export type ScaleExportSkipReason =
  | "no_price"
  | "parent"
  | "not_sellable_by_scale"
  | "plu_too_long"

export interface ScaleExportSkip {
  productId: string
  productName: string
  reason: ScaleExportSkipReason
}

export interface ScaleExportWarning {
  productId: string
  productName: string
  reason: "duplicate_name" | "sku_too_long"
}

export interface BuildScaleCsvResult {
  csv: string
  included: number
  skipped: ScaleExportSkip[]
  warnings: ScaleExportWarning[]
}

// ─── Constantes del Formato 1 (D12) ────────────────────────────────────────────

const TOTAL_FIELDS = 31 // 9 con datos + 22 vacíos, como la línea "PLU 9 campos" del ejemplo oficial
const MAX_SECTION_LEN = 56
const MAX_NAME_LEN = 56
const MAX_SKU_LEN = 25

// ─── Transliteración (D12) ──────────────────────────────────────────────────

/**
 * NFD + quitar diacríticos (cubre `ñ`→`n` sin caso especial: `ñ` se
 * descompone en `n` + tilde combinante); `;`→`,` (separaría dos campos);
 * controles y saltos de línea → espacio; cualquier resto no-ASCII-imprimible
 * (emoji, comillas tipográficas) se quita. Systel advierte contra `Ñ`/`ñ` y
 * `;` en las descripciones (research/qendra-importar-datos-automatico-rev2.txt
 * págs. 7-8) — así el archivo es idéntico en Windows-1252 y UTF-8.
 */
function toAsciiPrintable(input: string): string {
  return input
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .replace(/;/g, ",")
    .replace(/[\r\n\t\u0000-\u001f]/g, " ")
    .replace(/[^\x20-\x7e]/g, "")
    .trim()
}

function truncate(s: string, maxLen: number): string {
  return s.length > maxLen ? s.slice(0, maxLen) : s
}

/** `1234,56` — 2 decimales, coma decimal, sin separador de miles ni símbolo. */
function formatPriceField(amount: number): string {
  return amount.toFixed(2).replace(".", ",")
}

// ─── API ────────────────────────────────────────────────────────────────────

/**
 * Genera el CSV del Formato 1 de Systel Suite Neo con los productos vivos que
 * tienen código de balanza asignado. Devuelve también qué se omitió (y por
 * qué) y qué se avisó sin omitir, para que la pantalla informe el resumen.
 *
 * Desvío del D12 literal: recibe además `settings` — sin ella no hay forma de
 * saber si un PLU excede el ancho del campo Código del formato habilitado
 * (el propio D12 exige omitir ese caso).
 */
export function buildScaleCsv(
  products: Product[],
  categoriesById: Map<string, ProductCategory>,
  units: UnitOfMeasure[],
  settings: ScaleSettings,
): BuildScaleCsvResult {
  const unitsById = new Map(units.map((u) => [u.id, u]))
  const parentIds = new Set(products.filter((p) => p.parentId).map((p) => p.parentId as string))
  const kgUnit = units.find((u) => u.type === "weight" && isBaseUnit(u))

  const skipped: ScaleExportSkip[] = []
  const warnings: ScaleExportWarning[] = []
  const rows: string[] = []
  const seenNames = new Set<string>()

  const weighedLayout = settings.layouts.find((l) => l.kind === "weighed")
  const unitLayout = settings.layouts.find((l) => l.kind === "unit")

  for (const product of products) {
    if (product.scalePlu == null) continue // sin código de balanza: no es candidato a exportar
    if (product.stockControlType === "variant_only" || parentIds.has(product.id)) {
      skipped.push({ productId: product.id, productName: product.name, reason: "parent" })
      continue
    }
    if (!(product.price > 0)) {
      skipped.push({ productId: product.id, productName: product.name, reason: "no_price" })
      continue
    }

    const baseUnit = resolveUnit(product.baseUnitId, unitsById)
    const isWeighed = baseUnit?.type === "weight"
    const isUnit = isProductoPorUnidades(baseUnit)

    if (!isWeighed && !isUnit) {
      // Medible que no es de peso (volumen, longitud, personalizada): sin
      // modo de venta en la balanza (D7).
      skipped.push({ productId: product.id, productName: product.name, reason: "not_sellable_by_scale" })
      continue
    }

    const relevantLayout = isWeighed ? weighedLayout : unitLayout
    if (relevantLayout?.enabled) {
      const pluSeg = relevantLayout.segments.find((s) => s.field === "plu")
      if (pluSeg && String(product.scalePlu).length > pluSeg.digits) {
        skipped.push({ productId: product.id, productName: product.name, reason: "plu_too_long" })
        continue
      }
    }

    const parent = product.parentId ? products.find((p) => p.id === product.parentId) : undefined
    const rawName = getCanonicalLabel(product, parent)
    const name = truncate(toAsciiPrintable(rawName), MAX_NAME_LEN)

    if (seenNames.has(name)) {
      warnings.push({ productId: product.id, productName: product.name, reason: "duplicate_name" })
    }
    seenNames.add(name)

    const categoryName =
      (product.categoryId ? categoriesById.get(product.categoryId)?.name : undefined) ?? product.category ?? "Otros"
    const section = truncate(toAsciiPrintable(categoryName || "Otros"), MAX_SECTION_LEN)

    // Precio re-expresado POR KG cuando la unidad base es de peso (D12), con
    // la misma función que reexpresa cualquier precio de línea (D-F′): la
    // catalogada es por unidad BASE del producto.
    const pricePerReferenceUnit =
      isWeighed && baseUnit && kgUnit ? convertUnitPrice(product.price, baseUnit, kgUnit, baseUnit) : product.price
    const priceField = formatPriceField(pricePerReferenceUnit)

    let erpCode = ""
    if (product.sku) {
      const asciiSku = toAsciiPrintable(product.sku)
      if (asciiSku.length > MAX_SKU_LEN) {
        warnings.push({ productId: product.id, productName: product.name, reason: "sku_too_long" })
        erpCode = "" // NUNCA se trunca — dos SKU con el mismo prefijo quedarían iguales (D12)
      } else {
        erpCode = asciiSku
      }
    }

    const dataFields = [
      section,
      String(product.scalePlu),
      name,
      erpCode,
      priceField,
      "0,00",
      isWeighed ? "p" : "u",
      "0",
      "",
    ]
    const emptyFields = Array(TOTAL_FIELDS - dataFields.length).fill("")
    rows.push([...dataFields, ...emptyFields].join(";"))
  }

  const included = rows.length
  const csv = rows.length > 0 ? rows.join("\r\n") + "\r\n" : ""

  return { csv, included, skipped, warnings }
}
