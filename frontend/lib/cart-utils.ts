/**
 * lib/cart-utils.ts
 * ─────────────────────────────────────────────────────────────────────────────
 * Cart types and pure math utilities shared between sale-form and purchase-form.
 *
 * ⚠️  Pure logic only — no persistence, no Supabase calls, no React.
 *     Each form manages its own independent cart state and calls the
 *     appropriate service upon submission.
 *
 * Precision contract
 * - All subtotals are rounded to 4 decimal places (matches NUMERIC(15,4) in DB)
 * - toFixed(4) via _round4 prevents floating-point drift (1.1 * 3 ≠ 3.3000…03)
 * - A line UNIT PRICE is NOT rounded to a fixed number of decimals
 *   (ventas-unidades-conversion D-F′): re-expressed per gram a catalogue price
 *   with cents needs 5 decimals ($1.234,56/kg = $1,23456/g) and, per mg, 8.
 *   `roundUnitPrice` only strips binary noise (15 significant digits); the
 *   price columns of every document line are unconstrained NUMERIC.
 */

import { getCanonicalLabel } from "@/lib/product-labels"
import { formatStock } from "@/lib/format-unit"
import {
  isProductoMedible,
  resolveUnit,
  toBaseQuantity,
  unitInputMin,
  unitInputStep,
} from "@/lib/unit-utils"
import type { ScanResult } from "@/lib/scan-resolution"
import type { Product, UnitOfMeasure } from "@/lib/types"

// ─── Operation ID ─────────────────────────────────────────────────────────────

/**
 * Generates a UUID v4 to logically group all items submitted from the same
 * cart operation. Stored in sales.operation_id / purchases.operation_id.
 */
export function generateOperationId(): string {
  return crypto.randomUUID()
}

// ─── Sale Cart ────────────────────────────────────────────────────────────────

export interface SaleCartItem {
  /** Frontend-only identifier (not persisted). */
  id: string
  productId: string
  productName: string
  /** Catalogue unit price (before discount). */
  unitPrice: number
  /** Visual quantity — in the selected unit (may be fractional for medibles). */
  quantity: number
  /** Discount percentage applied to this item (0–100). */
  discount: number
  /** Pre-computed: unitPrice × qty × (1 − discount/100), rounded to 4dp. */
  subtotal: number
  // ── Unit of measure ────────────────────────────────────────────────────────
  /** UUID of the selected unit; undefined = base unit (factor 1). */
  unitId?: string
  /** Symbol shown in cart and on receipt (e.g. "kg", "doc"). */
  unitSymbol?: string
  /**
   * Visual qty converted to the PRODUCT's base unit (ventas-unidades-conversion
   * D1/D5) — pre-normalized for local stock validation only; the server
   * normalizes again with the single SQL definition and is the one that decides.
   */
  quantityBase?: number
  // ── Input constraints (driven by unit type) ────────────────────────────────
  /** HTML input step: 1 for unitarios, 0.001 for medibles. */
  step?: number
  /** Minimum quantity: mirrors step. */
  minQty?: number
  /**
   * balanza-etiquetas-pos (D8): origen de la línea.
   * - `"scale"`:     una etiqueta de balanza leída en esta sesión — nunca se
   *   fusiona con otra alta (código común, SKU o manual): cada pesada es una
   *   línea propia con su propio importe.
   * - `"persisted"`: una línea rehidratada al editar una venta existente —
   *   tampoco se fusiona (su cantidad ya salió de `product.stock`) y no
   *   cuenta contra el disponible en `exceedsStock`.
   * - `undefined`:   una línea creada a mano o por código común/SKU en esta
   *   sesión — la única fusionable.
   */
  source?: "scale" | "persisted"
}

export function calcSaleSubtotal(
  unitPrice: number,
  qty: number,
  discount: number,
): number {
  return _round4(unitPrice * qty * (1 - discount / 100))
}

/**
 * Inverse of calcSaleSubtotal for the discount-free case: given a desired line
 * subtotal and quantity, returns the effective unit price (rounded to 4dp).
 *
 * Used when the user edits the Subtotal field directly to hit the exact price a
 * sale closed at (when a % discount can't land on a round number). The result
 * becomes the stored `amount` (effective unit price); discount resets to 0.
 *
 * Guards qty <= 0 → returns 0 to avoid division by zero / Infinity.
 */
export function unitPriceFromSubtotal(subtotal: number, qty: number): number {
  if (qty <= 0) return 0
  return roundUnitPrice(subtotal / qty)
}

/**
 * Cleans the binary floating-point noise of a line UNIT PRICE without
 * truncating its precision (ventas-unidades-conversion D-F′, provisional until
 * the PO signs off): 15 significant digits, the precision a double carries
 * reliably. Rounding to a fixed 4 decimals broke the line total as soon as the
 * unit is small — $1.234,56/kg is $1,23456/g, and 1,2346 × 450 g charged
 * $555,57 instead of $555,552 (in mg, 1000× worse); a subtotal typed on a line
 * in grams did not round-trip either (2000 / 450 → 4,4444 → $1.999,98).
 *
 * @example
 * roundUnitPrice(1234.56 * 0.001)   → 1.23456   (not 1.2345599999999999)
 * roundUnitPrice(1.1 * 0.001)       → 0.0011    (not 0.0011000000000000001)
 * roundUnitPrice(10000 / 3)         → 3333.33333333333
 */
export function roundUnitPrice(price: number): number {
  if (!Number.isFinite(price)) return price
  return Number(price.toPrecision(15))
}

// ─── Purchase Cart ────────────────────────────────────────────────────────────

export interface PurchaseCartItem {
  /** Frontend-only identifier (not persisted). */
  id: string
  productId: string
  productName: string
  unitCost: number
  /** Visual quantity — in the selected unit (may be fractional for medibles). */
  quantity: number
  /** Pre-computed: unitCost × qty, rounded to 4dp. */
  subtotal: number
  // ── Unit of measure ────────────────────────────────────────────────────────
  /** UUID of the selected unit; undefined = base unit (factor 1). */
  unitId?: string
  /** Symbol shown in cart (e.g. "kg", "doc"). */
  unitSymbol?: string
  /** Visual qty converted to the PRODUCT's base unit — local validation only. */
  quantityBase?: number
  // ── Input constraints (driven by unit type) ────────────────────────────────
  /** HTML input step: 1 for unitarios, 0.001 for medibles. */
  step?: number
  /** Minimum quantity: mirrors step. */
  minQty?: number
}

export function calcPurchaseSubtotal(unitCost: number, qty: number): number {
  return _round4(unitCost * qty)
}

// ─── Shared ───────────────────────────────────────────────────────────────────

export function calcCartTotal(items: { subtotal: number }[]): number {
  return _round4(items.reduce((sum, item) => sum + item.subtotal, 0))
}

// ─── Internal ─────────────────────────────────────────────────────────────────

/** Rounds to 4 decimal places — matches NUMERIC(15,4) precision in the DB. */
function _round4(n: number): number {
  return Math.round(n * 10_000) / 10_000
}


// ─── balanza-etiquetas-pos (D7/D8) ─────────────────────────────────────────────

/**
 * Chequeo de stock ACUMULATIVO (D7, OQ-9): suma el `quantityBase` de todas
 * las líneas del carrito del MISMO producto agregadas en esta sesión
 * (`source !== "persisted"` — al editar una venta, esas líneas ya salieron de
 * `product.stock`) más `addBase`, y compara contra `stock`. Usado tanto por
 * una etiqueta de balanza como por el alta manual (POS y formulario de venta),
 * en sus dos ramas (fusión y línea nueva) — antes cada pantalla sólo medía la
 * línea que estaba tocando, lo que dejaba pasar dos etiquetas que juntas
 * superaban el disponible.
 */
export function exceedsStock(
  items: Pick<SaleCartItem, "productId" | "source" | "quantityBase">[],
  productId: string,
  addBase: number,
  stock: number,
): boolean {
  const sumBase = items
    .filter((item) => item.productId === productId && item.source !== "persisted")
    .reduce((sum, item) => sum + (item.quantityBase ?? 0), 0)
  return sumBase + addBase > stock
}

/**
 * remitos-compra (D11): de dónde sale el precio de una línea NUEVA. `"price"`
 * (default) es el precio de venta del catálogo — venta, presupuesto y POS;
 * `"cost"` es el costo, para el remito de compra (la mercadería se recibe a lo
 * que cuesta, no a lo que se vende).
 */
export type CartPriceSource = "price" | "cost"

/**
 * El precio de catálogo de un producto según la fuente. `cost` nulo es dato
 * ausente (productos-costo-nullable): la línea entra a 0, nunca al precio de
 * venta.
 */
export function catalogPriceOf(product: Pick<Product, "price" | "cost">, source: CartPriceSource = "price"): number {
  return source === "cost" ? (product.cost ?? 0) : product.price
}

export interface AddScannedProductLineContext {
  unitsById: Map<string, UnitOfMeasure>
  /** Catálogo completo — para resolver el nombre del producto con su padre. */
  products: Product[]
}

export type AddScannedProductLineResult =
  | { items: SaleCartItem[] }
  | { needsQuantity: true }

/**
 * Alta de un producto encontrado por CÓDIGO COMÚN o SKU (D6/D8) — nunca por
 * una etiqueta de balanza (esa la resuelve `resolveScaleScan`, D7). Reglas:
 *
 * - Producto **por unidades**: suma `unitInputMin` a la línea NO-balanza
 *   (`source` ausente) del mismo producto y unidad base, conservando el
 *   `unitPrice` de esa línea (un precio editado a mano no se pisa con el del
 *   catálogo); si no hay una línea así, crea una con el precio del catálogo.
 *   Nunca fusiona sobre una línea `"scale"` ni `"persisted"`.
 * - Producto **medible** (peso, volumen, longitud, personalizada): NO agrega
 *   una cantidad mínima arbitraria — devuelve `{ needsQuantity: true }` para
 *   que la pantalla deje el producto elegido en su selector con el foco en
 *   "Cantidad".
 */
export function addScannedProductLine(
  items: SaleCartItem[],
  product: Product,
  ctx: AddScannedProductLineContext,
  priceSource: CartPriceSource = "price",
): AddScannedProductLineResult {
  const baseUnit = resolveUnit(product.baseUnitId, ctx.unitsById)

  if (isProductoMedible(baseUnit)) {
    return { needsQuantity: true }
  }

  // Fix F4 (revisión adversarial PR #599): el alta MANUAL (POS y formulario
  // de venta) guarda `unitId: product.baseUnitId` para un producto con
  // unidad base con nombre propio (nunca `undefined`) — comparar contra
  // `!item.unitId` nunca encontraba esa línea y creaba una segunda. La
  // comparación correcta es "la unidad base del producto", igual que el
  // alta manual (`(item.unitId ?? '') === unitId`, D8).
  const existingIndex = items.findIndex(
    (item) =>
      item.productId === product.id &&
      !item.source &&
      (item.unitId ?? product.baseUnitId ?? "") === (product.baseUnitId ?? ""),
  )
  const addQty = unitInputMin(baseUnit)

  if (existingIndex >= 0) {
    const existing = items[existingIndex]
    const newQty = existing.quantity + addQty
    const nextItems = items.slice()
    nextItems[existingIndex] = {
      ...existing,
      quantity: newQty,
      quantityBase: newQty,
      subtotal: calcSaleSubtotal(existing.unitPrice, newQty, existing.discount),
    }
    return { items: nextItems }
  }

  const parent = product.parentId ? ctx.products.find((p) => p.id === product.parentId) : undefined
  const catalogPrice = catalogPriceOf(product, priceSource)
  const newLine: SaleCartItem = {
    id: crypto.randomUUID(),
    productId: product.id,
    productName: getCanonicalLabel(product, parent),
    unitPrice: catalogPrice,
    quantity: addQty,
    discount: 0,
    subtotal: calcSaleSubtotal(catalogPrice, addQty, 0),
    // F4: la línea nueva nace con la MISMA unidad que el alta manual
    // (`product.baseUnitId`), no `undefined` — así un escaneo posterior del
    // mismo producto la encuentra y fusiona en vez de crear una tercera.
    unitId: product.baseUnitId || undefined,
    unitSymbol: baseUnit?.symbol,
    quantityBase: addQty,
    step: addQty,
    minQty: addQty,
  }
  return { items: [...items, newLine] }
}


// ─── presupuestos-modulo (D12) — operaciones de carrito compartidas ────────────
//
// Antes vivían embebidas en `components/forms/sale-form.tsx` (`handleAddToCart`,
// el despacho de `handleScan`, `handleUpdateQty`, `handleUpdateSubtotal`). El
// formulario de venta y el de presupuesto las comparten desde acá. La única
// diferencia entre los dos es `enforceStock`: la venta rechaza lo que supera el
// disponible; el presupuesto (no reserva ni baja stock) lo agrega y sólo avisa.
// El POS conserva su copia de `handleScan` (duplicación preexistente).

export interface CartContext {
  unitsById: Map<string, UnitOfMeasure>
  /** Catálogo completo — para resolver el nombre de una variante con su padre y la unidad base. */
  products: Product[]
}

export interface CartStockOptions {
  /**
   * `true`: lo que supera el disponible se rechaza (chequeo acumulativo,
   * `exceedsStock`). `false`: se agrega igual y el resultado trae
   * `stockWarning` con el disponible.
   */
  enforceStock: boolean
  /**
   * remitos-venta (D11): el disponible de un producto en la SUCURSAL de la
   * operación, en su unidad base. Cuando está presente, el alta manual y el
   * escaneo (sus tres ramas) lo usan EN LUGAR de `product.stock`, que es el
   * agregado del catálogo: con stock en otra sucursal, el agregado dejaría pasar
   * lo que el servidor rechaza. En una edición, el llamador le suma lo que el
   * documento ya retiene (todas las líneas cuentan contra ese disponible — por
   * eso las líneas del remito no llevan `source: "persisted"`). Ausente, nada
   * cambia: la venta y el presupuesto siguen con `product.stock`.
   */
  availableFor?: (productId: string) => number
  /**
   * remitos-compra (D11): la fuente del precio de las líneas NUEVAS que crea un
   * código (`applyScanToCart`). Ausente = `"price"`: nada cambia para venta,
   * presupuesto y POS. En el alta MANUAL no actúa: el precio ya viene en la línea
   * en preparación (`StagedProductLine` lee la misma fuente).
   */
  priceSource?: CartPriceSource
}

/** El disponible contra el que se valida: el de la sucursal si se lo pasó, si no el del catálogo. */
function availableStockOf(options: CartStockOptions, productId: string, catalogStock: number): number {
  return options.availableFor ? options.availableFor(productId) : catalogStock
}

/** Lo que el usuario dejó "en preparación" antes de agregarlo al carrito. */
export interface StagedCartLine {
  product: Product
  /** Precio unitario en la unidad de la línea (ya re-expresado si cambió la unidad). */
  unitPrice: number
  quantity: number
  /** Descuento en % (0–100). */
  discount: number
  /** Unidad elegida; `""` = sin unidad explícita. */
  unitId: string
}

export type AddManualLineResult =
  | {
      ok: true
      items: SaleCartItem[]
      /** `true` si sumó sobre una línea existente (no creó una nueva). */
      merged: boolean
      productName: string
      /** Sólo con `enforceStock: false` y stock superado: el disponible a mostrar. */
      stockWarning?: string
    }
  | { ok: false; reason: "insufficient_stock"; message: string }

function insufficientStockMessage(stock: number, baseUnit: UnitOfMeasure | undefined): string {
  // El stock del producto se lleva en su unidad BASE: el disponible se informa
  // con el símbolo de la base, nunca con el de la línea (con la línea en gramos
  // decía "0.550 g" sobre 0,55 kg — corrección del PR #584).
  return `Stock insuficiente (disponible: ${formatStock(stock, baseUnit?.symbol)})`
}

/**
 * Alta MANUAL de una línea (producto + cantidad + descuento + unidad elegidos
 * a mano). Fusiona sólo sobre una línea del mismo producto y unidad SIN
 * `source` (D8): una línea de balanza o rehidratada al editar nunca se toca.
 */
export function addManualLineToCart(
  cart: SaleCartItem[],
  staged: StagedCartLine,
  ctx: CartContext,
  stockOptions: CartStockOptions,
): AddManualLineResult {
  const { enforceStock } = stockOptions
  const { product, unitPrice, quantity, discount, unitId } = staged
  const selectedUnit = resolveUnit(unitId, ctx.unitsById)
  const baseUnit = resolveUnit(product.baseUnitId, ctx.unitsById)
  const quantityBase = toBaseQuantity(quantity, selectedUnit, baseUnit)

  // D7/OQ-9: chequeo ACUMULATIVO — todas las líneas del mismo producto
  // (`persisted` excluida) más lo nuevo, no sólo la que se está tocando.
  const available = availableStockOf(stockOptions, product.id, product.stock)
  const exceeded = exceedsStock(cart, product.id, quantityBase, available)
  const warning = insufficientStockMessage(available, baseUnit)
  if (exceeded && enforceStock) {
    return { ok: false, reason: "insufficient_stock", message: warning }
  }
  const stockWarning = exceeded ? warning : undefined

  const existing = cart.find(
    (item) => item.productId === product.id && (item.unitId ?? "") === unitId && !item.source,
  )

  if (existing) {
    const newQty = existing.quantity + quantity
    const items = cart.map((item) =>
      item.id === existing.id
        ? {
            ...item,
            quantity: newQty,
            quantityBase: toBaseQuantity(newQty, selectedUnit, baseUnit),
            subtotal: calcSaleSubtotal(item.unitPrice, newQty, item.discount),
          }
        : item,
    )
    return { ok: true, items, merged: true, productName: product.name, stockWarning }
  }

  const parent = product.parentId ? ctx.products.find((p) => p.id === product.parentId) : undefined
  const newLine: SaleCartItem = {
    id: crypto.randomUUID(),
    productId: product.id,
    productName: getCanonicalLabel(product, parent),
    unitPrice,
    quantity,
    discount,
    subtotal: calcSaleSubtotal(unitPrice, quantity, discount),
    unitId: unitId || undefined,
    unitSymbol: selectedUnit?.symbol,
    quantityBase,
    step: unitInputStep(selectedUnit),
    minQty: unitInputMin(selectedUnit),
  }
  return { ok: true, items: [...cart, newLine], merged: false, productName: product.name, stockWarning }
}

export type ApplyScanResult =
  | { kind: "added"; items: SaleCartItem[]; label: string; stockWarning?: string }
  /** Producto medible: la pantalla lo deja elegido con el foco en "Cantidad". */
  | { kind: "needs_quantity"; product: Product; label: string }
  | { kind: "rejected"; label: string }

/**
 * Despacha un código YA resuelto por `resolveScan` (balanza-etiquetas-pos
 * D6/D9) sobre el carrito: producto por unidades (suma o crea la línea),
 * medible (pide la cantidad) o etiqueta de balanza (una línea nueva, nunca
 * fusionada). El chequeo de stock es acumulativo en las dos ramas.
 */
export function applyScanToCart(
  cart: SaleCartItem[],
  scan: ScanResult,
  ctx: CartContext,
  stockOptions: CartStockOptions,
): ApplyScanResult {
  const { enforceStock } = stockOptions
  if (scan.kind === "error") return { kind: "rejected", label: scan.message }

  if (scan.kind === "product") {
    const { product } = scan
    const baseUnit = resolveUnit(product.baseUnitId, ctx.unitsById)
    const askQuantity: ApplyScanResult = {
      kind: "needs_quantity",
      product,
      label: `Ingresá la cantidad de «${product.name}»`,
    }
    // D8: un medible por código común/SKU no agrega una cantidad arbitraria.
    if (isProductoMedible(baseUnit)) return askQuantity

    // Un producto por unidades también suma stock (fix F3, PR #599).
    const available = availableStockOf(stockOptions, product.id, product.stock)
    const exceeded = exceedsStock(cart, product.id, unitInputMin(baseUnit), available)
    const warning = insufficientStockMessage(available, baseUnit)
    if (exceeded && enforceStock) return { kind: "rejected", label: warning }

    const added = addScannedProductLine(
      cart,
      product,
      { unitsById: ctx.unitsById, products: ctx.products },
      stockOptions.priceSource,
    )
    if ("needsQuantity" in added) return askQuantity // defensivo: ya se descartó arriba
    // Sólo el nombre: el indicador del lector ya antepone su propio "✓" (F9).
    return { kind: "added", items: added.items, label: product.name, stockWarning: exceeded ? warning : undefined }
  }

  // scan.kind === "scale_line" (D7): una línea nueva, nunca fusionada (D8).
  const { line } = scan
  const lineProduct = ctx.products.find((p) => p.id === line.productId)
  const stock = availableStockOf(stockOptions, line.productId, lineProduct?.stock ?? 0)
  const exceeded = exceedsStock(cart, line.productId, line.quantityBase ?? line.quantity, stock)
  const warning = insufficientStockMessage(stock, resolveUnit(lineProduct?.baseUnitId, ctx.unitsById))
  if (exceeded && enforceStock) return { kind: "rejected", label: warning }
  // La etiqueta trae el importe de VENTA: en compra se reprecia al costo y se
  // conserva el peso leído (la línea sigue siendo una pesada propia, `source: "scale"`).
  const pricedLine =
    stockOptions.priceSource === "cost" && lineProduct
      ? {
          ...line,
          unitPrice: catalogPriceOf(lineProduct, "cost"),
          subtotal: calcSaleSubtotal(catalogPriceOf(lineProduct, "cost"), line.quantity, 0),
        }
      : line
  return {
    kind: "added",
    items: [...cart, { id: crypto.randomUUID(), ...pricedLine }],
    label: line.productName,
    stockWarning: exceeded ? warning : undefined,
  }
}

/** Quita la línea con ese `id`. */
export function removeLine(items: SaleCartItem[], id: string): SaleCartItem[] {
  return items.filter((item) => item.id !== id)
}

/**
 * Cambia la cantidad de una línea (en la unidad de la línea), sin bajar de su
 * mínimo — el de la línea, no un 1 global, para que un medible pueda bajar de
 * 1 — y recalcula la cantidad base y el subtotal con SU precio y descuento.
 */
export function updateLineQuantity(
  items: SaleCartItem[],
  id: string,
  qty: number,
  ctx: CartContext,
): SaleCartItem[] {
  return items.map((item) => {
    if (item.id !== id) return item
    const productBaseUnit = resolveUnit(
      ctx.products.find((p) => p.id === item.productId)?.baseUnitId,
      ctx.unitsById,
    )
    const lineUnit = resolveUnit(item.unitId, ctx.unitsById)
    const newQty = Math.max(item.minQty ?? unitInputMin(lineUnit ?? productBaseUnit), qty)
    return {
      ...item,
      quantity: newQty,
      quantityBase: toBaseQuantity(newQty, lineUnit, productBaseUnit),
      subtotal: calcSaleSubtotal(item.unitPrice, newQty, item.discount),
    }
  })
}

/**
 * Edita el subtotal de una línea ya cargada: despeja el precio unitario
 * efectivo y borra el descuento (el precio al que cerró queda como verdad).
 */
export function updateLineSubtotal(items: SaleCartItem[], id: string, newSubtotal: number): SaleCartItem[] {
  return items.map((item) =>
    item.id === id
      ? {
          ...item,
          unitPrice: unitPriceFromSubtotal(newSubtotal, item.quantity),
          discount: 0,
          subtotal: newSubtotal,
        }
      : item,
  )
}


// ─── remitos-venta (D11) — validación contra el disponible por sucursal ────────

/**
 * Tope de cada input de cantidad (en la unidad de la LÍNEA), para
 * `CartItemList.maxQtyMap`: lo que deja el disponible del producto una vez
 * descontadas las demás líneas del mismo producto. Nunca baja de 0 — lo que ya
 * no alcanza (p. ej. al cambiar de sucursal) se señala con
 * `linesExceedingAvailable`, no con un tope negativo.
 */
export function maxQuantityPerLine(
  items: SaleCartItem[],
  availableFor: (productId: string) => number,
  ctx: CartContext,
): Record<string, number> {
  const map: Record<string, number> = {}
  for (const item of items) {
    const baseUnit = resolveUnit(ctx.products.find((p) => p.id === item.productId)?.baseUnitId, ctx.unitsById)
    const lineUnit = resolveUnit(item.unitId, ctx.unitsById)
    // Misma lectura que `toBaseQuantity`, sin su redondeo a 4 decimales (un
    // factor de miligramos se redondearía a 0): sin unidad, la cantidad tal cual.
    const factor = lineUnit ? lineUnit.factor / (baseUnit?.factor ?? 1) : 1
    const others = items
      .filter((other) => other.id !== item.id && other.productId === item.productId)
      .reduce((sum, other) => sum + (other.quantityBase ?? 0), 0)
    const room = Math.max(0, availableFor(item.productId) - others)
    map[item.id] = factor > 0 ? Math.floor((room / factor) * 10_000 + 1e-9) / 10_000 : 0
  }
  return map
}

/**
 * Ids de las líneas cuyo producto, sumadas todas sus líneas, supera el
 * disponible. Sirve para re-validar el carrito entero al cambiar de sucursal y
 * marcar las que no alcanzan SIN borrarlas (reutiliza `exceedsStock`).
 */
export function linesExceedingAvailable(
  items: Pick<SaleCartItem, "id" | "productId" | "source" | "quantityBase">[],
  availableFor: (productId: string) => number,
): string[] {
  const exceeding = new Set<string>()
  for (const productId of new Set(items.map((item) => item.productId))) {
    if (exceedsStock(items, productId, 0, availableFor(productId))) exceeding.add(productId)
  }
  return items.filter((item) => exceeding.has(item.productId)).map((item) => item.id)
}
