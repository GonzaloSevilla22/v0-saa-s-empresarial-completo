/**
 * remitos-venta (tanda B, 7.3/7.4, D7/D11) — `ConvertDeliveryNoteDialog`: la
 * conversión atómica de un remito en venta.
 *
 * Invariantes bajo test:
 *  - resumen de líneas y total en sólo lectura, con la línea fija que dice que el
 *    stock ya se descontó al emitir el remito (la venta no lo vuelve a descontar);
 *  - SUCURSAL FIJA: la del remito (de donde salió el stock). No hay selector, el
 *    payload no lleva `branch_id` y la caja se resuelve en esa sucursal;
 *  - "Registrar venta" exige forma de pago; con banco se elige la cuenta destino;
 *  - caja con la semántica del POS: con `kind = cash` se manda SIEMPRE la sesión
 *    abierta de la sucursal del remito, sin checkbox; sin sesión, el botón queda
 *    deshabilitado con el motivo y un enlace a /caja;
 *  - con `credit`, el saldo actual del cliente;
 *  - manda `expected_revision` = la revisión que muestra el resumen;
 *  - éxito (también con `replayed: true`): "Venta registrada" con el foco en el
 *    título + EmitInvoiceButton + "Ver en Ventas";
 *  - `delivery_note_changed`/`delivery_note_invalid_state`: recarga el detalle del
 *    remito SIN cerrar, y la confirmación siguiente usa la revisión vigente;
 *  - errores accionables dentro del diálogo, en `role="alert"`, sin cerrar;
 *  - doble clic → una sola request efectiva;
 *  - la clave de idempotencia es POR remito y se resetea tras cada éxito.
 */
import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent, waitFor, within, act } from "@testing-library/react"
import "@testing-library/jest-dom"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"

import { PythonApiError } from "@/lib/api/python-api-error"
import type { DeliveryNoteApiRow, DeliveryNoteConvertResult } from "@/lib/delivery-note-types"

const mocks = vi.hoisted(() => ({
  convert: vi.fn(),
  cashboxesFor: vi.fn(),
  session: null as { id: string } | null,
  customerBalance: 0,
  emitProps: vi.fn(),
  branchSelectRendered: vi.fn(),
}))

vi.mock("@/hooks/data/use-delivery-notes", () => ({
  useConvertDeliveryNote: () => ({ mutateAsync: mocks.convert, isPending: false }),
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
  useBranches: () => ({
    branches: [
      { id: "b-1", name: "Sucursal Centro" },
      { id: "b-2", name: "Sucursal Norte" },
    ],
  }),
}))
vi.mock("@/hooks/data/use-cashboxes", () => ({
  useCashboxes: (branchId: string | null) => {
    mocks.cashboxesFor(branchId)
    return { data: branchId ? [{ id: `cb-${branchId}` }] : undefined }
  },
}))
vi.mock("@/hooks/data/use-cash-session", () => ({
  useCurrentSession: (cashboxId: string | null) => ({ data: cashboxId ? mocks.session ?? undefined : undefined }),
}))
vi.mock("@/hooks/data/use-customer-account", () => ({
  useCustomerAccount: (clientId: string | null) => ({
    data: clientId ? { balance: mocks.customerBalance } : undefined,
  }),
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
  BranchSelect: () => {
    mocks.branchSelectRendered()
    return <select aria-label="Sucursal" />
  },
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
  BankAccountDestinationSelect: (props: { paymentMethodKind: string | null; onChange: (v: string | null) => void }) =>
    props.paymentMethodKind === "transfer" ? (
      <select aria-label="Cuenta bancaria" onChange={(e) => props.onChange(e.target.value || null)}>
        <option value="">Usar el destino configurado</option>
        <option value="ba-1">Banco Nación</option>
      </select>
    ) : null,
}))

import { ConvertDeliveryNoteDialog } from "@/components/delivery-notes/ConvertDeliveryNoteDialog"

function note(overrides: Partial<DeliveryNoteApiRow> = {}): DeliveryNoteApiRow {
  return {
    id: "dn-1",
    direction: "sale",
    number: 12,
    number_label: "R-00000012",
    status: "issued",
    revision: 3,
    client_id: "c-1",
    client_name: "Ana Pérez",
    client_phone: null,
    branch_id: "b-1",
    branch_name: "Sucursal Centro",
    issued_on: "2026-10-02",
    delivery_address: null,
    notes: null,
    total: "4500.0000",
    created_at: "2026-10-02T15:00:00Z",
    created_by: "u-1",
    updated_at: null,
    updated_by: null,
    items: [
      {
        id: "i-1", delivery_note_id: "dn-1", product_id: "p-1", unit_id: "u-u", unit_symbol: "u",
        quantity: "3.0000", price: "1500.0000", subtotal: "4500.0000", quantity_base: "3.0000",
        name_snapshot: "Remera", sku_snapshot: null, unit_cost_snapshot: null, iva_rate_snapshot: null, line_no: 1,
      },
      {
        id: "i-2", delivery_note_id: "dn-1", product_id: "p-2", unit_id: "u-kg", unit_symbol: "kg",
        quantity: "0.4500", price: "0", subtotal: "0", quantity_base: "0.4500",
        name_snapshot: "Queso", sku_snapshot: null, unit_cost_snapshot: null, iva_rate_snapshot: null, line_no: 2,
      },
    ],
    history: [],
    ...overrides,
  }
}

const RESULT: DeliveryNoteConvertResult = {
  delivery_note_id: "dn-1",
  delivery_note_number: 12,
  delivery_note_number_label: "R-00000012",
  sales_order_id: "so-1",
  operation_id: "op-1",
  total: "4500.00",
  replayed: false,
}

let queryClient: QueryClient
let invalidateSpy: ReturnType<typeof vi.spyOn>

function renderDialog(n: DeliveryNoteApiRow = note(), onOpenChange: (open: boolean) => void = vi.fn()) {
  const tree = (current: DeliveryNoteApiRow) => (
    <QueryClientProvider client={queryClient}>
      <ConvertDeliveryNoteDialog deliveryNote={current} open onOpenChange={onOpenChange} />
    </QueryClientProvider>
  )
  const view = render(tree(n))
  return { ...view, onOpenChange, rerenderWith: (next: DeliveryNoteApiRow) => view.rerender(tree(next)) }
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
  mocks.convert.mockResolvedValue(RESULT)
  queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  invalidateSpy = vi.spyOn(queryClient, "invalidateQueries")
})

describe("ConvertDeliveryNoteDialog — resumen", () => {
  it("muestra las líneas y el total en sólo lectura, con el número y el cliente del remito", () => {
    renderDialog()
    const dialog = screen.getByRole("dialog")

    expect(within(dialog).getByText("Remera")).toBeInTheDocument()
    expect(within(dialog).getByText("Queso")).toBeInTheDocument()
    expect(within(dialog).getByText(/0,45\s*kg/)).toBeInTheDocument()
    expect(within(dialog).getByText(/^R-00000012 · Ana Pérez$/)).toBeInTheDocument()
    expect(within(dialog).getByTestId("convert-delivery-note-total")).toHaveTextContent(/4\.500/)
    expect(within(dialog).queryByRole("spinbutton")).not.toBeInTheDocument()
  })

  it("dice que el stock ya se descontó al emitir el remito y que la venta no lo vuelve a descontar", () => {
    renderDialog()
    expect(
      screen.getByText(/el stock ya se descontó al emitir el remito R-00000012: esta venta no lo vuelve a descontar/i),
    ).toBeInTheDocument()
  })

  it("un remito sin número (fila anterior) no inventa uno en la línea fija", () => {
    renderDialog(note({ number: null, number_label: null }))
    expect(screen.getByText(/el stock ya se descontó al emitir el remito: esta venta no lo vuelve a descontar/i)).toBeInTheDocument()
  })
})

describe("ConvertDeliveryNoteDialog — sucursal fija (D7)", () => {
  it("muestra el nombre de la sucursal del remito y NO ofrece ningún selector de sucursal", () => {
    renderDialog()

    expect(screen.getByText("Sucursal Centro")).toBeInTheDocument()
    expect(screen.queryByLabelText("Sucursal")).not.toBeInTheDocument()
    expect(mocks.branchSelectRendered).not.toHaveBeenCalled()
  })

  it("el payload no lleva branch_id: la venta se imputa a la sucursal del remito", async () => {
    renderDialog()
    pickPayment("pm-transfer")
    fireEvent.click(saleButton())

    await waitFor(() => expect(mocks.convert).toHaveBeenCalledTimes(1))
    expect(mocks.convert.mock.calls[0][0].payload).not.toHaveProperty("branch_id")
  })

  it("la caja se resuelve SIEMPRE en la sucursal del remito (nunca en otra)", () => {
    renderDialog(note({ branch_id: "b-2", branch_name: "Sucursal Norte" }))
    pickPayment("pm-cash")

    // Sin efectivo elegido el hook de caja no consulta ninguna sucursal (null); con efectivo, sólo la del remito.
    const asked = mocks.cashboxesFor.mock.calls.map((c) => c[0]).filter((id) => id !== null)
    expect(asked.length).toBeGreaterThan(0)
    expect(new Set(asked)).toEqual(new Set(["b-2"]))
    expect(screen.getByText("Sucursal Norte")).toBeInTheDocument()
  })
})

describe("ConvertDeliveryNoteDialog — forma de pago y banco", () => {
  it("'Registrar venta' queda deshabilitada hasta elegir la forma de pago, y lo explica", () => {
    renderDialog()

    expect(saleButton()).toBeDisabled()
    expect(saleButton()).toHaveAccessibleDescription(/elegí la forma de pago/i)

    pickPayment("pm-transfer")
    expect(saleButton()).toBeEnabled()
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

describe("ConvertDeliveryNoteDialog — caja con la semántica del POS", () => {
  it("efectivo CON caja abierta: manda SIEMPRE la sesión, sin checkbox", async () => {
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

  it("efectivo SIN caja abierta: deshabilitada, con el motivo y el enlace a /caja", () => {
    mocks.session = null
    renderDialog()
    pickPayment("pm-cash")

    expect(saleButton()).toBeDisabled()
    expect(screen.getByText(/abrí la caja de esta sucursal para cobrar en efectivo, o elegí otra forma de pago/i)).toBeInTheDocument()
    expect(screen.getByRole("link", { name: /ir a caja/i })).toHaveAttribute("href", "/caja")
    expect(saleButton()).toHaveAccessibleDescription(/abrí la caja de esta sucursal/i)
  })

  it("sin caja pero con otra forma de pago NO bloquea y no manda sesión", async () => {
    mocks.session = null
    renderDialog()
    pickPayment("pm-transfer")

    expect(screen.queryByRole("link", { name: /ir a caja/i })).not.toBeInTheDocument()
    fireEvent.click(saleButton())

    await waitFor(() => expect(mocks.convert).toHaveBeenCalledTimes(1))
    expect(mocks.convert.mock.calls[0][0].payload.cash_session_id).toBeNull()
  })
})

describe("ConvertDeliveryNoteDialog — cuenta corriente", () => {
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

describe("ConvertDeliveryNoteDialog — el payload", () => {
  it("manda expected_revision = la revisión que muestra el resumen, el remito y el canal nulo", async () => {
    renderDialog(note({ revision: 7 }))
    pickPayment("pm-transfer")
    fireEvent.click(saleButton())

    await waitFor(() => expect(mocks.convert).toHaveBeenCalledTimes(1))
    const arg = mocks.convert.mock.calls[0][0]
    expect(arg.deliveryNoteId).toBe("dn-1")
    expect(arg.payload).toMatchObject({ expected_revision: 7, canal: null })
  })
})

describe("ConvertDeliveryNoteDialog — éxito", () => {
  it("pasa a 'Venta registrada' con el foco en el título, Facturar y 'Ver en Ventas'", async () => {
    const { onOpenChange } = renderDialog()
    pickPayment("pm-transfer")
    fireEvent.click(saleButton())

    const title = await screen.findByRole("heading", { name: /venta registrada/i })
    await waitFor(() => expect(title).toHaveFocus())
    expect(mocks.emitProps).toHaveBeenCalledWith(
      expect.objectContaining({ salesOrderId: "so-1", salesOrderStatus: "confirmed", fiscalDocumentId: null }),
    )
    expect(screen.getByRole("button", { name: /facturar \(mock\)/i })).toBeInTheDocument()
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

  it("sigue mostrando 'Venta registrada' aunque el remito de la pantalla ya cambie a convertido", async () => {
    const view = renderDialog()
    pickPayment("pm-transfer")
    fireEvent.click(saleButton())
    await screen.findByRole("heading", { name: /venta registrada/i })

    view.rerenderWith(note({ status: "converted" }))

    expect(screen.getByRole("heading", { name: /venta registrada/i })).toBeInTheDocument()
  })
})

describe("ConvertDeliveryNoteDialog — el remito cambió (recarga sin cerrar)", () => {
  async function submitWith(err: PythonApiError) {
    mocks.convert.mockRejectedValue(err)
    const view = renderDialog()
    pickPayment("pm-transfer")
    fireEvent.click(saleButton())
    const alert = await screen.findByRole("alert")
    return { alert, ...view }
  }

  it("delivery_note_changed: avisa, recarga el detalle del remito y NO cierra", async () => {
    const { alert, onOpenChange } = await submitWith(
      new PythonApiError("delivery_note_changed", 409, { code: "delivery_note_changed" }),
    )

    expect(alert).toHaveTextContent(/el remito cambió mientras lo tenías abierto/i)
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ["deliveryNotes", "detail", "dn-1"] })
    expect(onOpenChange).not.toHaveBeenCalledWith(false)
    expect(screen.getByLabelText("Forma de pago")).toBeInTheDocument()
  })

  it("tras recargar, la confirmación siguiente usa la revisión vigente y el total que se ve", async () => {
    mocks.convert.mockRejectedValueOnce(new PythonApiError("delivery_note_changed", 409, { code: "delivery_note_changed" }))
    const view = renderDialog(note({ revision: 3 }))
    pickPayment("pm-transfer")
    fireEvent.click(saleButton())
    await screen.findByRole("alert")

    view.rerenderWith(note({ revision: 4, total: "5000.0000" }))
    expect(screen.getByTestId("convert-delivery-note-total")).toHaveTextContent(/5\.000/)
    fireEvent.click(saleButton())

    await waitFor(() => expect(mocks.convert).toHaveBeenCalledTimes(2))
    expect(mocks.convert.mock.calls[0][0].payload.expected_revision).toBe(3)
    expect(mocks.convert.mock.calls[1][0].payload.expected_revision).toBe(4)
  })

  it("delivery_note_invalid_state (otro usuario lo convirtió o anuló): también recarga el detalle", async () => {
    const { alert, onOpenChange } = await submitWith(
      new PythonApiError("delivery_note_invalid_state: estado actual converted", 409, { code: "delivery_note_invalid_state" }),
    )

    expect(alert).toHaveTextContent(/ya no está en un estado/i)
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ["deliveryNotes", "detail", "dn-1"] })
    expect(onOpenChange).not.toHaveBeenCalledWith(false)
  })

  it("un error que no es de versión NO recarga el detalle", async () => {
    await submitWith(new PythonApiError("payment_method_required", 400, { code: "payment_method_required" }))
    expect(invalidateSpy).not.toHaveBeenCalledWith({ queryKey: ["deliveryNotes", "detail", "dn-1"] })
  })

  // Revisión adversarial 8.5 (RB-06): tras `delivery_note_invalid_state` el detalle
  // recargado ya no está `issued`; el diálogo no puede seguir ofreciendo una
  // confirmación que va a fallar con el mismo error en cada reintento.
  it.each([
    ["converted", /ya fue convertido en venta/i],
    ["canceled", /ya fue anulado/i],
  ] as const)(
    "tras invalid_state, con el remito recargado en %s: avisa el estado y sólo deja Cerrar",
    async (status, message) => {
      const { onOpenChange, rerenderWith } = await submitWith(
        new PythonApiError("delivery_note_invalid_state", 409, { code: "delivery_note_invalid_state" }),
      )

      rerenderWith(note({ status }))

      const dialog = screen.getByRole("dialog")
      expect(within(dialog).getByText(message)).toBeInTheDocument()
      expect(within(dialog).queryByRole("button", { name: /^registrar venta$/i })).not.toBeInTheDocument()
      expect(within(dialog).queryByLabelText("Forma de pago")).not.toBeInTheDocument()
      fireEvent.click(within(dialog).getByRole("button", { name: /^cerrar$/i }))
      expect(onOpenChange).toHaveBeenCalledWith(false)
    },
  )

  it("un remito pendiente (issued) sigue mostrando el formulario completo", () => {
    renderDialog(note({ status: "issued" }))
    expect(screen.getByRole("button", { name: /^registrar venta$/i })).toBeInTheDocument()
    expect(screen.queryByText(/ya fue (convertido|anulado)/i)).not.toBeInTheDocument()
  })
})

describe("ConvertDeliveryNoteDialog — errores accionables (el diálogo no se cierra)", () => {
  async function submitWith(err: PythonApiError) {
    mocks.convert.mockRejectedValue(err)
    const view = renderDialog()
    pickPayment("pm-transfer")
    fireEvent.click(saleButton())
    const alert = await screen.findByRole("alert")
    return { alert, ...view }
  }

  it("cliente dado de baja: dice que hay que editar el remito y elegir uno vigente", async () => {
    const { alert, onOpenChange } = await submitWith(
      new PythonApiError("delivery_note_client_unavailable: el cliente fue dado de baja", 404, {
        code: "delivery_note_client_unavailable",
      }),
    )
    expect(alert).toHaveTextContent(/editá el remito y elegí un cliente vigente/i)
    expect(alert).not.toHaveTextContent(/delivery_note_client_unavailable/)
    expect(onOpenChange).not.toHaveBeenCalledWith(false)
  })

  it("sucursal del remito cerrada o desactivada: NO manda a 'elegir otra' (es fija), manda a reactivarla", async () => {
    const { alert } = await submitWith(new PythonApiError("branch_closed: la sucursal está cerrada", 422, { code: "branch_closed" }))

    expect(alert).toHaveTextContent(/sucursal del remito/i)
    expect(alert).toHaveTextContent(/reactivala|reabrila/i)
    expect(alert).not.toHaveTextContent(/elegí otra sucursal/i)
    expect(alert).not.toHaveTextContent(/branch_closed/)
  })

  it("la caja se cerró mientras se confirmaba: mensaje accionable con enlace a /caja y recarga de las sesiones", async () => {
    const { alert } = await submitWith(
      new PythonApiError("cash_optin_requires_open_session: la sesión de caja debe estar abierta", 409, {
        code: "cash_optin_requires_open_session",
      }),
    )

    expect(alert).toHaveTextContent(/la caja .* ya no está abierta/i)
    expect(alert).not.toHaveTextContent(/cash_optin/)
    expect(within(alert).getByRole("link", { name: /ir a caja/i })).toHaveAttribute("href", "/caja")
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ["cashSessions"] })
  })

  it("forma de pago o cuenta bancaria inválidas: piden elegir otra, sin el token ni el uuid", async () => {
    const { alert } = await submitWith(
      new PythonApiError("payment_method_not_found: 686292f2-1111-2222-3333-444455556666 no existe", 404, {
        code: "payment_method_not_found",
      }),
    )
    expect(alert).toHaveTextContent(/elegí otra forma de pago/i)
    expect(alert).not.toHaveTextContent(/686292f2|payment_method_not_found/)
  })

  it("interbloqueo (concurrent_update_retry): pide reintentar y el reintento usa LA MISMA clave", async () => {
    mocks.convert.mockRejectedValueOnce(new PythonApiError("concurrent_update_retry", 409, { code: "concurrent_update_retry" }))
    renderDialog()
    pickPayment("pm-transfer")
    fireEvent.click(saleButton())
    const alert = await screen.findByRole("alert")
    expect(alert).toHaveTextContent(/volvé a intentarlo/i)

    fireEvent.click(saleButton())
    await waitFor(() => expect(mocks.convert).toHaveBeenCalledTimes(2))
    expect(mocks.convert.mock.calls[1][0].idempotencyKey).toBe(mocks.convert.mock.calls[0][0].idempotencyKey)
  })

  it("idempotency_key_conflict: el reintento usa una clave NUEVA (si no, chocaría con el mismo conflicto)", async () => {
    mocks.convert.mockRejectedValueOnce(new PythonApiError("idempotency_key_conflict", 409, { code: "idempotency_key_conflict" }))
    renderDialog()
    pickPayment("pm-transfer")
    fireEvent.click(saleButton())
    await screen.findByRole("alert")

    fireEvent.click(saleButton())
    await waitFor(() => expect(mocks.convert).toHaveBeenCalledTimes(2))
    expect(mocks.convert.mock.calls[1][0].idempotencyKey).not.toBe(mocks.convert.mock.calls[0][0].idempotencyKey)
  })

  it("el aviso de un intento se limpia al reintentar", async () => {
    mocks.convert.mockRejectedValueOnce(new PythonApiError("concurrent_update_retry", 409, {}))
    renderDialog()
    pickPayment("pm-transfer")
    fireEvent.click(saleButton())
    await screen.findByRole("alert")

    fireEvent.click(saleButton())
    await screen.findByRole("heading", { name: /venta registrada/i })
    expect(screen.queryByRole("alert")).not.toBeInTheDocument()
  })
})

describe("ConvertDeliveryNoteDialog — doble clic", () => {
  it("dos clics seguidos producen UNA sola request", async () => {
    let resolve!: (value: DeliveryNoteConvertResult) => void
    mocks.convert.mockReturnValue(new Promise<DeliveryNoteConvertResult>((r) => { resolve = r }))
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

describe("ConvertDeliveryNoteDialog — la clave de idempotencia es por remito", () => {
  const keyOf = (n: number) => mocks.convert.mock.calls[n][0].idempotencyKey as string

  it("la conversión de A y la de B usan claves distintas, y la de A se resetea tras el éxito", async () => {
    const a = renderDialog(note({ id: "dn-A" }))
    pickPayment("pm-transfer")
    fireEvent.click(saleButton())
    await screen.findByRole("heading", { name: /venta registrada/i })
    const keyA = keyOf(0)
    expect(window.sessionStorage.getItem("idem:delivery-note-convert:dn-A")).not.toBe(keyA)
    a.unmount()

    renderDialog(note({ id: "dn-B" }))
    pickPayment("pm-transfer")
    fireEvent.click(saleButton())
    await waitFor(() => expect(mocks.convert).toHaveBeenCalledTimes(2))

    expect(mocks.convert.mock.calls[1][0].deliveryNoteId).toBe("dn-B")
    expect(keyOf(1)).not.toBe(keyA)
  })

  it("una respuesta perdida de A (sin éxito) no contamina a B", async () => {
    mocks.convert.mockRejectedValueOnce(new PythonApiError("Failed to fetch", 0, {}))
    const a = renderDialog(note({ id: "dn-A" }))
    pickPayment("pm-transfer")
    fireEvent.click(saleButton())
    await screen.findByRole("alert")
    const keyA = keyOf(0)
    a.unmount()

    renderDialog(note({ id: "dn-B" }))
    pickPayment("pm-transfer")
    fireEvent.click(saleButton())
    await waitFor(() => expect(mocks.convert).toHaveBeenCalledTimes(2))

    expect(keyOf(1)).not.toBe(keyA)
  })
})
