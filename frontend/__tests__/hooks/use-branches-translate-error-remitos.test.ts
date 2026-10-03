/**
 * remitos-venta (D10, tarea 4.10) — `translateRpcError` de
 * `hooks/data/use-branches.ts` gana el cuarto token de `P0428`:
 * `branch_has_pending_delivery_notes` (la baja con un remito pendiente, venta o
 * compra, en la sucursal). Importa la función REAL, como
 * `use-branches-translate-error.test.ts`; los tres tokens previos no se mueven.
 */
import { describe, it, expect } from "vitest"

import { translateRpcError } from "@/hooks/data/use-branches"

describe("translateRpcError — branch_has_pending_delivery_notes (P0428)", () => {
  const RAW =
    "branch_has_pending_delivery_notes: la sucursal tiene 2 remito(s) pendiente(s) — convertilos en venta o anulalos (un administrador o el dueño) antes de darla de baja"

  it("traduce a un mensaje que nombra los remitos y la salida", () => {
    expect(translateRpcError(RAW)).toBe(
      "La sucursal tiene remitos pendientes. Convertilos en venta o anulalos (un administrador o el dueño) antes de darla de baja.",
    )
  })

  it("no se confunde con los otros motivos de P0428 (stock, caja, transferencias)", () => {
    const msg = translateRpcError(RAW)
    expect(msg).not.toMatch(/stock/i)
    expect(msg).not.toMatch(/sesión de caja/i)
    expect(msg).not.toMatch(/transferencias/i)
  })

  it("el mensaje crudo con otro texto después del token se traduce igual (se discrimina por token)", () => {
    expect(translateRpcError("branch_has_pending_delivery_notes")).toContain("remitos pendientes")
  })

  it("los tres tokens previos siguen traduciendo a lo suyo", () => {
    expect(translateRpcError("branch_has_stock: la sucursal tiene 585 unidades")).toContain("stock")
    expect(translateRpcError("branch_has_open_cash_session: …")).toContain("sesión de caja")
    expect(translateRpcError("branch_has_pending_transfers: …")).toContain("transferencias")
  })

  it("un mensaje desconocido vuelve tal cual", () => {
    expect(translateRpcError("algo raro")).toBe("algo raro")
  })
})
