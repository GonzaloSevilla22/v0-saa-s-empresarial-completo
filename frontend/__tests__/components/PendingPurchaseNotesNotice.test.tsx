/**
 * remitos-compra (tanda B, D11, tarea 7.9) — `PendingPurchaseNotesNotice`: el aviso
 * contra la doble suma. Lo montan el formulario de compra (con el proveedor elegido)
 * y la Factura IA (sin proveedor identificado).
 *
 * Invariantes bajo test:
 *  - reutiliza `useDeliveryNotes({ direction: "purchase", status: "issued" })` (sin
 *    hook gemelo), acotado al proveedor cuando se conoce y de a una fila (sólo se
 *    necesita el total);
 *  - sin remitos pendientes, mientras carga o si la consulta falla: NO hay aviso;
 *  - con `supplierId === null` (el formulario todavía no tiene proveedor): NO hay aviso
 *    y NO se consulta nada — preguntar por los pendientes de toda la cuenta ahí sería
 *    otra pregunta;
 *  - el aviso es informativo (`role="note"`), nunca una alerta que bloquee, y lleva el
 *    enlace a la pestaña De compra filtrada por pendientes.
 */
import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen } from "@testing-library/react"
import "@testing-library/jest-dom"

const mocks = vi.hoisted(() => ({
  useDeliveryNotes: vi.fn(),
}))

vi.mock("@/hooks/data/use-delivery-notes", () => ({
  useDeliveryNotes: (filters: unknown) => mocks.useDeliveryNotes(filters),
}))

import { PendingPurchaseNotesNotice } from "@/components/delivery-notes/PendingPurchaseNotesNotice"

function pending(total: number | undefined, extra: Record<string, unknown> = {}) {
  mocks.useDeliveryNotes.mockReturnValue({ data: total === undefined ? undefined : { items: [], total }, ...extra })
}

beforeEach(() => {
  vi.clearAllMocks()
  pending(0)
})

describe("PendingPurchaseNotesNotice — con proveedor", () => {
  it("consulta los pendientes de COMPRA de ese proveedor, de a una fila", () => {
    pending(2)
    render(<PendingPurchaseNotesNotice supplierId="sup-1" />)

    expect(mocks.useDeliveryNotes).toHaveBeenCalledWith({
      direction: "purchase",
      status: "issued",
      supplierId: "sup-1",
      pageSize: 1,
    })
  })

  it("con pendientes avisa cuántos hay y manda a convertirlos desde el remito", () => {
    pending(3)
    render(<PendingPurchaseNotesNotice supplierId="sup-1" />)

    const note = screen.getByRole("note")
    expect(note).toHaveTextContent(/este proveedor tiene 3 remitos de compra pendientes/i)
    expect(note).toHaveTextContent(/convertilo desde el remito para no sumar el stock dos veces/i)
  })

  it("el enlace lleva a la pestaña De compra, pendientes, de ese proveedor", () => {
    pending(3)
    render(<PendingPurchaseNotesNotice supplierId="sup-1" />)

    expect(screen.getByRole("link", { name: /ver remitos pendientes/i })).toHaveAttribute(
      "href",
      "/remitos?sentido=compra&estado=pendientes&proveedor=sup-1",
    )
  })

  it("un solo pendiente habla en singular", () => {
    pending(1)
    render(<PendingPurchaseNotesNotice supplierId="sup-1" />)

    expect(screen.getByRole("note")).toHaveTextContent(/este proveedor tiene 1 remito de compra pendiente\. si esta factura es de ese remito/i)
  })

  it("no es una alerta: informa, no bloquea ni interrumpe al lector de pantalla", () => {
    pending(3)
    render(<PendingPurchaseNotesNotice supplierId="sup-1" />)

    expect(screen.queryByRole("alert")).not.toBeInTheDocument()
  })

  it.each([
    ["sin pendientes", 0],
    ["mientras carga (sin datos)", undefined],
  ])("%s: no hay aviso", (_label, total) => {
    pending(total)
    const { container } = render(<PendingPurchaseNotesNotice supplierId="sup-1" />)

    expect(screen.queryByRole("note")).not.toBeInTheDocument()
    expect(container).toBeEmptyDOMElement()
  })

  it("si la consulta falla no hay aviso (no inventa un conteo)", () => {
    mocks.useDeliveryNotes.mockReturnValue({ data: undefined, isError: true })
    render(<PendingPurchaseNotesNotice supplierId="sup-1" />)

    expect(screen.queryByRole("note")).not.toBeInTheDocument()
  })
})

describe("PendingPurchaseNotesNotice — proveedor todavía sin elegir", () => {
  it("con supplierId null no hay aviso y no se consulta ningún remito", () => {
    pending(5)
    const { container } = render(<PendingPurchaseNotesNotice supplierId={null} />)

    expect(mocks.useDeliveryNotes).not.toHaveBeenCalled()
    expect(container).toBeEmptyDOMElement()
  })

  it("al elegir un proveedor aparece el aviso de ese proveedor", () => {
    pending(2)
    const view = render(<PendingPurchaseNotesNotice supplierId={null} />)
    expect(screen.queryByRole("note")).not.toBeInTheDocument()

    view.rerender(<PendingPurchaseNotesNotice supplierId="sup-9" />)

    expect(screen.getByRole("note")).toHaveTextContent(/2 remitos de compra pendientes/i)
    expect(mocks.useDeliveryNotes).toHaveBeenCalledWith(expect.objectContaining({ supplierId: "sup-9" }))
  })
})

describe("PendingPurchaseNotesNotice — sin proveedor identificado (Factura IA)", () => {
  it("consulta los pendientes de compra de TODA la cuenta, sin filtrar proveedor", () => {
    pending(4)
    render(<PendingPurchaseNotesNotice />)

    expect(mocks.useDeliveryNotes).toHaveBeenCalledWith({ direction: "purchase", status: "issued", pageSize: 1 })
    expect(mocks.useDeliveryNotes.mock.calls[0][0]).not.toHaveProperty("supplierId")
  })

  it("avisa de los pendientes de la cuenta y enlaza a la pestaña De compra filtrada por pendientes", () => {
    pending(4)
    render(<PendingPurchaseNotesNotice />)

    expect(screen.getByRole("note")).toHaveTextContent(/tenés 4 remitos de compra pendientes/i)
    expect(screen.getByRole("link", { name: /ver remitos pendientes/i })).toHaveAttribute(
      "href",
      "/remitos?sentido=compra&estado=pendientes",
    )
  })

  it("sin pendientes en la cuenta no hay aviso", () => {
    pending(0)
    const { container } = render(<PendingPurchaseNotesNotice />)

    expect(container).toBeEmptyDOMElement()
  })
})
