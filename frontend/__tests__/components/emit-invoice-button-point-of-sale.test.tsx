/**
 * punto-venta-seleccion (D4/D8, tasks 4.3/4.4) — EmitInvoiceButton resuelve el
 * punto de venta POR SÍ MISMO (las pantallas ya no calculan uno).
 *
 *   - 1 PV activo  → emite al primer clic con ese PV explícito, sin diálogo;
 *   - ≥ 2 activos  → abre EmitirComprobanteDialog con la preselección; la
 *                    emisión manda SIEMPRE el id elegido (nunca null);
 *   - tras un OK se recuerda la elección en sessionStorage por cuenta y la
 *     próxima apertura (otra venta, misma sesión) la preselecciona; cancelar
 *     no escribe nada;
 *   - 0 activos    → aviso "Sin punto de venta" con enlace a la configuración,
 *                    sin botón (antes la RPC fallaba con no_active_point_of_sale);
 *   - un PV inactivo (aunque sea el de menor número) nunca se envía.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, waitFor } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"

const { getMock, postMock } = vi.hoisted(() => ({ getMock: vi.fn(), postMock: vi.fn() }))
vi.mock("@/lib/api/python-client", () => ({ pythonClient: { get: getMock, post: postMock } }))
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn(), info: vi.fn() } }))
vi.mock("@/components/fiscal/FiscalDocumentBadge", () => ({ FiscalDocumentBadge: () => <span>badge</span> }))

import { EmitInvoiceButton } from "@/components/fiscal/EmitInvoiceButton"

const pvRow = (id: string, numero: number, isActive = true, isDefault = false) => ({
  id, numero, is_active: isActive, is_default: isDefault,
  fiscal_profile_id: "fp-1", account_id: "acc-1", branch_id: null, created_at: "2026-09-26T00:00:00Z",
})

const PROFILE_ROW = {
  id: "fp-1", account_id: "acc-1", cuit: "27213790337", iva_condition: "monotributista",
  iibb_condition: null, ambiente: "produccion", delegacion_autorizada: true,
  certificado_afip_path: null, created_at: "2026-09-26T00:00:00Z",
}

const EMIT_OK = (pv: number) => ({
  fiscal_document_id: `fd-${pv}`, comprobante_type: "factura_c", status: "pending_cae",
  punto_de_venta: pv, number: 501, sales_order_id: "so-1",
})

function mockBackend(pvs: ReturnType<typeof pvRow>[]) {
  getMock.mockImplementation(async (path: string) => {
    if (path === "/fiscal/points-of-sale") return pvs
    if (path === "/fiscal/profile") return PROFILE_ROW
    throw new Error(`GET inesperado: ${path}`)
  })
}

function renderButton(salesOrderId = "so-1", client = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })) {
  return render(
    <QueryClientProvider client={client}>
      <EmitInvoiceButton
        salesOrderId={salesOrderId}
        salesOrderStatus="confirmed"
        fiscalDocumentId={null}
        ivaConditionEmisor="monotributista"
      />
    </QueryClientProvider>,
  )
}

const emitButton = () => screen.findByRole("button", { name: /Emitir comprobante AFIP/ })
const confirmButton = () => screen.getByRole("button", { name: /Confirmar y enviar al ARCA/ })

beforeEach(() => {
  getMock.mockReset()
  postMock.mockReset()
  sessionStorage.clear()
})

describe("EmitInvoiceButton — selección del punto de venta", () => {
  it("con UN PV activo emite al primer clic con ese PV explícito y sin diálogo", async () => {
    const user = userEvent.setup()
    // El inactivo de menor número NUNCA se envía (antes /ventas mandaba pointsOfSale[0]).
    mockBackend([pvRow("pv-1", 1, false), pvRow("pv-3", 3)])
    postMock.mockResolvedValueOnce(EMIT_OK(3))
    renderButton()

    const btn = await emitButton()
    await waitFor(() => expect(btn).toBeEnabled())
    await user.click(btn)

    await waitFor(() =>
      expect(postMock).toHaveBeenCalledWith("/sales-orders/so-1/emit-invoice", { point_of_sale_id: "pv-3" }),
    )
    expect(screen.queryByRole("dialog")).toBeNull()
    expect(await screen.findByText("badge")).toBeInTheDocument()
  })

  it("con DOS activos abre el diálogo y todavía no emite", async () => {
    const user = userEvent.setup()
    mockBackend([pvRow("pv-3", 3), pvRow("pv-9999", 9999)])
    renderButton()

    const btn = await emitButton()
    await waitFor(() => expect(btn).toBeEnabled())
    await user.click(btn)

    expect(await screen.findByRole("dialog")).toBeInTheDocument()
    expect(postMock).not.toHaveBeenCalled()
    // Sin predeterminado ni elección previa: hay que elegir.
    expect(confirmButton()).toBeDisabled()
  })

  it("confirmar emite con el id elegido (explícito, nunca null) y lo recuerda por cuenta", async () => {
    const user = userEvent.setup()
    mockBackend([pvRow("pv-3", 3), pvRow("pv-9999", 9999)])
    postMock.mockResolvedValueOnce(EMIT_OK(9999))
    renderButton()

    await user.click(await emitButton())
    await user.click(await screen.findByRole("combobox", { name: "Punto de venta" }))
    await user.click(screen.getByRole("option", { name: /PV 9999/ }))
    await user.click(confirmButton())

    await waitFor(() =>
      expect(postMock).toHaveBeenCalledWith("/sales-orders/so-1/emit-invoice", { point_of_sale_id: "pv-9999" }),
    )
    expect(JSON.parse(sessionStorage.getItem("fiscal:last-pv:acc-1") ?? "null")).toBe("pv-9999")
    await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull())
  })

  it("con predeterminado el diálogo abre ya elegido y se confirma en un clic", async () => {
    const user = userEvent.setup()
    mockBackend([pvRow("pv-3", 3), pvRow("pv-9999", 9999, true, true)])
    postMock.mockResolvedValueOnce(EMIT_OK(9999))
    renderButton()

    await user.click(await emitButton())
    await screen.findByRole("dialog")
    expect(confirmButton()).toBeEnabled()
    await user.click(confirmButton())
    await waitFor(() =>
      expect(postMock).toHaveBeenCalledWith("/sales-orders/so-1/emit-invoice", { point_of_sale_id: "pv-9999" }),
    )
  })

  it("la elección se recuerda: otra venta de la misma sesión abre con ese PV (gana al predeterminado)", async () => {
    const user = userEvent.setup()
    mockBackend([pvRow("pv-3", 3), pvRow("pv-9999", 9999, true, true)])
    postMock.mockResolvedValueOnce(EMIT_OK(3))
    const client = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
    // Las dos filas montadas A LA VEZ, como en /ventas/ordenes.
    render(
      <QueryClientProvider client={client}>
        <EmitInvoiceButton salesOrderId="so-1" salesOrderStatus="confirmed" fiscalDocumentId={null} ivaConditionEmisor="monotributista" />
        <EmitInvoiceButton salesOrderId="so-2" salesOrderStatus="confirmed" fiscalDocumentId={null} ivaConditionEmisor="monotributista" />
      </QueryClientProvider>,
    )

    const [first] = await screen.findAllByRole("button", { name: /Emitir comprobante AFIP/ })
    await waitFor(() => expect(first).toBeEnabled())
    await user.click(first)
    await user.click(await screen.findByRole("combobox", { name: "Punto de venta" }))
    await user.click(screen.getByRole("option", { name: /PV 0003/ }))
    await user.click(confirmButton())
    await waitFor(() => expect(postMock).toHaveBeenCalledTimes(1))
    await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull())

    const [second] = screen.getAllByRole("button", { name: /Emitir comprobante AFIP/ })
    await user.click(second)
    expect(await screen.findByRole("combobox", { name: "Punto de venta" })).toHaveTextContent("PV 0003")
  })

  it("cancelar no emite ni cambia la elección recordada", async () => {
    const user = userEvent.setup()
    sessionStorage.setItem("fiscal:last-pv:acc-1", JSON.stringify("pv-9999"))
    mockBackend([pvRow("pv-3", 3), pvRow("pv-9999", 9999)])
    renderButton()

    await user.click(await emitButton())
    await user.click(await screen.findByRole("combobox", { name: "Punto de venta" }))
    await user.click(screen.getByRole("option", { name: /PV 0003/ }))
    await user.click(screen.getByRole("button", { name: "Cancelar" }))

    expect(postMock).not.toHaveBeenCalled()
    expect(JSON.parse(sessionStorage.getItem("fiscal:last-pv:acc-1") ?? "null")).toBe("pv-9999")
  })

  it("una emisión fallida no se recuerda", async () => {
    const user = userEvent.setup()
    mockBackend([pvRow("pv-3", 3), pvRow("pv-9999", 9999, true, true)])
    postMock.mockRejectedValueOnce(new Error("Error de base de datos: algo"))
    renderButton()

    await user.click(await emitButton())
    await screen.findByRole("dialog")
    await user.click(confirmButton())
    await waitFor(() => expect(postMock).toHaveBeenCalledTimes(1))
    expect(sessionStorage.getItem("fiscal:last-pv:acc-1")).toBeNull()
  })

  it("sin PV activos: aviso con enlace a la configuración y sin botón de emitir", async () => {
    mockBackend([pvRow("pv-1", 1, false)])
    renderButton()

    expect(await screen.findByText("Sin punto de venta")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: /Configurar/ })).toHaveAttribute("href", "/configuracion/fiscal")
    expect(screen.queryByRole("button", { name: /Emitir comprobante AFIP/ })).toBeNull()
  })
})
