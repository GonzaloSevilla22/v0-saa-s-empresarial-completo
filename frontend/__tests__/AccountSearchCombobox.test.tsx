/**
 * mp-real-subscriptions follow-up (task 8.8) — TDD tests for
 * AccountSearchCombobox (selector de cuenta destino de la cola de
 * suscripciones ambiguas).
 *
 * Cycle: RED → GREEN → TRIANGULATE
 */

import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, waitFor } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import "@testing-library/jest-dom"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { AccountSearchCombobox } from "@/components/billing/AccountSearchCombobox"
import type { AccountSearchResult } from "@/hooks/data/use-ambiguous-subscriptions"

vi.mock("@/lib/api/python-client", () => ({
  pythonClient: {
    get: vi.fn(),
    post: vi.fn(),
    put: vi.fn(),
    patch: vi.fn(),
    delete: vi.fn(),
  },
}))

import { pythonClient } from "@/lib/api/python-client"

const ACCOUNT: AccountSearchResult = {
  accountId: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
  ownerEmail: "buyer@example.com",
  ownerName: "Buyer Test",
  billingPlan: "pro",
}

function renderCombobox(value: AccountSearchResult | null = null) {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  const onSelect = vi.fn()
  render(
    <QueryClientProvider client={queryClient}>
      <AccountSearchCombobox value={value} onSelect={onSelect} id="test-combobox" />
    </QueryClientProvider>,
  )
  return { onSelect }
}

beforeEach(() => {
  vi.clearAllMocks()
})

describe("AccountSearchCombobox", () => {
  it("§1 RED: renders a combobox trigger with a placeholder when no account is selected", () => {
    renderCombobox(null)

    const trigger = screen.getByRole("combobox")
    expect(trigger).toHaveAccessibleName(/buscar cuenta destino/i)
    expect(trigger).toHaveTextContent(/buscar cuenta por email o nombre/i)
  })

  it("§2 GREEN: shows the selected account's name and email in the trigger", () => {
    renderCombobox(ACCOUNT)

    const trigger = screen.getByRole("combobox")
    expect(trigger).toHaveTextContent("Buyer Test")
    expect(trigger).toHaveTextContent("buyer@example.com")
  })

  it("§3 TRIANGULATE: opening the popover with fewer than 2 characters shows a hint, not a query", async () => {
    const user = userEvent.setup()
    renderCombobox(null)

    await user.click(screen.getByRole("combobox"))

    expect(await screen.findByText(/al menos 2 caracteres/i)).toBeInTheDocument()
    expect(pythonClient.get).not.toHaveBeenCalled()
  })

  it("§4 TRIANGULATE: typing >= 2 characters queries and lists matching accounts", async () => {
    vi.mocked(pythonClient.get).mockResolvedValueOnce([
      {
        account_id: ACCOUNT.accountId,
        owner_email: ACCOUNT.ownerEmail,
        owner_name: ACCOUNT.ownerName,
        billing_plan: ACCOUNT.billingPlan,
      },
    ])
    const user = userEvent.setup()
    renderCombobox(null)

    await user.click(screen.getByRole("combobox"))
    await user.type(screen.getByPlaceholderText(/email o nombre del titular/i), "bu")

    await waitFor(() => {
      expect(pythonClient.get).toHaveBeenCalledWith("/payments/accounts/search?q=bu")
    })
    expect(await screen.findByText("buyer@example.com")).toBeInTheDocument()
  })

  it("§5 TRIANGULATE: selecting a result calls onSelect with that account", async () => {
    vi.mocked(pythonClient.get).mockResolvedValueOnce([
      {
        account_id: ACCOUNT.accountId,
        owner_email: ACCOUNT.ownerEmail,
        owner_name: ACCOUNT.ownerName,
        billing_plan: ACCOUNT.billingPlan,
      },
    ])
    const user = userEvent.setup()
    const { onSelect } = renderCombobox(null)

    await user.click(screen.getByRole("combobox"))
    await user.type(screen.getByPlaceholderText(/email o nombre del titular/i), "bu")

    const option = await screen.findByText("buyer@example.com")
    await user.click(option)

    expect(onSelect).toHaveBeenCalledWith(ACCOUNT)
  })

  it("§6 TRIANGULATE: no results for a >= 2 character query shows an explicit empty state", async () => {
    vi.mocked(pythonClient.get).mockResolvedValueOnce([])
    const user = userEvent.setup()
    renderCombobox(null)

    await user.click(screen.getByRole("combobox"))
    await user.type(screen.getByPlaceholderText(/email o nombre del titular/i), "zz")

    expect(await screen.findByText(/sin cuentas para/i)).toBeInTheDocument()
  })
})
