import { describe, it, expect } from "vitest"
import {
  describeBlock,
  moneyPlanItems,
  moneyPlanHasEffect,
  summarizeEdit,
  summarizeExecutedPlan,
  voidedFiscalText,
  type MoneyPlan,
} from "@/lib/money-plan"
import { formatMoney } from "@/lib/format"

// edicion-operaciones-con-dinero (tanda C, D13/D17): UNA sola redacción del plan por libro, consumida por el diálogo
// de edición y por el de borrado. El sentido (entra o sale de la caja) sale del signo del importe que calculó el
// servidor: la interfaz nunca recalcula el plan.

const EMPTY: MoneyPlan = {
  writes_money: false,
  blocks: [],
  account: { action: "none", party_kind: null, register: null, reverse: [], current_balance: null, projected_balance: null, current_due_date: null },
  cash: { action: "none", register: null, reverse: [] },
  bank: { action: "none", register: null, reverse: [] },
}

function plan(over: Partial<MoneyPlan>): MoneyPlan {
  return { ...EMPTY, ...over }
}

const m = (n: number) => formatMoney(n)

describe("moneyPlanItems — el plan por libro, con el sentido real del dinero", () => {
  it("un plan sin acciones no enumera nada", () => {
    expect(moneyPlanItems(EMPTY, { party: "cliente" })).toEqual([])
    expect(moneyPlanHasEffect(EMPTY)).toBe(false)
  })

  it("venta a crédito que sube: revierte el cargo viejo y registra el nuevo, con vencimiento y saldo proyectado", () => {
    const p = plan({
      writes_money: true,
      account: {
        action: "both",
        party_kind: "customer",
        register: { party_id: "c1", amount: "1200.00", due_date: "2026-12-15", reference_id: "r2" },
        reverse: [{ ledger_id: "l1", net: "1000.00", reference_id: "r1" }],
        current_balance: "1000.00",
        projected_balance: "1200.00",
        current_due_date: "2026-12-01",
      },
    })
    const items = moneyPlanItems(p, { party: "cliente" })
    const texts = items.map((i) => i.text).join(" | ")
    expect(items.every((i) => i.book === "account")).toBe(true)
    expect(texts).toContain(m(1000))
    expect(texts).toMatch(/revertir/i)
    expect(texts).toContain(m(1200))
    expect(texts).toMatch(/cuenta corriente del cliente/i)
    expect(texts).toContain("15/12/2026")
  })

  it("compra a crédito: nombra al proveedor, no al cliente; y un cargo sin vencimiento lo dice", () => {
    const p = plan({
      writes_money: true,
      account: {
        action: "register",
        party_kind: "supplier",
        register: { party_id: "s1", amount: 500, due_date: null, reference_id: "r2" },
        reverse: [],
        current_balance: 0,
        projected_balance: 500,
        current_due_date: null,
      },
    })
    const texts = moneyPlanItems(p, { party: "proveedor" }).map((i) => i.text).join(" | ")
    expect(texts).toMatch(/proveedor/i)
    expect(texts).not.toMatch(/cliente/i)
    expect(texts).toMatch(/sin vencimiento/i)
  })

  it("caja de una VENTA: registrar entra a la caja; compensar lo que había entrado, sale", () => {
    const entra = plan({ writes_money: true, cash: { action: "register", register: { session_id: "s", cashbox_id: "b", amount: 1500, movement_type: "sale" }, reverse: [] } })
    const sale = plan({ writes_money: true, cash: { action: "reverse", register: null, reverse: [{ cashbox_id: "b", session_id: "s", net: 1000, reference_id: "r", movement_type: "sale_reversal" }] } })
    const a = moneyPlanItems(entra, { party: "cliente" })[0].text
    const b = moneyPlanItems(sale, { party: "cliente" })[0].text
    expect(a).toMatch(/entran/i)
    expect(a).toContain(m(1500))
    expect(a).toMatch(/caja/i)
    expect(b).toMatch(/salen/i)
    expect(b).toContain(m(1000))
  })

  it("caja de una COMPRA o un GASTO: registrar sale de la caja; compensar lo que había salido, vuelve", () => {
    const sale = plan({ writes_money: true, cash: { action: "register", register: { session_id: "s", cashbox_id: "b", amount: -800, movement_type: "expense" }, reverse: [] } })
    const vuelve = plan({ writes_money: true, cash: { action: "reverse", register: null, reverse: [{ cashbox_id: "b", session_id: "s", net: -800, reference_id: "r", movement_type: "expense_reversal" }] } })
    const a = moneyPlanItems(sale, { party: "proveedor" })[0].text
    const b = moneyPlanItems(vuelve, { party: "proveedor" })[0].text
    expect(a).toMatch(/salen/i)
    expect(a).toContain(m(800)) // sin signo: el sentido va en el verbo
    expect(a).not.toContain("-")
    expect(b).toMatch(/vuelven/i)
    expect(b).toContain(m(800))
  })

  it("corrección en un libro a la vez (both): enumera la compensación y el registro nuevo, en ese orden", () => {
    const p = plan({
      writes_money: true,
      cash: {
        action: "both",
        register: { session_id: "s2", cashbox_id: "b", amount: -300, movement_type: "expense" },
        reverse: [{ cashbox_id: "b", session_id: "s2", net: -500, reference_id: "r", movement_type: "expense_reversal" }],
      },
    })
    const items = moneyPlanItems(p, { party: "proveedor" })
    expect(items).toHaveLength(2)
    expect(items[0].text).toContain(m(500))
    expect(items[1].text).toContain(m(300))
  })

  it("banco: ingreso o egreso según el signo, pendiente de conciliar", () => {
    const egreso = plan({ writes_money: true, bank: { action: "register", register: { bank_account_id: "ba", amount: -900, family: "transfer", reference_id: "r", value_date: "2026-11-02" }, reverse: [] } })
    const inverso = plan({ writes_money: true, bank: { action: "reverse", register: null, reverse: [{ bank_account_id: "ba", family: "transfer", net: 400, mirror_type: "x", reference_id: "r", branch_id: null }] } })
    const a = moneyPlanItems(egreso, { party: "proveedor" })[0]
    const b = moneyPlanItems(inverso, { party: "cliente" })[0]
    expect(a.book).toBe("bank")
    expect(a.text).toMatch(/egreso/i)
    expect(a.text).toContain(m(900))
    expect(b.text).toMatch(/inverso/i)
    expect(b.text).toContain(m(400))
    expect(b.text).toMatch(/conciliar/i)
  })
})

describe("describeBlock — el motivo del bloqueo, en lenguaje del usuario", () => {
  const block = (token: string, message: string, book = "cash", code = "P0426") => ({ book, code, token, message })

  it("sin sesión abierta (P0426): pide abrir la caja", () => {
    const t = describeBlock(block("no_open_session_for_reversal", "no_open_session_for_reversal: abrí la caja…"))
    expect(t).toMatch(/abr[ií] la caja/i)
  })

  it("saldo que quedaría negativo (P0425): nombra el saldo y el camino (anular el cobro desde la cuenta corriente)", () => {
    const t = describeBlock(
      block("reversal_would_go_negative", "reversal_would_go_negative: el saldo de la cuenta corriente quedaría en -150.00: ya se registraron cobros", "account", "P0425"),
      { party: "cliente" },
    )
    expect(t).toContain(m(150))
    expect(t).toMatch(/anul[aá] primero el cobro/i)
  })

  it("saldo negativo en una compra: habla del pago, no del cobro", () => {
    const t = describeBlock(
      block("reversal_would_go_negative", "reversal_would_go_negative: el saldo de la cuenta corriente quedaría en -20.50: ya", "account", "P0425"),
      { party: "proveedor" },
    )
    expect(t).toMatch(/anul[aá] primero el pago/i)
    expect(t).toContain(m(20.5))
  })

  it("período conciliado (P0424): lo dice y sugiere el ajuste manual", () => {
    const t = describeBlock(block("bank_period_reconciled", "bank_period_reconciled: la fecha 2026-10-02 cae", "bank", "P0424"))
    expect(t).toMatch(/per[ií]odo (bancario )?conciliado/i)
    expect(t).toMatch(/ajuste/i)
  })

  it("solo dueño o administrador (P0403)", () => {
    const t = describeBlock(block("money_edit_requires_admin", "money_edit_requires_admin: …", "role", "P0403"))
    expect(t).toMatch(/due[ñn]o o un administrador/i)
  })

  it("un token que no conoce usa el mensaje del servidor SIN el prefijo técnico", () => {
    const t = describeBlock(block("token_nuevo", "token_nuevo: algo que el servidor sabe decir", "cash", "P0400"))
    expect(t).toBe("algo que el servidor sabe decir")
  })
})

describe("voidedFiscalText — única redacción del comprobante que se anula", () => {
  it("nombra el comprobante y avisa que se puede volver a emitir", () => {
    const t = voidedFiscalText("0003-00000005")
    expect(t).toContain("0003-00000005")
    expect(t).toMatch(/anulará el comprobante pendiente/i)
    expect(t).toMatch(/volver a emitirlo/i)
  })
})

describe("summarizeExecutedPlan — lo que el SERVIDOR dijo que hizo", () => {
  it("sin efectos: null (el toast no agrega nada)", () => {
    expect(summarizeExecutedPlan(EMPTY, { party: "cliente" })).toBeNull()
    expect(summarizeExecutedPlan(null, { party: "cliente" })).toBeNull()
  })

  it("con efectos: una línea con los libros tocados", () => {
    const p = plan({ writes_money: true, cash: { action: "register", register: { session_id: "s", cashbox_id: "b", amount: 200, movement_type: "sale" }, reverse: [] } })
    const t = summarizeExecutedPlan(p, { party: "cliente" })
    expect(t).toMatch(/caja/i)
    expect(t).toContain(m(200))
  })
})

describe("summarizeEdit — el resumen de una entrada del historial", () => {
  it("total cambiado + caja: 'Total $1.000 → $1.200; …'", () => {
    const s = summarizeEdit(
      {
        before: { total: "1000.00", date: "2026-11-01" },
        after: { total: "1200.00", date: "2026-11-01" },
        money: plan({ writes_money: true, cash: { action: "register", register: { session_id: "s", cashbox_id: "b", amount: 200, movement_type: "sale" }, reverse: [] } }),
        reason: null,
      },
      "venta",
    )
    expect(s).toContain(`Total ${m(1000)} → ${m(1200)}`)
    expect(s).toMatch(/caja/i)
  })

  it("gasto: el importe se llama 'Importe'; también cambia la fecha y el motivo se muestra", () => {
    const s = summarizeEdit(
      {
        before: { amount: 500, date: "2026-10-30" },
        after: { amount: 300, date: "2026-11-02" },
        money: null,
        reason: "Cargado de más",
      },
      "gasto",
    )
    expect(s).toContain(`Importe ${m(500)} → ${m(300)}`)
    expect(s).toContain("30/10/2026")
    expect(s).toContain("02/11/2026")
    expect(s).toContain("Cargado de más")
  })

  it("una edición que no cambió nada visible lo dice, sin inventar", () => {
    const s = summarizeEdit({ before: { total: 100 }, after: { total: 100 }, money: null, reason: null }, "venta")
    expect(s).toBe("Sin cambios de importe ni de fecha.")
  })
})
