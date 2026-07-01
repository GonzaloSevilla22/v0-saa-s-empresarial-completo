/**
 * bank-payment-routing C2 — Frontend TDD tests (Strict TDD Mode)
 *
 * Cycle: RED → GREEN → TRIANGULATE
 * Mock: @/lib/api/python-client
 *
 * Comportamientos cubiertos:
 *  - useBankAccounts: fetch de cuentas bancarias activas, mapeo camelCase
 *  - useRegisterPayment: acepta paymentMethod + bankAccountId opcionales; los envía
 *    como payment_method/bank_account_id; sin especificar → default 'cash' implícito
 *    del backend (el hook no fuerza default, deja que el backend lo aplique)
 *  - useRegisterPaymentMade: espejo de arriba para pagos a proveedor
 *  - TRIANGULATE: retrocompatibilidad — llamada sin paymentMethod/bankAccountId sigue
 *    funcionando (no rompe la firma existente de C-30)
 */

import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, waitFor, act } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"

import { useRegisterPayment } from "@/hooks/data/use-customer-account"
import { useRegisterPaymentMade } from "@/hooks/data/use-supplier-account"
import { useBankAccounts } from "@/hooks/data/use-bank-accounts"

// ── Mocks ──────────────────────────────────────────────────────────────────────

vi.mock("@/lib/api/python-client", () => ({
  pythonClient: {
    get:    vi.fn(),
    post:   vi.fn(),
    put:    vi.fn(),
    delete: vi.fn(),
  },
}))

import { pythonClient } from "@/lib/api/python-client"

// ── Fixtures ───────────────────────────────────────────────────────────────────

const CLIENT_ID       = "cccccccc-cccc-cccc-cccc-cccccccccccc"
const SUPPLIER_ID     = "dddddddd-dddd-dddd-dddd-dddddddddddd"
const ACCOUNT_ID      = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
const CA_ID           = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
const SA_ID           = "ffffffff-ffff-ffff-ffff-ffffffffffff"
const BANK_ACCOUNT_ID = "99999999-9999-9999-9999-999999999999"
const PAYMENT_ID      = "11111111-1111-1111-1111-111111111111"
const OP_ID           = "33333333-3333-3333-3333-333333333333"

const PAYMENT_RECEIVED_RESULT = {
  payment_id:          PAYMENT_ID,
  customer_account_id: CA_ID,
  balance_after:       "600.00",
  replayed:            false,
  operation_id:        OP_ID,
}

const PAYMENT_MADE_RESULT = {
  payment_id:          PAYMENT_ID,
  supplier_account_id: SA_ID,
  balance_after:       "1600.00",
  replayed:            false,
  operation_id:        OP_ID,
}

const BANK_ACCOUNTS_API = [
  {
    id:         BANK_ACCOUNT_ID,
    account_id: ACCOUNT_ID,
    name:       "Cuenta Santander",
    bank_name:  "Santander",
    cbu:        null,
    alias:      "empresa.santander",
    currency:   "ARS",
    is_active:  true,
  },
]

// ── Wrapper helper ─────────────────────────────────────────────────────────────

function makeWrapper() {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  })
  return ({ children }: { children: React.ReactNode }) =>
    React.createElement(QueryClientProvider, { client: queryClient }, children)
}

// ══════════════════════════════════════════════════════════════════════════════
// Section 1: useBankAccounts
// ══════════════════════════════════════════════════════════════════════════════

describe("useBankAccounts", () => {
  beforeEach(() => { vi.clearAllMocks() })

  it("fetches and maps active bank accounts", async () => {
    vi.mocked(pythonClient.get).mockResolvedValueOnce(BANK_ACCOUNTS_API)

    const { result } = renderHook(() => useBankAccounts(), { wrapper: makeWrapper() })

    await waitFor(() => expect(result.current.isLoading).toBe(false))

    expect(pythonClient.get).toHaveBeenCalledWith("/bank-accounts")
    expect(result.current.data).toHaveLength(1)
    expect(result.current.data?.[0]).toMatchObject({
      id:       BANK_ACCOUNT_ID,
      name:     "Cuenta Santander",
      bankName: "Santander",
      isActive: true,
    })
  })
})

// ══════════════════════════════════════════════════════════════════════════════
// Section 2: useRegisterPayment — payment_method + bank_account_id
// ══════════════════════════════════════════════════════════════════════════════

describe("useRegisterPayment (bank routing)", () => {
  beforeEach(() => { vi.clearAllMocks() })

  it("sends payment_method + bank_account_id when provided (transfer)", async () => {
    vi.mocked(pythonClient.post).mockResolvedValueOnce(PAYMENT_RECEIVED_RESULT)

    const { result } = renderHook(
      () => useRegisterPayment(CLIENT_ID),
      { wrapper: makeWrapper() }
    )

    await act(async () => {
      await result.current.mutateAsync({
        idempotencyKey: "test-key-002",
        amount: 400,
        paymentMethod: "transfer",
        bankAccountId: BANK_ACCOUNT_ID,
      })
    })

    expect(pythonClient.post).toHaveBeenCalledWith(
      "/customer-accounts/payments",
      expect.objectContaining({
        client_id:         CLIENT_ID,
        amount:            "400",
        payment_method:    "transfer",
        bank_account_id:   BANK_ACCOUNT_ID,
      })
    )
  })

  it("still works without paymentMethod/bankAccountId (regression, C-30 default cash)", async () => {
    vi.mocked(pythonClient.post).mockResolvedValueOnce(PAYMENT_RECEIVED_RESULT)

    const { result } = renderHook(
      () => useRegisterPayment(CLIENT_ID),
      { wrapper: makeWrapper() }
    )

    await act(async () => {
      await result.current.mutateAsync({
        idempotencyKey: "test-key-003",
        amount: 400,
      })
    })

    const [, body] = vi.mocked(pythonClient.post).mock.calls[0]
    expect((body as Record<string, unknown>).client_id).toBe(CLIENT_ID)
    expect((body as Record<string, unknown>).amount).toBe("400")
  })
})

// ══════════════════════════════════════════════════════════════════════════════
// Section 3: useRegisterPaymentMade — payment_method + bank_account_id
// ══════════════════════════════════════════════════════════════════════════════

describe("useRegisterPaymentMade (bank routing)", () => {
  beforeEach(() => { vi.clearAllMocks() })

  it("sends payment_method + bank_account_id when provided (card)", async () => {
    vi.mocked(pythonClient.post).mockResolvedValueOnce(PAYMENT_MADE_RESULT)

    const { result } = renderHook(
      () => useRegisterPaymentMade(SUPPLIER_ID),
      { wrapper: makeWrapper() }
    )

    await act(async () => {
      await result.current.mutateAsync({
        idempotencyKey: "pay-supplier-002",
        amount: 400,
        paymentMethod: "card",
        bankAccountId: BANK_ACCOUNT_ID,
      })
    })

    expect(pythonClient.post).toHaveBeenCalledWith(
      "/supplier-accounts/payments",
      expect.objectContaining({
        supplier_id:      SUPPLIER_ID,
        amount:           "400",
        payment_method:   "card",
        bank_account_id:  BANK_ACCOUNT_ID,
      })
    )
  })
})
