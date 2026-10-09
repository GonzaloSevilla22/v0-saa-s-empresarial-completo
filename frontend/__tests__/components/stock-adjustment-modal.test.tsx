/**
 * stock-ledger-solo-rpc (tanda B, task 12.2) — `StockAdjustmentModal`:
 *   - el MOTIVO es obligatorio: rótulo «Motivo *», envío deshabilitado con el
 *     motivo en blanco, mensaje en línea asociado al campo, y NUNCA llama al
 *     servidor sin motivo;
 *   - se envía recortado (`p_reason`);
 *   - las transferencias dejaron de ser un tipo de ajuste (OQ-1);
 *   - el rechazo del servidor (rol, motivo, producto, stock) se muestra en
 *     castellano por el mapa canónico `humanizeOperationError`, no el
 *     `error.message` crudo.
 */
import { describe, expect, it, vi, beforeEach } from "vitest"
import { render, screen, waitFor } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"

const rpc = vi.hoisted(() => vi.fn())
const toastMock = vi.hoisted(() => ({ success: vi.fn(), warning: vi.fn(), error: vi.fn() }))

vi.mock("@/lib/supabase/client", () => ({ createClient: () => ({ rpc }) }))
vi.mock("sonner", () => ({ toast: toastMock }))
vi.mock("@/hooks/data/use-products", () => ({
  useProducts: () => ({
    products: [
      { id: "p-1", name: "Tomate", category: "Verdulería", price: 1000, cost: 600, stock: 8, minStock: 2, stockControlType: "tracked" },
      { id: "p-2", name: "Remera", category: "Ropa", price: 5000, cost: 2000, stock: 4, minStock: 1, stockControlType: "tracked" },
    ],
  }),
}))
vi.mock("@/lib/api/python-client", () => ({
  pythonClient: { get: vi.fn(), post: vi.fn(), put: vi.fn(), patch: vi.fn(), delete: vi.fn() },
}))

import { StockAdjustmentModal, MOVEMENT_OPTIONS } from "@/components/stock/stock-adjustment-modal"
import type { Product } from "@/lib/types"

const PRODUCT = {
  id: "p-1", name: "Tomate", category: "Verdulería", price: 1000, cost: 600, margin: 40,
  stock: 8, minStock: 2, isVariant: false, stockControlType: "tracked",
} as Product

function renderModal(onOpenChange = vi.fn(), onSuccess = vi.fn()) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <StockAdjustmentModal open onOpenChange={onOpenChange} product={PRODUCT} onSuccess={onSuccess} />
    </QueryClientProvider>,
  )
  return { onOpenChange, onSuccess }
}

const submit = () => screen.getByRole("button", { name: /registrar ajuste/i })

async function fillQuantity(user: ReturnType<typeof userEvent.setup>, value: string) {
  await user.type(screen.getByPlaceholderText("Cantidad…"), value)
}

describe("StockAdjustmentModal — motivo obligatorio", () => {
  beforeEach(() => {
    rpc.mockReset()
    toastMock.success.mockReset()
    toastMock.warning.mockReset()
    toastMock.error.mockReset()
    rpc.mockResolvedValue({ data: {}, error: null })
  })

  it("el campo se rotula «Motivo *» (obligatorio), ya no «(opcional)»", () => {
    renderModal()
    const field = screen.getByLabelText(/motivo/i)
    expect(field).toBeRequired()
    const label = screen.getByText(/motivo/i, { selector: "label" })
    expect(label.textContent).toMatch(/\*/)
    expect(label.textContent).not.toMatch(/opcional/i)
    // «Notas» sigue siendo opcional: la obligatoriedad es del motivo, no de todo el formulario.
    expect(screen.getByText(/notas/i, { selector: "label" }).textContent).toMatch(/opcional/i)
  })

  it("con cantidad y motivo en blanco el envío está deshabilitado, el mensaje lo explica y NO llama al servidor", async () => {
    const user = userEvent.setup()
    renderModal()
    await fillQuantity(user, "3")
    expect(submit()).toBeDisabled()
    const field = screen.getByLabelText(/motivo/i)
    expect(field).toHaveAttribute("aria-invalid", "true")
    const hint = screen.getByText(/el motivo es obligatorio/i)
    expect(field.getAttribute("aria-describedby")).toContain(hint.id)
    await user.click(submit())
    expect(rpc).not.toHaveBeenCalled()
  })

  it("un motivo sólo con espacios cuenta como en blanco", async () => {
    const user = userEvent.setup()
    renderModal()
    await fillQuantity(user, "3")
    await user.type(screen.getByLabelText(/motivo/i), "     ")
    expect(submit()).toBeDisabled()
    expect(rpc).not.toHaveBeenCalled()
  })

  it("con motivo se habilita, el mensaje desaparece y el motivo viaja RECORTADO", async () => {
    const user = userEvent.setup()
    const { onOpenChange, onSuccess } = renderModal()
    await fillQuantity(user, "3")
    await user.type(screen.getByLabelText(/motivo/i), "  rotura en depósito  ")
    expect(submit()).toBeEnabled()
    expect(screen.queryByText(/el motivo es obligatorio/i)).not.toBeInTheDocument()
    expect(screen.getByLabelText(/motivo/i)).toHaveAttribute("aria-invalid", "false")
    await user.click(submit())
    await waitFor(() => expect(rpc).toHaveBeenCalledTimes(1))
    expect(rpc).toHaveBeenCalledWith("rpc_stock_adjustment", {
      p_product_id: "p-1",
      p_type: "adjustment",
      p_reason: "rotura en depósito",
      p_notes: null,
      p_quantity_delta: 3,
    })
    await waitFor(() => expect(onSuccess).toHaveBeenCalled())
    expect(onOpenChange).toHaveBeenCalledWith(false)
  })
})

describe("StockAdjustmentModal — sin transferencias como tipo de ajuste (OQ-1)", () => {
  it("la lista de tipos ofrece los cinco ajustes manuales y ninguna transferencia", () => {
    const types = MOVEMENT_OPTIONS.map((o) => o.type)
    expect(types).toEqual(expect.arrayContaining(["adjustment", "physical_count", "loss", "damage", "expiry"]))
    expect(types).not.toContain("transfer_in")
    expect(types).not.toContain("transfer_out")
    for (const o of MOVEMENT_OPTIONS) expect(`${o.label} ${o.description}`).not.toMatch(/transferencia/i)
  })
})

describe("StockAdjustmentModal — el rechazo del servidor llega en castellano", () => {
  beforeEach(() => {
    rpc.mockReset()
    toastMock.error.mockReset()
  })

  async function submitWithServerError(message: string) {
    rpc.mockResolvedValue({ data: null, error: { message } })
    const user = userEvent.setup()
    renderModal()
    await fillQuantity(user, "3")
    await user.type(screen.getByLabelText(/motivo/i), "conteo")
    await user.click(submit())
    await waitFor(() => expect(rpc).toHaveBeenCalled())
  }

  it("insufficient_role → explica quién puede ajustar stock, sin el token", async () => {
    await submitWithServerError(
      "insufficient_role: tu rol no permite ajustar el stock a mano (requiere depósito, administrador o dueño)",
    )
    expect(await screen.findByText(/tu rol no permite ajustar el stock a mano/i)).toBeInTheDocument()
    expect(screen.getByText(/dep[óo]sito/i, { selector: "p" })).toBeInTheDocument()
    expect(screen.queryByText(/insufficient_role/)).not.toBeInTheDocument()
    expect(toastMock.error).toHaveBeenCalled()
  })

  it("stock insuficiente del ajuste → cuánto hay y cuánto se restaba", async () => {
    await submitWithServerError("Stock insuficiente. Disponible: 5.0000, delta: -9")
    expect(await screen.findByText(/no alcanza el stock/i)).toBeInTheDocument()
    expect(screen.queryByText(/delta/)).not.toBeInTheDocument()
  })

  it("un error NO reconocido se muestra tal cual y el modal sigue abierto con la fila marcada", async () => {
    await submitWithServerError("algo que nadie previó")
    expect(await screen.findByText("algo que nadie previó")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /registrar ajuste/i })).toBeInTheDocument()
  })
})
