/**
 * edicion-operaciones-con-dinero (tanda C, 13.2/D17) — `invalidateAfterOperationEdit`: editar una operación con dinero toca
 * los mismos libros que el borrado y las altas (cuenta corriente, caja, banco), más la conciliación, el libro diario, el
 * reporte de formas de pago y el historial de cambios. Una definición por documento, no una lista por pantalla.
 */
import { describe, it, expect, vi } from "vitest"
import { QueryClient } from "@tanstack/react-query"
import { invalidateAfterOperationEdit, OPERATION_EDIT_INVALIDATED_ROOTS } from "@/lib/query-invalidation"

function roots(spy: ReturnType<typeof vi.spyOn>): string[] {
  return spy.mock.calls.map((c: unknown[]) => String((c[0] as { queryKey?: unknown[] })?.queryKey?.[0]))
}

const COMMON = ["cashSessions", "cashMovements", "bankAccounts", "bankReconciliation", "journal-entries", "paymentMethods", "operation-edits"]

describe("invalidateAfterOperationEdit", () => {
  it.each(COMMON)("toda edición invalida %s", (root) => {
    for (const kind of ["sale", "purchase", "expense"] as const) {
      const queryClient = new QueryClient()
      const spy = vi.spyOn(queryClient, "invalidateQueries")
      invalidateAfterOperationEdit(queryClient, kind)
      expect(roots(spy)).toContain(root)
    }
  })

  it("venta: su listado, el stock, la cuenta corriente del cliente y cobranzas", () => {
    const queryClient = new QueryClient()
    const spy = vi.spyOn(queryClient, "invalidateQueries")
    invalidateAfterOperationEdit(queryClient, "sale")
    const r = roots(spy)
    for (const root of ["sales", "products", "branchStock", "customerAccounts", "receivables"]) expect(r).toContain(root)
    expect(r).not.toContain("supplierAccounts")
    expect(r).not.toContain("expenses")
  })

  it("compra: su listado, el stock, la cuenta corriente del proveedor y por pagar", () => {
    const queryClient = new QueryClient()
    const spy = vi.spyOn(queryClient, "invalidateQueries")
    invalidateAfterOperationEdit(queryClient, "purchase")
    const r = roots(spy)
    for (const root of ["purchases", "products", "branchStock", "supplierAccounts", "payables"]) expect(r).toContain(root)
    expect(r).not.toContain("customerAccounts")
  })

  it("gasto: su listado y nada de cuentas corrientes ni stock", () => {
    const queryClient = new QueryClient()
    const spy = vi.spyOn(queryClient, "invalidateQueries")
    invalidateAfterOperationEdit(queryClient, "expense")
    const r = roots(spy)
    expect(r).toContain("expenses")
    for (const root of ["customerAccounts", "supplierAccounts", "branchStock", "products"]) expect(r).not.toContain(root)
  })

  it("las listas exportadas son las que se invalidan (un test no puede quedar atrás del código)", () => {
    for (const kind of ["sale", "purchase", "expense"] as const) {
      const queryClient = new QueryClient()
      const spy = vi.spyOn(queryClient, "invalidateQueries")
      invalidateAfterOperationEdit(queryClient, kind)
      expect([...OPERATION_EDIT_INVALIDATED_ROOTS[kind]].sort()).toEqual([...new Set(roots(spy))].sort())
    }
  })
})
