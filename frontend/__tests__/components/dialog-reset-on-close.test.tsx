/**
 * qa-integral-modulos G11 (H15) — LedgerAdjustmentDialog y
 * BankAccountFormDialog solo hacían `reset()` en el submit EXITOSO: descartar
 * con Escape/Cancelar y reabrir mostraba el borrador entero (a un clic de un
 * "Confirmar ajuste" irreversible), y cambiar de kind (banco→billetera)
 * arrastraba nombre, saldo y hasta el error de validación del intento previo.
 */
import React, { useState } from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, waitFor } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import "@testing-library/jest-dom"

vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }))

const createBankAccountMock = vi.fn()
vi.mock("@/hooks/data/use-bank-accounts", () => ({
  useBankAccounts: () => ({
    createBankAccount: createBankAccountMock,
    createBankAccountMutation: { isPending: false },
  }),
}))

import { LedgerAdjustmentDialog } from "@/components/ledger/LedgerAdjustmentDialog"
import { BankAccountFormDialog } from "@/components/bank-accounts/BankAccountFormDialog"
import type { AccountKind } from "@/lib/bank-account-kind"

function AdjustmentHarness() {
  const [open, setOpen] = useState(false)
  return (
    <>
      <button type="button" onClick={() => setOpen(true)}>abrir ajuste</button>
      <LedgerAdjustmentDialog
        open={open}
        onOpenChange={setOpen}
        mode="cash"
        canSubmit={true}
        isSubmitting={false}
        onConfirm={vi.fn().mockResolvedValue(undefined)}
      />
    </>
  )
}

function BankAccountHarness() {
  const [open, setOpen] = useState(false)
  const [kind, setKind] = useState<AccountKind>("bank")
  return (
    <>
      <button type="button" onClick={() => { setKind("bank"); setOpen(true) }}>abrir banco</button>
      <button type="button" onClick={() => { setKind("wallet"); setOpen(true) }}>abrir billetera</button>
      <BankAccountFormDialog open={open} onOpenChange={setOpen} kind={kind} />
    </>
  )
}

beforeEach(() => {
  vi.clearAllMocks()
})

describe("LedgerAdjustmentDialog — reset al descartar (G11/H15)", () => {
  it("Escape descarta el borrador: reabrir muestra el formulario limpio", async () => {
    const user = userEvent.setup()
    render(<AdjustmentHarness />)

    await user.click(screen.getByRole("button", { name: "abrir ajuste" }))
    await user.click(screen.getByLabelText(/Faltante/))
    await user.clear(screen.getByLabelText(/Importe/))
    await user.type(screen.getByLabelText(/Importe/), "55555")
    await user.type(screen.getByLabelText(/Motivo/), "motivo largo del ajuste descartado")

    await user.keyboard("{Escape}")
    await waitFor(() =>
      expect(screen.queryByText("Registrar ajuste")).not.toBeInTheDocument(),
    )

    await user.click(screen.getByRole("button", { name: "abrir ajuste" }))
    expect(screen.getByLabelText(/Importe/)).toHaveValue(0)
    expect(screen.getByLabelText(/Motivo/)).toHaveValue("")
    expect(screen.getByLabelText(/Sobrante/)).toBeChecked()
    expect(screen.getByLabelText(/Faltante/)).not.toBeChecked()
  })
})

describe("BankAccountFormDialog — reset al descartar y al cambiar de kind (G11/H15)", () => {
  it("Cancelar descarta el borrador: reabrir muestra el formulario limpio", async () => {
    const user = userEvent.setup()
    render(<BankAccountHarness />)

    await user.click(screen.getByRole("button", { name: "abrir banco" }))
    await user.type(screen.getByLabelText(/Nombre \*/), "Galicia sucia")
    await user.clear(screen.getByLabelText(/Saldo inicial/))
    await user.type(screen.getByLabelText(/Saldo inicial/), "12345")

    await user.click(screen.getByRole("button", { name: "Cancelar" }))
    await waitFor(() =>
      expect(screen.queryByLabelText(/Nombre \*/)).not.toBeInTheDocument(),
    )

    await user.click(screen.getByRole("button", { name: "abrir billetera" }))
    expect(screen.getByLabelText(/Nombre \*/)).toHaveValue("")
  })

  it("el error de validación del intento previo no se arrastra al otro kind", async () => {
    const user = userEvent.setup()
    render(<BankAccountHarness />)

    // Intento de enviar vacío en banco: aparece el error de nombre.
    await user.click(screen.getByRole("button", { name: "abrir banco" }))
    await user.click(screen.getByRole("button", { name: "Crear" }))
    expect(await screen.findByText("El nombre es obligatorio")).toBeInTheDocument()
    expect(createBankAccountMock).not.toHaveBeenCalled()

    await user.keyboard("{Escape}")
    await waitFor(() =>
      expect(screen.queryByLabelText(/Nombre \*/)).not.toBeInTheDocument(),
    )

    // La billetera abre sin el error fantasma sobre un campo jamás tocado.
    await user.click(screen.getByRole("button", { name: "abrir billetera" }))
    expect(screen.queryByText("El nombre es obligatorio")).not.toBeInTheDocument()
  })
})
