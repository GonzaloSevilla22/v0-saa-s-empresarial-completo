/**
 * bank-account-crud — TDD tests for useBankAccounts().createBankAccount (task 5.1-5.2)
 *
 * Cycle: RED → GREEN
 * Mock: @/lib/api/python-client
 */

import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, waitFor, act } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"
import { useBankAccounts } from "@/hooks/data/use-bank-accounts"

// ── Mocks ─────────────────────────────────────────────────────────────────────

vi.mock("@/lib/api/python-client", () => ({
  pythonClient: {
    get:    vi.fn(),
    post:   vi.fn(),
    put:    vi.fn(),
    patch:  vi.fn(),
    delete: vi.fn(),
  },
}))

import { pythonClient } from "@/lib/api/python-client"

// ── Fixtures ──────────────────────────────────────────────────────────────────

const mockBankAccountRow = {
  id:           "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
  account_id:   "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
  name:         "Cuenta corriente Galicia",
  bank_name:    "Banco Galicia",
  cbu:          "0".repeat(22),
  alias:        "galicia.cuenta",
  currency:     "ARS",
  account_kind: "bank" as const,
  is_active:    true,
}

function makeWrapper() {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  })
  return {
    Wrapper: ({ children }: { children: React.ReactNode }) =>
      React.createElement(QueryClientProvider, { client: queryClient }, children),
    queryClient,
  }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("useBankAccounts().createBankAccount", () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it("posts to /bank-accounts with the payload (snake_case)", async () => {
    vi.mocked(pythonClient.get).mockResolvedValueOnce([])
    vi.mocked(pythonClient.post).mockResolvedValueOnce(mockBankAccountRow)
    const { Wrapper } = makeWrapper()

    const { result } = renderHook(() => useBankAccounts(), { wrapper: Wrapper })

    await act(async () => {
      await result.current.createBankAccount({
        name: "Cuenta corriente Galicia",
        bank_name: "Banco Galicia",
      })
    })

    expect(pythonClient.post).toHaveBeenCalledWith("/bank-accounts", {
      name: "Cuenta corriente Galicia",
      bank_name: "Banco Galicia",
    })
  })

  it("invalidates queryKeys.bankAccounts on success", async () => {
    vi.mocked(pythonClient.get).mockResolvedValueOnce([])
    vi.mocked(pythonClient.post).mockResolvedValueOnce(mockBankAccountRow)
    const { Wrapper, queryClient } = makeWrapper()
    const invalidateSpy = vi.spyOn(queryClient, "invalidateQueries")

    const { result } = renderHook(() => useBankAccounts(), { wrapper: Wrapper })

    await act(async () => {
      await result.current.createBankAccount({ name: "Cuenta corriente Galicia" })
    })

    await waitFor(() => {
      expect(invalidateSpy).toHaveBeenCalledWith(
        expect.objectContaining({ queryKey: ["bankAccounts"] })
      )
    })
  })

  it("returns the mapped BankAccount from the mutation", async () => {
    vi.mocked(pythonClient.get).mockResolvedValueOnce([])
    vi.mocked(pythonClient.post).mockResolvedValueOnce(mockBankAccountRow)
    const { Wrapper } = makeWrapper()

    const { result } = renderHook(() => useBankAccounts(), { wrapper: Wrapper })

    let created
    await act(async () => {
      created = await result.current.createBankAccount({ name: "Cuenta corriente Galicia" })
    })

    expect(created).toEqual(
      expect.objectContaining({
        id: mockBankAccountRow.id,
        name: "Cuenta corriente Galicia",
        bankName: "Banco Galicia",
      })
    )
  })

  // ── cuentas-billetera-tipo (task 6.5) ──────────────────────────────────────

  it("maps account_kind from the API row (wallet)", async () => {
    vi.mocked(pythonClient.get).mockResolvedValueOnce([])
    vi.mocked(pythonClient.post).mockResolvedValueOnce({ ...mockBankAccountRow, account_kind: "wallet" })
    const { Wrapper } = makeWrapper()

    const { result } = renderHook(() => useBankAccounts(), { wrapper: Wrapper })

    let created
    await act(async () => {
      created = await result.current.createBankAccount({ name: "Mercado Pago", account_kind: "wallet" })
    })

    expect(created).toEqual(expect.objectContaining({ accountKind: "wallet" }))
  })

  it("passes account_kind through in the create payload", async () => {
    vi.mocked(pythonClient.get).mockResolvedValueOnce([])
    vi.mocked(pythonClient.post).mockResolvedValueOnce({ ...mockBankAccountRow, account_kind: "wallet" })
    const { Wrapper } = makeWrapper()

    const { result } = renderHook(() => useBankAccounts(), { wrapper: Wrapper })

    await act(async () => {
      await result.current.createBankAccount({ name: "Mercado Pago", account_kind: "wallet" })
    })

    expect(pythonClient.post).toHaveBeenCalledWith("/bank-accounts", {
      name: "Mercado Pago",
      account_kind: "wallet",
    })
  })
})
