/**
 * remitos-venta (tarea 5.3) — `CancelDeliveryNoteDialog`: la anulación exige
 * motivo (3 a 500 caracteres), enumera lo que vuelve al stock, manda la
 * `revision` que se mostró y traduce los errores del servidor.
 */
import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, waitFor, fireEvent, within, cleanup } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import "@testing-library/jest-dom"

import type { DeliveryNoteApiRow, DeliveryNoteItemApiRow } from "@/lib/delivery-note-types"
import type { UnitOfMeasure } from "@/lib/types"

const mocks = vi.hoisted(() => ({
  mutateAsync: vi.fn(),
  toastError: vi.fn(),
  toastSuccess: vi.fn(),
}))

const U: UnitOfMeasure = { id: "u-u", name: "Unidad", symbol: "u", type: "unit", factor: 1, isSystem: true }
const KG: UnitOfMeasure = { id: "u-kg", name: "Kilogramo", symbol: "kg", type: "weight", factor: 1, isSystem: true }

vi.mock("sonner", () => ({ toast: { error: mocks.toastError, success: mocks.toastSuccess } }))
vi.mock("@/hooks/data/use-delivery-notes", () => ({
  useCancelDeliveryNote: () => ({ mutateAsync: mocks.mutateAsync, isPending: false }),
}))
vi.mock("@/hooks/data/use-products", () => ({
  useProducts: () => ({
    products: [
      { id: "p-a", name: "Producto A", baseUnitId: "u-u" },
      { id: "p-b", name: "Producto B", baseUnitId: "u-kg" },
      { id: "11111111-1111-4111-8111-111111111111", name: "Producto Uuid", baseUnitId: "u-u" },
    ],
  }),
}))
vi.mock("@/hooks/use-units-of-measure", () => ({
  useUnitsOfMeasure: () => ({ units: [U, KG], unitsById: new Map([U, KG].map((u) => [u.id, u])) }),
}))
vi.mock("@/components/shared/responsive-modal", () => ({
  ResponsiveModal: ({ open, title, children }: { open: boolean; title: string; children: React.ReactNode }) =>
    open ? (
      <div role="dialog" aria-label={title}>
        {children}
      </div>
    ) : null,
}))

const { CancelDeliveryNoteDialog } = await import("@/components/delivery-notes/CancelDeliveryNoteDialog")

function item(overrides: Partial<DeliveryNoteItemApiRow> & { id: string }): DeliveryNoteItemApiRow {
  return {
    delivery_note_id: "dn-1",
    product_id: "p-a",
    unit_id: "u-u",
    quantity: "3",
    price: "100",
    subtotal: "300",
    quantity_base: "3",
    name_snapshot: "Producto A",
    sku_snapshot: null,
    unit_cost_snapshot: null,
    iva_rate_snapshot: null,
    line_no: 1,
    ...overrides,
  }
}

function deliveryNote(overrides: Partial<DeliveryNoteApiRow> = {}): DeliveryNoteApiRow {
  return {
    id: "dn-1",
    direction: "sale",
    number: 12,
    number_label: "R-00000012",
    status: "issued",
    revision: 4,
    client_id: "c-ana",
    client_name: "Ana Pérez",
    client_phone: null,
    branch_id: "b-1",
    branch_name: "Sucursal Centro",
    issued_on: "2026-10-02",
    delivery_address: null,
    notes: null,
    total: "300",
    created_at: "2026-10-02T12:00:00Z",
    created_by: "u-1",
    updated_at: null,
    updated_by: null,
    items: [item({ id: "i-1" })],
    history: [],
    ...overrides,
  }
}

const onOpenChange = vi.fn()

function renderDialog(note: DeliveryNoteApiRow = deliveryNote()) {
  return render(<CancelDeliveryNoteDialog deliveryNote={note} open onOpenChange={onOpenChange} />)
}

beforeEach(() => {
  vi.clearAllMocks()
  mocks.mutateAsync.mockResolvedValue({})
})

describe("CancelDeliveryNoteDialog", () => {
  it("enumera lo que vuelve a la sucursal, junto por producto y con la unidad base", () => {
    renderDialog(
      deliveryNote({
        items: [
          item({ id: "i-1", product_id: "p-a", quantity_base: "3" }),
          item({ id: "i-2", product_id: "p-b", unit_id: "u-kg", quantity: "450", quantity_base: "0.45", name_snapshot: "Producto B", line_no: 2 }),
          item({ id: "i-3", product_id: "p-a", quantity_base: "2", line_no: 3 }),
        ],
      }),
    )
    expect(screen.getByText(/Vuelven a Sucursal Centro: 5 × Producto A, 0[.,]45\d* kg de Producto B/)).toBeInTheDocument()
  })

  it("sin motivo no se puede anular y no se llama al servidor", async () => {
    renderDialog()
    const submit = screen.getByRole("button", { name: /anular remito/i })
    expect(submit).toBeDisabled()
    fireEvent.click(submit)
    expect(mocks.mutateAsync).not.toHaveBeenCalled()
  })

  it("un motivo de menos de 3 caracteres (o sólo espacios) no alcanza", async () => {
    const user = userEvent.setup()
    renderDialog()
    const reason = screen.getByLabelText(/motivo/i)
    await user.type(reason, "ab")
    expect(screen.getByRole("button", { name: /anular remito/i })).toBeDisabled()
    await user.clear(reason)
    await user.type(reason, "     ")
    expect(screen.getByRole("button", { name: /anular remito/i })).toBeDisabled()
  })

  it("con motivo manda reason recortado y la revision que se mostró, y cierra", async () => {
    const user = userEvent.setup()
    renderDialog()
    await user.type(screen.getByLabelText(/motivo/i), "  Cliente devolvió todo  ")
    await user.click(screen.getByRole("button", { name: /anular remito/i }))
    await waitFor(() => expect(mocks.mutateAsync).toHaveBeenCalledTimes(1))
    expect(mocks.mutateAsync).toHaveBeenCalledWith({
      deliveryNoteId: "dn-1",
      payload: { reason: "Cliente devolvió todo", revision: 4 },
    })
    await waitFor(() => expect(onOpenChange).toHaveBeenCalledWith(false))
    expect(mocks.toastSuccess).toHaveBeenCalled()
  })

  it("otra revision (remito editado antes de anular) viaja tal cual", async () => {
    const user = userEvent.setup()
    renderDialog(deliveryNote({ revision: 9 }))
    await user.type(screen.getByLabelText(/motivo/i), "Error de carga")
    await user.click(screen.getByRole("button", { name: /anular remito/i }))
    await waitFor(() => expect(mocks.mutateAsync).toHaveBeenCalled())
    expect(mocks.mutateAsync.mock.calls[0][0].payload.revision).toBe(9)
  })

  it("el campo respeta el tope de 500 caracteres y muestra el contador", async () => {
    renderDialog()
    const reason = screen.getByLabelText(/motivo/i) as HTMLTextAreaElement
    expect(reason).toHaveAttribute("maxlength", "500")
    fireEvent.change(reason, { target: { value: "x".repeat(40) } })
    expect(screen.getByText("40/500")).toBeInTheDocument()
  })

  it("ante delivery_note_changed muestra el mensaje accionable y deja el diálogo abierto con el motivo escrito", async () => {
    const user = userEvent.setup()
    mocks.mutateAsync.mockRejectedValue(new Error("delivery_note_changed: el remito cambió"))
    renderDialog()
    await user.type(screen.getByLabelText(/motivo/i), "Motivo válido")
    await user.click(screen.getByRole("button", { name: /anular remito/i }))
    await waitFor(() => expect(mocks.toastError).toHaveBeenCalled())
    expect(mocks.toastError.mock.calls[0][0]).toMatch(/cambió.*recargalo/i)
    expect(onOpenChange).not.toHaveBeenCalledWith(false)
    expect(screen.getByLabelText(/motivo/i)).toHaveValue("Motivo válido")
  })

  it("ante insufficient_role muestra un mensaje que habla del remito, no de la venta", async () => {
    const user = userEvent.setup()
    mocks.mutateAsync.mockRejectedValue(new Error("insufficient_role"))
    renderDialog()
    await user.type(screen.getByLabelText(/motivo/i), "Motivo válido")
    await user.click(screen.getByRole("button", { name: /anular remito/i }))
    await waitFor(() => expect(mocks.toastError).toHaveBeenCalled())
    expect(mocks.toastError.mock.calls[0][0]).toMatch(/remito/i)
  })

  it("Volver cierra sin llamar al servidor", async () => {
    const user = userEvent.setup()
    renderDialog()
    await user.click(screen.getByRole("button", { name: /^volver$/i }))
    expect(onOpenChange).toHaveBeenCalledWith(false)
    expect(mocks.mutateAsync).not.toHaveBeenCalled()
  })

  it("al abrir el foco queda en el motivo", async () => {
    renderDialog()
    await waitFor(() => expect(screen.getByLabelText(/motivo/i)).toHaveFocus())
  })
})

// ── remitos-compra (D11, tarea 5.3): la anulación por sentido ──────────────────

const UUID_PRODUCT = "11111111-1111-4111-8111-111111111111"

function purchaseNote(overrides: Partial<DeliveryNoteApiRow> = {}): DeliveryNoteApiRow {
  return deliveryNote({
    direction: "purchase",
    number: 7,
    number_label: "RC-00000007",
    client_id: null,
    client_name: null,
    supplier_id: "s-1",
    supplier_name: "Distribuidora Sur",
    supplier_reference: "0004-00001234",
    items: [item({ id: "i-1", product_id: "p-a", quantity: "10", quantity_base: "10" })],
    ...overrides,
  })
}

describe("CancelDeliveryNoteDialog — remito de compra", () => {
  it("enumera lo que SALE de la sucursal, junto por producto", () => {
    renderDialog(
      purchaseNote({
        items: [
          item({ id: "i-1", product_id: "p-a", quantity: "6", quantity_base: "6" }),
          item({ id: "i-2", product_id: "p-a", quantity: "4", quantity_base: "4", line_no: 2 }),
        ],
      }),
    )
    expect(screen.getByText("Salen de Sucursal Centro: 10 × Producto A")).toBeInTheDocument()
    expect(screen.queryByText(/Vuelven a/)).not.toBeInTheDocument()
  })

  it("el título y el botón siguen hablando del remito, con el número RC", () => {
    renderDialog(purchaseNote())
    expect(screen.getByRole("dialog", { name: "Anular RC-00000007" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /anular remito/i })).toBeInTheDocument()
  })

  it("el placeholder del motivo es el de compra, no el de venta", () => {
    renderDialog(purchaseNote())
    expect(screen.getByLabelText(/motivo/i)).toHaveAttribute("placeholder", "Ej.: el proveedor se llevó la mercadería")
    cleanup()
    renderDialog(deliveryNote())
    expect(screen.getByLabelText(/motivo/i)).toHaveAttribute("placeholder", "Ej: el cliente devolvió la mercadería")
  })

  it("al anular manda el motivo y la revisión, y el toast dice que el stock SALIÓ", async () => {
    const user = userEvent.setup()
    renderDialog(purchaseNote({ revision: 3 }))
    await user.type(screen.getByLabelText(/motivo/i), "El proveedor se llevó todo")
    await user.click(screen.getByRole("button", { name: /anular remito/i }))
    await waitFor(() => expect(mocks.mutateAsync).toHaveBeenCalledTimes(1))
    expect(mocks.mutateAsync).toHaveBeenCalledWith({
      deliveryNoteId: "dn-1",
      payload: { reason: "El proveedor se llevó todo", revision: 3 },
    })
    expect(mocks.toastSuccess).toHaveBeenCalledWith("Remito RC-00000007 anulado: el stock salió de Sucursal Centro")
    await waitFor(() => expect(onOpenChange).toHaveBeenCalledWith(false))
  })

  it("ante delivery_note_stock_consumed deja el diálogo abierto y muestra lo que queda con las dos salidas", async () => {
    const user = userEvent.setup()
    mocks.mutateAsync.mockRejectedValue(
      new Error("delivery_note_stock_consumed: de Producto A en la sucursal quedan 3, el remito necesita restar 10"),
    )
    renderDialog(purchaseNote())
    await user.type(screen.getByLabelText(/motivo/i), "Motivo válido")
    await user.click(screen.getByRole("button", { name: /anular remito/i }))

    const alert = await screen.findByRole("alert", { name: /mercadería consumida/i })
    expect(alert).toHaveTextContent(/quedan 3/)
    expect(alert).toHaveTextContent(/restar 10/)
    expect(within(alert).getByRole("link", { name: "Editar el remito" })).toHaveAttribute("href", "/remitos/dn-1/editar")
    expect(within(alert).getByRole("link", { name: "Ajustar stock" })).toHaveAttribute("href", "/stock")
    // No se anuló nada: el diálogo sigue abierto con el motivo escrito y sin toast de éxito.
    expect(onOpenChange).not.toHaveBeenCalledWith(false)
    expect(screen.getByLabelText(/motivo/i)).toHaveValue("Motivo válido")
    expect(mocks.toastSuccess).not.toHaveBeenCalled()
  })

  it("si el servidor nombra el producto por uuid, 'Ajustar stock' lleva a ese producto y el nombre se resuelve", async () => {
    const user = userEvent.setup()
    mocks.mutateAsync.mockRejectedValue(
      new Error(`delivery_note_stock_consumed: de ${UUID_PRODUCT} en la sucursal quedan 0.5, el remito necesita restar 2`),
    )
    renderDialog(purchaseNote())
    await user.type(screen.getByLabelText(/motivo/i), "Motivo válido")
    await user.click(screen.getByRole("button", { name: /anular remito/i }))
    const alert = await screen.findByRole("alert", { name: /mercadería consumida/i })
    expect(alert).toHaveTextContent("«Producto Uuid»")
    expect(within(alert).getByRole("link", { name: "Ajustar stock" })).toHaveAttribute(
      "href",
      `/stock?product=${UUID_PRODUCT}`,
    )
  })

  it("el aviso de mercadería consumida se limpia al reabrir el diálogo", async () => {
    const user = userEvent.setup()
    mocks.mutateAsync.mockRejectedValue(new Error("delivery_note_stock_consumed"))
    const note = purchaseNote()
    const { rerender } = render(<CancelDeliveryNoteDialog deliveryNote={note} open onOpenChange={onOpenChange} />)
    await user.type(screen.getByLabelText(/motivo/i), "Motivo válido")
    await user.click(screen.getByRole("button", { name: /anular remito/i }))
    await screen.findByRole("alert", { name: /mercadería consumida/i })
    rerender(<CancelDeliveryNoteDialog deliveryNote={note} open={false} onOpenChange={onOpenChange} />)
    rerender(<CancelDeliveryNoteDialog deliveryNote={note} open onOpenChange={onOpenChange} />)
    expect(screen.queryByRole("alert", { name: /mercadería consumida/i })).not.toBeInTheDocument()
  })

  it("otro error en compra (remito modificado) sigue siendo un toast y no abre el aviso de stock", async () => {
    const user = userEvent.setup()
    mocks.mutateAsync.mockRejectedValue(new Error("delivery_note_changed: el remito cambió"))
    renderDialog(purchaseNote())
    await user.type(screen.getByLabelText(/motivo/i), "Motivo válido")
    await user.click(screen.getByRole("button", { name: /anular remito/i }))
    await waitFor(() => expect(mocks.toastError).toHaveBeenCalled())
    expect(screen.queryByRole("alert", { name: /mercadería consumida/i })).not.toBeInTheDocument()
  })

  it("en venta el mismo error de stock no abre el aviso de compra (el camino de venta no cambia)", async () => {
    const user = userEvent.setup()
    mocks.mutateAsync.mockRejectedValue(new Error("delivery_note_stock_consumed"))
    renderDialog(deliveryNote())
    await user.type(screen.getByLabelText(/motivo/i), "Motivo válido")
    await user.click(screen.getByRole("button", { name: /anular remito/i }))
    await waitFor(() => expect(mocks.toastError).toHaveBeenCalled())
    expect(screen.queryByRole("link", { name: "Editar el remito" })).not.toBeInTheDocument()
  })
})
