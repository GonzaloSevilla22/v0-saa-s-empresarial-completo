/**
 * sucursal-guard-vaciado-auditoria (G1, task 6.1/6.2): la traducción REAL de
 * frontend/hooks/data/use-branches.ts gana los tres tokens nuevos de P0428
 * (branch_has_stock ya existía; branch_has_open_cash_session,
 * branch_has_pending_transfers y branch_delete_forbidden son nuevos) sin
 * romper ninguno de los casos existentes. Importa la función REAL (ahora
 * exportada) en vez de duplicarla — a diferencia de __tests__/branches.test.ts,
 * que quedó desactualizado por duplicar la lógica.
 */
import { describe, it, expect } from "vitest"

import { translateRpcError } from "@/hooks/data/use-branches"

describe("translateRpcError — sucursal-guard-vaciado-auditoria (P0428)", () => {
  it("branch_has_stock (existente, ahora unificado con P0428) sigue traduciendo", () => {
    const msg = translateRpcError(
      "branch_has_stock: la sucursal tiene 585 unidades en 518 producto(s) — transferí el stock a otra sucursal antes de darla de baja",
    )
    expect(msg).toContain("stock")
    expect(msg.toLowerCase()).toContain("transferi")
  })

  it("branch_has_open_cash_session traduce a un mensaje propio", () => {
    const msg = translateRpcError(
      "branch_has_open_cash_session: la sucursal tiene una sesión de caja abierta — cerrala antes de darla de baja",
    )
    expect(msg).toContain("sesión de caja")
    expect(msg).not.toContain("stock")
  })

  it("branch_has_pending_transfers traduce a un mensaje propio", () => {
    const msg = translateRpcError(
      "branch_has_pending_transfers: la sucursal tiene 2 transferencia(s) de stock sin completar",
    )
    expect(msg).toContain("transferencias")
    expect(msg).not.toContain("sesión de caja")
  })

  it("branch_delete_forbidden traduce nombrando la desactivación", () => {
    const msg = translateRpcError(
      "branch_delete_forbidden: el borrado físico de una sucursal está prohibido — desactivala en su lugar",
    )
    expect(msg.toLowerCase()).toContain("desactiv")
  })

  it("last_active_branch sigue funcionando (no se tocó)", () => {
    expect(translateRpcError("last_active_branch: no se puede cerrar la única sucursal operativa"))
      .toBe("No podés cerrar la única sucursal operativa de tu cuenta.")
  })

  it("un error no reconocido se devuelve intacto", () => {
    const original = "some_unmapped_error: detalle"
    expect(translateRpcError(original)).toBe(original)
  })
})
