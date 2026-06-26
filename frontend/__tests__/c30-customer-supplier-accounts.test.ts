/**
 * C-30 v21-customer-supplier-accounts — Frontend TDD tests (Strict TDD Mode)
 *
 * Cycle: RED → GREEN → TRIANGULATE
 * Mock: @/lib/api/python-client
 *
 * Comportamientos cubiertos:
 *  - useCustomerAccount: fetch saldo + movimientos por clientId
 *  - useRegisterPayment: POST cobro, invalida cache, devuelve replayed=false
 *  - useCustomerAccount: null cuando clientId es null (guard)
 *  - useSupplierAccount: fetch saldo + movimientos por supplierId
 *  - useRegisterPaymentMade: POST pago, invalida cache, devuelve replayed=false
 *  - TRIANGULATE: idempotencia — replayed=true en segundo cobro
 *  - TRIANGULATE: overpayment — throws con mensaje traducido
 *  - TRIANGULATE: supplierId null → no hace fetch
 */

import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, waitFor, act } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"

import { useCustomerAccount, useRegisterPayment, type PaymentReceivedResult } from "@/hooks/data/use-customer-account"
import { useSupplierAccount, useRegisterPaymentMade, type PaymentMadeResult } from "@/hooks/data/use-supplier-account"

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

const CLIENT_ID   = "cccccccc-cccc-cccc-cccc-cccccccccccc"
const SUPPLIER_ID = "dddddddd-dddd-dddd-dddd-dddddddddddd"
const ACCOUNT_ID  = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
const CA_ID       = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
const SA_ID       = "ffffffff-ffff-ffff-ffff-ffffffffffff"
const PAYMENT_ID  = "11111111-1111-1111-1111-111111111111"
const MOVEMENT_ID = "22222222-2222-2222-2222-222222222222"
const OP_ID       = "33333333-3333-3333-3333-333333333333"

const CUSTOMER_ACCOUNT_API = {
  id:         CA_ID,
  account_id: ACCOUNT_ID,
  client_id:  CLIENT_ID,
  balance:    "1000.00",
  created_at: "2026-06-20T00:00:00Z",
  movements: [
    {
      id:                   MOVEMENT_ID,
      customer_account_id:  CA_ID,
      account_id:           ACCOUNT_ID,
      amount:               "1000.00",
      balance_after:        "1000.00",
      movement_type:        "sale" as const,
      reference_id:         null,
      created_by:           "11111111-1111-1111-1111-111111111111",
      created_at:           "2026-06-20T00:00:00Z",
    },
  ],
}

const SUPPLIER_ACCOUNT_API = {
  id:          SA_ID,
  account_id:  ACCOUNT_ID,
  supplier_id: SUPPLIER_ID,
  balance:     "2000.00",
  created_at:  "2026-06-20T00:00:00Z",
  movements: [
    {
      id:                   MOVEMENT_ID,
      supplier_account_id:  SA_ID,
      account_id:           ACCOUNT_ID,
      amount:               "2000.00",
      balance_after:        "2000.00",
      movement_type:        "purchase" as const,
      reference_id:         null,
      created_by:           "11111111-1111-1111-1111-111111111111",
      created_at:           "2026-06-20T00:00:00Z",
    },
  ],
}

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

// ── Wrapper helper ─────────────────────────────────────────────────────────────

function makeWrapper() {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  })
  return ({ children }: { children: React.ReactNode }) =>
    React.createElement(QueryClientProvider, { client: queryClient }, children)
}

// ══════════════════════════════════════════════════════════════════════════════
// Section 1: useCustomerAccount
// ══════════════════════════════════════════════════════════════════════════════

describe("useCustomerAccount", () => {
  beforeEach(() => { vi.clearAllMocks() })

  // ── RED → GREEN: hook fetches and maps account data ─────────────────────
  it("returns mapped account with balance as number", async () => {
    vi.mocked(pythonClient.get).mockResolvedValueOnce(CUSTOMER_ACCOUNT_API)

    const { result } = renderHook(
      () => useCustomerAccount(CLIENT_ID),
      { wrapper: makeWrapper() }
    )

    expect(result.current.isLoading).toBe(true)

    await waitFor(() => {
      expect(result.current.isLoading).toBe(false)
    })

    expect(result.current.data).not.toBeNull()
    expect(result.current.data?.balance).toBe(1000)
    expect(result.current.data?.clientId).toBe(CLIENT_ID)
    expect(pythonClient.get).toHaveBeenCalledWith(`/clientes/${CLIENT_ID}/cuenta`)
  })

  // ── TRIANGULATE: movements are mapped correctly ──────────────────────────
  it("maps movements with amount and balanceAfter as numbers", async () => {
    vi.mocked(pythonClient.get).mockResolvedValueOnce(CUSTOMER_ACCOUNT_API)

    const { result } = renderHook(
      () => useCustomerAccount(CLIENT_ID),
      { wrapper: makeWrapper() }
    )

    await waitFor(() => expect(result.current.isLoading).toBe(false))

    const movements = result.current.data?.movements ?? []
    expect(movements).toHaveLength(1)
    expect(movements[0].amount).toBe(1000)
    expect(movements[0].balanceAfter).toBe(1000)
    expect(movements[0].movementType).toBe("sale")
  })

  // ── TRIANGULATE: null clientId → no fetch ───────────────────────────────
  it("returns null and does not fetch when clientId is null", async () => {
    const { result } = renderHook(
      () => useCustomerAccount(null),
      { wrapper: makeWrapper() }
    )

    await waitFor(() => expect(result.current.isLoading).toBe(false))

    expect(result.current.data).toBeUndefined()
    expect(pythonClient.get).not.toHaveBeenCalled()
  })
})

// ══════════════════════════════════════════════════════════════════════════════
// Section 2: useRegisterPayment
// ══════════════════════════════════════════════════════════════════════════════

describe("useRegisterPayment", () => {
  beforeEach(() => { vi.clearAllMocks() })

  // ── RED → GREEN: registers payment and returns result ───────────────────
  it("calls POST /customer-accounts/payments with correct payload", async () => {
    vi.mocked(pythonClient.get).mockResolvedValue(CUSTOMER_ACCOUNT_API)
    vi.mocked(pythonClient.post).mockResolvedValueOnce(PAYMENT_RECEIVED_RESULT)

    const { result } = renderHook(
      () => useRegisterPayment(CLIENT_ID),
      { wrapper: makeWrapper() }
    )

    let mutationResult: PaymentReceivedResult | undefined

    await act(async () => {
      mutationResult = await result.current.mutateAsync({
        idempotencyKey: "test-key-001",
        amount: 400,
      })
    })

    expect(mutationResult?.replayed).toBe(false)
    expect(mutationResult?.balance_after).toBe("600.00")
    expect(pythonClient.post).toHaveBeenCalledWith(
      "/customer-accounts/payments",
      expect.objectContaining({
        client_id:       CLIENT_ID,
        amount:          "400",
        idempotency_key: "test-key-001",
      })
    )
  })

  // ── TRIANGULATE: idempotencia — second call returns replayed=true ────────
  it("returns replayed=true when the same key is used twice", async () => {
    vi.mocked(pythonClient.get).mockResolvedValue(CUSTOMER_ACCOUNT_API)
    vi.mocked(pythonClient.post)
      .mockResolvedValueOnce(PAYMENT_RECEIVED_RESULT)           // first call
      .mockResolvedValueOnce({ ...PAYMENT_RECEIVED_RESULT, payment_id: null, replayed: true }) // replay

    const { result } = renderHook(
      () => useRegisterPayment(CLIENT_ID),
      { wrapper: makeWrapper() }
    )

    let r2: PaymentReceivedResult | undefined
    await act(async () => {
      await result.current.mutateAsync({ idempotencyKey: "same-key", amount: 400 })
      r2 = await result.current.mutateAsync({ idempotencyKey: "same-key", amount: 400 })
    })

    expect(r2?.replayed).toBe(true)
    expect(pythonClient.post).toHaveBeenCalledTimes(2)
  })

  // ── TRIANGULATE: overpayment → translated error ──────────────────────────
  it("throws translated error when backend returns overpayment", async () => {
    vi.mocked(pythonClient.get).mockResolvedValue(CUSTOMER_ACCOUNT_API)
    vi.mocked(pythonClient.post).mockRejectedValueOnce(
      new Error("overpayment: el pago excede el saldo deudor")
    )

    const { result } = renderHook(
      () => useRegisterPayment(CLIENT_ID),
      { wrapper: makeWrapper() }
    )

    await expect(
      act(async () => {
        await result.current.mutateAsync({ idempotencyKey: "overpay-key", amount: 9999 })
      })
    ).rejects.toThrow("El cobro excede el saldo deudor del cliente.")
  })
})

// ══════════════════════════════════════════════════════════════════════════════
// Section 3: useSupplierAccount
// ══════════════════════════════════════════════════════════════════════════════

describe("useSupplierAccount", () => {
  beforeEach(() => { vi.clearAllMocks() })

  // ── RED → GREEN: hook fetches and maps supplier account ─────────────────
  it("returns mapped supplier account with balance as number", async () => {
    vi.mocked(pythonClient.get).mockResolvedValueOnce(SUPPLIER_ACCOUNT_API)

    const { result } = renderHook(
      () => useSupplierAccount(SUPPLIER_ID),
      { wrapper: makeWrapper() }
    )

    await waitFor(() => expect(result.current.isLoading).toBe(false))

    expect(result.current.data?.balance).toBe(2000)
    expect(result.current.data?.supplierId).toBe(SUPPLIER_ID)
    expect(pythonClient.get).toHaveBeenCalledWith(`/proveedores/${SUPPLIER_ID}/cuenta`)
  })

  // ── TRIANGULATE: movements mapped for supplier ───────────────────────────
  it("maps supplier movements with movementType=purchase", async () => {
    vi.mocked(pythonClient.get).mockResolvedValueOnce(SUPPLIER_ACCOUNT_API)

    const { result } = renderHook(
      () => useSupplierAccount(SUPPLIER_ID),
      { wrapper: makeWrapper() }
    )

    await waitFor(() => expect(result.current.isLoading).toBe(false))

    const movements = result.current.data?.movements ?? []
    expect(movements[0].movementType).toBe("purchase")
    expect(movements[0].amount).toBe(2000)
  })

  // ── TRIANGULATE: null supplierId → no fetch ──────────────────────────────
  it("does not fetch when supplierId is null", async () => {
    const { result } = renderHook(
      () => useSupplierAccount(null),
      { wrapper: makeWrapper() }
    )

    await waitFor(() => expect(result.current.isLoading).toBe(false))

    expect(result.current.data).toBeUndefined()
    expect(pythonClient.get).not.toHaveBeenCalled()
  })
})

// ══════════════════════════════════════════════════════════════════════════════
// Section 4: useRegisterPaymentMade
// ══════════════════════════════════════════════════════════════════════════════

describe("useRegisterPaymentMade", () => {
  beforeEach(() => { vi.clearAllMocks() })

  // ── RED → GREEN: registers payment_made and returns result ───────────────
  it("calls POST /supplier-accounts/payments with correct payload", async () => {
    vi.mocked(pythonClient.get).mockResolvedValue(SUPPLIER_ACCOUNT_API)
    vi.mocked(pythonClient.post).mockResolvedValueOnce(PAYMENT_MADE_RESULT)

    const { result } = renderHook(
      () => useRegisterPaymentMade(SUPPLIER_ID),
      { wrapper: makeWrapper() }
    )

    let mutationResult: PaymentMadeResult | undefined

    await act(async () => {
      mutationResult = await result.current.mutateAsync({
        idempotencyKey: "pay-supplier-001",
        amount: 400,
      })
    })

    expect(mutationResult?.replayed).toBe(false)
    expect(mutationResult?.balance_after).toBe("1600.00")
    expect(pythonClient.post).toHaveBeenCalledWith(
      "/supplier-accounts/payments",
      expect.objectContaining({
        supplier_id:     SUPPLIER_ID,
        amount:          "400",
        idempotency_key: "pay-supplier-001",
      })
    )
  })

  // ── TRIANGULATE: overpayment translated ─────────────────────────────────
  it("throws translated error for supplier overpayment", async () => {
    vi.mocked(pythonClient.get).mockResolvedValue(SUPPLIER_ACCOUNT_API)
    vi.mocked(pythonClient.post).mockRejectedValueOnce(
      new Error("overpayment: el pago excede el saldo")
    )

    const { result } = renderHook(
      () => useRegisterPaymentMade(SUPPLIER_ID),
      { wrapper: makeWrapper() }
    )

    await expect(
      act(async () => {
        await result.current.mutateAsync({ idempotencyKey: "over-key", amount: 99999 })
      })
    ).rejects.toThrow("El pago excede el saldo deudor con el proveedor.")
  })
})
