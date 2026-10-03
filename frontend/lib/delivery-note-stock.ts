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
 * Remito de COMPRA (remitos-compra, D4/D5/D11): el efecto del remito sobre el
 * stock es el inverso. Recibir SUMA lo aportado; editar es el mismo par espejo
 * (sale lo aportado, entra lo nuevo) sólo en los pares que cambian, con las patas
 * que SUMAN primero; anular RESTA. Como restar puede dejar la sucursal sin lo que
 * ya se consumió, la edición tiene un MÍNIMO por producto
 * (`max(0, aportado − stock vigente de la sucursal)`: la misma cuenta que el
 * chequeo del neto del servidor) y mover la recepción a otra sucursal exige que la
 * vieja siga teniendo todo lo aportado. Los textos no atribuyen origen a la
 * diferencia: el stock de la sucursal mezcla otras entradas.
 *
 * La validación y los topes por línea son los de `lib/cart-utils`
 * (`exceedsStock`, `maxQuantityPerLine`, `linesExceedingAvailable`) alimentados
 * con `deliveryNoteAvailableFor`; la presentación de cantidades es
 * `formatQuantity` de `lib/format-unit`.
 */
import type { SaleCartItem } from "@/lib/cart-utils"
import type { DeliveryNoteDirection, DeliveryNoteItemApiRow } from "@/lib/delivery-note-types"
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
  /**
   * La pata del par espejo. `return`: se DESHACE el efecto vigente del remito
   * (en venta vuelve al stock lo retenido; en compra sale lo aportado). `out`: se
   * APLICA el efecto nuevo (en venta sale lo nuevo; en compra entra lo nuevo).
   */
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
 * El resumen del ajuste que se muestra antes de guardar una edición. Venta:
 * "Vuelven 2 × A a Centro · Salen 4 × A de Centro". Compra: "Entran 4 × A a
 * Centro · Salen 2 × A de Centro" (las patas que SUMAN primero, como el
 * servidor). Sin ajuste: "Este cambio no mueve stock".
 */
export function describeStockAdjustment(
  adjustments: StockPairAdjustment[],
  branchName: (branchId: string) => string,
  baseUnitOf: (productId: string) => UnitOfMeasure | undefined,
  direction: DeliveryNoteDirection = "sale",
): string {
  if (adjustments.length === 0) return "Este cambio no mueve stock"

  const clause = (leg: "return" | "out"): string | null => {
    const groups = groupByBranch(adjustments.filter((a) => a.direction === leg))
    if (groups.size === 0) return null
    // Qué le pasa al stock de la sucursal en esta pata, según el sentido.
    const adds = direction === "sale" ? leg === "return" : leg === "out"
    const text = [...groups.entries()]
      .map(([branchId, items]) => {
        const what = items.map((a) => formatProductQuantity(a.quantity, a.productName, baseUnitOf(a.productId))).join(", ")
        return adds ? `${what} a ${branchName(branchId)}` : `${what} de ${branchName(branchId)}`
      })
      .join(" y ")
    const verb = direction === "sale" ? (leg === "return" ? "Vuelven" : "Salen") : leg === "out" ? "Entran" : "Salen"
    return `${verb} ${text}`
  }

  const legs: Array<"return" | "out"> = direction === "sale" ? ["return", "out"] : ["out", "return"]
  return legs
    .map(clause)
    .filter((part): part is string => part !== null)
    .join(" · ")
}

/** El aviso junto al botón Emitir (D11): en venta se descuenta, en compra se suma. */
export function describeEmitNotice(branchName: string, direction: DeliveryNoteDirection = "sale"): string {
  return direction === "purchase"
    ? `Al emitir, se suma al stock de ${branchName}.`
    : `Al emitir, se descuenta del stock de ${branchName}.`
}

/**
 * La confirmación al quitar una línea de un producto dado de baja: lo que
 * vuelve al stock en venta, lo que SALE del stock en compra (D5, D11).
 */
export function describeRemovalReturn(
  productName: string,
  quantity: number,
  branchName: string,
  baseUnit?: UnitOfMeasure | null,
  direction: DeliveryNoteDirection = "sale",
): string {
  const what = formatProductQuantity(quantity, productName, baseUnit)
  return direction === "purchase"
    ? `Quitarla resta ${what} del stock de ${branchName}.`
    : `Quitarla devuelve ${what} al stock de ${branchName}.`
}

/**
 * Lo que mueve la anulación del remito: todo lo retenido, junto por producto.
 * Venta: "Vuelven a Sucursal Centro: 3 × Producto A, 0.450 kg de Producto B".
 * Compra: "Salen de Sucursal Centro: 10 × Producto A".
 */
export function describeHeldReturn(
  savedItems: Pick<DeliveryNoteItemApiRow, "product_id" | "quantity_base" | "name_snapshot">[],
  branchName: string,
  baseUnitOf: (productId: string) => UnitOfMeasure | undefined,
  direction: DeliveryNoteDirection = "sale",
): string {
  const held = heldByProduct(savedItems)
  const names = new Map<string, string>()
  for (const item of savedItems) {
    if (!names.has(item.product_id)) names.set(item.product_id, item.name_snapshot ?? item.product_id)
  }
  const what = [...held.entries()]
    .map(([productId, quantity]) => formatProductQuantity(quantity, names.get(productId) ?? productId, baseUnitOf(productId)))
    .join(", ")
  return direction === "purchase" ? `Salen de ${branchName}: ${what}` : `Vuelven a ${branchName}: ${what}`
}

// ── Remito de compra: mínimo por producto y mover la recepción ──────────────────

/** Una cantidad en la unidad base del producto, sin repetir el nombre ("3", "0.450 kg"). */
function formatBaseQuantity(qty: number, baseUnit?: UnitOfMeasure | null): string {
  return isProductoPorUnidades(baseUnit) ? formatQuantity(qty) : formatQuantity(qty, baseUnit?.symbol)
}

export interface PurchaseEditFloorArgs {
  savedItems: Pick<DeliveryNoteItemApiRow, "product_id" | "quantity_base" | "name_snapshot">[]
  /** Stock vigente del producto en la sucursal GUARDADA (la que recibió la mercadería), en su unidad base. */
  savedBranchStockOf: (productId: string) => number
}

/**
 * El MÍNIMO por producto al editar un remito de compra: `max(0, aportado − stock
 * vigente de la sucursal)`, donde lo aportado sale de las líneas guardadas
 * (`Σ quantity_base`, nunca del ledger). Es la misma contabilidad que el chequeo
 * del neto del servidor: bajar una cantidad resta la diferencia del stock, y eso
 * sólo se puede si la sucursal todavía la tiene. Sólo figuran los productos con
 * mínimo mayor que 0.
 */
export function purchaseMinimumByProduct({ savedItems, savedBranchStockOf }: PurchaseEditFloorArgs): Map<string, number> {
  const minimums = new Map<string, number>()
  for (const [productId, held] of heldByProduct(savedItems)) {
    const minimum = round4(Math.max(0, held - savedBranchStockOf(productId)))
    if (minimum > 0) minimums.set(productId, minimum)
  }
  return minimums
}

/**
 * El aviso del mínimo de una línea: "En Centro quedan 3: este remito no puede
 * bajar de 7". No atribuye origen a la diferencia (el stock mezcla otras
 * entradas), sólo dice cuánto queda y hasta dónde se puede bajar.
 */
export function describePurchaseMinimum(
  minimum: number,
  remaining: number,
  branchName: string,
  baseUnit?: UnitOfMeasure | null,
): string {
  return `En ${branchName} quedan ${formatBaseQuantity(remaining, baseUnit)}: este remito no puede bajar de ${formatBaseQuantity(minimum, baseUnit)}`
}

export interface PurchaseBranchMoveBlocker {
  productId: string
  productName: string
  /** Lo que aportó el remito (unidad base). */
  held: number
  /** Lo que queda en la sucursal guardada (unidad base). */
  remaining: number
}

/**
 * Los productos que impiden mover la recepción a otra sucursal: mover suma en la
 * nueva y resta en la vieja, así que la vieja tiene que tener TODO lo aportado.
 */
export function purchaseBranchMoveBlockers({
  savedItems,
  savedBranchStockOf,
}: PurchaseEditFloorArgs): PurchaseBranchMoveBlocker[] {
  const names = new Map<string, string>()
  for (const item of savedItems) {
    if (!names.has(item.product_id)) names.set(item.product_id, item.name_snapshot ?? item.product_id)
  }
  const blockers: PurchaseBranchMoveBlocker[] = []
  for (const [productId, held] of heldByProduct(savedItems)) {
    const remaining = savedBranchStockOf(productId)
    if (remaining < held) {
      blockers.push({ productId, productName: names.get(productId) ?? productId, held, remaining })
    }
  }
  return blockers
}

/**
 * "En Centro quedan 3 de las 10 que entraron con este remito: no se puede mover
 * a otra sucursal".
 */
export function describePurchaseBranchMove(
  blocker: PurchaseBranchMoveBlocker,
  branchName: string,
  baseUnit?: UnitOfMeasure | null,
): string {
  const heldText = formatBaseQuantity(blocker.held, baseUnit)
  const article = isProductoPorUnidades(baseUnit) ? "las" : "los"
  return `En ${branchName} quedan ${formatBaseQuantity(blocker.remaining, baseUnit)} de ${article} ${heldText} que entraron con este remito: no se puede mover a otra sucursal`
}

export interface PurchaseLinesBelowMinimumArgs {
  savedItems: Pick<DeliveryNoteItemApiRow, "product_id" | "name_snapshot">[]
  /** `purchaseMinimumByProduct` de las líneas guardadas. */
  minimums: Map<string, number>
  nextLines: Pick<SaleCartItem, "productId" | "productName" | "quantity" | "quantityBase">[]
}

/**
 * Los nombres de los productos cuyas líneas, sumadas, quedan por debajo de su
 * mínimo (quitar la línea entera cuenta como 0). Alimenta `validateDeliveryNoteDraft`.
 */
export function purchaseLinesBelowMinimum({ savedItems, minimums, nextLines }: PurchaseLinesBelowMinimumArgs): string[] {
  const names = new Map<string, string>()
  for (const item of savedItems) {
    if (!names.has(item.product_id)) names.set(item.product_id, item.name_snapshot ?? item.product_id)
  }
  const next = new Map<string, number>()
  for (const line of nextLines) {
    next.set(line.productId, round4((next.get(line.productId) ?? 0) + (line.quantityBase ?? line.quantity)))
    if (!names.has(line.productId)) names.set(line.productId, line.productName)
  }
  const below: string[] = []
  for (const [productId, minimum] of minimums) {
    if ((next.get(productId) ?? 0) < minimum) below.push(names.get(productId) ?? productId)
  }
  return below
}
