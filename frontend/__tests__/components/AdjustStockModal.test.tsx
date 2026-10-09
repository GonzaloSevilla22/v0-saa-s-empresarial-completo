/**
 * stock-ledger-solo-rpc (tanda B, task 12.4) — `AdjustStockModal` (ajuste por
 * sucursal): el MOTIVO es obligatorio, se valida RECORTADO (`.trim().min(1)`) y
 * viaja recortado; el campo se rotula «Motivo» y el error queda asociado al input.
 * (Antes un motivo de puros espacios pasaba el `min(1)`.)
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, waitFor } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { AdjustStockModal } from "@/components/branches/AdjustStockModal"

const { adjust, toastMock } = vi.hoisted(() => ({
  adjust: vi.fn(),
  toastMock: { success: vi.fn(), error: vi.fn() },
}))

vi.mock("@/hooks/data/use-branch-stock", () => ({
  useAdjustBranchStock: () => ({ mutateAsync: adjust, isPending: false }),
}))
vi.mock("sonner", () => ({ toast: toastMock }))

function renderModal(onClose = vi.fn()) {
  render(
    <AdjustStockModal productId="p1" branchId="b1" currentQuantity={10} productName="Tomate" onClose={onClose} />,
  )
  return onClose
}

describe("AdjustStockModal — motivo obligatorio y recortado", () => {
  beforeEach(() => {
    adjust.mockReset()
    adjust.mockResolvedValue({})
    toastMock.success.mockReset()
    toastMock.error.mockReset()
  })

  it("el campo se rotula «Motivo» y es obligatorio", () => {
    renderModal()
    const input = screen.getByLabelText(/motivo/i)
    expect(input).toHaveAttribute("id", "reason")
  })

  it("sin motivo no llama al servidor y explica que es obligatorio, asociado al campo", async () => {
    const user = userEvent.setup()
    renderModal()
    await user.click(screen.getByRole("button", { name: /^ajustar stock$/i }))
    const message = await screen.findByText(/el motivo es obligatorio/i)
    const input = screen.getByLabelText(/motivo/i)
    expect(input).toHaveAttribute("aria-invalid", "true")
    expect(input.getAttribute("aria-describedby")).toContain(message.id)
    expect(adjust).not.toHaveBeenCalled()
  })

  it("un motivo de puros espacios tampoco pasa (antes pasaba el min(1))", async () => {
    const user = userEvent.setup()
    renderModal()
    await user.type(screen.getByLabelText(/motivo/i), "      ")
    await user.click(screen.getByRole("button", { name: /^ajustar stock$/i }))
    expect(await screen.findByText(/el motivo es obligatorio/i)).toBeInTheDocument()
    expect(adjust).not.toHaveBeenCalled()
  })

  it("con motivo viaja RECORTADO y la cantidad nueva", async () => {
    const user = userEvent.setup()
    const onClose = renderModal()
    const qty = screen.getByLabelText(/nueva cantidad/i)
    await user.clear(qty)
    await user.type(qty, "7")
    await user.type(screen.getByLabelText(/motivo/i), "  inventario físico  ")
    await user.click(screen.getByRole("button", { name: /^ajustar stock$/i }))
    await waitFor(() => expect(adjust).toHaveBeenCalledTimes(1))
    expect(adjust).toHaveBeenCalledWith({
      productId: "p1",
      branchId: "b1",
      newQuantity: 7,
      reason: "inventario físico",
    })
    await waitFor(() => expect(onClose).toHaveBeenCalled())
  })

  it("un rechazo del servidor (ya traducido por el hook) se muestra en el toast tal cual", async () => {
    adjust.mockRejectedValue(new Error("Tu rol no permite ajustar el stock a mano."))
    const user = userEvent.setup()
    renderModal()
    await user.type(screen.getByLabelText(/motivo/i), "conteo")
    await user.click(screen.getByRole("button", { name: /^ajustar stock$/i }))
    await waitFor(() => expect(toastMock.error).toHaveBeenCalledWith("Tu rol no permite ajustar el stock a mano."))
  })
})
