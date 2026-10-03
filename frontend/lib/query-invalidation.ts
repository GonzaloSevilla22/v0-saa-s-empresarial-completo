/**
 * presupuestos-modulo (D12) — invalidaciones de React Query compartidas.
 *
 * Una venta confirmada toca muchas pantallas a la vez (la venta y su orden, el
 * stock, la cuenta corriente, el panel de cobranzas, la caja y el banco). Esa
 * lista vivía repetida en dos mutaciones de `hooks/data/use-sales-orders.ts` y
 * en ninguna estaban la caja, el banco ni el catálogo de productos: después de
 * vender, `/caja`, `/banco` y el stock del catálogo quedaban desactualizados
 * hasta recargar. Ahora hay UNA definición, que consumen esas dos mutaciones y
 * la conversión de un presupuesto en venta.
 */
import type { QueryClient } from "@tanstack/react-query"
import { queryKeys } from "@/lib/query-keys"

/** Las raíces que invalida una venta confirmada (una definición, un test). */
export const SALE_INVALIDATED_ROOTS = [
  "salesOrders",
  "sales",
  "branchStock",
  "products",
  "customerAccounts",
  "receivables",
  "cashSessions",
  "cashMovements",
  "bankAccounts",
] as const

/**
 * Invalida todo lo que una venta confirmada pudo cambiar:
 * - `salesOrders` / `sales`: la venta, su orden y el listado de /ventas.
 * - `branchStock` / `products`: el stock por sucursal y el del catálogo (lo que
 *   muestran los selectores de producto).
 * - `customerAccounts` / `receivables`: una venta a crédito postea un cargo; el
 *   panel /cobranzas y el KPI del Tablero derivan del mismo saldo.
 * - `cashSessions` / `cashMovements`: la venta en efectivo escribe en la caja.
 * - `bankAccounts`: una transferencia o billetera escribe en el banco.
 */
export function invalidateAfterSale(queryClient: QueryClient): void {
  queryClient.invalidateQueries({ queryKey: queryKeys.salesOrders.all() })
  queryClient.invalidateQueries({ queryKey: queryKeys.sales.all() })
  queryClient.invalidateQueries({ queryKey: queryKeys.branchStock.all() })
  queryClient.invalidateQueries({ queryKey: queryKeys.products.all() })
  queryClient.invalidateQueries({ queryKey: queryKeys.customerAccounts.all() })
  queryClient.invalidateQueries({ queryKey: queryKeys.receivables.all() })
  queryClient.invalidateQueries({ queryKey: queryKeys.cashSessions.all() })
  queryClient.invalidateQueries({ queryKey: queryKeys.cashMovements.all() })
  queryClient.invalidateQueries({ queryKey: queryKeys.bankAccounts.all() })
}

/**
 * remitos-venta (D9/D11, task 7.7): lo que invalida el BORRADO de una venta.
 *
 * Borrar compensa los mismos libros que la venta escribió (cuenta corriente,
 * caja, banco y stock), así que comparte la unión de `invalidateAfterSale`. Y
 * suma `deliveryNotes`: borrar una venta nacida de un remito lo devuelve a
 * `issued` en la misma transacción (R5). Sin invalidar los remitos, `/remitos`
 * mostraría "Convertido" con "Ver venta" apuntando a una orden cancelada hasta
 * recargar. Una definición para `deleteSaleMutation` y
 * `deleteSalesByOperationMutation`.
 */
export function invalidateAfterSaleDelete(queryClient: QueryClient): void {
  invalidateAfterSale(queryClient)
  queryClient.invalidateQueries({ queryKey: queryKeys.deliveryNotes.all() })
}
