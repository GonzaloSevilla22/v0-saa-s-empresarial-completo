/**
 * metodos-pago-operaciones — Frontend unit tests (task 5.1 TDD RED→GREEN).
 * Espejo exacto de cost-center-dimension.test.ts.
 *
 * Tests cover:
 *   - mapPaymentMethod: API row → PaymentMethod domain object
 *   - Selector filter: only active methods shown in new-entry forms
 *   - Role gating: CRUD visible only to owner/admin (member reads, doesn't write)
 *   - Mutation payloads: create/update send correct data
 *   - kind vocabulary: closed set (D2)
 */
import { describe, it, expect } from "vitest"
import type { PaymentMethod, PaymentMethodKind } from "@/lib/types"

// ── Pure functions extracted from the hook for isolated testing ──────────────

interface PaymentMethodApiRow {
  id: string
  account_id: string
  name: string
  kind: PaymentMethodKind
  is_active: boolean
  sort_order: number
  created_at: string
  // pos-banco-movimientos (D7): destino bancario por defecto, opcional en
  // la respuesta (ausente = null).
  bank_account_id?: string | null
}

function mapPaymentMethod(r: PaymentMethodApiRow): PaymentMethod {
  return {
    id:        r.id,
    accountId: r.account_id,
    name:      r.name,
    kind:      r.kind,
    isActive:  r.is_active,
    sortOrder: r.sort_order,
    createdAt: r.created_at,
    bankAccountId: r.bank_account_id ?? null,
  }
}

function filterActiveMethods(methods: PaymentMethod[]): PaymentMethod[] {
  return methods.filter(m => m.isActive)
}

/** Simulate role-gating logic for catalog management UI (mismo criterio que cost centers). */
function canManagePaymentMethods(role: string | null): boolean {
  return role === "owner" || role === "admin"
}

/** Build the API payload for creating a payment method (mirrors the mutation). */
function buildCreatePayload(name: string, kind: PaymentMethodKind, sortOrder = 0) {
  return { name: name.trim(), kind, sort_order: sortOrder }
}

const PAYMENT_METHOD_KINDS: readonly PaymentMethodKind[] = [
  "cash", "transfer", "card", "check", "wallet", "credit", "other",
]

// ── mapPaymentMethod ──────────────────────────────────────────────────────────

describe("mapPaymentMethod — API row → PaymentMethod", () => {
  it("maps all fields correctly", () => {
    const row: PaymentMethodApiRow = {
      id:         "cccccccc-cccc-cccc-cccc-cccccccccccc",
      account_id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
      name:       "Efectivo",
      kind:       "cash",
      is_active:  true,
      sort_order: 1,
      created_at: "2026-08-19T10:00:00+00:00",
    }

    const pm = mapPaymentMethod(row)

    expect(pm.id).toBe(row.id)
    expect(pm.accountId).toBe(row.account_id)
    expect(pm.name).toBe("Efectivo")
    expect(pm.kind).toBe("cash")
    expect(pm.isActive).toBe(true)
    expect(pm.sortOrder).toBe(1)
    expect(pm.createdAt).toBe(row.created_at)
  })

  it("maps is_active=false correctly", () => {
    const row: PaymentMethodApiRow = {
      id:         "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee",
      account_id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
      name:       "Cheque",
      kind:       "check",
      is_active:  false,
      sort_order: 7,
      created_at: "2026-08-01T09:00:00+00:00",
    }

    const pm = mapPaymentMethod(row)

    expect(pm.isActive).toBe(false)
  })

  it("pos-banco-movimientos: maps bank_account_id when present", () => {
    const row: PaymentMethodApiRow = {
      id: "f", account_id: "a", name: "Transferencia bancaria", kind: "transfer",
      is_active: true, sort_order: 2, created_at: "2026-08-20T00:00:00+00:00",
      bank_account_id: "dddddddd-dddd-dddd-dddd-dddddddddddd",
    }

    const pm = mapPaymentMethod(row)

    expect(pm.bankAccountId).toBe("dddddddd-dddd-dddd-dddd-dddddddddddd")
  })

  it("pos-banco-movimientos: bank_account_id absent maps to null", () => {
    const row: PaymentMethodApiRow = {
      id: "g", account_id: "a", name: "Efectivo", kind: "cash",
      is_active: true, sort_order: 1, created_at: "2026-08-20T00:00:00+00:00",
    }

    const pm = mapPaymentMethod(row)

    expect(pm.bankAccountId).toBeNull()
  })
})

// ── filterActiveMethods — selector shows only active ─────────────────────────

describe("filterActiveMethods — only active shown in new-entry selector", () => {
  const active: PaymentMethod = {
    id: "1", accountId: "a", name: "Efectivo", kind: "cash",
    isActive: true, sortOrder: 1, createdAt: "2026-08-19T10:00:00+00:00",
    bankAccountId: null,
  }
  const inactive: PaymentMethod = {
    id: "2", accountId: "a", name: "Cheque", kind: "check",
    isActive: false, sortOrder: 7, createdAt: "2026-07-01T09:00:00+00:00",
    bankAccountId: null,
  }

  it("returns only active methods", () => {
    const result = filterActiveMethods([active, inactive])
    expect(result).toHaveLength(1)
    expect(result[0].name).toBe("Efectivo")
  })

  it("returns empty list when all are inactive", () => {
    const result = filterActiveMethods([inactive])
    expect(result).toHaveLength(0)
  })

  it("returns all when all are active", () => {
    const another: PaymentMethod = { ...active, id: "3", name: "Transferencia", kind: "transfer" }
    const result = filterActiveMethods([active, another])
    expect(result).toHaveLength(2)
  })
})

// ── canManagePaymentMethods — role gating for CRUD ────────────────────────────

describe("canManagePaymentMethods — owner/admin can manage, member cannot", () => {
  it("owner can manage", () => {
    expect(canManagePaymentMethods("owner")).toBe(true)
  })

  it("admin can manage", () => {
    expect(canManagePaymentMethods("admin")).toBe(true)
  })

  it("member CANNOT manage (read-only)", () => {
    expect(canManagePaymentMethods("member")).toBe(false)
  })

  it("null role CANNOT manage (unauthenticated or loading)", () => {
    expect(canManagePaymentMethods(null)).toBe(false)
  })
})

// ── buildCreatePayload — mutation payload shape ───────────────────────────────

describe("buildCreatePayload — API payload for create mutation", () => {
  it("includes name and kind", () => {
    const payload = buildCreatePayload("Mercado Pago", "wallet")
    expect(payload.name).toBe("Mercado Pago")
    expect(payload.kind).toBe("wallet")
  })

  it("trims whitespace from name", () => {
    const payload = buildCreatePayload("  Efectivo  ", "cash")
    expect(payload.name).toBe("Efectivo")
  })

  it("defaults sort_order to 0", () => {
    const payload = buildCreatePayload("Efectivo", "cash")
    expect(payload.sort_order).toBe(0)
  })

  it("passes explicit sort_order", () => {
    const payload = buildCreatePayload("Efectivo", "cash", 3)
    expect(payload.sort_order).toBe(3)
  })
})

// ── D2: kind es un vocabulario cerrado ────────────────────────────────────────

describe("PAYMENT_METHOD_KINDS — vocabulario cerrado (D2)", () => {
  it("contiene exactamente los 7 kinds del superset de las dos taxonomías existentes", () => {
    expect(PAYMENT_METHOD_KINDS).toEqual(["cash", "transfer", "card", "check", "wallet", "credit", "other"])
  })

  it("es superset del CHECK de sales_orders.payment_method", () => {
    const salesOrdersCheck = ["cash", "transfer", "card", "other", "credit"]
    expect(salesOrdersCheck.every((k) => PAYMENT_METHOD_KINDS.includes(k as PaymentMethodKind))).toBe(true)
  })

  it("es superset de la taxonomía de cobro/pago", () => {
    const paymentRpcCheck = ["cash", "transfer", "card", "check"]
    expect(paymentRpcCheck.every((k) => PAYMENT_METHOD_KINDS.includes(k as PaymentMethodKind))).toBe(true)
  })
})

// ── Type safety: Sale/Purchase carry the payment method fields ───────────────

describe("Sale/Purchase types include optional paymentMethodId (metodos-pago-operaciones)", () => {
  it("accepts a Purchase without paymentMethodId", () => {
    const purchase: import("@/lib/types").Purchase = {
      id: "p1",
      date: "2026-08-19",
      productId: "prod-1",
      productName: "Harina",
      quantity: 10,
      unitCost: 500,
      total: 5000,
    }
    expect(purchase.paymentMethodId).toBeUndefined()
  })

  it("accepts a Purchase with paymentMethodId=null (Sin especificar)", () => {
    const purchase: import("@/lib/types").Purchase = {
      id: "p1",
      date: "2026-08-19",
      productId: "prod-1",
      productName: "Harina",
      quantity: 10,
      unitCost: 500,
      total: 5000,
      paymentMethodId: null,
      paymentMethodName: null,
    }
    expect(purchase.paymentMethodId).toBeNull()
  })

  it("accepts a Sale with an imputed paymentMethodId + kind", () => {
    const sale: import("@/lib/types").Sale = {
      id: "s1",
      date: "2026-08-19",
      productId: "prod-1",
      productName: "Torta",
      clientId: "cl-1",
      clientName: "Consumidor Final",
      quantity: 1,
      unitPrice: 3000,
      total: 3000,
      currency: "ARS",
      paymentMethodId: "pm-1",
      paymentMethodName: "Efectivo",
      paymentMethodKind: "cash",
    }
    expect(sale.paymentMethodKind).toBe("cash")
  })
})
