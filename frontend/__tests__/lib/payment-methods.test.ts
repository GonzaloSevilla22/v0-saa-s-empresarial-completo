/**
 * Regresión prod 2026-08-24: compra a cuenta corriente rechazada con
 * `bank_account_requires_bank_kind` porque el formulario mandaba la cuenta
 * bancaria elegida para un método anterior después de cambiar a `credit`.
 */
import { describe, expect, it } from "vitest"

import { bankAccountForKind, isBankPaymentKind } from "@/lib/types"

const CUENTA = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

describe("isBankPaymentKind", () => {
  it.each(["transfer", "card", "check", "wallet"] as const)("%s es bancario", (kind) => {
    expect(isBankPaymentKind(kind)).toBe(true)
  })

  it.each(["cash", "credit", "other"] as const)("%s NO es bancario", (kind) => {
    expect(isBankPaymentKind(kind)).toBe(false)
  })

  it("null/undefined no son bancarios", () => {
    expect(isBankPaymentKind(null)).toBe(false)
    expect(isBankPaymentKind(undefined)).toBe(false)
  })
})

describe("bankAccountForKind", () => {
  it("EL BUG: kind credit con una cuenta viva en el estado → no viaja", () => {
    expect(bankAccountForKind("credit", CUENTA)).toBeNull()
  })

  it.each(["cash", "other"] as const)("kind %s tampoco arrastra la cuenta", (kind) => {
    expect(bankAccountForKind(kind, CUENTA)).toBeNull()
  })

  it.each(["transfer", "card", "check", "wallet"] as const)(
    "kind %s sí informa la cuenta elegida",
    (kind) => {
      expect(bankAccountForKind(kind, CUENTA)).toBe(CUENTA)
    },
  )

  it("kind bancario sin cuenta elegida → null (usa el destino configurado)", () => {
    expect(bankAccountForKind("transfer", null)).toBeNull()
  })

  it("sin forma de pago elegida → null", () => {
    expect(bankAccountForKind(null, CUENTA)).toBeNull()
  })
})
