/**
 * banco-saldo-segun-libro — saldo "según libro" al elegir una cuenta en /banco.
 * Lectura pura: el servidor calcula (saldo inicial + movimientos); acá se mapea y se muestra.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, renderHook, waitFor } from "@testing-library/react"
import React from "react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"

vi.mock("@/lib/api/python-client", () => ({
  pythonClient: { get: vi.fn(), post: vi.fn() },
}))

import { pythonClient } from "@/lib/api/python-client"
import { useBankAccounts, type BankAccount, type BankAccountApi } from "@/hooks/data/use-bank-accounts"
import { BankAccountBalanceCard } from "@/components/bank-accounts/BankAccountBalanceCard"

const API_ROW: BankAccountApi = {
  id: "ba-1",
  account_id: "acc-1",
  name: "Cuenta Galicia",
  bank_name: "Galicia",
  cbu: null,
  alias: null,
  currency: "ARS",
  account_kind: "bank",
  is_active: true,
  opening_balance: "1000.00",
  current_balance: "1300.00",
  last_movement_date: "2026-11-03",
  pending_reconciliation_count: 2,
}

function makeAccount(over: Partial<BankAccount> = {}): BankAccount {
  return {
    id: "ba-1",
    accountId: "acc-1",
    name: "Cuenta Galicia",
    bankName: "Galicia",
    cbu: null,
    alias: null,
    currency: "ARS",
    accountKind: "bank",
    isActive: true,
    openingBalance: 1000,
    currentBalance: 1300,
    lastMovementDate: "2026-11-03",
    pendingReconciliationCount: 2,
    ...over,
  }
}

function wrapper({ children }: { children: React.ReactNode }) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return React.createElement(QueryClientProvider, { client: qc }, children)
}

describe("useBankAccounts — mapeo del saldo según libro", () => {
  beforeEach(() => vi.clearAllMocks())

  it("convierte los importes (string del backend) a número", async () => {
    vi.mocked(pythonClient.get).mockResolvedValueOnce([API_ROW])
    const { result } = renderHook(() => useBankAccounts(), { wrapper })
    await waitFor(() => expect(result.current.isLoading).toBe(false))
    expect(result.current.data?.[0]).toMatchObject({
      openingBalance: 1000,
      currentBalance: 1300,
      lastMovementDate: "2026-11-03",
      pendingReconciliationCount: 2,
    })
  })

  it("degrada a 0 / null si el backend todavía no manda los campos", async () => {
    const legacy = { ...API_ROW } as Partial<BankAccountApi>
    delete legacy.opening_balance
    delete legacy.current_balance
    delete legacy.last_movement_date
    delete legacy.pending_reconciliation_count
    vi.mocked(pythonClient.get).mockResolvedValueOnce([legacy])
    const { result } = renderHook(() => useBankAccounts(), { wrapper })
    await waitFor(() => expect(result.current.isLoading).toBe(false))
    expect(result.current.data?.[0]).toMatchObject({
      openingBalance: 0,
      currentBalance: 0,
      lastMovementDate: null,
      pendingReconciliationCount: 0,
    })
  })
})

describe("BankAccountBalanceCard", () => {
  it("sin cuenta elegida no renderiza nada", () => {
    const { container } = render(<BankAccountBalanceCard account={null} />)
    expect(container).toBeEmptyDOMElement()
  })

  it("muestra el saldo según libro formateado es-AR, el inicial y los pendientes", () => {
    render(<BankAccountBalanceCard account={makeAccount()} />)
    expect(screen.getByText("Saldo según libro")).toBeInTheDocument()
    const amount = screen.getByTestId("bank-libro-balance")
    expect(amount.textContent).toMatch(/1\.300/)
    expect(amount.className).not.toMatch(/destructive/)
    expect(screen.getByText(/Saldo inicial/)).toHaveTextContent(/1\.000/)
    expect(screen.getByText(/Último movimiento/)).toHaveTextContent("03/11/2026")
    expect(screen.getByText(/2 movimientos sin conciliar/)).toBeInTheDocument()
  })

  it("saldo negativo usa el estilo destructivo", () => {
    render(<BankAccountBalanceCard account={makeAccount({ currentBalance: -250.5 })} />)
    expect(screen.getByTestId("bank-libro-balance").className).toMatch(/text-destructive/)
  })

  it("sin movimientos ni pendientes omite esas líneas", () => {
    render(
      <BankAccountBalanceCard
        account={makeAccount({ lastMovementDate: null, pendingReconciliationCount: 0, currentBalance: 1000 })}
      />,
    )
    expect(screen.queryByText(/Último movimiento/)).toBeNull()
    expect(screen.queryByText(/sin conciliar/)).toBeNull()
  })

  it("singular para un solo movimiento pendiente", () => {
    render(<BankAccountBalanceCard account={makeAccount({ pendingReconciliationCount: 1 })} />)
    expect(screen.getByText(/1 movimiento sin conciliar/)).toBeInTheDocument()
  })
})

describe("invalidación del saldo según libro", () => {
  it("un ajuste manual de banco invalida las cuentas (el saldo cambió)", async () => {
    const { useRegisterManualMovement } = await import("@/hooks/data/use-bank-reconciliation")
    const { queryKeys } = await import("@/lib/query-keys")
    vi.mocked(pythonClient.post).mockResolvedValueOnce({})
    const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    const spy = vi.spyOn(qc, "invalidateQueries")
    const w = ({ children }: { children: React.ReactNode }) =>
      React.createElement(QueryClientProvider, { client: qc }, children)
    const { result } = renderHook(() => useRegisterManualMovement("ba-1"), { wrapper: w })
    await result.current.mutateAsync({
      idempotencyKey: "k1",
      amount: "100",
      movementType: "manual_adjustment",
      valueDate: null,
      description: null,
    })
    expect(spy).toHaveBeenCalledWith({ queryKey: queryKeys.bankAccounts.all() })
  })
})
