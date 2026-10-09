import { describe, it, expect, vi } from "vitest"
import { humanizeOperationError } from "@/lib/operation-errors"

// ventas-formulario-sucursal (ronda 1 de revisión): desde que el alta del
// formulario de venta entrega la sucursal elegida a la RPC, los rechazos por
// sucursal dejaron de ser inalcanzables. El selector lista las sucursales con
// `is_active = true`, y una sucursal CERRADA (`rpc_close_branch` pone
// `status = 'closed'` y deja `is_active = true`) sigue apareciendo ahí. Los
// textos son los RAISE literales de las RPCs vivas:
//   - rpc_create_sale_operation_v2 (alta): `branch_closed: …` (P0422) y
//     `branch_not_found or not active for this account` (P0404);
//   - rpc_apply_product_stock_delta (borrado / reverso de stock):
//     `branch_closed: …` (P0422);
//   - rpc_atomic_update_sale_operation (edición): `branch_invalid: …` (P0422).

describe("humanizeOperationError — rechazos por sucursal", () => {
  it("branch_closed (alta o borrado en una sucursal cerrada) → explica la salida, sin el token interno", () => {
    const { message, action } = humanizeOperationError("branch_closed: la sucursal está cerrada")
    expect(message).toMatch(/la sucursal está cerrada/i)
    expect(message).toMatch(/eleg[ií] otra sucursal/i)
    expect(message).toMatch(/reabrila/i)
    expect(message).not.toContain("branch_closed")
    expect(action).toBeUndefined()
  })

  it("branch_not_found (sucursal ajena o desactivada en el alta) → invita a elegir otra, sin el texto crudo en inglés", () => {
    const { message, action } = humanizeOperationError("branch_not_found or not active for this account")
    expect(message).toMatch(/no existe, está desactivada o no pertenece a esta cuenta/i)
    expect(message).toMatch(/eleg[ií] otra sucursal/i)
    expect(message).not.toMatch(/branch_not_found|not active for this account/)
    expect(action).toBeUndefined()
  })

  it("branch_invalid (edición con la sucursal ya cerrada o desactivada) → mismo tipo de salida, sin el token", () => {
    const { message, action } = humanizeOperationError(
      "branch_invalid: la sucursal no pertenece a la cuenta o no está operativa",
    )
    expect(message).toMatch(/cerrada o desactivada/i)
    expect(message).toMatch(/eleg[ií] otra sucursal/i)
    expect(message).not.toContain("branch_invalid")
    expect(action).toBeUndefined()
  })

  it("no atrapa tokens parecidos de otro dominio: `no_branch_found` del POS sigue pasando tal cual", () => {
    const raw = "no_branch_found: la cuenta no tiene sucursal activa"
    const { message, action } = humanizeOperationError(raw)
    expect(message).toBe(raw)
    expect(action).toBeUndefined()
  })

  it("el stock insuficiente de la sucursal elegida sigue siendo el mensaje de stock con la acción de transferir", () => {
    const productId = "0dd2e5bb-2b93-4470-b4b6-52f008046112"
    const { message, action } = humanizeOperationError(
      `insufficient_branch_stock for product ${productId}`,
      () => "Remera Lisa",
      "Sucursal Humo",
    )
    expect(message).toContain("«Remera Lisa»")
    expect(message).toContain("Sucursal Humo")
    expect(message).not.toMatch(/sucursal está cerrada/i)
    expect(action).toEqual({ label: "Transferir stock", href: `/stock?product=${productId}` })
  })
})

// ── stock-ledger-solo-rpc (tanda B, task 11.3) ─────────────────────────────────
// `translateBranchStockError` (inventario por sucursal y transferencias) tenía su
// propio mapa de cinco textos y devolvía CRUDO todo lo demás: el rechazo por rol
// (`insufficient_role`) y por motivo (`stock_adjustment_reason_required`) que
// introduce el núcleo de ajuste manual habría llegado como token en inglés. Ahora
// delega en el mapa canónico lo que no reconoce (regla del proyecto: extender el
// mapa, no duplicarlo).

vi.mock("@/lib/supabase/client", () => ({ createClient: () => ({}) }))
vi.mock("@/contexts/auth-context", () => ({ useAuth: () => ({ user: null }) }))

import { translateBranchStockError } from "@/hooks/data/use-branch-stock"

describe("translateBranchStockError — delega en el mapa canónico lo que no reconoce", () => {
  it("rol que no ajusta stock (P0403 insufficient_role) → quién puede, en castellano, sin el token", () => {
    const msg = translateBranchStockError(
      "insufficient_role: tu rol no permite ajustar el stock a mano (requiere depósito, administrador o dueño)",
    )
    expect(msg).toMatch(/ajustar el stock/i)
    expect(msg).toMatch(/dep[óo]sito/i)
    expect(msg).not.toContain("insufficient_role")
  })

  it("motivo vacío (P0400) → pide el motivo", () => {
    const msg = translateBranchStockError("stock_adjustment_reason_required: el ajuste de stock requiere un motivo")
    expect(msg).toMatch(/motivo/i)
    expect(msg).not.toContain("stock_adjustment_reason_required")
  })

  it("producto de otra cuenta (P0404) → castellano del contexto de ajuste", () => {
    const msg = translateBranchStockError("product_not_found: el producto no existe o no pertenece a tu cuenta")
    expect(msg).toMatch(/no pertenece a tu cuenta/i)
    expect(msg).not.toMatch(/uno de los productos/i)
    expect(msg).not.toContain("product_not_found")
  })

  it("lo que ya traducía sigue exactamente igual", () => {
    expect(translateBranchStockError("insufficient_branch_stock: origin has 1, requested 5")).toBe(
      "Stock insuficiente en esta sucursal.",
    )
    expect(translateBranchStockError("same_branch_transfer_not_allowed")).toBe(
      "El origen y destino de la transferencia deben ser diferentes.",
    )
    expect(translateBranchStockError("branch_not_found for this account")).toBe("La sucursal no existe o no está activa.")
    expect(translateBranchStockError("unauthorized")).toBe("No tenés permisos para realizar esta acción.")
    expect(translateBranchStockError("Quantity must be greater than zero")).toBe("La cantidad debe ser mayor a cero.")
    expect(translateBranchStockError("New quantity must be >= 0")).toBe("La cantidad no puede ser negativa.")
  })

  it("un error NO reconocido se devuelve tal cual; el vacío, el genérico de siempre", () => {
    expect(translateBranchStockError("algo que nadie previó")).toBe("algo que nadie previó")
    expect(translateBranchStockError("")).toBe("Ocurrió un error inesperado.")
  })
})
