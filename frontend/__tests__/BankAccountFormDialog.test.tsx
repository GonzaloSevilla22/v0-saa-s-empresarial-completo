/**
 * bank-account-crud — TDD tests for BankAccountFormDialog (tasks 6.1-6.3)
 *
 * 6.1 RED/GREEN: Zod schema validation (name requerido; cbu opcional 22 dígitos;
 *                opening_balance >= 0; currency default ARS).
 * 6.3 TRIANGULATE: comportamiento del form — submit vacío no dispara la mutación,
 *                   submit válido la dispara una vez.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent, waitFor } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import React from "react"

// ── Mocks ─────────────────────────────────────────────────────────────────────

const mockCreateBankAccount = vi.fn()
const mockMutation = { isPending: false }

vi.mock("@/hooks/data/use-bank-accounts", () => ({
  useBankAccounts: () => ({
    createBankAccount: mockCreateBankAccount,
    createBankAccountMutation: mockMutation,
  }),
}))

vi.mock("sonner", () => ({
  toast: { success: vi.fn(), error: vi.fn() },
}))

import { BankAccountFormDialog } from "@/components/bank-accounts/BankAccountFormDialog"
import { bankAccountFormSchema } from "@/components/bank-accounts/BankAccountFormDialog"

// ── 6.1/6.2: Zod schema ────────────────────────────────────────────────────────

describe("bankAccountFormSchema", () => {
  it("requires name", () => {
    const result = bankAccountFormSchema.safeParse({ name: "" })
    expect(result.success).toBe(false)
  })

  it("accepts minimal payload with only name", () => {
    const result = bankAccountFormSchema.safeParse({ name: "Cuenta Ahorro" })
    expect(result.success).toBe(true)
  })

  it("defaults currency to ARS when omitted", () => {
    const result = bankAccountFormSchema.safeParse({ name: "Cuenta Ahorro" })
    expect(result.success).toBe(true)
    if (result.success) {
      expect(result.data.currency).toBe("ARS")
    }
  })

  it("rejects cbu that is not exactly 22 digits", () => {
    const result = bankAccountFormSchema.safeParse({ name: "Cuenta X", cbu: "12345" })
    expect(result.success).toBe(false)
  })

  it("accepts a valid 22-digit cbu", () => {
    const result = bankAccountFormSchema.safeParse({ name: "Cuenta X", cbu: "0".repeat(22) })
    expect(result.success).toBe(true)
  })

  it("accepts omitted cbu (optional)", () => {
    const result = bankAccountFormSchema.safeParse({ name: "Cuenta X" })
    expect(result.success).toBe(true)
  })

  it("rejects negative opening_balance", () => {
    const result = bankAccountFormSchema.safeParse({ name: "Cuenta X", opening_balance: -100 })
    expect(result.success).toBe(false)
  })

  it("accepts opening_balance of zero", () => {
    const result = bankAccountFormSchema.safeParse({ name: "Cuenta X", opening_balance: 0 })
    expect(result.success).toBe(true)
  })
})

// ── 6.3 TRIANGULATE: form behaviour ───────────────────────────────────────────

describe("BankAccountFormDialog — form behaviour", () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it("does not call the mutation when submitting with empty name", async () => {
    const user = userEvent.setup()
    render(<BankAccountFormDialog open onOpenChange={() => {}} />)

    const submitButton = screen.getByRole("button", { name: /crear/i })
    await user.click(submitButton)

    await waitFor(() => {
      expect(mockCreateBankAccount).not.toHaveBeenCalled()
    })
  })

  it("calls the mutation once when submitting with a valid name", async () => {
    mockCreateBankAccount.mockResolvedValueOnce({ id: "new-id" })
    const user = userEvent.setup()
    render(<BankAccountFormDialog open onOpenChange={() => {}} />)

    const nameInput = screen.getByLabelText(/nombre/i)
    await user.type(nameInput, "Cuenta corriente Galicia")

    const submitButton = screen.getByRole("button", { name: /crear/i })
    await user.click(submitButton)

    await waitFor(() => {
      expect(mockCreateBankAccount).toHaveBeenCalledTimes(1)
    })
    expect(mockCreateBankAccount).toHaveBeenCalledWith(
      expect.objectContaining({ name: "Cuenta corriente Galicia" })
    )
  })
})
