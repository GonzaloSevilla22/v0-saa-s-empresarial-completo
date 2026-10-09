import { describe, it, expect } from "vitest"
import { humanizeOperationError } from "@/lib/operation-errors"

// stock-ledger-solo-rpc (tanda B, task 11.2): los rechazos del núcleo único de
// ajuste manual de stock. Los textos de entrada son los RAISE literales de la
// migración 20261074000001 (`_stock_manual_adjustment`, `_stock_apply_delta`,
// `rpc_apply_product_stock_delta`) tal como los entrega PostgREST en
// `error.message`, y el 422 `stock_adjust_required` del backend. Mismo mapa que
// venta, compra, presupuesto y remito — NO un segundo mapa.

const CTX = { documentLabel: "ajuste de stock" } as const

describe("humanizeOperationError — ajuste manual de stock", () => {
  it("stock_adjustment_reason_required → pide el motivo y dice que no se guardó nada", () => {
    const { message, action } = humanizeOperationError(
      "stock_adjustment_reason_required: el ajuste de stock requiere un motivo",
      undefined,
      undefined,
      CTX,
    )
    expect(message).toMatch(/motivo/i)
    expect(message).toMatch(/no se (guardó|registró) nada/i)
    expect(message).not.toContain("stock_adjustment_reason_required")
    expect(action).toBeUndefined()
  })

  it("stock_adjustment_type_invalid (transferencia como ajuste) → deriva a «Transferir stock»", () => {
    const { message, action } = humanizeOperationError(
      'stock_adjustment_type_invalid: tipo de ajuste manual no válido (transfer_in). Una transferencia entre sucursales se registra con "Transferir stock".',
      undefined,
      undefined,
      CTX,
    )
    expect(message).toMatch(/transferencia/i)
    expect(message).toMatch(/transferir stock/i)
    expect(message).not.toContain("stock_adjustment_type_invalid")
    expect(message).not.toContain("transfer_in")
    expect(action).toEqual({ label: "Transferir stock", href: "/stock" })
  })

  it("stock_adjustment_product_not_adjustable → se ajusta por variantes, sin el token ni el tipo de control crudo", () => {
    const { message, action } = humanizeOperationError(
      "stock_adjustment_product_not_adjustable: este producto no permite ajuste manual de stock (control = variant_only). Los productos con variantes se ajustan por sus variantes; los que no controlan stock no tienen existencias.",
      undefined,
      undefined,
      CTX,
    )
    expect(message).toMatch(/variantes/i)
    expect(message).not.toContain("stock_adjustment_product_not_adjustable")
    expect(message).not.toContain("variant_only")
    expect(action).toBeUndefined()
  })

  it("stock_adjustment_sign_invalid → explica que pérdida/rotura/vencimiento sólo restan", () => {
    const { message } = humanizeOperationError(
      "stock_adjustment_sign_invalid: un ajuste de pérdida sólo puede restar stock (cantidad negativa)",
      undefined,
      undefined,
      CTX,
    )
    expect(message).toMatch(/restan|restar/i)
    expect(message).not.toContain("stock_adjustment_sign_invalid")
  })

  it("stock_internal_flags_not_allowed → mensaje genérico en castellano, sin el token", () => {
    const { message, action } = humanizeOperationError(
      "stock_internal_flags_not_allowed: p_log_movement y p_allow_negative no son configurables desde la API",
      undefined,
      undefined,
      CTX,
    )
    expect(message).toMatch(/actualiz/i)
    expect(message).not.toContain("stock_internal_flags_not_allowed")
    expect(message).not.toContain("p_log_movement")
    expect(action).toBeUndefined()
  })

  it("stock_adjust_required (422 del PUT /products) → deriva a «Ajustar stock»", () => {
    const { message, action } = humanizeOperationError("stock_adjust_required")
    expect(message).toMatch(/ajustar stock/i)
    expect(message).toMatch(/motivo/i)
    expect(action).toEqual({ label: "Ajustar stock", href: "/stock" })
  })

  it("stock_adjust_required también se reconoce dentro del detail del backend", () => {
    const { action } = humanizeOperationError("stock_adjust_required: El stock se ajusta desde «Ajustar stock», con un motivo.")
    expect(action).toEqual({ label: "Ajustar stock", href: "/stock" })
  })
})

describe("humanizeOperationError — insufficient_role en el contexto «ajuste de stock»", () => {
  const raw =
    "insufficient_role: tu rol no permite ajustar el stock a mano (requiere depósito, administrador o dueño)"

  it("nombra quién puede ajustar stock y no dice «vendedor»", () => {
    const { message } = humanizeOperationError(raw, undefined, undefined, CTX)
    expect(message).toMatch(/ajustar el stock/i)
    expect(message).toMatch(/dep[óo]sito/i)
    expect(message).toMatch(/administrador/i)
    expect(message).toMatch(/due[ñn]o/i)
    expect(message).not.toMatch(/vendedor/i)
    expect(message).not.toContain("insufficient_role")
  })

  it("fuera de ese contexto sigue diciendo lo de siempre (el rol de vendedor): ningún caller existente cambia", () => {
    const { message } = humanizeOperationError(raw)
    expect(message).toMatch(/rol de vendedor/i)
  })

  it("el 403 de require_account_role del backend (sin code) también cae en el texto del ajuste", () => {
    const { message } = humanizeOperationError("Rol de cuenta insuficiente: se requiere admin o owner o stock", undefined, undefined, CTX)
    expect(message).toMatch(/ajustar el stock/i)
    expect(message).not.toMatch(/vendedor/i)
  })
})

describe("humanizeOperationError — otros rechazos del ajuste de stock", () => {
  it("product_not_found en el contexto del ajuste → el producto no existe o no es de la cuenta (singular)", () => {
    const { message } = humanizeOperationError(
      "product_not_found: el producto no existe o no pertenece a tu cuenta",
      undefined,
      undefined,
      CTX,
    )
    expect(message).toMatch(/producto/i)
    expect(message).not.toMatch(/uno de los productos/i)
    expect(message).not.toContain("product_not_found")
  })

  it("«Stock insuficiente. Disponible: 5, delta: -9» → cuánto hay y cuánto se pidió restar", () => {
    const { message } = humanizeOperationError("Stock insuficiente. Disponible: 5.0000, delta: -9", undefined, undefined, CTX)
    expect(message).toMatch(/5/)
    expect(message).toMatch(/9/)
    expect(message).toMatch(/no alcanza|insuficiente/i)
    expect(message).not.toContain("delta")
  })

  it("el rechazo por stock de la sucursal principal de un conteo total ya está en castellano y pasa tal cual", () => {
    const raw = "El ajuste excede el stock de la sucursal principal (3.0000 disponibles). Usá el ajuste por sucursal."
    expect(humanizeOperationError(raw, undefined, undefined, CTX).message).toBe(raw)
  })

  it("un error NO reconocido se muestra tal cual (nunca se oculta)", () => {
    const raw = "algo que nadie previó 12345"
    const { message, action } = humanizeOperationError(raw, undefined, undefined, CTX)
    expect(message).toBe(raw)
    expect(action).toBeUndefined()
  })
})
