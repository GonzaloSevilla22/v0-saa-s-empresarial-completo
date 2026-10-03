/**
 * remitos-venta (D10/D11, tarea 5.10) — `DeactivateBranchDialog`: además de las
 * existencias, el diálogo de baja de una sucursal consulta sus remitos pendientes
 * (`GET /delivery-notes?status=issued&branch_id=…`, SIN filtro de sentido: el
 * remito de compra también retiene stock) y, si hay, en lugar de "Desactivar"
 * ofrece "Ver remitos pendientes" (`/remitos?estado=pendientes&sucursal=<id>`,
 * el contrato de query params de D11).
 *
 * Es UX, no seguridad: el guard real es el disparador de la base (`P0428`,
 * `branch_has_pending_delivery_notes`), que ya traduce `use-branches.ts`.
 */
import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, within } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import "@testing-library/jest-dom"

const mocks = vi.hoisted(() => ({
  branchStock: vi.fn(),
  deliveryNotes: vi.fn(),
}))

vi.mock("@/hooks/data/use-branch-stock", () => ({ useBranchStock: (id: string) => mocks.branchStock(id) }))
vi.mock("@/hooks/data/use-delivery-notes", () => ({
  useDeliveryNotes: (filters: unknown) => mocks.deliveryNotes(filters),
}))

import { DeactivateBranchDialog } from "@/components/branches/DeactivateBranchDialog"

function stockResult(rows: Array<{ quantity: number }> = [], isLoading = false) {
  return { branchStock: rows, isLoading, isError: false }
}

function notesResult(total: number | undefined, extra: Record<string, unknown> = {}) {
  return {
    data: total === undefined ? undefined : { items: [], total, page: 0, pages: total ? 1 : 0, summary: { pending_count: total, pending_total: "0" } },
    isLoading: false,
    isError: false,
    ...extra,
  }
}

const onConfirm = vi.fn()

/** El párrafo cuyo texto completo (con los <strong>) cumple el patrón. */
const paragraph = (scope: ReturnType<typeof within>, pattern: RegExp) =>
  scope.getByText((_, element) => element?.tagName === "P" && pattern.test(element.textContent ?? ""))

async function openDialog() {
  const user = userEvent.setup()
  render(<DeactivateBranchDialog branchId="b-7" branchName="Norte" onConfirm={onConfirm} isDeactivating={false} />)
  await user.click(screen.getByRole("button", { name: "Desactivar Norte" }))
  return { user, dialog: await screen.findByRole("alertdialog") }
}

beforeEach(() => {
  vi.clearAllMocks()
  mocks.branchStock.mockReturnValue(stockResult())
  mocks.deliveryNotes.mockReturnValue(notesResult(0))
})

describe("DeactivateBranchDialog — remitos pendientes", () => {
  it("consulta los remitos issued de ESTA sucursal, sin filtrar por sentido y de a una fila", () => {
    render(<DeactivateBranchDialog branchId="b-7" branchName="Norte" onConfirm={onConfirm} isDeactivating={false} />)
    expect(mocks.deliveryNotes).toHaveBeenCalledWith({ status: "issued", branchId: "b-7", pageSize: 1 })
    const filters = mocks.deliveryNotes.mock.calls[0][0] as Record<string, unknown>
    expect(filters).not.toHaveProperty("direction")
  })

  it("sin existencias y sin remitos pendientes ofrece Desactivar y llama a onConfirm", async () => {
    const { user, dialog } = await openDialog()
    expect(within(dialog).getByText(/vacía de existencias/i)).toBeInTheDocument()
    expect(within(dialog).queryByRole("link", { name: /ver remitos pendientes/i })).not.toBeInTheDocument()
    await user.click(within(dialog).getByRole("button", { name: "Desactivar" }))
    expect(onConfirm).toHaveBeenCalledTimes(1)
  })

  it("con remitos pendientes NO ofrece Desactivar: avisa cuántos y ofrece 'Ver remitos pendientes' con el contrato de la URL", async () => {
    mocks.deliveryNotes.mockReturnValue(notesResult(3))
    const { dialog } = await openDialog()
    expect(within(dialog).queryByRole("button", { name: "Desactivar" })).not.toBeInTheDocument()
    expect(paragraph(within(dialog), /3 remitos pendientes/i)).toBeInTheDocument()
    expect(within(dialog).getByRole("link", { name: /ver remitos pendientes/i })).toHaveAttribute(
      "href",
      "/remitos?estado=pendientes&sucursal=b-7",
    )
    expect(onConfirm).not.toHaveBeenCalled()
  })

  it("con uno solo usa el singular", async () => {
    mocks.deliveryNotes.mockReturnValue(notesResult(1))
    const { dialog } = await openDialog()
    expect(paragraph(within(dialog), /Tiene 1 remito pendiente que retiene mercadería/i)).toBeInTheDocument()
  })

  it("el título nombra la sucursal y el motivo (convertir o anular)", async () => {
    mocks.deliveryNotes.mockReturnValue(notesResult(2))
    const { dialog } = await openDialog()
    expect(within(dialog).getByRole("heading", { name: /"Norte" tiene remitos pendientes/i })).toBeInTheDocument()
    expect(within(dialog).getByText(/convertilos en venta o anulalos/i)).toBeInTheDocument()
  })

  it("con existencias Y remitos pendientes muestra los dos motivos y las dos salidas", async () => {
    mocks.branchStock.mockReturnValue(stockResult([{ quantity: 4 }, { quantity: 2 }]))
    mocks.deliveryNotes.mockReturnValue(notesResult(2))
    const { dialog } = await openDialog()
    expect(paragraph(within(dialog), /tiene 6 unidades/i)).toBeInTheDocument()
    expect(paragraph(within(dialog), /2 remitos pendientes/i)).toBeInTheDocument()
    expect(within(dialog).getByRole("link", { name: /ir a transferir stock/i })).toHaveAttribute("href", "/sucursales/b-7/stock")
    expect(within(dialog).getByRole("link", { name: /ver remitos pendientes/i })).toBeInTheDocument()
    expect(within(dialog).queryByRole("button", { name: "Desactivar" })).not.toBeInTheDocument()
  })

  it("con existencias y sin remitos conserva el comportamiento de siempre (sin enlace a remitos)", async () => {
    mocks.branchStock.mockReturnValue(stockResult([{ quantity: 5 }]))
    const { dialog } = await openDialog()
    expect(within(dialog).getByRole("link", { name: /ir a transferir stock/i })).toBeInTheDocument()
    expect(within(dialog).queryByRole("link", { name: /ver remitos pendientes/i })).not.toBeInTheDocument()
    expect(within(dialog).queryByRole("button", { name: "Desactivar" })).not.toBeInTheDocument()
  })

  it("mientras no se sabe si hay remitos pendientes, el disparador queda deshabilitado", () => {
    mocks.deliveryNotes.mockReturnValue({ data: undefined, isLoading: true, isError: false })
    render(<DeactivateBranchDialog branchId="b-7" branchName="Norte" onConfirm={onConfirm} isDeactivating={false} />)
    expect(screen.getByRole("button", { name: "Desactivar Norte" })).toBeDisabled()
  })

  it("si la consulta de remitos falla no bloquea la baja: la base igual la rechazaría con el motivo traducido", async () => {
    mocks.deliveryNotes.mockReturnValue({ data: undefined, isLoading: false, isError: true })
    const { dialog } = await openDialog()
    expect(within(dialog).getByRole("button", { name: "Desactivar" })).toBeInTheDocument()
  })
})
