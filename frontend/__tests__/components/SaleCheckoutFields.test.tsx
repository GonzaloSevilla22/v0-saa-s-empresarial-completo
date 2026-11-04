/**
 * remitos-venta (tanda B, 7.4) — `SaleCheckoutFields` gana la prop aditiva
 * `branchReadOnly`: la sucursal se MUESTRA (por nombre) en vez de elegirse. La
 * usa la conversión de un remito, que se imputa a la sucursal de donde salió el
 * stock (D7). El presupuesto no la pasa y sigue usando `BranchSelect` con su valor.
 *
 * ventas-sucursal-por-defecto (D9, tarea 6.7): la conversión de un presupuesto
 * REGISTRA UNA VENTA, así que su selector de sucursal sigue la regla de toda
 * superficie que registra una venta: `allowUnassigned={false}` (sin «Sucursal por
 * defecto»/«Sin sucursal»: se ve siempre la sucursal que se va a usar) y el rótulo
 * «Sucursal» DENTRO del selector (no huérfano en las cuentas sin el módulo).
 */
import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent } from "@testing-library/react"
import "@testing-library/jest-dom"

vi.mock("@/hooks/data/use-customer-account", () => ({
  useCustomerAccount: () => ({ data: undefined }),
}))
// Props con las que el contenedor monta el selector (última render).
const branchSelectProps = vi.hoisted(() => ({
  last: null as null | { value: string | null; allowUnassigned?: boolean; label?: string; placeholder?: string },
}))
vi.mock("@/components/branches/BranchSelect", () => ({
  BranchSelect: (props: {
    value: string | null
    onChange: (v: string | null) => void
    allowUnassigned?: boolean
    label?: string
    placeholder?: string
  }) => {
    branchSelectProps.last = props
    return (
      <select
        aria-label="Selector de sucursal"
        value={props.value ?? ""}
        onChange={(e) => props.onChange(e.target.value || null)}
      >
        <option value="b-1">Central</option>
        <option value="b-2">Norte</option>
      </select>
    )
  },
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

beforeEach(() => {
  branchSelectProps.last = null
})

describe("SaleCheckoutFields — sucursal", () => {
  it("sin la prop (el presupuesto): el selector de sucursal con su valor, sin opción «sin sucursal» y con el rótulo propio (la venta siempre tiene sucursal)", () => {
    const { onBranchChange } = renderFields()

    const select = screen.getByLabelText("Selector de sucursal")
    expect(select).toHaveValue("b-1")
    expect(branchSelectProps.last?.allowUnassigned).toBe(false)
    expect(branchSelectProps.last?.label).toBe("Sucursal")
    expect(branchSelectProps.last?.placeholder).toBeUndefined()
    fireEvent.change(select, { target: { value: "b-2" } })
    expect(onBranchChange).toHaveBeenCalledWith("b-2")
  })

  it("el rótulo «Sucursal» lo pone el selector: el contenedor no agrega un <label> huérfano aparte", () => {
    renderFields()

    // El selector está mockeado y no dibuja su rótulo: si el contenedor lo dibujara
    // también, aparecería acá (en las cuentas sin módulo quedaría suelto, sin control).
    expect(screen.queryByText("Sucursal")).not.toBeInTheDocument()
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

// caja-optin-carga — el motivo de bloqueo mientras se averigua la sesión es un aviso de
// ESPERA (spinner, sin enlace a /caja), no la advertencia de «abrí la caja».
describe("SaleCheckoutFields — caja cargando (caja-optin-carga)", () => {
  const loadingCheckout = {
    ...checkout,
    block: "cash_loading",
    blockedReason: "Verificando la caja…",
  } as unknown as SaleCheckoutState

  it("muestra «Verificando la caja…» como estado, con un spinner y SIN el enlace «Ir a Caja»", () => {
    const { container } = render(
      <SaleCheckoutFields
        branchId="b-1"
        onBranchChange={vi.fn()}
        paymentMethodId="pm-cash"
        onPaymentMethodChange={vi.fn()}
        bankAccountId={null}
        onBankAccountChange={vi.fn()}
        clientId="c-1"
        checkout={loadingCheckout}
      />,
    )

    expect(screen.getByRole("status")).toHaveTextContent("Verificando la caja…")
    expect(screen.queryByRole("link", { name: /ir a caja/i })).not.toBeInTheDocument()
    expect(container.querySelector("svg.animate-spin")).not.toBeNull()
  })

  it("el bloqueo «abrí la caja» (ya resuelto, sin sesión) conserva el enlace a /caja y la advertencia", () => {
    const { container } = render(
      <SaleCheckoutFields
        branchId="b-1"
        onBranchChange={vi.fn()}
        paymentMethodId="pm-cash"
        onPaymentMethodChange={vi.fn()}
        bankAccountId={null}
        onBankAccountChange={vi.fn()}
        clientId="c-1"
        checkout={{ ...checkout, block: "cash_session", blockedReason: "Abrí la caja de esta sucursal." } as unknown as SaleCheckoutState}
      />,
    )

    expect(screen.getByRole("link", { name: /ir a caja/i })).toHaveAttribute("href", "/caja")
    expect(container.querySelector("svg.animate-spin")).toBeNull()
  })
})
