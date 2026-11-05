import { describe, it, expect } from "vitest"
import { humanizeOperationError } from "@/lib/operation-errors"

// edicion-operaciones-con-dinero (tanda C, 15.2): los rechazos de la EDICIÓN con dinero llegan como `token: texto`
// (RFC 7807 con `code` estable). Ninguno debe mostrarse crudo, y los que ya existían para el borrado
// (P0426 / P0424) cambian de redacción en contexto de edición: «no se pudo guardar», no «no se pudo anular».

const EDIT = { intent: "edit" } as const

describe("humanizeOperationError — edición con dinero (P0425 saldo negativo)", () => {
  const RAW =
    "reversal_would_go_negative: el saldo de la cuenta corriente quedaría en -150.00: ya se registraron cobros o pagos por esta operación — anulá primero el cobro o el pago desde la cuenta corriente"

  it("dice cuánto quedaría y el camino, sin el literal interno, y que no se guardó nada", () => {
    const { message } = humanizeOperationError(RAW, undefined, undefined, { ...EDIT, party: "cliente" })
    expect(message).not.toContain("reversal_would_go_negative")
    expect(message).toMatch(/150/)
    expect(message).toMatch(/anul[aá] primero el cobro/i)
    expect(message).toMatch(/no se guard[oó] ning[uú]n cambio/i)
  })

  it("en una compra habla del pago", () => {
    const { message } = humanizeOperationError(RAW, undefined, undefined, { ...EDIT, party: "proveedor" })
    expect(message).toMatch(/anul[aá] primero el pago/i)
  })

  it("el token se reconoce aunque el formulario no pase contexto (nunca crudo)", () => {
    const { message } = humanizeOperationError(RAW)
    expect(message).not.toContain("reversal_would_go_negative")
  })
})

describe("humanizeOperationError — edición con dinero (P0426 sin sesión abierta)", () => {
  const RAW = "no_open_session_for_reversal: abrí la caja para poder corregir esta operación — el efectivo ya registrado se compensa en la sesión abierta de la misma caja"

  it("en edición pide abrir la caja para corregir y ofrece ir a Caja", () => {
    const { message, action } = humanizeOperationError(RAW, undefined, undefined, EDIT)
    expect(message).toMatch(/abr[ií] la caja/i)
    expect(message).toMatch(/corregir/i)
    expect(message).not.toMatch(/anular/i)
    expect(message).toMatch(/no se guard[oó] ning[uú]n cambio/i)
    expect(action).toEqual({ label: "Ir a Caja", href: "/caja" })
  })

  it("fuera de edición conserva la redacción del borrado/anulación", () => {
    const { message } = humanizeOperationError(RAW)
    expect(message).toMatch(/anular/i)
  })
})

describe("humanizeOperationError — edición con dinero (P0424 período conciliado)", () => {
  const RAW = "bank_period_reconciled: la fecha 2026-10-02 cae dentro de un período ya conciliado y cerrado de la cuenta bancaria — registrá el ajuste como movimiento bancario manual"

  it("en edición dice que no se guardó nada y sugiere el ajuste manual", () => {
    const { message } = humanizeOperationError(RAW, undefined, undefined, EDIT)
    expect(message).toMatch(/per[ií]odo (bancario )?conciliado/i)
    expect(message).toMatch(/ajuste/i)
    expect(message).toMatch(/no se guard[oó] ning[uú]n cambio/i)
  })

  it("fuera de edición mantiene el texto de siempre ('no se registró nada')", () => {
    const { message } = humanizeOperationError(RAW)
    expect(message).toMatch(/no se registr[oó] nada/i)
  })
})

describe("humanizeOperationError — tokens nuevos de la edición", () => {
  it.each([
    ["money_edit_requires_admin: solo el dueño o un administrador corrigen dinero ya registrado — esta edición modifica la caja", /due[ñn]o o un administrador/i],
    ["cash_intent_required: la sucursal cambió y una sucursal puede tener varias cajas — indicá en qué sesión de caja se registra el efectivo", /sesi[oó]n de caja/i],
    ["cash_optin_requires_today: sólo se puede registrar en caja una operación fechada hoy", /fechad[ao] hoy/i],
    ["cash_optin_requires_cash_kind: sólo un pago en efectivo puede registrarse en la caja", /efectivo/i],
    ["due_date_before_charge: el vencimiento (2026-10-01) no puede ser anterior a la fecha del cargo (2026-10-05)", /vencimiento/i],
    ["credit_requires_client: una venta a crédito necesita un cliente identificado para cargar su cuenta corriente", /cliente/i],
    ["credit_requires_supplier: una compra a crédito necesita un proveedor identificado para cargar su cuenta corriente", /proveedor/i],
    ["bank_account_required_for_expense: elegí la cuenta bancaria de la que sale el dinero — sin ella el gasto no aparecería", /cuenta bancaria/i],
    ["bank_account_requires_bank_kind: se informó una cuenta bancaria explícita para un kind no bancario (cash)", /cuenta bancaria/i],
  ])("%s", (raw, expected) => {
    const { message } = humanizeOperationError(raw, undefined, undefined, EDIT)
    expect(message).toMatch(expected)
    // nunca el token técnico ni un uuid
    expect(message).not.toMatch(/[a-z]+_[a-z_]+:/)
    expect(message).toMatch(/no se guard[oó] ning[uú]n cambio/i)
  })
})
