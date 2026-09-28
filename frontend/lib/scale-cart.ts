/**
 * lib/scale-cart.ts
 * ─────────────────────────────────────────────────────────────────────────────
 * balanza-etiquetas-pos (D7) — resuelve una etiqueta de balanza YA decodificada
 * (`ScaleDecodeResult` con `status: "ok"`) a una línea de carrito.
 *
 * ⚠️  Pura — reutiliza `unitPriceFromSubtotal`, `calcSaleSubtotal`,
 *     `toBaseQuantity`, `convertUnitPrice`, `resolveUnit`, `unitInputStep`/
 *     `unitInputMin`, `isProductoPorUnidades`/`isBaseUnit` (nunca reimplementa
 *     esa matemática ni compara `unit.type` a mano salvo `=== "weight"`, la
 *     única comparación que la Regla de Tres no cubre todavía).
 */

import { calcSaleSubtotal, unitPriceFromSubtotal, type SaleCartItem } from "@/lib/cart-utils"
import {
  convertUnitPrice,
  isBaseUnit,
  isProductoPorUnidades,
  resolveUnit,
  toBaseQuantity,
  unitInputMin,
  unitInputStep,
} from "@/lib/unit-utils"
import { getCanonicalLabel } from "@/lib/product-labels"
import type { Product, UnitOfMeasure } from "@/lib/types"
import type { ScaleDecodeResult } from "@/lib/scale-barcode"

// ─── Tipos ──────────────────────────────────────────────────────────────────

export type ScaleCartLine = Pick<
  SaleCartItem,
  | "productId"
  | "productName"
  | "unitPrice"
  | "quantity"
  | "discount"
  | "subtotal"
  | "unitId"
  | "unitSymbol"
  | "quantityBase"
  | "step"
  | "minQty"
  | "source"
>

export type ScaleLineError =
  | "plu_not_assigned"
  | "product_is_parent"
  | "product_without_price"
  | "sale_mode_mismatch"
  | "quantity_below_precision"

export type ResolveScaleScanResult = { ok: true; line: ScaleCartLine } | { ok: false; error: ScaleLineError; message: string }

export interface ScaleCartContext {
  /** Productos vivos de la cuenta (los que la pantalla ya tiene en memoria). */
  products: Product[]
  units: UnitOfMeasure[]
  unitsById: Map<string, UnitOfMeasure>
}

// ─── Internos ─────────────────────────────────────────────────────────────────

const err = (error: ScaleLineError, message: string): ResolveScaleScanResult => ({ ok: false, error, message })

/** El Kilogramo (o la unidad base de tipo peso, si no se llama así) del catálogo de unidades. */
function findKilogramUnit(units: UnitOfMeasure[]): UnitOfMeasure | undefined {
  return units.find((u) => u.type === "weight" && isBaseUnit(u))
}

/** Redondeo a 3 decimales — la precisión mínima de un peso derivado (D7). */
function round3(n: number): number {
  return Math.round(n * 1000) / 1000
}

function saleModeMismatchMessage(
  scanLayout: "weighed" | "unit",
  productName: string,
  baseUnit: UnitOfMeasure | undefined,
): string {
  const etiquetaDice = scanLayout === "weighed" ? "de venta por peso" : "de venta por unidad"
  const productoSellsByUnit = isProductoPorUnidades(baseUnit)
  const productoSellsByWeight = baseUnit?.type === "weight"
  const productoDice = productoSellsByUnit ? "por unidad" : productoSellsByWeight ? "por peso" : "por otra unidad"
  return `La etiqueta es ${etiquetaDice} pero «${productName}» se vende ${productoDice} en Aliadata. Revisá el modo de venta del PLU en la balanza o la unidad del producto.`
}

// ─── API ────────────────────────────────────────────────────────────────────

/**
 * Convierte una etiqueta de balanza YA decodificada (D5) en la línea de
 * carrito que corresponde (D7). El producto se busca por `scale_plu` entre
 * los productos vivos de la cuenta que la pantalla ya tiene en memoria.
 */
export function resolveScaleScan(
  scan: Extract<ScaleDecodeResult, { status: "ok" }>,
  ctx: ScaleCartContext,
): ResolveScaleScanResult {
  const product = ctx.products.find((p) => p.scalePlu === scan.plu)
  if (!product) {
    return err(
      "plu_not_assigned",
      `El PLU ${scan.plu} no está asignado a ningún producto. Asignalo en Productos → Código de balanza.`,
    )
  }

  if (product.stockControlType === "variant_only") {
    return err(
      "product_is_parent",
      `«${product.name}» es un producto padre con variantes: el código de balanza se asigna a cada variante.`,
    )
  }

  if (!(product.price > 0)) {
    return err("product_without_price", `«${product.name}» no tiene precio cargado.`)
  }

  const baseUnit = resolveUnit(product.baseUnitId, ctx.unitsById)

  if (scan.layout === "weighed") {
    if (baseUnit?.type !== "weight") {
      return err("sale_mode_mismatch", saleModeMismatchMessage("weighed", product.name, baseUnit))
    }
  } else {
    if (!isProductoPorUnidades(baseUnit)) {
      return err("sale_mode_mismatch", saleModeMismatchMessage("unit", product.name, baseUnit))
    }
  }

  const parent = product.parentId ? ctx.products.find((p) => p.id === product.parentId) : undefined
  const productName = getCanonicalLabel(product, parent)
  const unitSymbol = baseUnit?.symbol
  const step = unitInputStep(baseUnit)
  const minQty = unitInputMin(baseUnit)

  const buildLine = (quantity: number, unitPrice: number, subtotal: number): ScaleCartLine => ({
    productId: product.id,
    productName,
    unitPrice,
    quantity,
    discount: 0,
    subtotal,
    unitId: undefined, // siempre en la unidad BASE del producto (D7)
    unitSymbol,
    quantityBase: quantity,
    step,
    minQty,
    source: "scale",
  })

  if (scan.layout === "weighed") {
    if (scan.value.kind === "amount") {
      // Importe embebido (fábrica): el cliente paga lo que dice la etiqueta.
      const kgUnit = findKilogramUnit(ctx.units)
      const pricePerKg = kgUnit
        ? convertUnitPriceToKg(product.price, baseUnit, kgUnit)
        : product.price
      const kg = round3(scan.value.amount / pricePerKg)
      if (kg < 0.001) {
        return err("quantity_below_precision", "La cantidad derivada de la etiqueta es menor a 0,001 kg.")
      }
      const quantityBase = kgUnit ? toBaseQuantity(kg, kgUnit, baseUnit) : kg
      const unitPrice = unitPriceFromSubtotal(scan.value.amount, quantityBase)
      return { ok: true, line: buildLine(quantityBase, unitPrice, scan.value.amount) }
    }
    // Peso embebido: la cantidad es el peso (en kg) expresado en la base;
    // el precio es el del catálogo.
    const kgUnit = findKilogramUnit(ctx.units)
    const quantityBase = kgUnit ? toBaseQuantity(scan.value.amount, kgUnit, baseUnit) : scan.value.amount
    const unitPrice = product.price
    const subtotal = calcSaleSubtotal(unitPrice, quantityBase, 0)
    return { ok: true, line: buildLine(quantityBase, unitPrice, subtotal) }
  }

  // Formato por unidad
  if (scan.value.kind === "quantity") {
    const quantity = scan.value.amount
    const unitPrice = product.price
    const subtotal = calcSaleSubtotal(unitPrice, quantity, 0)
    return { ok: true, line: buildLine(quantity, unitPrice, subtotal) }
  }
  // Importe embebido: se cobra exacto con una cantidad de al menos 1.
  const quantity = Math.max(1, Math.round(scan.value.amount / product.price))
  const unitPrice = unitPriceFromSubtotal(scan.value.amount, quantity)
  return { ok: true, line: buildLine(quantity, unitPrice, scan.value.amount) }
}

/**
 * Reexpresa un precio de catálogo (por unidad base del producto) a precio
 * por kilogramo — envoltorio de `convertUnitPrice` con el orden de
 * argumentos que este módulo necesita (fromUnit = la base del producto,
 * toUnit = Kilogramo).
 */
function convertUnitPriceToKg(price: number, productBaseUnit: UnitOfMeasure | undefined, kgUnit: UnitOfMeasure): number {
  if (!productBaseUnit) return price
  return convertUnitPrice(price, productBaseUnit, kgUnit, productBaseUnit)
}
