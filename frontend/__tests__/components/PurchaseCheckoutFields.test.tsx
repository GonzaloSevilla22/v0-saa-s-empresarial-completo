/**
 * remitos-compra (tanda B, 7.3, D11) — `PurchaseCheckoutFields`: los campos de
 * cierre de una compra (fecha, centro de costo, forma de pago, cuenta bancaria,
 * opt-in de caja y saldo del proveedor a crédito), extraídos de `purchase-form.tsx`
 * para que el formulario y el diálogo de conversión de un remito los compartan.
 *
 * Es CONTROLADO y no decide nada: lo derivado (kind, caja, saldo) viene de
 * `usePurchaseCheckout`. Dos props nuevas respecto de lo que ya hacía el
 * formulario, ambas con default que no cambia nada:
 *   - `showDueDate`: el vencimiento de la deuda (con la cascada de
 *     `useDueDateCascade`), sólo a crédito;
 *   - `paymentRequired`: la forma de pago es obligatoria (OQ-RC4).
 */
import { describe, it, expect, vi } from "vitest"
import { render, screen, fireEvent, within } from "@testing-library/react"
import type { ReactNode } from "react"

vi.mock("@/components/payment-methods/PaymentMethodSelect", () => ({
  PaymentMethodSelect: (props: { value: string | null; required?: boolean; context?: string }) => (
    <div data-testid="payment-method-select" data-required={String(!!props.required)} data-context={props.context}>
      valor:{props.value ?? "null"}
    </div>
  ),
  BankAccountDestinationSelect: (props: { paymentMethodKind: string | null }) => (
    <div data-testid="bank-account-select" data-kind={props.paymentMethodKind ?? "null"} />
  ),
}))
vi.mock("@/components/cost-centers/CostCenterSelect", () => ({
  CostCenterSelect: () => <div data-testid="cost-center-select" />,
}))

import { PurchaseCheckoutFields } from "@/components/compras/PurchaseCheckoutFields"
import type { PurchaseCheckoutState } from "@/hooks/use-purchase-checkout"
import type { DueDateCascadeState } from "@/hooks/use-due-date-cascade"

function checkoutState(over: Partial<PurchaseCheckoutState> = {}): PurchaseCheckoutState {
  return {
    kind: null,
    isCredit: false,
    cash: {
      isCashSelected: false,
      isDateToday: true,
      effectiveBranchId: "branch-1",
      cashboxId: null,
      session: null,
      eligible: false,
      reason: "Sólo un pago en efectivo puede registrarse en la caja.",
    },
    showCashBlock: false,
    registerInCash: true,
    setRegisterInCash: vi.fn(),
    cashSessionId: null,
    supplierBalance: 0,
    projectedBalance: 0,
    creditBlockedNoSupplier: false,
    paymentMethods: [],
    ...over,
  }
}

function dueDateState(over: Partial<DueDateCascadeState> = {}): DueDateCascadeState {
  return {
    dueDate: "",
    touched: false,
    setDueDate: vi.fn(),
    effectiveTermsDays: null,
    termsSource: null,
    valueForServer: null,
    ...over,
  }
}

const baseProps = {
  date: "2026-10-15",
  onDateChange: vi.fn(),
  costCenterId: null,
  onCostCenterChange: vi.fn(),
  paymentMethodId: null,
  onPaymentMethodChange: vi.fn(),
  bankAccountId: null,
  onBankAccountChange: vi.fn(),
}

function renderFields(over: Partial<React.ComponentProps<typeof PurchaseCheckoutFields>> = {}) {
  return render(<PurchaseCheckoutFields checkout={checkoutState()} {...baseProps} {...over} />)
}

describe("PurchaseCheckoutFields — campos base", () => {
  it("muestra fecha, centro de costo y forma de pago (opcional por defecto)", () => {
    renderFields()
    expect(screen.getByLabelText("Fecha")).toHaveValue("2026-10-15")
    expect(screen.getByTestId("cost-center-select")).toBeInTheDocument()
    const pm = screen.getByTestId("payment-method-select")
    expect(pm).toHaveAttribute("data-required", "false")
    expect(pm).toHaveAttribute("data-context", "purchase")
  })

  it("editar la fecha la reporta", () => {
    const onDateChange = vi.fn()
    renderFields({ onDateChange })
    fireEvent.change(screen.getByLabelText("Fecha"), { target: { value: "2026-10-16" } })
    expect(onDateChange).toHaveBeenCalledWith("2026-10-16")
  })

  it("minDate acota la fecha desde la recepción del remito", () => {
    renderFields({ minDate: "2026-10-14" })
    expect(screen.getByLabelText("Fecha")).toHaveAttribute("min", "2026-10-14")
  })

  it("la fecha nunca admite el futuro (la caja y el costo exigen hoy o antes)", () => {
    renderFields()
    expect(screen.getByLabelText("Fecha")).toHaveAttribute("max")
  })
})

describe("PurchaseCheckoutFields — paymentRequired", () => {
  it("lo pasa al selector de forma de pago", () => {
    renderFields({ paymentRequired: true })
    expect(screen.getByTestId("payment-method-select")).toHaveAttribute("data-required", "true")
  })
})

describe("PurchaseCheckoutFields — cuenta bancaria", () => {
  it("en el alta monta el selector de destino con el kind elegido", () => {
    renderFields({ checkout: checkoutState({ kind: "transfer" }) })
    expect(screen.getByTestId("bank-account-select")).toHaveAttribute("data-kind", "transfer")
  })

  it("en la edición NO se monta (la RPC de edición no tiene destino bancario, D8)", () => {
    renderFields({ mode: "edit", checkout: checkoutState({ kind: "transfer" }) })
    expect(screen.queryByTestId("bank-account-select")).not.toBeInTheDocument()
  })
})

describe("PurchaseCheckoutFields — opt-in de caja", () => {
  const eligible = checkoutState({
    kind: "cash",
    showCashBlock: true,
    cash: {
      isCashSelected: true, isDateToday: true, effectiveBranchId: "branch-1", cashboxId: "cb-1",
      session: { id: "abcdef12-0000-0000-0000-000000000000" } as never, eligible: true, reason: "",
    },
  })

  it("elegible: casilla «Registrar en caja» con la sesión y tildada por defecto", () => {
    renderFields({ checkout: eligible })
    const checkbox = screen.getByRole("checkbox")
    expect(checkbox).toBeChecked()
    expect(screen.getByText(/Registrar en caja — sesión abcdef12…/)).toBeInTheDocument()
  })

  it("destildar reporta la intención", () => {
    const setRegisterInCash = vi.fn()
    renderFields({ checkout: { ...eligible, setRegisterInCash } })
    fireEvent.click(screen.getByRole("checkbox"))
    expect(setRegisterInCash).toHaveBeenCalledWith(false)
  })

  it("no elegible: explica el motivo en una nota (nunca se oculta en silencio)", () => {
    renderFields({
      checkout: checkoutState({
        kind: "cash",
        showCashBlock: true,
        cash: {
          isCashSelected: true, isDateToday: true, effectiveBranchId: "branch-1", cashboxId: null,
          session: null, eligible: false, reason: "No hay caja abierta en esta sucursal — el efectivo no se registrará en el arqueo.",
        },
      }),
    })
    expect(screen.queryByRole("checkbox")).not.toBeInTheDocument()
    expect(screen.getByRole("note")).toHaveTextContent("No hay caja abierta en esta sucursal")
  })

  it("sin showCashBlock (otra forma de pago o edición) no hay bloque de caja", () => {
    renderFields({ checkout: checkoutState({ kind: "transfer", showCashBlock: false }) })
    expect(screen.queryByRole("checkbox")).not.toBeInTheDocument()
    expect(screen.queryByRole("note")).not.toBeInTheDocument()
  })
})

describe("PurchaseCheckoutFields — cuenta corriente del proveedor", () => {
  const credit = checkoutState({ kind: "credit", isCredit: true, supplierBalance: 1000, projectedBalance: 1250 })

  it("a crédito en el alta: saldo actual y saldo después de la compra", () => {
    renderFields({ checkout: credit })
    expect(screen.getByText(/Saldo actual:/)).toHaveTextContent("$")
    expect(screen.getByText(/Después de esta compra:/)).toBeInTheDocument()
  })

  it("a crédito sin proveedor: advertencia y ningún saldo", () => {
    renderFields({ checkout: { ...credit, creditBlockedNoSupplier: true } })
    expect(
      screen.getByText("Elegí un proveedor: una compra a cuenta corriente se le carga a alguien."),
    ).toBeInTheDocument()
    expect(screen.queryByText(/Saldo actual:/)).not.toBeInTheDocument()
  })

  it("en la edición sólo muestra el saldo actual (la edición nunca postea cargos)", () => {
    renderFields({ mode: "edit", checkout: credit })
    expect(screen.getByText(/Saldo actual:/)).toBeInTheDocument()
    expect(screen.queryByText(/Después de esta compra:/)).not.toBeInTheDocument()
  })

  it("en la edición, pasar a crédito desde otra forma de pago se avisa", () => {
    renderFields({ mode: "edit", checkout: credit, isTransitioningToCredit: true })
    expect(
      screen.getByText("La edición no postea cargos: para pasar esta compra a crédito, borrala y volvé a cargarla."),
    ).toBeInTheDocument()
  })

  it("con otra forma de pago no hay bloque de crédito", () => {
    renderFields({ checkout: checkoutState({ kind: "transfer" }) })
    expect(screen.queryByText(/Saldo actual:/)).not.toBeInTheDocument()
  })
})

describe("PurchaseCheckoutFields — vencimiento (showDueDate)", () => {
  const credit = checkoutState({ kind: "credit", isCredit: true, supplierBalance: 0, projectedBalance: 300 })

  it("a crédito con showDueDate: campo «Vencimiento» pre-cargado y su origen", () => {
    renderFields({
      checkout: credit,
      showDueDate: true,
      dueDate: dueDateState({ dueDate: "2026-11-14", effectiveTermsDays: 30, termsSource: "entity" }),
    })
    const input = screen.getByLabelText("Vencimiento") as HTMLInputElement
    expect(input.value).toBe("2026-11-14")
    expect(input).toHaveAttribute("min", "2026-10-15")
    expect(screen.getByText("Resuelto por el plazo del proveedor (30 días).")).toBeInTheDocument()
  })

  it("sin plazo del proveedor usa el de la cuenta y lo dice", () => {
    renderFields({
      checkout: credit,
      showDueDate: true,
      dueDate: dueDateState({ dueDate: "2026-11-14", effectiveTermsDays: 30, termsSource: "account" }),
    })
    expect(screen.getByText("Resuelto por el plazo de la cuenta (30 días).")).toBeInTheDocument()
  })

  it("sin ningún plazo avisa que el cargo nace sin vencimiento", () => {
    renderFields({ checkout: credit, showDueDate: true, dueDate: dueDateState() })
    expect(screen.getByText(/Sin plazo configurado: el cargo nace sin vencimiento/)).toBeInTheDocument()
  })

  it("editarlo reporta el cambio y, una vez elegido, el texto lo dice", () => {
    const setDueDate = vi.fn()
    const { rerender } = renderFields({
      checkout: credit, showDueDate: true, dueDate: dueDateState({ dueDate: "2026-11-14", termsSource: "entity", effectiveTermsDays: 30, setDueDate }),
    })
    fireEvent.change(screen.getByLabelText("Vencimiento"), { target: { value: "2026-12-01" } })
    expect(setDueDate).toHaveBeenCalledWith("2026-12-01")

    rerender(
      <PurchaseCheckoutFields
        checkout={credit}
        {...baseProps}
        showDueDate
        dueDate={dueDateState({ dueDate: "2026-12-01", touched: true, setDueDate })}
      />,
    )
    expect(screen.getByText("Vencimiento elegido para esta compra.")).toBeInTheDocument()
  })

  it("showDueDate apagado (el formulario de compra directa): no hay campo de vencimiento", () => {
    renderFields({ checkout: credit })
    expect(screen.queryByLabelText("Vencimiento")).not.toBeInTheDocument()
  })

  it("showDueDate sin crédito: no hay campo de vencimiento", () => {
    renderFields({ checkout: checkoutState({ kind: "transfer" }), showDueDate: true, dueDate: dueDateState() })
    expect(screen.queryByLabelText("Vencimiento")).not.toBeInTheDocument()
  })
})

describe("PurchaseCheckoutFields — slots del formulario", () => {
  it("afterDate va entre la fecha y el resto de los campos; beforeCredit antes del bloque de crédito", () => {
    const slot = (id: string): ReactNode => <div data-testid={id} />
    const { container } = renderFields({
      checkout: checkoutState({ kind: "credit", isCredit: true, projectedBalance: 10 }),
      afterDate: slot("slot-after-date"),
      beforeCredit: slot("slot-before-credit"),
    })
    const order = Array.from(container.querySelectorAll("[data-testid], input[type=date]")).map((el) =>
      el.getAttribute("data-testid") ?? "date",
    )
    expect(order.indexOf("date")).toBeLessThan(order.indexOf("slot-after-date"))
    expect(order.indexOf("slot-after-date")).toBeLessThan(order.indexOf("cost-center-select"))
    expect(order.indexOf("payment-method-select")).toBeLessThan(order.indexOf("slot-before-credit"))
  })

  it("el bloque de crédito va DESPUÉS de beforeCredit (el selector de proveedor)", () => {
    const { container } = renderFields({
      checkout: checkoutState({ kind: "credit", isCredit: true, projectedBalance: 10 }),
      beforeCredit: <div data-testid="slot-before-credit" />,
    })
    const slot = screen.getByTestId("slot-before-credit")
    const saldo = within(container).getByText(/Saldo actual:/)
    expect(slot.compareDocumentPosition(saldo) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
  })
})
