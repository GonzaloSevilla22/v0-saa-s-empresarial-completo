/**
 * remitos-compra (tanda B, 7.4/7.5, D8/D11) — `ConvertPurchaseDeliveryNoteDialog`:
 * la conversión atómica de un remito de compra en compra.
 *
 * Invariantes bajo test:
 *  - resumen de líneas y total en sólo lectura, con la línea fija que dice que el
 *    stock YA SE SUMÓ al recibir el remito (la compra no lo vuelve a sumar);
 *  - PROVEEDOR Y SUCURSAL FIJOS: los del remito. No hay selectores y el payload no
 *    lleva `supplier_id`, `branch_id` ni líneas (las lee el servidor del remito);
 *  - "Registrar compra" EXIGE forma de pago (OQ-RC4): sin "Sin especificar", el
 *    botón queda deshabilitado y lo explica; con banco se elige la cuenta destino;
 *  - caja como OPT-IN de la compra (no como el POS): pre-marcado con las tres
 *    condiciones; sin sesión abierta o con otra fecha se muestra el motivo, la
 *    compra se registra igual y NO viaja sesión;
 *  - con `credit`: saldo del proveedor, vencimiento resuelto por la cascada del
 *    plazo (el del PROVEEDOR primero, el de la cuenta si no tiene), editable; sólo
 *    viaja lo que el usuario toca;
 *  - la fecha no puede ser anterior a la recepción del remito;
 *  - manda `expected_revision` = la revisión que muestra el resumen;
 *  - éxito (también con `replayed: true`): "Compra registrada" con el foco en el
 *    título + "Ver en Compras";
 *  - `delivery_note_changed`/`delivery_note_invalid_state`: recarga el detalle SIN
 *    cerrar, y la confirmación siguiente usa la revisión vigente;
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
import { argentinaToday } from "@/lib/date-range"
import { addDaysToIsoDate } from "@/lib/receivables-aging"
import type { DeliveryNoteApiRow, PurchaseDeliveryNoteConvertResult } from "@/lib/delivery-note-types"

const mocks = vi.hoisted(() => ({
  convert: vi.fn(),
  cashboxesFor: vi.fn(),
  supplierAccountFor: vi.fn(),
  supplierFor: vi.fn(),
  paymentMethodSelectProps: vi.fn(),
  session: null as { id: string } | null,
  // caja-optin-carga: mientras es true, las cajas y la sesión están sin resolver.
  cashLoading: false,
  supplierBalance: 0,
  supplierTermsDays: null as number | null,
  accountTermsDays: null as number | null,
  branchSelectRendered: vi.fn(),
  supplierSelectRendered: vi.fn(),
}))

vi.mock("@/hooks/data/use-delivery-notes", () => ({
  useConvertPurchaseDeliveryNote: () => ({ mutateAsync: mocks.convert, isPending: false }),
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
    if (mocks.cashLoading) return { data: undefined, isLoading: true }
    return { data: branchId ? [{ id: `cb-${branchId}` }] : undefined, isLoading: false }
  },
}))
vi.mock("@/hooks/data/use-cash-session", () => ({
  useCurrentSession: (cashboxId: string | null) => ({ data: cashboxId ? mocks.session ?? undefined : undefined }),
}))
vi.mock("@/hooks/data/use-supplier-account", () => ({
  useSupplierAccount: (supplierId: string | null) => {
    mocks.supplierAccountFor(supplierId)
    return { data: supplierId ? { balance: mocks.supplierBalance } : undefined }
  },
}))
vi.mock("@/hooks/data/use-suppliers", () => ({
  useSupplier: (supplierId: string | null) => {
    mocks.supplierFor(supplierId)
    return { data: supplierId ? { id: supplierId, name: "Distribuidora Sur", paymentTermsDays: mocks.supplierTermsDays } : undefined }
  },
}))
vi.mock("@/hooks/data/use-collection-settings", () => ({
  useCollectionSettings: () => ({ data: { defaultPaymentTermsDays: mocks.accountTermsDays } }),
}))
vi.mock("@/components/cost-centers/CostCenterSelect", () => ({
  CostCenterSelect: ({ value, onChange }: { value: string | null; onChange: (v: string | null) => void }) => (
    <select aria-label="Centro de costo" value={value ?? ""} onChange={(e) => onChange(e.target.value || null)}>
      <option value="">Sin centro de costo</option>
      <option value="cc-1">Depósito</option>
    </select>
  ),
}))
vi.mock("@/components/branches/BranchSelect", () => ({
  BranchSelect: () => {
    mocks.branchSelectRendered()
    return <select aria-label="Sucursal" />
  },
}))
vi.mock("@/components/suppliers/SupplierSelect", () => ({
  SupplierSelect: () => {
    mocks.supplierSelectRendered()
    return <select aria-label="Proveedor" />
  },
}))
vi.mock("@/components/payment-methods/PaymentMethodSelect", () => ({
  PaymentMethodSelect: (props: {
    value: string | null
    onChange: (v: string | null) => void
    context?: string
    required?: boolean
  }) => {
    mocks.paymentMethodSelectProps(props)
    return (
      <select aria-label="Forma de pago" value={props.value ?? ""} onChange={(e) => props.onChange(e.target.value || null)}>
        {props.required ? <option value="">Elegí la forma de pago</option> : <option value="">Sin especificar</option>}
        <option value="pm-cash">Efectivo</option>
        <option value="pm-transfer">Transferencia</option>
        <option value="pm-credit">Cuenta corriente</option>
      </select>
    )
  },
  BankAccountDestinationSelect: (props: { paymentMethodKind: string | null; onChange: (v: string | null) => void }) =>
    props.paymentMethodKind === "transfer" ? (
      <select aria-label="Cuenta bancaria" onChange={(e) => props.onChange(e.target.value || null)}>
        <option value="">Usar el destino configurado</option>
        <option value="ba-1">Banco Nación</option>
      </select>
    ) : null,
}))

import { ConvertPurchaseDeliveryNoteDialog } from "@/components/delivery-notes/ConvertPurchaseDeliveryNoteDialog"

const TODAY = argentinaToday()
const RECEIVED_ON = addDaysToIsoDate(TODAY, -3)

function note(overrides: Partial<DeliveryNoteApiRow> = {}): DeliveryNoteApiRow {
  return {
    id: "dn-1",
    direction: "purchase",
    number: 12,
    number_label: "RC-00000012",
    status: "issued",
    revision: 3,
    client_id: null,
    client_name: null,
    client_phone: null,
    supplier_id: "s-1",
    supplier_name: "Distribuidora Sur",
    supplier_phone: null,
    supplier_reference: "0003-00004567",
    supplier_deleted: false,
    missing_price_count: 0,
    branch_id: "b-1",
    branch_name: "Sucursal Centro",
    issued_on: RECEIVED_ON,
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

const RESULT: PurchaseDeliveryNoteConvertResult = {
  delivery_note_id: "dn-1",
  delivery_note_number: 12,
  delivery_note_number_label: "RC-00000012",
  operation_id: "op-1",
  total: "4500.00",
  replayed: false,
}

let queryClient: QueryClient
let invalidateSpy: ReturnType<typeof vi.spyOn>

function renderDialog(n: DeliveryNoteApiRow = note(), onOpenChange: (open: boolean) => void = vi.fn()) {
  const tree = (current: DeliveryNoteApiRow) => (
    <QueryClientProvider client={queryClient}>
      <ConvertPurchaseDeliveryNoteDialog deliveryNote={current} open onOpenChange={onOpenChange} />
    </QueryClientProvider>
  )
  const view = render(tree(n))
  return { ...view, onOpenChange, rerenderWith: (next: DeliveryNoteApiRow) => view.rerender(tree(next)) }
}

function pickPayment(id: string) {
  fireEvent.change(screen.getByLabelText("Forma de pago"), { target: { value: id } })
}

const purchaseButton = () => screen.getByRole("button", { name: /^registrar compra$/i })
const dateInput = () => screen.getByLabelText("Fecha") as HTMLInputElement
const dueDateInput = () => screen.getByLabelText("Vencimiento") as HTMLInputElement

beforeEach(() => {
  vi.clearAllMocks()
  window.sessionStorage.clear()
  mocks.session = { id: "cs-1" }
  mocks.cashLoading = false
  mocks.supplierBalance = 0
  mocks.supplierTermsDays = null
  mocks.accountTermsDays = null
  mocks.convert.mockResolvedValue(RESULT)
  queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  invalidateSpy = vi.spyOn(queryClient, "invalidateQueries")
})

describe("ConvertPurchaseDeliveryNoteDialog — resumen", () => {
  it("muestra las líneas y el total en sólo lectura, con el número, el proveedor y el remito del proveedor", () => {
    renderDialog()
    const dialog = screen.getByRole("dialog")

    expect(within(dialog).getByRole("heading", { name: /pasar a compra/i })).toBeInTheDocument()
    expect(within(dialog).getByText("Remera")).toBeInTheDocument()
    expect(within(dialog).getByText("Queso")).toBeInTheDocument()
    expect(within(dialog).getByText(/0,45\s*kg/)).toBeInTheDocument()
    expect(within(dialog).getByText(/^RC-00000012 · Distribuidora Sur$/)).toBeInTheDocument()
    expect(within(dialog).getByText(/remito del proveedor n° 0003-00004567/i)).toBeInTheDocument()
    expect(within(dialog).getByTestId("convert-delivery-note-total")).toHaveTextContent(/4\.500/)
    expect(within(dialog).queryByRole("spinbutton")).not.toBeInTheDocument()
  })

  it("dice que el stock ya se sumó al recibir el remito y que la compra no lo vuelve a sumar", () => {
    renderDialog()
    expect(
      screen.getByText(/el stock ya se sumó al recibir el remito RC-00000012: esta compra no lo vuelve a sumar/i),
    ).toBeInTheDocument()
  })

  it("un remito sin número (fila anterior) y sin número del proveedor no inventa ninguno", () => {
    renderDialog(note({ number: null, number_label: null, supplier_reference: null }))

    expect(screen.getByText(/el stock ya se sumó al recibir el remito: esta compra no lo vuelve a sumar/i)).toBeInTheDocument()
    expect(screen.queryByText(/remito del proveedor n°/i)).not.toBeInTheDocument()
  })
})

describe("ConvertPurchaseDeliveryNoteDialog — proveedor y sucursal fijos (D8)", () => {
  it("muestra el proveedor y la sucursal de destino del remito y NO ofrece ningún selector de ellos", () => {
    renderDialog()
    const dialog = screen.getByRole("dialog")

    expect(within(dialog).getByText(/ingresa a/i)).toHaveTextContent(/sucursal centro/i)
    expect(screen.queryByLabelText("Sucursal")).not.toBeInTheDocument()
    expect(screen.queryByLabelText("Proveedor")).not.toBeInTheDocument()
    expect(mocks.branchSelectRendered).not.toHaveBeenCalled()
    expect(mocks.supplierSelectRendered).not.toHaveBeenCalled()
  })

  it("el payload no lleva supplier_id, branch_id ni líneas: la compra sale del remito", async () => {
    renderDialog()
    pickPayment("pm-transfer")
    fireEvent.click(purchaseButton())

    await waitFor(() => expect(mocks.convert).toHaveBeenCalledTimes(1))
    const payload = mocks.convert.mock.calls[0][0].payload
    expect(payload).not.toHaveProperty("supplier_id")
    expect(payload).not.toHaveProperty("branch_id")
    expect(payload).not.toHaveProperty("items")
  })

  it("la caja se resuelve SIEMPRE en la sucursal del remito (nunca en otra)", () => {
    renderDialog(note({ branch_id: "b-2", branch_name: "Sucursal Norte" }))
    pickPayment("pm-cash")

    const asked = mocks.cashboxesFor.mock.calls.map((c) => c[0]).filter((id) => id !== null)
    expect(asked.length).toBeGreaterThan(0)
    expect(new Set(asked)).toEqual(new Set(["b-2"]))
    expect(screen.getByText(/ingresa a/i)).toHaveTextContent(/sucursal norte/i)
  })

  it("el saldo del proveedor se consulta para el proveedor del remito, y sólo a crédito", () => {
    renderDialog()
    pickPayment("pm-transfer")
    expect(mocks.supplierAccountFor.mock.calls.every((c) => c[0] === null)).toBe(true)

    pickPayment("pm-credit")
    expect(mocks.supplierAccountFor).toHaveBeenLastCalledWith("s-1")
  })
})

describe("ConvertPurchaseDeliveryNoteDialog — forma de pago obligatoria y banco (OQ-RC4)", () => {
  it("el selector se pide como obligatorio, en el contexto de compra, sin 'Sin especificar'", () => {
    renderDialog()

    expect(mocks.paymentMethodSelectProps).toHaveBeenCalledWith(
      expect.objectContaining({ context: "purchase", required: true }),
    )
    expect(screen.queryByRole("option", { name: /sin especificar/i })).not.toBeInTheDocument()
  })

  it("'Registrar compra' queda deshabilitada hasta elegir la forma de pago, y lo explica", () => {
    renderDialog()

    expect(purchaseButton()).toBeDisabled()
    expect(purchaseButton()).toHaveAccessibleDescription(/elegí la forma de pago/i)

    pickPayment("pm-transfer")
    expect(purchaseButton()).toBeEnabled()
  })

  it("la cuenta bancaria sólo se ofrece con una forma de pago bancaria y se manda si se elige", async () => {
    renderDialog()
    pickPayment("pm-cash")
    expect(screen.queryByLabelText("Cuenta bancaria")).not.toBeInTheDocument()

    pickPayment("pm-transfer")
    fireEvent.change(screen.getByLabelText("Cuenta bancaria"), { target: { value: "ba-1" } })
    fireEvent.click(purchaseButton())

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
    fireEvent.click(purchaseButton())

    await waitFor(() => expect(mocks.convert).toHaveBeenCalledTimes(1))
    expect(mocks.convert.mock.calls[0][0].payload.bank_account_id).toBeNull()
  })
})

// caja-optin-carga — el caso del humo de la tanda B (2026-10-16): el script clicaba
// «Registrar compra» enseguida, antes de que cargaran las cajas y la sesión, y la
// compra en efectivo se registraba SIN movimiento de caja, en silencio.
describe("ConvertPurchaseDeliveryNoteDialog — caja cargando (caja-optin-carga)", () => {
  it("efectivo con la caja cargando: avisa «Verificando la caja…» y NO deja registrar la compra", () => {
    mocks.cashLoading = true
    renderDialog()
    pickPayment("pm-cash")

    expect(screen.getByRole("status")).toHaveTextContent("Verificando la caja…")
    expect(purchaseButton()).toBeDisabled()
    expect(screen.queryByText(/no hay caja abierta/i)).not.toBeInTheDocument()
    fireEvent.click(purchaseButton())
    expect(mocks.convert).not.toHaveBeenCalled()
  })

  it("al resolver CON sesión: se habilita y la compra sale con la sesión pre-marcada", async () => {
    mocks.cashLoading = true
    const { rerenderWith } = renderDialog()
    pickPayment("pm-cash")
    expect(purchaseButton()).toBeDisabled()

    mocks.cashLoading = false
    rerenderWith(note())

    expect(screen.queryByRole("status")).not.toBeInTheDocument()
    expect(screen.getByRole("checkbox")).toBeChecked()
    expect(purchaseButton()).toBeEnabled()
    fireEvent.click(purchaseButton())
    await waitFor(() => expect(mocks.convert).toHaveBeenCalledTimes(1))
    expect(mocks.convert.mock.calls[0][0].payload).toMatchObject({ payment_method_id: "pm-cash", cash_session_id: "cs-1" })
  })

  it("al resolver SIN sesión: se habilita (no bloquea para siempre) y la compra sale sin caja", async () => {
    mocks.cashLoading = true
    mocks.session = null
    const { rerenderWith } = renderDialog()
    pickPayment("pm-cash")
    expect(purchaseButton()).toBeDisabled()

    mocks.cashLoading = false
    rerenderWith(note())

    expect(screen.getByText(/no hay caja abierta en esta sucursal/i)).toBeInTheDocument()
    expect(purchaseButton()).toBeEnabled()
    fireEvent.click(purchaseButton())
    await waitFor(() => expect(mocks.convert).toHaveBeenCalledTimes(1))
    expect(mocks.convert.mock.calls[0][0].payload.cash_session_id).toBeNull()
  })

  it("otra forma de pago: no hay espera de caja aunque las consultas estén cargando", async () => {
    mocks.cashLoading = true
    renderDialog()
    pickPayment("pm-transfer")

    expect(screen.queryByRole("status")).not.toBeInTheDocument()
    expect(purchaseButton()).toBeEnabled()
  })
})

describe("ConvertPurchaseDeliveryNoteDialog — caja como opt-in de la compra", () => {
  it("efectivo CON caja abierta y fecha de hoy: checkbox pre-marcado y manda la sesión", async () => {
    renderDialog()
    pickPayment("pm-cash")

    const optin = screen.getByRole("checkbox")
    expect(optin).toBeChecked()
    expect(screen.getByText(/registrar en caja — sesión cs-1/i)).toBeInTheDocument()
    fireEvent.click(purchaseButton())

    await waitFor(() => expect(mocks.convert).toHaveBeenCalledTimes(1))
    expect(mocks.convert.mock.calls[0][0].payload).toMatchObject({ payment_method_id: "pm-cash", cash_session_id: "cs-1" })
  })

  it("destildar el opt-in registra la compra SIN sesión de caja", async () => {
    renderDialog()
    pickPayment("pm-cash")
    fireEvent.click(screen.getByRole("checkbox"))
    fireEvent.click(purchaseButton())

    await waitFor(() => expect(mocks.convert).toHaveBeenCalledTimes(1))
    expect(mocks.convert.mock.calls[0][0].payload.cash_session_id).toBeNull()
  })

  it("efectivo SIN caja abierta: avisa el motivo, NO bloquea y no manda sesión", async () => {
    mocks.session = null
    renderDialog()
    pickPayment("pm-cash")

    expect(screen.getByText(/no hay caja abierta en esta sucursal/i)).toBeInTheDocument()
    expect(screen.queryByRole("checkbox")).not.toBeInTheDocument()
    expect(purchaseButton()).toBeEnabled()
    fireEvent.click(purchaseButton())

    await waitFor(() => expect(mocks.convert).toHaveBeenCalledTimes(1))
    expect(mocks.convert.mock.calls[0][0].payload.cash_session_id).toBeNull()
  })

  it("efectivo con la compra fechada otro día: avisa que la caja sólo registra una compra de hoy y no manda sesión", async () => {
    renderDialog()
    pickPayment("pm-cash")
    fireEvent.change(dateInput(), { target: { value: addDaysToIsoDate(TODAY, -1) } })

    expect(screen.getByText(/sólo se puede registrar en caja una compra fechada hoy/i)).toBeInTheDocument()
    fireEvent.click(purchaseButton())

    await waitFor(() => expect(mocks.convert).toHaveBeenCalledTimes(1))
    expect(mocks.convert.mock.calls[0][0].payload.cash_session_id).toBeNull()
  })

  it("con otra forma de pago no hay bloque de caja y no se manda sesión", async () => {
    renderDialog()
    pickPayment("pm-transfer")

    expect(screen.queryByRole("checkbox")).not.toBeInTheDocument()
    expect(screen.queryByText(/no hay caja abierta/i)).not.toBeInTheDocument()
    fireEvent.click(purchaseButton())

    await waitFor(() => expect(mocks.convert).toHaveBeenCalledTimes(1))
    expect(mocks.convert.mock.calls[0][0].payload.cash_session_id).toBeNull()
  })
})

describe("ConvertPurchaseDeliveryNoteDialog — cuenta corriente y vencimiento", () => {
  it("con credit muestra el saldo actual del proveedor y el saldo después de esta compra", () => {
    mocks.supplierBalance = 12500
    renderDialog()
    pickPayment("pm-credit")

    expect(screen.getByText(/saldo actual/i)).toHaveTextContent(/12\.500/)
    expect(screen.getByText(/después de esta compra/i)).toHaveTextContent(/17\.000/)
  })

  it("con otra forma de pago no muestra el saldo ni el vencimiento", () => {
    renderDialog()
    pickPayment("pm-transfer")

    expect(screen.queryByText(/saldo actual/i)).not.toBeInTheDocument()
    expect(screen.queryByLabelText("Vencimiento")).not.toBeInTheDocument()
  })

  it("el vencimiento se pre-carga con el plazo del PROVEEDOR y lo dice", () => {
    mocks.supplierTermsDays = 30
    mocks.accountTermsDays = 7
    renderDialog()
    pickPayment("pm-credit")

    expect(dueDateInput().value).toBe(addDaysToIsoDate(TODAY, 30))
    expect(screen.getByText(/resuelto por el plazo del proveedor \(30 días\)/i)).toBeInTheDocument()
  })

  it("sin plazo propio, el proveedor usa el de la cuenta; sin ninguno, el cargo nace sin vencimiento", () => {
    mocks.supplierTermsDays = null
    mocks.accountTermsDays = 15
    const first = renderDialog()
    pickPayment("pm-credit")
    expect(dueDateInput().value).toBe(addDaysToIsoDate(TODAY, 15))
    expect(screen.getByText(/resuelto por el plazo de la cuenta \(15 días\)/i)).toBeInTheDocument()
    first.unmount()

    mocks.accountTermsDays = null
    renderDialog()
    pickPayment("pm-credit")
    expect(dueDateInput().value).toBe("")
    expect(screen.getByText(/sin plazo configurado/i)).toBeInTheDocument()
  })

  it("el plazo se cuenta desde la fecha de la compra: cambiar la fecha recalcula el vencimiento", () => {
    mocks.supplierTermsDays = 10
    renderDialog()
    pickPayment("pm-credit")

    const yesterday = addDaysToIsoDate(TODAY, -1)
    fireEvent.change(dateInput(), { target: { value: yesterday } })

    expect(dueDateInput().value).toBe(addDaysToIsoDate(yesterday, 10))
  })

  it("sin tocar el vencimiento NO viaja: la cascada autoritativa es del servidor", async () => {
    mocks.supplierTermsDays = 30
    renderDialog()
    pickPayment("pm-credit")
    fireEvent.click(purchaseButton())

    await waitFor(() => expect(mocks.convert).toHaveBeenCalledTimes(1))
    expect(mocks.convert.mock.calls[0][0].payload.due_date).toBeNull()
  })

  it("un vencimiento elegido por el usuario viaja, y no se pisa al cambiar la fecha", async () => {
    mocks.supplierTermsDays = 30
    renderDialog()
    pickPayment("pm-credit")
    const chosen = addDaysToIsoDate(TODAY, 45)
    fireEvent.change(dueDateInput(), { target: { value: chosen } })
    fireEvent.change(dateInput(), { target: { value: addDaysToIsoDate(TODAY, -1) } })
    expect(dueDateInput().value).toBe(chosen)
    fireEvent.click(purchaseButton())

    await waitFor(() => expect(mocks.convert).toHaveBeenCalledTimes(1))
    expect(mocks.convert.mock.calls[0][0].payload.due_date).toBe(chosen)
  })

  it("un vencimiento elegido y luego pasar a una forma de pago que no es crédito NO viaja", async () => {
    renderDialog()
    pickPayment("pm-credit")
    fireEvent.change(dueDateInput(), { target: { value: addDaysToIsoDate(TODAY, 45) } })
    pickPayment("pm-transfer")
    fireEvent.click(purchaseButton())

    await waitFor(() => expect(mocks.convert).toHaveBeenCalledTimes(1))
    expect(mocks.convert.mock.calls[0][0].payload.due_date).toBeNull()
  })
})

describe("ConvertPurchaseDeliveryNoteDialog — fecha y centro de costo", () => {
  it("la fecha arranca en hoy, no puede ser anterior a la recepción ni posterior a hoy", () => {
    renderDialog()

    expect(dateInput().value).toBe(TODAY)
    expect(dateInput()).toHaveAttribute("min", RECEIVED_ON)
    expect(dateInput()).toHaveAttribute("max", TODAY)
  })

  it("una fecha anterior a la recepción del remito deshabilita la confirmación y lo dice", () => {
    renderDialog()
    pickPayment("pm-transfer")
    expect(purchaseButton()).toBeEnabled()

    fireEvent.change(dateInput(), { target: { value: addDaysToIsoDate(RECEIVED_ON, -1) } })

    expect(purchaseButton()).toBeDisabled()
    expect(purchaseButton()).toHaveAccessibleDescription(/no puede ser anterior a la recepción del remito/i)
    expect(mocks.convert).not.toHaveBeenCalled()

    fireEvent.change(dateInput(), { target: { value: RECEIVED_ON } })
    expect(purchaseButton()).toBeEnabled()
  })

  it("el payload lleva la fecha elegida, el centro de costo y el remito", async () => {
    renderDialog(note({ revision: 7 }))
    pickPayment("pm-transfer")
    fireEvent.change(dateInput(), { target: { value: RECEIVED_ON } })
    fireEvent.change(screen.getByLabelText("Centro de costo"), { target: { value: "cc-1" } })
    fireEvent.click(purchaseButton())

    await waitFor(() => expect(mocks.convert).toHaveBeenCalledTimes(1))
    const arg = mocks.convert.mock.calls[0][0]
    expect(arg.deliveryNoteId).toBe("dn-1")
    expect(arg.payload).toMatchObject({
      expected_revision: 7,
      payment_method_id: "pm-transfer",
      date: RECEIVED_ON,
      cost_center_id: "cc-1",
    })
  })

  it("sin centro de costo manda null, y con hoy como fecha manda hoy", async () => {
    renderDialog()
    pickPayment("pm-transfer")
    fireEvent.click(purchaseButton())

    await waitFor(() => expect(mocks.convert).toHaveBeenCalledTimes(1))
    expect(mocks.convert.mock.calls[0][0].payload).toMatchObject({ date: TODAY, cost_center_id: null })
  })
})

describe("ConvertPurchaseDeliveryNoteDialog — éxito", () => {
  it("pasa a 'Compra registrada' con el foco en el título y 'Ver en Compras'", async () => {
    const { onOpenChange } = renderDialog()
    pickPayment("pm-transfer")
    fireEvent.click(purchaseButton())

    const title = await screen.findByRole("heading", { name: /compra registrada/i })
    await waitFor(() => expect(title).toHaveFocus())
    expect(screen.getByText(/4\.500/)).toBeInTheDocument()
    expect(screen.getByRole("link", { name: /ver en compras/i })).toHaveAttribute("href", "/compras")
    expect(screen.queryByLabelText("Forma de pago")).not.toBeInTheDocument()
    expect(screen.queryByText(/ya estaba registrada/i)).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: /^cerrar$/i }))
    expect(onOpenChange).toHaveBeenCalledWith(false)
  })

  it("el replay (replayed: true) se muestra igual, avisando que ya estaba registrada", async () => {
    mocks.convert.mockResolvedValue({ ...RESULT, replayed: true })
    renderDialog()
    pickPayment("pm-transfer")
    fireEvent.click(purchaseButton())

    await screen.findByRole("heading", { name: /compra registrada/i })
    expect(screen.getByText(/esta compra ya estaba registrada: no se registró dos veces/i)).toBeInTheDocument()
    expect(screen.getByRole("link", { name: /ver en compras/i })).toBeInTheDocument()
  })

  it("sigue mostrando 'Compra registrada' aunque el remito de la pantalla ya cambie a convertido", async () => {
    const view = renderDialog()
    pickPayment("pm-transfer")
    fireEvent.click(purchaseButton())
    await screen.findByRole("heading", { name: /compra registrada/i })

    view.rerenderWith(note({ status: "converted" }))

    expect(screen.getByRole("heading", { name: /compra registrada/i })).toBeInTheDocument()
  })
})

describe("ConvertPurchaseDeliveryNoteDialog — el remito cambió (recarga sin cerrar)", () => {
  async function submitWith(err: PythonApiError) {
    mocks.convert.mockRejectedValue(err)
    const view = renderDialog()
    pickPayment("pm-transfer")
    fireEvent.click(purchaseButton())
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
    fireEvent.click(purchaseButton())
    await screen.findByRole("alert")

    view.rerenderWith(note({ revision: 4, total: "5000.0000" }))
    expect(screen.getByTestId("convert-delivery-note-total")).toHaveTextContent(/5\.000/)
    fireEvent.click(purchaseButton())

    await waitFor(() => expect(mocks.convert).toHaveBeenCalledTimes(2))
    expect(mocks.convert.mock.calls[0][0].payload.expected_revision).toBe(3)
    expect(mocks.convert.mock.calls[1][0].payload.expected_revision).toBe(4)
  })

  it("delivery_note_invalid_state (otro usuario lo convirtió o anuló): recarga el detalle y habla de compra", async () => {
    const { alert, onOpenChange } = await submitWith(
      new PythonApiError("delivery_note_invalid_state: estado actual converted", 409, { code: "delivery_note_invalid_state" }),
    )

    expect(alert).toHaveTextContent(/ya no está en un estado/i)
    expect(alert).toHaveTextContent(/convertido en compra/i)
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ["deliveryNotes", "detail", "dn-1"] })
    expect(onOpenChange).not.toHaveBeenCalledWith(false)
  })

  it("un error que no es de versión NO recarga el detalle", async () => {
    await submitWith(new PythonApiError("payment_method_required", 400, { code: "payment_method_required" }))
    expect(invalidateSpy).not.toHaveBeenCalledWith({ queryKey: ["deliveryNotes", "detail", "dn-1"] })
  })

  it.each([
    ["converted", /ya fue convertido en compra/i],
    ["canceled", /ya fue anulado/i],
  ] as const)(
    "con el remito recargado en %s: avisa el estado y sólo deja Cerrar",
    async (status, message) => {
      const { onOpenChange, rerenderWith } = await submitWith(
        new PythonApiError("delivery_note_invalid_state", 409, { code: "delivery_note_invalid_state" }),
      )

      rerenderWith(note({ status }))

      const dialog = screen.getByRole("dialog")
      expect(within(dialog).getByText(message)).toBeInTheDocument()
      expect(within(dialog).queryByRole("button", { name: /^registrar compra$/i })).not.toBeInTheDocument()
      expect(within(dialog).queryByLabelText("Forma de pago")).not.toBeInTheDocument()
      fireEvent.click(within(dialog).getByRole("button", { name: /^cerrar$/i }))
      expect(onOpenChange).toHaveBeenCalledWith(false)
    },
  )

  it("un remito pendiente (issued) sigue mostrando el formulario completo", () => {
    renderDialog(note({ status: "issued" }))
    expect(screen.getByRole("button", { name: /^registrar compra$/i })).toBeInTheDocument()
    expect(screen.queryByText(/ya fue (convertido|anulado)/i)).not.toBeInTheDocument()
  })
})

describe("ConvertPurchaseDeliveryNoteDialog — errores accionables (el diálogo no se cierra)", () => {
  async function submitWith(err: PythonApiError) {
    mocks.convert.mockRejectedValue(err)
    const view = renderDialog()
    pickPayment("pm-transfer")
    fireEvent.click(purchaseButton())
    const alert = await screen.findByRole("alert")
    return { alert, ...view }
  }

  it("proveedor dado de baja: dice que hay que editar el remito y elegir uno vigente, sin el token", async () => {
    const { alert, onOpenChange } = await submitWith(
      new PythonApiError("delivery_note_supplier_unavailable: el proveedor fue dado de baja", 404, {
        code: "delivery_note_supplier_unavailable",
      }),
    )
    expect(alert).toHaveTextContent(/editá el remito y elegí un proveedor vigente/i)
    expect(alert).not.toHaveTextContent(/delivery_note_supplier_unavailable/)
    expect(onOpenChange).not.toHaveBeenCalledWith(false)
  })

  it("falta un precio: manda a editar el remito y cargarlos", async () => {
    const { alert } = await submitWith(
      new PythonApiError("delivery_note_price_required: hay líneas sin precio", 409, { code: "delivery_note_price_required" }),
    )
    expect(alert).toHaveTextContent(/cargá el precio de compra de todas las líneas/i)
    expect(alert).not.toHaveTextContent(/delivery_note_price_required/)
  })

  it("fecha anterior a la recepción (rechazo del servidor): pide elegir la fecha del remito o una posterior", async () => {
    const { alert } = await submitWith(
      new PythonApiError("delivery_note_purchase_date_before_receipt", 422, { code: "delivery_note_purchase_date_before_receipt" }),
    )
    expect(alert).toHaveTextContent(/no puede ser anterior a la recepción del remito/i)
    expect(alert).not.toHaveTextContent(/delivery_note_purchase_date_before_receipt/)
  })

  it("sucursal del remito cerrada o desactivada: NO manda a 'elegir otra' (es fija), manda a reactivarla", async () => {
    const { alert } = await submitWith(new PythonApiError("branch_closed: la sucursal está cerrada", 422, { code: "branch_closed" }))

    expect(alert).toHaveTextContent(/sucursal del remito/i)
    expect(alert).toHaveTextContent(/reabrila|reactivala/i)
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

  it("interbloqueo (concurrent_update_retry): pide reintentar y el reintento usa LA MISMA clave", async () => {
    mocks.convert.mockRejectedValueOnce(new PythonApiError("concurrent_update_retry", 409, { code: "concurrent_update_retry" }))
    renderDialog()
    pickPayment("pm-transfer")
    fireEvent.click(purchaseButton())
    const alert = await screen.findByRole("alert")
    expect(alert).toHaveTextContent(/volvé a intentarlo/i)

    fireEvent.click(purchaseButton())
    await waitFor(() => expect(mocks.convert).toHaveBeenCalledTimes(2))
    expect(mocks.convert.mock.calls[1][0].idempotencyKey).toBe(mocks.convert.mock.calls[0][0].idempotencyKey)
  })

  it("idempotency_key_conflict: el reintento usa una clave NUEVA (si no, chocaría con el mismo conflicto)", async () => {
    mocks.convert.mockRejectedValueOnce(new PythonApiError("idempotency_key_conflict", 409, { code: "idempotency_key_conflict" }))
    renderDialog()
    pickPayment("pm-transfer")
    fireEvent.click(purchaseButton())
    await screen.findByRole("alert")

    fireEvent.click(purchaseButton())
    await waitFor(() => expect(mocks.convert).toHaveBeenCalledTimes(2))
    expect(mocks.convert.mock.calls[1][0].idempotencyKey).not.toBe(mocks.convert.mock.calls[0][0].idempotencyKey)
  })

  it("el aviso de un intento se limpia al reintentar", async () => {
    mocks.convert.mockRejectedValueOnce(new PythonApiError("concurrent_update_retry", 409, {}))
    renderDialog()
    pickPayment("pm-transfer")
    fireEvent.click(purchaseButton())
    await screen.findByRole("alert")

    fireEvent.click(purchaseButton())
    await screen.findByRole("heading", { name: /compra registrada/i })
    expect(screen.queryByRole("alert")).not.toBeInTheDocument()
  })
})

describe("ConvertPurchaseDeliveryNoteDialog — doble clic", () => {
  it("dos clics seguidos producen UNA sola request", async () => {
    let resolve!: (value: PurchaseDeliveryNoteConvertResult) => void
    mocks.convert.mockReturnValue(new Promise<PurchaseDeliveryNoteConvertResult>((r) => { resolve = r }))
    renderDialog()
    pickPayment("pm-transfer")

    const button = purchaseButton()
    fireEvent.click(button)
    fireEvent.click(button)

    expect(mocks.convert).toHaveBeenCalledTimes(1)
    await act(async () => {
      resolve(RESULT)
    })
    await screen.findByRole("heading", { name: /compra registrada/i })
    expect(mocks.convert).toHaveBeenCalledTimes(1)
  })
})

describe("ConvertPurchaseDeliveryNoteDialog — la clave de idempotencia es por remito", () => {
  const keyOf = (n: number) => mocks.convert.mock.calls[n][0].idempotencyKey as string

  it("la conversión de A y la de B usan claves distintas, y la de A se resetea tras el éxito", async () => {
    const a = renderDialog(note({ id: "dn-A" }))
    pickPayment("pm-transfer")
    fireEvent.click(purchaseButton())
    await screen.findByRole("heading", { name: /compra registrada/i })
    const keyA = keyOf(0)
    expect(window.sessionStorage.getItem("idem:delivery-note-purchase-convert:dn-A")).not.toBe(keyA)
    a.unmount()

    renderDialog(note({ id: "dn-B" }))
    pickPayment("pm-transfer")
    fireEvent.click(purchaseButton())
    await waitFor(() => expect(mocks.convert).toHaveBeenCalledTimes(2))

    expect(mocks.convert.mock.calls[1][0].deliveryNoteId).toBe("dn-B")
    expect(keyOf(1)).not.toBe(keyA)
  })

  it("la clave nace con el alcance del remito de COMPRA (no el de venta)", async () => {
    renderDialog(note({ id: "dn-C" }))
    pickPayment("pm-transfer")
    fireEvent.click(purchaseButton())
    await waitFor(() => expect(mocks.convert).toHaveBeenCalledTimes(1))

    expect(window.sessionStorage.getItem("idem:delivery-note-convert:dn-C")).toBeNull()
  })

  it("una respuesta perdida de A (sin éxito) no contamina a B", async () => {
    mocks.convert.mockRejectedValueOnce(new PythonApiError("Failed to fetch", 0, {}))
    const a = renderDialog(note({ id: "dn-A" }))
    pickPayment("pm-transfer")
    fireEvent.click(purchaseButton())
    await screen.findByRole("alert")
    const keyA = keyOf(0)
    a.unmount()

    renderDialog(note({ id: "dn-B" }))
    pickPayment("pm-transfer")
    fireEvent.click(purchaseButton())
    await waitFor(() => expect(mocks.convert).toHaveBeenCalledTimes(2))

    expect(keyOf(1)).not.toBe(keyA)
  })
})

describe("ConvertPurchaseDeliveryNoteDialog — el plazo del proveedor", () => {
  it("consulta el proveedor del remito (useSupplier) para resolver el plazo, sin pedir otra cosa", () => {
    renderDialog()
    expect(mocks.supplierFor).toHaveBeenCalledWith("s-1")
  })

  it("un remito sin proveedor no consulta ninguno y a crédito no se puede confirmar", () => {
    renderDialog(note({ supplier_id: null, supplier_name: null }))
    pickPayment("pm-credit")

    expect(mocks.supplierFor).toHaveBeenCalledWith(null)
    expect(screen.getByText(/elegí un proveedor/i)).toBeInTheDocument()
    expect(purchaseButton()).toBeDisabled()
  })
})
