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
    } else {
      map.set(key, {
        key,
        operationId: purchase.operationId,
        date: purchase.date,
        items: [purchase],
        total: purchase.total,
        description: purchase.description,
        isGrouped: false,
      })
    }
  }

  return Array.from(map.values()).sort((a, b) => b.date.localeCompare(a.date))
}
