/**
 * remitos-venta (D4/D5/D11) — la contabilidad de stock del remito en el
 * cliente, en la capa canónica, como funciones puras.
 *
 * Es el ESPEJO de lo que hace el servidor y nada más: el servidor decide. Sirve
 * para validar el formulario antes de la red y para mostrar, antes de guardar
 * una edición, el ajuste que se va a hacer.
 *
 * Reglas (design.md):
 *  - Lo RETENIDO de un remito sale de sus líneas guardadas
 *    (`Σ quantity_base` por producto, en la sucursal GUARDADA), nunca del
 *    ledger de movimientos (D4).
 *  - Disponible para editar = stock de la sucursal elegida + lo retenido SI la
 *    sucursal elegida es la guardada, y 0 si no (D11, "una sola contabilidad").
 *    Todas las líneas del carrito cuentan contra ese disponible: por eso las
 *    líneas rehidratadas no llevan `source: "persisted"`.
 *  - La edición hace un par espejo SÓLO en los pares producto-sucursal que
 *    cambian (vuelve lo retenido, sale lo nuevo); un producto que no cambia no
 *    recibe movimientos, y una edición de precio, cliente o notas no mueve
 *    stock (D5).
 *
 * La validación y los topes por línea son los de `lib/cart-utils`
 * (`exceedsStock`, `maxQuantityPerLine`, `linesExceedingAvailable`) alimentados
 * con `deliveryNoteAvailableFor`; la presentación de cantidades es
 * `formatQuantity` de `lib/format-unit`.
 */
import type { SaleCartItem } from "@/lib/cart-utils"
import type { DeliveryNoteItemApiRow } from "@/lib/delivery-note-types"
import { formatQuantity } from "@/lib/format-unit"
import { isProductoPorUnidades } from "@/lib/unit-utils"
import type { UnitOfMeasure } from "@/lib/types"

/** NUMERIC(15,4): lo que el servidor guarda; compara sin ruido binario. */
const round4 = (n: number): number => Math.round(n * 10_000) / 10_000

/** `quantity_base` llega como texto (`"5.0000"`) o número según el serializador. */
const toNumber = (value: string | number): number => Number(value)

/**
 * Lo que el remito retiene por producto: `Σ quantity_base` de sus líneas
 * guardadas. Fuente única de lo retenido en el cliente (D4).
 */
export function heldByProduct(items: Pick<DeliveryNoteItemApiRow, "product_id" | "quantity_base">[]): Map<string, number> {
  const held = new Map<string, number>()
  for (const item of items) {
    held.set(item.product_id, round4((held.get(item.product_id) ?? 0) + toNumber(item.quantity_base)))
  }
  return held
}

export interface DeliveryNoteAvailabilityArgs {
  /** Stock del producto en la sucursal ELEGIDA (`useBranchStock`), en su unidad base. */
  branchStockOf: (productId: string) => number
  /** `heldByProduct` de las líneas guardadas; vacío en un alta. */
  held: Map<string, number>
  /** Sucursal del remito guardado; `null` en un alta. */
  savedBranchId: string | null
  /** Sucursal elegida en el formulario; `null` mientras no se eligió. */
  chosenBranchId: string | null
}

/**
 * Disponible por producto para el formulario del remito:
 * `branch_stock(sucursal elegida) + retenido` si la sucursal elegida es la
 * guardada, y sólo el stock si no. Sin sucursal elegida no hay nada disponible
 * (no se pueden agregar líneas).
 */
export function deliveryNoteAvailableFor({
  branchStockOf,
  held,
  savedBranchId,
  chosenBranchId,
}: DeliveryNoteAvailabilityArgs): (productId: string) => number {
  return (productId) => {
    if (!chosenBranchId) return 0
    const retained = savedBranchId !== null && savedBranchId === chosenBranchId ? (held.get(productId) ?? 0) : 0
    return round4(branchStockOf(productId) + retained)
  }
}

// ── Ajuste de stock de una edición ─────────────────────────────────────────────

export interface StockPairAdjustment {
  productId: string
  productName: string
  branchId: string
  /** `return`: vuelve al stock lo retenido. `out`: sale lo nuevo. */
  direction: "return" | "out"
  quantity: number
}

export interface StockAdjustmentArgs {
  savedItems: Pick<DeliveryNoteItemApiRow, "product_id" | "quantity_base" | "name_snapshot">[]
  savedBranchId: string
  nextLines: Pick<SaleCartItem, "productId" | "productName" | "quantity" | "quantityBase">[]
  nextBranchId: string
}

interface PairAccumulator {
  productId: string
  productName: string
  branchId: string
  held: number
  required: number
}

/**
 * Los pares producto-sucursal que cambian y qué se hace en cada uno: primero lo
 * que VUELVE (patas de reversa) y después lo que SALE (patas de aplicación),
 * igual que el servidor (D5, pasos 9-10). Un par con retenido igual al
 * requerido no figura.
 */
export function computeStockAdjustment({
  savedItems,
  savedBranchId,
  nextLines,
  nextBranchId,
}: StockAdjustmentArgs): StockPairAdjustment[] {
  const pairs = new Map<string, PairAccumulator>()
  const pairFor = (productId: string, productName: string, branchId: string): PairAccumulator => {
    const key = `${productId}|${branchId}`
    let pair = pairs.get(key)
    if (!pair) {
      pair = { productId, productName, branchId, held: 0, required: 0 }
      pairs.set(key, pair)
    }
    return pair
  }

  for (const item of savedItems) {
    const pair = pairFor(item.product_id, item.name_snapshot ?? item.product_id, savedBranchId)
    pair.held = round4(pair.held + toNumber(item.quantity_base))
  }
  for (const line of nextLines) {
    const pair = pairFor(line.productId, line.productName, nextBranchId)
    pair.required = round4(pair.required + (line.quantityBase ?? line.quantity))
  }

  const changed = [...pairs.values()].filter((pair) => pair.held !== pair.required)
  const returns = changed
    .filter((pair) => pair.held > 0)
    .map((pair): StockPairAdjustment => ({
      productId: pair.productId,
      productName: pair.productName,
      branchId: pair.branchId,
      direction: "return",
      quantity: pair.held,
    }))
  const outs = changed
    .filter((pair) => pair.required > 0)
    .map((pair): StockPairAdjustment => ({
      productId: pair.productId,
      productName: pair.productName,
      branchId: pair.branchId,
      direction: "out",
      quantity: pair.required,
    }))
  return [...returns, ...outs]
}

// ── Textos ─────────────────────────────────────────────────────────────────────

/**
 * Una cantidad con su producto, en la unidad BASE del producto (en la que se
 * lleva el stock): por unidades "3 × Producto A"; medibles "0.450 kg de Producto B".
 */
export function formatProductQuantity(qty: number, productName: string, baseUnit?: UnitOfMeasure | null): string {
  if (isProductoPorUnidades(baseUnit)) return `${formatQuantity(qty)} × ${productName}`
  return `${formatQuantity(qty, baseUnit?.symbol)} de ${productName}`
}

/** Agrupa por sucursal conservando el orden de aparición. */
function groupByBranch(adjustments: StockPairAdjustment[]): Map<string, StockPairAdjustment[]> {
  const groups = new Map<string, StockPairAdjustment[]>()
  for (const adjustment of adjustments) {
    groups.set(adjustment.branchId, [...(groups.get(adjustment.branchId) ?? []), adjustment])
  }
  return groups
}

/**
 * El resumen del ajuste que se muestra antes de guardar una edición:
 * "Vuelven 2 × A a Centro · Salen 4 × A de Centro". Sin ajuste:
 * "Este cambio no mueve stock".
 */
export function describeStockAdjustment(
  adjustments: StockPairAdjustment[],
  branchName: (branchId: string) => string,
  baseUnitOf: (productId: string) => UnitOfMeasure | undefined,
): string {
  if (adjustments.length === 0) return "Este cambio no mueve stock"

  const clause = (direction: "return" | "out"): string | null => {
    const groups = groupByBranch(adjustments.filter((a) => a.direction === direction))
    if (groups.size === 0) return null
    const text = [...groups.entries()]
      .map(([branchId, items]) => {
        const what = items.map((a) => formatProductQuantity(a.quantity, a.productName, baseUnitOf(a.productId))).join(", ")
        return direction === "return" ? `${what} a ${branchName(branchId)}` : `${what} de ${branchName(branchId)}`
      })
      .join(" y ")
    return `${direction === "return" ? "Vuelven" : "Salen"} ${text}`
  }

  return [clause("return"), clause("out")].filter((part): part is string => part !== null).join(" · ")
}

/** El aviso junto al botón Emitir (D11). */
export function describeEmitNotice(branchName: string): string {
  return `Al emitir, se descuenta del stock de ${branchName}.`
}

/**
 * La confirmación al quitar una línea de un producto dado de baja: lo que
 * vuelve al stock (D5, D11).
 */
export function describeRemovalReturn(
  productName: string,
  quantity: number,
  branchName: string,
  baseUnit?: UnitOfMeasure | null,
): string {
  return `Quitarla devuelve ${formatProductQuantity(quantity, productName, baseUnit)} al stock de ${branchName}.`
}

/**
 * Lo que vuelve a la sucursal al anular el remito: todo lo retenido, junto por
 * producto ("Vuelven a Sucursal Centro: 3 × Producto A, 0.450 kg de Producto B").
 */
export function describeHeldReturn(
  savedItems: Pick<DeliveryNoteItemApiRow, "product_id" | "quantity_base" | "name_snapshot">[],
  branchName: string,
  baseUnitOf: (productId: string) => UnitOfMeasure | undefined,
): string {
  const held = heldByProduct(savedItems)
  const names = new Map<string, string>()
  for (const item of savedItems) {
    if (!names.has(item.product_id)) names.set(item.product_id, item.name_snapshot ?? item.product_id)
  }
  const what = [...held.entries()]
    .map(([productId, quantity]) => formatProductQuantity(quantity, names.get(productId) ?? productId, baseUnitOf(productId)))
    .join(", ")
  return `Vuelven a ${branchName}: ${what}`
}
