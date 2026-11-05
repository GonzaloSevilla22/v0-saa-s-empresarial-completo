import { describe, it, expect } from "vitest"
import { buildEditMoneyIntent, moneyIntentPayload } from "@/lib/money-intent"

// edicion-operaciones-con-dinero (tanda C, D6/D7/D9): el contrato tri-estado por AUSENCIA. Una clave ausente = "conservar el
// efecto vigente"; presente —incluso con `null`— = intención explícita. El formulario manda `cash_session_id`,
// `bank_account_id` y `due_date` SÓLO cuando el usuario cambió algo.

const BASE = {
  cash: { finalKindIsCash: true, hadCash: false, registerInCash: false, branchChanged: false, eligible: true, sessionId: "ses-1" },
  bank: { touched: false, kindIsBank: false, value: null as string | null },
  due: { touched: false, isCredit: false, value: "" },
  reason: "",
}

describe("buildEditMoneyIntent — caja", () => {
  it("sin huella de caja y sin tildar: no manda nada (el plan no escribe en la caja)", () => {
    expect(buildEditMoneyIntent(BASE)).toEqual({})
  })

  it("sin huella y tildando 'Registrar en caja': manda la sesión abierta", () => {
    const intent = buildEditMoneyIntent({ ...BASE, cash: { ...BASE.cash, registerInCash: true } })
    expect(intent).toEqual({ cashSessionId: "ses-1" })
  })

  it("con huella y sin tocar nada: NO manda la clave (conserva lo vigente, aunque la fecha ya no sea hoy)", () => {
    const intent = buildEditMoneyIntent({ ...BASE, cash: { ...BASE.cash, hadCash: true, registerInCash: true } })
    expect("cashSessionId" in intent).toBe(false)
  })

  it("con huella y destildando: manda null explícito (saca la operación de la caja)", () => {
    const intent = buildEditMoneyIntent({ ...BASE, cash: { ...BASE.cash, hadCash: true, registerInCash: false } })
    expect("cashSessionId" in intent).toBe(true)
    expect(intent.cashSessionId).toBeNull()
  })

  it("con huella, tildado y la sucursal cambió: manda la sesión de la sucursal nueva", () => {
    const intent = buildEditMoneyIntent({
      ...BASE,
      cash: { ...BASE.cash, hadCash: true, registerInCash: true, branchChanged: true, sessionId: "ses-nueva" },
    })
    expect(intent).toEqual({ cashSessionId: "ses-nueva" })
  })

  it("con huella y sin sesión abierta (no elegible): no manda la clave — el plan nombra el bloqueo, no lo inventa el formulario", () => {
    const intent = buildEditMoneyIntent({ ...BASE, cash: { ...BASE.cash, hadCash: true, registerInCash: true, eligible: false, sessionId: null } })
    expect("cashSessionId" in intent).toBe(false)
  })

  it("si la forma de pago final no es efectivo, la caja no se toca desde el formulario (el plan compensa lo que haya)", () => {
    const intent = buildEditMoneyIntent({ ...BASE, cash: { ...BASE.cash, finalKindIsCash: false, hadCash: true, registerInCash: false } })
    expect("cashSessionId" in intent).toBe(false)
  })
})

describe("buildEditMoneyIntent — banco, vencimiento y motivo", () => {
  it("la cuenta bancaria viaja sólo si el usuario la tocó y la forma de pago es bancaria", () => {
    expect(buildEditMoneyIntent({ ...BASE, bank: { touched: true, kindIsBank: true, value: "ba-1" } })).toEqual({ bankAccountId: "ba-1" })
    expect(buildEditMoneyIntent({ ...BASE, bank: { touched: false, kindIsBank: true, value: "ba-1" } })).toEqual({})
    expect(buildEditMoneyIntent({ ...BASE, bank: { touched: true, kindIsBank: false, value: "ba-1" } })).toEqual({})
  })

  it("volver a 'usar el destino configurado' manda null explícito", () => {
    const intent = buildEditMoneyIntent({ ...BASE, bank: { touched: true, kindIsBank: true, value: null } })
    expect("bankAccountId" in intent).toBe(true)
    expect(intent.bankAccountId).toBeNull()
  })

  it("el vencimiento viaja sólo si se tocó y la forma de pago es a crédito; vaciarlo manda null", () => {
    expect(buildEditMoneyIntent({ ...BASE, due: { touched: true, isCredit: true, value: "2026-12-15" } })).toEqual({ dueDate: "2026-12-15" })
    expect(buildEditMoneyIntent({ ...BASE, due: { touched: false, isCredit: true, value: "2026-12-15" } })).toEqual({})
    expect(buildEditMoneyIntent({ ...BASE, due: { touched: true, isCredit: false, value: "2026-12-15" } })).toEqual({})
    const vacio = buildEditMoneyIntent({ ...BASE, due: { touched: true, isCredit: true, value: "" } })
    expect("dueDate" in vacio).toBe(true)
    expect(vacio.dueDate).toBeNull()
  })

  it("el motivo se manda recortado y sólo si no está vacío", () => {
    expect(buildEditMoneyIntent({ ...BASE, reason: "  Importe cargado de más  " })).toEqual({ reason: "Importe cargado de más" })
    expect(buildEditMoneyIntent({ ...BASE, reason: "   " })).toEqual({})
  })
})

describe("moneyIntentPayload — a las claves del contrato HTTP, ausentes cuando no se tocaron", () => {
  it("sólo emite las claves presentes en la intención, incluso las que valen null", () => {
    const payload = moneyIntentPayload({ cashSessionId: null, dueDate: "2026-12-01", reason: "x" })
    expect(payload).toEqual({ cash_session_id: null, due_date: "2026-12-01", reason: "x" })
    expect(Object.keys(payload)).not.toContain("bank_account_id")
  })

  it("una intención vacía no agrega ninguna clave", () => {
    expect(moneyIntentPayload({})).toEqual({})
  })
})
