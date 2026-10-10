/**
 * presupuestos-modulo (D6/D12, tarea 6.8) — `ConvertQuoteDialog`: la conversión
 * atómica de un presupuesto en venta.
 *
 * Invariantes bajo test:
 *  - resumen de líneas y total en sólo lectura (nadie edita el presupuesto acá);
 *  - "Venta" exige forma de pago; la sucursal por defecto es la del presupuesto;
 *  - caja con la semántica del POS: con `kind = cash` se manda SIEMPRE la sesión
 *    abierta de la sucursal elegida, sin checkbox; sin sesión, "Venta" queda
 *    deshabilitada con el motivo y un enlace a /caja;
 *  - con `credit`, el saldo actual del cliente;
 *  - manda `expected_revision` = la revisión que muestra el resumen;
 *  - éxito (también con `replayed: true`): "Venta registrada" con el foco en el
 *    título + EmitInvoiceButton + "Ver en Ventas";
 *  - errores dentro del diálogo, en `role="alert"`, sin cerrar: stock con el
 *    producto, producto dado de baja ("editá el presupuesto"), `quote_changed`
 *    (recarga el detalle);
 *  - doble clic → una sola request efectiva;
 *  - la clave de idempotencia es POR presupuesto y se resetea tras cada éxito.
 */
import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent, waitFor, within, act } from "@testing-library/react"
import "@testing-library/jest-dom"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"

import { PythonApiError } from "@/lib/api/python-api-error"
import type { QuoteApiRow, QuoteConvertResult } from "@/lib/quote-types"

const mocks = vi.hoisted(() => ({
  convert: vi.fn(),
  session: null as { id: string } | null,
  customerBalance: 0,
  emitProps: vi.fn(),
  bankSelectProps: vi.fn(),
  branches: [{ id: "b-1", name: "Central", isActive: true }, { id: "b-2", name: "Norte", isActive: true }] as Array<{ id: string; name: string; isActive?: boolean; status?: string }>,
}))

vi.mock("@/hooks/data/use-quotes", () => ({
  useConvertQuote: () => ({ mutateAsync: mocks.convert, isPending: false }),
}))
vi.mock("@/hooks/data/use-payment-methods", () => ({
  usePaymentMethods: () => ({
    paymentMethods: [
      { id: "pm-cash", name: "Efectivo", kind: "cash", isActive: true, bankAccountId: null },
      { id: "pm-transfer", name: "Transferencia", kind: "transfer", isActive: true, bankAccountId: null },
      { id: "pm-credit", name: "Cuenta corriente", kind: "credit", isActive: true, bankAccountId: null },
    ],
    isLoading: false,
  }),
}))
vi.mock("@/hooks/data/use-branches", () => ({
  useBranches: () => ({ branches: mocks.branches }),
}))
vi.mock("@/hooks/data/use-cashboxes", () => ({
  useCashboxes: (branchId: string | null) => ({ data: branchId ? [{ id: `cb-${branchId}` }] : undefined }),
}))
vi.mock("@/hooks/data/use-cash-session", () => ({
  useCurrentSession: (cashboxId: string | null) => ({ data: cashboxId ? mocks.session ?? undefined : undefined }),
}))
vi.mock("@/hooks/data/use-customer-account", () => ({
  useCustomerAccount: (clientId: string | null) => ({
    data: clientId ? { balance: mocks.customerBalance } : undefined,
  }),
}))
vi.mock("@/hooks/data/use-products", () => ({
  useProducts: () => ({ products: [{ id: "0dd2e5bb-2b93-4470-b4b6-52f008046112", name: "Remera" }], isLoading: false }),
}))
vi.mock("@/hooks/data/use-fiscal-profile", () => ({
  useFiscalProfile: () => ({ profile: { ivaCondition: "monotributista" } }),
}))
vi.mock("@/components/fiscal/EmitInvoiceButton", () => ({
  EmitInvoiceButton: (props: { salesOrderId: string; salesOrderStatus: string; fiscalDocumentId: string | null }) => {
    mocks.emitProps(props)
    return <button type="button">Facturar (mock)</button>
  },
}))
vi.mock("@/components/branches/BranchSelect", () => ({
  BranchSelect: ({
    value,
    onChange,
    allowUnassigned = true,
  }: {
    value: string | null
    onChange: (v: string | null) => void
    allowUnassigned?: boolean
  }) => (
    <select
      aria-label="Sucursal"
      data-allow-unassigned={String(allowUnassigned)}
      value={value ?? ""}
      onChange={(e) => onChange(e.target.value || null)}
    >
      {allowUnassigned && <option value="">Sucursal por defecto</option>}
      <option value="b-1">Central</option>
      <option value="b-2">Norte</option>
    </select>
  ),
}))
vi.mock("@/components/payment-methods/PaymentMethodSelect", () => ({
  PaymentMethodSelect: ({ value, onChange }: { value: string | null; onChange: (v: string | null) => void }) => (
    <select aria-label="Forma de pago" value={value ?? ""} onChange={(e) => onChange(e.target.value || null)}>
      <option value="">Elegí la forma de pago</option>
      <option value="pm-cash">Efectivo</option>
      <option value="pm-transfer">Transferencia</option>
      <option value="pm-credit">Cuenta corriente</option>
    </select>
  ),
  BankAccountDestinationSelect: (props: { paymentMethodKind: string | null; onChange: (v: string | null) => void }) => {
    mocks.bankSelectProps(props)
    return props.paymentMethodKind === "transfer" ? (
      <select aria-label="Cuenta bancaria" onChange={(e) => props.onChange(e.target.value || null)}>
        <option value="">Usar el destino configurado</option>
        <option value="ba-1">Banco Nación</option>
      </select>
    ) : null
  },
}))

import { ConvertQuoteDialog } from "@/components/quotes/ConvertQuoteDialog"

function quote(overrides: Partial<QuoteApiRow> = {}): QuoteApiRow {
  return {
    id: "q-1",
    number: 12,
    number_label: "P-00000012",
    status: "sent",
    revision: 3,
    client_id: "c-1",
    client_name: "Ana Pérez",
    client_phone: null,
    branch_id: null,
    valid_until: "2999-10-16",
    notes: null,
    total: "3000.00",
    sent_at: "2026-10-01T16:00:00Z",
    created_at: "2026-10-01T15:00:00Z",
    created_by: "u-1",
    updated_at: null,
    updated_by: null,
    is_expired: false,
    sales_order_id: null,
    items: [
      {
        id: "i-1", quote_id: "q-1", product_id: "0dd2e5bb-2b93-4470-b4b6-52f008046112", unit_id: "u-u", unit_symbol: "u",
        quantity: "2.0000", price: "1500", subtotal: "3000", name_snapshot: "Remera", sku_snapshot: null, line_no: 1,
      },
      {
        id: "i-2", quote_id: "q-1", product_id: null, unit_id: null, unit_symbol: null,
        quantity: "1.0000", price: "0", subtotal: "0", name_snapshot: "Flete a domicilio", sku_snapshot: null, line_no: 2,
      },
    ],
    history: [],
    ...overrides,
  }
}

const RESULT: QuoteConvertResult = {
  quote_id: "q-1",
  quote_number: 12,
  quote_number_label: "P-00000012",
  sales_order_id: "so-1",
  operation_id: "op-1",
  total: "3000.00",
  replayed: false,
}

let queryClient: QueryClient
let invalidateSpy: ReturnType<typeof vi.spyOn>

function renderDialog(q: QuoteApiRow = quote(), onOpenChange: (open: boolean) => void = vi.fn()) {
  const view = render(
    <QueryClientProvider client={queryClient}>
      <ConvertQuoteDialog quote={q} open onOpenChange={onOpenChange} />
    </QueryClientProvider>,
  )
  return { ...view, onOpenChange }
}

function pickPayment(id: string) {
  fireEvent.change(screen.getByLabelText("Forma de pago"), { target: { value: id } })
}

const saleButton = () => screen.getByRole("button", { name: /^registrar venta$/i })

beforeEach(() => {
  vi.clearAllMocks()
  window.sessionStorage.clear()
  mocks.session = { id: "cs-1" }
  mocks.customerBalance = 0
  mocks.branches = [{ id: "b-1", name: "Central", isActive: true }, { id: "b-2", name: "Norte", isActive: true }]
  mocks.convert.mockResolvedValue(RESULT)
  queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  invalidateSpy = vi.spyOn(queryClient, "invalidateQueries")
})

describe("ConvertQuoteDialog — resumen y campos", () => {
  it("muestra las líneas y el total en sólo lectura, sin ningún campo editable de líneas", () => {
    renderDialog()
    const dialog = screen.getByRole("dialog")

    expect(within(dialog).getByText("Remera")).toBeInTheDocument()
    expect(within(dialog).getByText("Flete a domicilio")).toBeInTheDocument()
    expect(within(dialog).getByText(/P-00000012/)).toBeInTheDocument()
    expect(within(dialog).getByText(/Ana Pérez/)).toBeInTheDocument()
    expect(within(dialog).getByTestId("convert-quote-total")).toHaveTextContent(/3\.000/)
    expect(within(dialog).queryByRole("spinbutton")).not.toBeInTheDocument()
  })

  it("'Registrar venta' queda deshabilitada hasta elegir la forma de pago, y lo explica", () => {
    renderDialog()

    expect(saleButton()).toBeDisabled()
    expect(saleButton()).toHaveAccessibleDescription(/elegí la forma de pago/i)

    pickPayment("pm-transfer")
    expect(saleButton()).toBeEnabled()
  })

  it("la sucursal por defecto es la del presupuesto", () => {
    renderDialog(quote({ branch_id: "b-2" }))
    expect(screen.getByLabelText("Sucursal")).toHaveValue("b-2")
  })

  // ventas-sucursal-por-defecto (D9, 6.7): la conversión registra una venta, así que su
  // selector no ofrece «sin sucursal» y muestra de entrada la que se va a usar.
  it("el selector de la conversión no ofrece «sin sucursal»: con el presupuesto en B y la principal A, muestra B y la venta queda en B", async () => {
    renderDialog(quote({ branch_id: "b-2" }))

    const selector = screen.getByLabelText("Sucursal")
    expect(selector).toHaveAttribute("data-allow-unassigned", "false")
    expect(selector).toHaveValue("b-2")
    expect(screen.queryByRole("option", { name: /por defecto/i })).not.toBeInTheDocument()

    pickPayment("pm-transfer")
    fireEvent.click(saleButton())
    await waitFor(() => expect(mocks.convert).toHaveBeenCalledTimes(1))
    expect(mocks.convert.mock.calls[0][0].payload.branch_id).toBe("b-2")
  })

  it("sin sucursal en el presupuesto muestra la principal (la primera operativa), y es la que viaja", async () => {
    renderDialog()

    expect(screen.getByLabelText("Sucursal")).toHaveValue("b-1")
    pickPayment("pm-transfer")
    fireEvent.click(saleButton())
    await waitFor(() => expect(mocks.convert).toHaveBeenCalledTimes(1))
    expect(mocks.convert.mock.calls[0][0].payload.branch_id).toBe("b-1")
  })

  it("la cuenta bancaria sólo se ofrece con una forma de pago bancaria y se manda si se elige", async () => {
    renderDialog()
    pickPayment("pm-cash")
    expect(screen.queryByLabelText("Cuenta bancaria")).not.toBeInTheDocument()

    pickPayment("pm-transfer")
    fireEvent.change(screen.getByLabelText("Cuenta bancaria"), { target: { value: "ba-1" } })
    fireEvent.click(saleButton())

    await waitFor(() => expect(mocks.convert).toHaveBeenCalledTimes(1))
    expect(mocks.convert.mock.calls[0][0].payload).toMatchObject({
      payment_method_id: "pm-transfer",
      bank_account_id: "ba-1",
      cash_session_id: null,
    })
  })

  it("cambiar de forma de pago descarta la cuenta bancaria elegida para la anterior", async () => {
    renderDialog()
    pickPayment("pm-transfer")
    fireEvent.change(screen.getByLabelText("Cuenta bancaria"), { target: { value: "ba-1" } })
    pickPayment("pm-credit")
    fireEvent.click(saleButton())

    await waitFor(() => expect(mocks.convert).toHaveBeenCalledTimes(1))
    expect(mocks.convert.mock.calls[0][0].payload.bank_account_id).toBeNull()
  })
})

describe("ConvertQuoteDialog — caja con la semántica del POS", () => {
  it("con efectivo manda SIEMPRE la sesión abierta de la sucursal elegida, sin checkbox", async () => {
    renderDialog()
    pickPayment("pm-cash")

    expect(screen.queryByRole("checkbox")).not.toBeInTheDocument()
    fireEvent.click(saleButton())

    await waitFor(() => expect(mocks.convert).toHaveBeenCalledTimes(1))
    expect(mocks.convert.mock.calls[0][0].payload).toMatchObject({
      payment_method_id: "pm-cash",
      cash_session_id: "cs-1",
    })
  })

  it("con efectivo y sin sesión abierta: 'Registrar venta' deshabilitada, con el motivo y el enlace a /caja", () => {
    mocks.session = null
    renderDialog()
    pickPayment("pm-cash")

    expect(saleButton()).toBeDisabled()
    expect(screen.getByText(/abrí la caja de esta sucursal para cobrar en efectivo, o elegí otra forma de pago/i)).toBeInTheDocument()
    expect(screen.getByRole("link", { name: /ir a caja/i })).toHaveAttribute("href", "/caja")
    expect(saleButton()).toHaveAccessibleDescription(/abrí la caja de esta sucursal/i)
  })

  it("sin sesión pero con otra forma de pago NO bloquea y no manda sesión", async () => {
    mocks.session = null
    renderDialog()
    pickPayment("pm-transfer")

    expect(screen.queryByRole("link", { name: /ir a caja/i })).not.toBeInTheDocument()
    fireEvent.click(saleButton())

    await waitFor(() => expect(mocks.convert).toHaveBeenCalledTimes(1))
    expect(mocks.convert.mock.calls[0][0].payload.cash_session_id).toBeNull()
  })

  it("la sesión se resuelve en la sucursal ELEGIDA (b-2), y esa misma sucursal viaja en el payload", async () => {
    renderDialog()
    fireEvent.change(screen.getByLabelText("Sucursal"), { target: { value: "b-2" } })
    pickPayment("pm-cash")
    fireEvent.click(saleButton())

    await waitFor(() => expect(mocks.convert).toHaveBeenCalledTimes(1))
    expect(mocks.convert.mock.calls[0][0].payload).toMatchObject({ branch_id: "b-2", cash_session_id: "cs-1" })
  })
})

describe("ConvertQuoteDialog — sucursal por defecto (revisión 6.11, B-02)", () => {
  it("sin sucursal en el presupuesto ni elegida, la que viaja es la misma con la que se resolvió la caja, no null", async () => {
    renderDialog() // quote.branch_id = null, sin elegir
    pickPayment("pm-cash")
    fireEvent.click(saleButton())

    await waitFor(() => expect(mocks.convert).toHaveBeenCalledTimes(1))
    expect(mocks.convert.mock.calls[0][0].payload).toMatchObject({ branch_id: "b-1", cash_session_id: "cs-1" })
  })

  it("la sucursal por defecto salta las cerradas: igual que c26_default_branch, así caja y venta caen en la misma", async () => {
    mocks.branches = [
      { id: "b-1", name: "Central", isActive: true, status: "closed" },
      { id: "b-2", name: "Norte", isActive: true, status: "active" },
    ]
    renderDialog()
    pickPayment("pm-cash")
    fireEvent.click(saleButton())

    await waitFor(() => expect(mocks.convert).toHaveBeenCalledTimes(1))
    expect(mocks.convert.mock.calls[0][0].payload).toMatchObject({ branch_id: "b-2", cash_session_id: "cs-1" })
  })

  it("la sucursal del presupuesto y la elegida siguen ganando sobre la por defecto", async () => {
    renderDialog(quote({ branch_id: "b-2" }))
    pickPayment("pm-transfer")
    fireEvent.click(saleButton())

    await waitFor(() => expect(mocks.convert).toHaveBeenCalledTimes(1))
    expect(mocks.convert.mock.calls[0][0].payload.branch_id).toBe("b-2")
  })
})

describe("ConvertQuoteDialog — cuenta corriente", () => {
  it("con credit muestra el saldo actual del cliente", () => {
    mocks.customerBalance = 12500
    renderDialog()
    pickPayment("pm-credit")

    expect(screen.getByText(/saldo actual/i)).toHaveTextContent(/12\.500/)
  })

  it("con otra forma de pago no muestra el saldo", () => {
    renderDialog()
    pickPayment("pm-transfer")
    expect(screen.queryByText(/saldo actual/i)).not.toBeInTheDocument()
  })
})

describe("ConvertQuoteDialog — el payload", () => {
  it("manda expected_revision = la revisión que muestra el resumen", async () => {
    renderDialog(quote({ revision: 7 }))
    pickPayment("pm-transfer")
    fireEvent.click(saleButton())

    await waitFor(() => expect(mocks.convert).toHaveBeenCalledTimes(1))
    const arg = mocks.convert.mock.calls[0][0]
    expect(arg.quoteId).toBe("q-1")
    expect(arg.payload.expected_revision).toBe(7)
  })
})

describe("ConvertQuoteDialog — éxito", () => {
  it("pasa a 'Venta registrada' con el foco en el título, Facturar y 'Ver en Ventas'", async () => {
    const { onOpenChange } = renderDialog()
    pickPayment("pm-transfer")
    fireEvent.click(saleButton())

    const title = await screen.findByRole("heading", { name: /venta registrada/i })
    await waitFor(() => expect(title).toHaveFocus())
    expect(screen.getByRole("button", { name: /facturar \(mock\)/i })).toBeInTheDocument()
    expect(mocks.emitProps).toHaveBeenCalledWith(
      expect.objectContaining({ salesOrderId: "so-1", salesOrderStatus: "confirmed", fiscalDocumentId: null }),
    )
    expect(screen.getByRole("link", { name: /ver en ventas/i })).toHaveAttribute("href", "/ventas")
    expect(screen.queryByLabelText("Forma de pago")).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: /^cerrar$/i }))
    expect(onOpenChange).toHaveBeenCalledWith(false)
  })

  it("el replay (replayed: true) se muestra igual, avisando que ya estaba registrada", async () => {
    mocks.convert.mockResolvedValue({ ...RESULT, replayed: true })
    renderDialog()
    pickPayment("pm-transfer")
    fireEvent.click(saleButton())

    await screen.findByRole("heading", { name: /venta registrada/i })
    expect(screen.getByText(/ya estaba registrada/i)).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /facturar \(mock\)/i })).toBeInTheDocument()
  })
})

describe("ConvertQuoteDialog — errores (el diálogo no se cierra)", () => {
  async function submitWith(err: PythonApiError) {
    mocks.convert.mockRejectedValue(err)
    const view = renderDialog()
    pickPayment("pm-transfer")
    fireEvent.click(saleButton())
    const alert = await screen.findByRole("alert")
    return { alert, ...view }
  }

  it("stock insuficiente: nombra el producto, en un role=alert, y el diálogo sigue abierto", async () => {
    const { alert, onOpenChange } = await submitWith(
      new PythonApiError("stock_insuficiente para producto 0dd2e5bb-2b93-4470-b4b6-52f008046112: disponible 1, solicitado 2", 409, {
        code: "stock_insuficiente",
      }),
    )

    expect(alert).toHaveTextContent(/«Remera»/)
    expect(alert).toHaveTextContent(/no hay stock/i)
    expect(onOpenChange).not.toHaveBeenCalledWith(false)
    expect(screen.getByLabelText("Forma de pago")).toBeInTheDocument()
    expect(saleButton()).toBeEnabled()
  })

  it("producto dado de baja: dice que hay que editar el presupuesto y nombra el producto", async () => {
    const { alert } = await submitWith(
      new PythonApiError("quote_product_unavailable: Remera", 404, { code: "quote_product_unavailable" }),
    )
    expect(alert).toHaveTextContent(/editá el presupuesto/i)
    expect(alert).toHaveTextContent(/«Remera»/)
  })

  it("quote_changed: avisa, recarga el detalle del presupuesto y no cierra", async () => {
    const { alert, onOpenChange } = await submitWith(
      new PythonApiError("quote_changed", 409, { code: "quote_changed" }),
    )

    expect(alert).toHaveTextContent(/cambió mientras lo tenías abierto/i)
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ["quotes", "detail", "q-1"] })
    expect(onOpenChange).not.toHaveBeenCalledWith(false)
  })

  it("un error de stock no recarga el detalle (sólo quote_changed lo hace)", async () => {
    await submitWith(new PythonApiError("stock_insuficiente para producto 0dd2e5bb-2b93-4470-b4b6-52f008046112", 409, { code: "stock_insuficiente" }))
    expect(invalidateSpy).not.toHaveBeenCalled()
  })

  it("quote_invalid_state (otro usuario lo convirtió o rechazó): recarga el detalle para que la pantalla refleje el estado real", async () => {
    const { alert, onOpenChange } = await submitWith(
      new PythonApiError("quote_invalid_state: estado actual accepted", 409, { code: "quote_invalid_state" }),
    )

    expect(alert).toHaveTextContent(/ya no está en un estado/i)
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ["quotes", "detail", "q-1"] })
    expect(onOpenChange).not.toHaveBeenCalledWith(false)
  })

  it("la caja se cerró mientras se confirmaba: mensaje accionable (sin token) con enlace a /caja y recarga de las sesiones", async () => {
    const { alert } = await submitWith(
      new PythonApiError(
        "cash_optin_requires_open_session: la sesión de caja debe estar abierta y pertenecer a la sucursal efectiva de la venta",
        409,
        { code: "cash_optin_requires_open_session" },
      ),
    )

    expect(alert).toHaveTextContent(/la caja .* ya no está abierta/i)
    expect(alert).not.toHaveTextContent(/cash_optin/)
    expect(within(alert).getByRole("link", { name: /ir a caja/i })).toHaveAttribute("href", "/caja")
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ["cashSessions"] })
  })

  it("forma de pago o cuenta bancaria inválidas: piden elegir otra, sin el token ni el uuid", async () => {
    const { alert } = await submitWith(
      new PythonApiError("payment_method_not_found: 686292f2-1111-2222-3333-444455556666 no pertenece a la cuenta o no existe", 404, {
        code: "payment_method_not_found",
      }),
    )
    expect(alert).toHaveTextContent(/elegí otra forma de pago/i)
    expect(alert).not.toHaveTextContent(/686292f2|payment_method_not_found/)
  })

  it("idempotency_key_conflict: reabrir y reintentar usa una clave NUEVA (si no, el reintento chocaría con el mismo conflicto)", async () => {
    mocks.convert.mockRejectedValueOnce(new PythonApiError("idempotency_key_conflict", 409, { code: "idempotency_key_conflict" }))
    renderDialog()
    pickPayment("pm-transfer")
    fireEvent.click(saleButton())
    await screen.findByRole("alert")

    fireEvent.click(saleButton())
    await waitFor(() => expect(mocks.convert).toHaveBeenCalledTimes(2))
    expect(mocks.convert.mock.calls[1][0].idempotencyKey).not.toBe(mocks.convert.mock.calls[0][0].idempotencyKey)
  })

  it("reintentar tras un error usa LA MISMA clave (la conversión fallida no dejó nada registrado)", async () => {
    mocks.convert.mockRejectedValueOnce(new PythonApiError("stock_insuficiente para producto 0dd2e5bb-2b93-4470-b4b6-52f008046112", 409, {}))
    renderDialog()
    pickPayment("pm-transfer")
    fireEvent.click(saleButton())
    await screen.findByRole("alert")

    fireEvent.click(saleButton())
    await waitFor(() => expect(mocks.convert).toHaveBeenCalledTimes(2))
    expect(mocks.convert.mock.calls[1][0].idempotencyKey).toBe(mocks.convert.mock.calls[0][0].idempotencyKey)
  })

  it("el aviso de un intento se limpia al reintentar", async () => {
    mocks.convert.mockRejectedValueOnce(new PythonApiError("stock_insuficiente para producto 0dd2e5bb-2b93-4470-b4b6-52f008046112", 409, {}))
    renderDialog()
    pickPayment("pm-transfer")
    fireEvent.click(saleButton())
    await screen.findByRole("alert")

    fireEvent.click(saleButton())
    await screen.findByRole("heading", { name: /venta registrada/i })
    expect(screen.queryByRole("alert")).not.toBeInTheDocument()
  })
})

describe("ConvertQuoteDialog — doble clic", () => {
  it("dos clics seguidos producen UNA sola request", async () => {
    let resolve!: (value: QuoteConvertResult) => void
    mocks.convert.mockReturnValue(new Promise<QuoteConvertResult>((r) => { resolve = r }))
    renderDialog()
    pickPayment("pm-transfer")

    const button = saleButton()
    fireEvent.click(button)
    fireEvent.click(button)

    expect(mocks.convert).toHaveBeenCalledTimes(1)
    await act(async () => {
      resolve(RESULT)
    })
    await screen.findByRole("heading", { name: /venta registrada/i })
    expect(mocks.convert).toHaveBeenCalledTimes(1)
  })
})

describe("ConvertQuoteDialog — la clave de idempotencia es por presupuesto", () => {
  const keyOf = (n: number) => mocks.convert.mock.calls[n][0].idempotencyKey as string

  it("la conversión de A y la de B usan claves distintas, y la de A se resetea tras el éxito", async () => {
    const a = renderDialog(quote({ id: "q-A" }))
    pickPayment("pm-transfer")
    fireEvent.click(saleButton())
    await screen.findByRole("heading", { name: /venta registrada/i })
    const keyA = keyOf(0)
    expect(window.sessionStorage.getItem("idem:quote-convert:q-A")).not.toBe(keyA)
    a.unmount()

    renderDialog(quote({ id: "q-B" }))
    pickPayment("pm-transfer")
    fireEvent.click(saleButton())
    await waitFor(() => expect(mocks.convert).toHaveBeenCalledTimes(2))

    expect(mocks.convert.mock.calls[1][0].quoteId).toBe("q-B")
    expect(keyOf(1)).not.toBe(keyA)
  })

  it("una respuesta perdida de A (sin éxito) no contamina a B", async () => {
    mocks.convert.mockRejectedValueOnce(new PythonApiError("Failed to fetch", 0, {}))
    const a = renderDialog(quote({ id: "q-A" }))
    pickPayment("pm-transfer")
    fireEvent.click(saleButton())
    await screen.findByRole("alert")
    const keyA = keyOf(0)
    a.unmount()

    renderDialog(quote({ id: "q-B" }))
    pickPayment("pm-transfer")
    fireEvent.click(saleButton())
    await waitFor(() => expect(mocks.convert).toHaveBeenCalledTimes(2))

    expect(keyOf(1)).not.toBe(keyA)
  })
})
