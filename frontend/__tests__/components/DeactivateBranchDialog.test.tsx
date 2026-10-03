/**
 * remitos-venta (D10/D11, tarea 5.10) y remitos-compra (D11, tarea 5.8) —
 * `DeactivateBranchDialog`: además de las existencias, el diálogo de baja de una
 * sucursal consulta sus remitos pendientes y, si hay, en lugar de "Desactivar"
 * ofrece ir a verlos.
 *
 * remitos-compra: con las pestañas De venta / De compra de `/remitos`, el diálogo
 * consulta el total de CADA sentido (`GET /delivery-notes?direction=…&status=issued
 * &branch_id=…`, de a una fila) y muestra UN enlace por sentido con pendientes
 * (`/remitos?estado=pendientes&sucursal=<id>&sentido=venta|compra`, el contrato de
 * query params de D11), cada uno con el texto de su sentido: el remito de venta
 * RETIENE mercadería de la sucursal y el de compra le APORTÓ stock.
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

/** Los pendientes de cada sentido: la consulta de venta y la de compra devuelven cosas distintas. */
function givenPending(pending: { sale?: number; purchase?: number }) {
  mocks.deliveryNotes.mockImplementation((filters: { direction?: string }) =>
    notesResult(filters.direction === "purchase" ? (pending.purchase ?? 0) : (pending.sale ?? 0)),
  )
}

const onConfirm = vi.fn()

/** El párrafo cuyo texto completo (con los <strong>) cumple el patrón. */
const paragraph = (scope: ReturnType<typeof within>, pattern: RegExp) =>
  scope.getByText((_content: string, element: Element | null) => element?.tagName === "P" && pattern.test(element.textContent ?? ""))

async function openDialog() {
  const user = userEvent.setup()
  render(<DeactivateBranchDialog branchId="b-7" branchName="Norte" onConfirm={onConfirm} isDeactivating={false} />)
  await user.click(screen.getByRole("button", { name: "Desactivar Norte" }))
  return { user, dialog: await screen.findByRole("alertdialog") }
}

beforeEach(() => {
  vi.clearAllMocks()
  mocks.branchStock.mockReturnValue(stockResult())
  givenPending({})
})

describe("DeactivateBranchDialog — remitos pendientes", () => {
  it("consulta los remitos issued de ESTA sucursal, uno por sentido y de a una fila", () => {
    render(<DeactivateBranchDialog branchId="b-7" branchName="Norte" onConfirm={onConfirm} isDeactivating={false} />)
    expect(mocks.deliveryNotes).toHaveBeenCalledWith({ direction: "sale", status: "issued", branchId: "b-7", pageSize: 1 })
    expect(mocks.deliveryNotes).toHaveBeenCalledWith({ direction: "purchase", status: "issued", branchId: "b-7", pageSize: 1 })
  })

  it("sin existencias y sin remitos pendientes ofrece Desactivar y llama a onConfirm", async () => {
    const { user, dialog } = await openDialog()
    expect(within(dialog).getByText(/vacía de existencias/i)).toBeInTheDocument()
    expect(within(dialog).queryByRole("link", { name: /ver remitos/i })).not.toBeInTheDocument()
    await user.click(within(dialog).getByRole("button", { name: "Desactivar" }))
    expect(onConfirm).toHaveBeenCalledTimes(1)
  })

  it("con remitos de venta pendientes NO ofrece Desactivar: avisa cuántos y enlaza a la pestaña De venta", async () => {
    givenPending({ sale: 3 })
    const { dialog } = await openDialog()
    expect(within(dialog).queryByRole("button", { name: "Desactivar" })).not.toBeInTheDocument()
    expect(paragraph(within(dialog), /3 remitos pendientes/i)).toBeInTheDocument()
    expect(within(dialog).getByRole("link", { name: /ver remitos pendientes/i })).toHaveAttribute(
      "href",
      "/remitos?estado=pendientes&sucursal=b-7&sentido=venta",
    )
    expect(within(dialog).queryByRole("link", { name: /remitos de compra/i })).not.toBeInTheDocument()
    expect(onConfirm).not.toHaveBeenCalled()
  })

  it("con uno solo usa el singular", async () => {
    givenPending({ sale: 1 })
    const { dialog } = await openDialog()
    expect(paragraph(within(dialog), /Tiene 1 remito pendiente que retiene mercadería/i)).toBeInTheDocument()
  })

  it("el título nombra la sucursal y el motivo; las salidas son convertir en venta o anular", async () => {
    givenPending({ sale: 2 })
    const { dialog } = await openDialog()
    expect(within(dialog).getByRole("heading", { name: /"Norte" tiene remitos pendientes/i })).toBeInTheDocument()
    expect(within(dialog).getByText(/convertilos en venta o anulalos \(un administrador o el dueño\)/i)).toBeInTheDocument()
  })

  it("con existencias Y remitos pendientes muestra los dos motivos y las dos salidas", async () => {
    mocks.branchStock.mockReturnValue(stockResult([{ quantity: 4 }, { quantity: 2 }]))
    givenPending({ sale: 2 })
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
    expect(within(dialog).queryByRole("link", { name: /ver remitos/i })).not.toBeInTheDocument()
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

describe("DeactivateBranchDialog — remitos de compra pendientes (remitos-compra 5.8)", () => {
  it("con remitos de compra pendientes NO ofrece Desactivar: dice que APORTARON stock y enlaza a la pestaña De compra", async () => {
    givenPending({ purchase: 3 })
    const { dialog } = await openDialog()
    expect(within(dialog).queryByRole("button", { name: "Desactivar" })).not.toBeInTheDocument()
    expect(
      paragraph(within(dialog), /Tiene 3 remitos de compra pendientes que aportaron stock a esta sucursal/i),
    ).toBeInTheDocument()
    expect(within(dialog).getByRole("link", { name: /ver remitos de compra pendientes/i })).toHaveAttribute(
      "href",
      "/remitos?estado=pendientes&sucursal=b-7&sentido=compra",
    )
    expect(within(dialog).queryByRole("link", { name: /^ver remitos pendientes$/i })).not.toBeInTheDocument()
    expect(onConfirm).not.toHaveBeenCalled()
  })

  it("con uno solo usa el singular de compra", async () => {
    givenPending({ purchase: 1 })
    const { dialog } = await openDialog()
    expect(paragraph(within(dialog), /Tiene 1 remito de compra pendiente que aportó stock/i)).toBeInTheDocument()
  })

  it("la salida de compra es convertir en compra o anular, no 'en venta'", async () => {
    givenPending({ purchase: 2 })
    const { dialog } = await openDialog()
    expect(within(dialog).getByRole("heading", { name: /"Norte" tiene remitos pendientes/i })).toBeInTheDocument()
    expect(within(dialog).getByText(/convertilos en compra o anulalos \(un administrador o el dueño\)/i)).toBeInTheDocument()
    expect(within(dialog).queryByText(/convertilos en venta/i)).not.toBeInTheDocument()
  })

  it("con pendientes de los DOS sentidos muestra un párrafo y un enlace por sentido, cada uno con su texto", async () => {
    givenPending({ sale: 2, purchase: 5 })
    const { dialog } = await openDialog()
    expect(paragraph(within(dialog), /Tiene 2 remitos pendientes que retienen mercadería de esta sucursal/i)).toBeInTheDocument()
    expect(paragraph(within(dialog), /Tiene 5 remitos de compra pendientes que aportaron stock a esta sucursal/i)).toBeInTheDocument()
    const saleLink = within(dialog).getByRole("link", { name: /^ver remitos pendientes$/i })
    const purchaseLink = within(dialog).getByRole("link", { name: /^ver remitos de compra pendientes$/i })
    expect(saleLink).toHaveAttribute("href", "/remitos?estado=pendientes&sucursal=b-7&sentido=venta")
    expect(purchaseLink).toHaveAttribute("href", "/remitos?estado=pendientes&sucursal=b-7&sentido=compra")
    expect(within(dialog).queryByRole("button", { name: "Desactivar" })).not.toBeInTheDocument()
  })

  it("con existencias y remitos de compra pendientes muestra los dos motivos", async () => {
    mocks.branchStock.mockReturnValue(stockResult([{ quantity: 4 }]))
    givenPending({ purchase: 1 })
    const { dialog } = await openDialog()
    expect(paragraph(within(dialog), /tiene 4 unidades/i)).toBeInTheDocument()
    expect(paragraph(within(dialog), /1 remito de compra pendiente/i)).toBeInTheDocument()
    expect(within(dialog).getByRole("link", { name: /ir a transferir stock/i })).toBeInTheDocument()
    expect(within(dialog).getByRole("link", { name: /ver remitos de compra pendientes/i })).toBeInTheDocument()
  })

  it("mientras carga la consulta de COMPRA el disparador queda deshabilitado aunque la de venta ya resolvió", () => {
    mocks.deliveryNotes.mockImplementation((filters: { direction?: string }) =>
      filters.direction === "purchase" ? { data: undefined, isLoading: true, isError: false } : notesResult(0),
    )
    render(<DeactivateBranchDialog branchId="b-7" branchName="Norte" onConfirm={onConfirm} isDeactivating={false} />)
    expect(screen.getByRole("button", { name: "Desactivar Norte" })).toBeDisabled()
  })

  it("si falla sólo la consulta de compra no bloquea, pero los pendientes de venta sí se muestran", async () => {
    mocks.deliveryNotes.mockImplementation((filters: { direction?: string }) =>
      filters.direction === "purchase" ? { data: undefined, isLoading: false, isError: true } : notesResult(2),
    )
    const { dialog } = await openDialog()
    expect(within(dialog).queryByRole("button", { name: "Desactivar" })).not.toBeInTheDocument()
    expect(within(dialog).getByRole("link", { name: /^ver remitos pendientes$/i })).toBeInTheDocument()
    expect(within(dialog).queryByRole("link", { name: /remitos de compra/i })).not.toBeInTheDocument()
  })
})
