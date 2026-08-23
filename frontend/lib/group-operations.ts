/**
 * Grouping utilities for sale and purchase operations.
 *
 * Rules:
 * - Records that share an operationId   → grouped as ONE operation.
 * - Records without operationId (historical) → each is its OWN operation.
 * - Result is sorted by date descending.
 */
import type { Sale, Purchase } from "@/lib/types"
import type { Currency } from "@/lib/format"

// ─── Sale Operations ──────────────────────────────────────────────────────────

export interface SaleOperation {
  /** operationId if grouped; saleId for historical records with no operationId */
  key: string
  /** Defined only when multiple rows share the same operationId */
  operationId?: string
  date: string
  clientId: string
  clientName: string
  currency: Currency
  items: Sale[]
  total: number
  /** true when > 1 item belongs to this operation */
  isGrouped: boolean
  /** metodos-pago-operaciones: forma de pago de la operación (D3: por operación, todas las líneas comparten el valor). */
  paymentMethodId: string | null
  /** edicion-preserva-contexto: sucursal de la operación (editable, tri-estado). */
  branchId: string | null
  /** edicion-preserva-contexto: canal de venta de la operación (editable, tri-estado). */
  canal: string | null
  /** edicion-preserva-contexto: unidad de medida de la primera línea (viaja pegada al producto, no al header). */
  unitId: string | null
  /** edicion-preserva-contexto (F2): true si la operación tiene un comprobante
   * fiscal pending_cae/authorized — el form de edición se abre en solo lectura. */
  isInvoiced: boolean
  /** pagos-cableados-restantes (D6): true si la operación tiene un cargo de
   * cuenta corriente o movimiento de caja posteado — inmutable (P0423). */
  isPaymentLocked: boolean
  /** delete-guard-ledgers: desglose de isPaymentLocked por libro, para que
   * el diálogo de borrado enumere específicamente qué se va a compensar. */
  hasAccountCharge: boolean
  hasCashMovement: boolean
  hasBankMovement: boolean
}

export function groupSalesByOperation(sales: Sale[]): SaleOperation[] {
  const map = new Map<string, SaleOperation>()

  for (const sale of sales) {
    // Use operationId as the aggregation key; fall back to the row id
    const key = sale.operationId ?? sale.id

    if (map.has(key)) {
      const op = map.get(key)!
      op.items.push(sale)
      op.total += sale.total
      op.isGrouped = true
      op.isInvoiced = op.isInvoiced || !!sale.isInvoiced
      op.isPaymentLocked = op.isPaymentLocked || !!sale.isPaymentLocked
      op.hasAccountCharge = op.hasAccountCharge || !!sale.hasAccountCharge
      op.hasCashMovement = op.hasCashMovement || !!sale.hasCashMovement
      op.hasBankMovement = op.hasBankMovement || !!sale.hasBankMovement
    } else {
      map.set(key, {
        key,
        operationId: sale.operationId,
        date: sale.date,
        clientId: sale.clientId,
        clientName: sale.clientName,
        currency: (sale.currency as Currency) || "ARS",
        items: [sale],
        total: sale.total,
        isGrouped: false,
        paymentMethodId: sale.paymentMethodId ?? null,
        branchId: sale.branchId ?? null,
        canal: sale.canal ?? null,
        unitId: sale.unitId ?? null,
        isInvoiced: !!sale.isInvoiced,
        isPaymentLocked: !!sale.isPaymentLocked,
        hasAccountCharge: !!sale.hasAccountCharge,
        hasCashMovement: !!sale.hasCashMovement,
        hasBankMovement: !!sale.hasBankMovement,
      })
    }
  }

  // Most recent first
  return Array.from(map.values()).sort((a, b) => b.date.localeCompare(a.date))
}

// ─── Purchase Operations ──────────────────────────────────────────────────────

export interface PurchaseOperation {
  key: string
  operationId?: string
  date: string
  items: Purchase[]
  total: number
  description?: string
  isGrouped: boolean
  /** metodos-pago-operaciones: forma de pago de la operación (D3: por operación, todas las líneas comparten el valor). */
  paymentMethodId: string | null
  /** edicion-preserva-contexto: sucursal de la operación (editable, tri-estado). */
  branchId: string | null
  /** edicion-preserva-contexto: unidad de medida de la primera línea. */
  unitId: string | null
  /** pagos-cableados-restantes (D6, task 9.3): true si la operación tiene un
   * cargo de cuenta corriente posteado — inmutable (P0423). */
  isPaymentLocked: boolean
  /** delete-guard-ledgers: desglose de isPaymentLocked por libro (sin
   * caja — las compras no tienen opt-in de caja). */
  hasAccountCharge: boolean
  hasBankMovement: boolean
  /** compras-proveedor-cuenta-corriente (D4): proveedor imputado a la
   * operación (editable, tri-estado — D7). null = sin proveedor. */
  supplierId: string | null
  /** compras-proveedor-cuenta-corriente (task 9.2): nombre resuelto por el
   * listado (LEFT JOIN suppliers), para el badge. */
  supplierName: string | null
}

export function groupPurchasesByOperation(purchases: Purchase[]): PurchaseOperation[] {
  const map = new Map<string, PurchaseOperation>()

  for (const purchase of purchases) {
    const key = purchase.operationId ?? purchase.id

    if (map.has(key)) {
      const op = map.get(key)!
      op.items.push(purchase)
      op.total += purchase.total
      op.isGrouped = true
      op.isPaymentLocked = op.isPaymentLocked || !!purchase.isPaymentLocked
      op.hasAccountCharge = op.hasAccountCharge || !!purchase.hasAccountCharge
      op.hasBankMovement = op.hasBankMovement || !!purchase.hasBankMovement
    } else {
      map.set(key, {
        key,
        operationId: purchase.operationId,
        date: purchase.date,
        items: [purchase],
        total: purchase.total,
        description: purchase.description,
        isGrouped: false,
        paymentMethodId: purchase.paymentMethodId ?? null,
        branchId: purchase.branchId ?? null,
        unitId: purchase.unitId ?? null,
        isPaymentLocked: !!purchase.isPaymentLocked,
        hasAccountCharge: !!purchase.hasAccountCharge,
        hasBankMovement: !!purchase.hasBankMovement,
        supplierId: purchase.supplierId ?? null,
        supplierName: purchase.supplierName ?? null,
      })
    }
  }

  return Array.from(map.values()).sort((a, b) => b.date.localeCompare(a.date))
}
