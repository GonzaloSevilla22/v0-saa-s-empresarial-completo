/**
 * remitos-venta (tanda B, 7.4) — `SaleCheckoutFields` gana la prop aditiva
 * `branchReadOnly`: la sucursal se MUESTRA (por nombre) en vez de elegirse. La
 * usa la conversión de un remito, que se imputa a la sucursal de donde salió el
 * stock (D7). El presupuesto no la pasa y tiene que seguir exactamente igual:
 * `BranchSelect` con su valor y su placeholder.
 */
import React from "react"
import { describe, it, expect, vi } from "vitest"
import { render, screen, fireEvent } from "@testing-library/react"
import "@testing-library/jest-dom"

vi.mock("@/hooks/data/use-customer-account", () => ({
  useCustomerAccount: () => ({ data: undefined }),
}))
vi.mock("@/components/branches/BranchSelect", () => ({
  BranchSelect: ({
    value,
    onChange,
    placeholder,
  }: {
    value: string | null
    onChange: (v: string | null) => void
    placeholder?: string
  }) => (
    <select
      aria-label="Selector de sucursal"
      data-placeholder={placeholder}
      value={value ?? ""}
      onChange={(e) => onChange(e.target.value || null)}
    >
      <option value="">{placeholder}</option>
      <option value="b-1">Central</option>
      <option value="b-2">Norte</option>
    </select>
  ),
}))
vi.mock("@/components/payment-methods/PaymentMethodSelect", () => ({
  PaymentMethodSelect: () => <div data-testid="payment-method-select" />,
  BankAccountDestinationSelect: () => <div data-testid="bank-select" />,
}))

import { SaleCheckoutFields } from "@/components/ventas/SaleCheckoutFields"
import type { SaleCheckoutState } from "@/hooks/use-sale-checkout"

const checkout = {
  kind: null,
  cash: { isCashSelected: false, session: null, effectiveBranchId: "b-1" },
  cashSessionId: null,
  block: null,
  blockedReason: null,
} as unknown as SaleCheckoutState

function renderFields(extra: Partial<React.ComponentProps<typeof SaleCheckoutFields>> = {}) {
  const onBranchChange = vi.fn()
  render(
    <SaleCheckoutFields
      branchId="b-1"
      onBranchChange={onBranchChange}
      paymentMethodId={null}
      onPaymentMethodChange={vi.fn()}
      bankAccountId={null}
      onBankAccountChange={vi.fn()}
      clientId="c-1"
      checkout={checkout}
      {...extra}
    />,
  )
  return { onBranchChange }
}

describe("SaleCheckoutFields — sucursal", () => {
  it("sin la prop (el presupuesto): el selector de sucursal de siempre, con su valor y su placeholder", () => {
    const { onBranchChange } = renderFields()

    const select = screen.getByLabelText("Selector de sucursal")
    expect(select).toHaveValue("b-1")
    expect(select).toHaveAttribute("data-placeholder", "Sucursal por defecto")
    fireEvent.change(select, { target: { value: "b-2" } })
    expect(onBranchChange).toHaveBeenCalledWith("b-2")
  })

  it("con branchReadOnly: muestra el NOMBRE de la sucursal y no ofrece ningún selector", () => {
    renderFields({ branchReadOnly: true, branchName: "Sucursal Centro" })

    expect(screen.queryByLabelText("Selector de sucursal")).not.toBeInTheDocument()
    expect(screen.getByText("Sucursal Centro")).toBeInTheDocument()
    expect(screen.getByText("Sucursal")).toBeInTheDocument()
  })

  it("con branchReadOnly y sin nombre resuelto: no inventa uno, dice que es la del remito", () => {
    renderFields({ branchReadOnly: true, branchName: null })

    expect(screen.queryByLabelText("Selector de sucursal")).not.toBeInTheDocument()
    expect(screen.getByText(/sucursal del remito/i)).toBeInTheDocument()
  })

  it("branchReadOnly = false equivale a no pasarla", () => {
    renderFields({ branchReadOnly: false, branchName: "Sucursal Centro" })

    expect(screen.getByLabelText("Selector de sucursal")).toBeInTheDocument()
    expect(screen.queryByText("Sucursal Centro")).not.toBeInTheDocument()
  })

  it("el resto de los campos (forma de pago, cuenta bancaria) sigue igual con la sucursal fija", () => {
    renderFields({ branchReadOnly: true, branchName: "Sucursal Centro" })

    expect(screen.getByTestId("payment-method-select")).toBeInTheDocument()
    expect(screen.getByTestId("bank-select")).toBeInTheDocument()
  })
})
