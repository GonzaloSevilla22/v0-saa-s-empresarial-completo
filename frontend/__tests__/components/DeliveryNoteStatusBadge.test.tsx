/**
 * remitos-venta (tarea 5.3) — `DeliveryNoteStatusBadge`: los tres estados del
 * remito con los rótulos de `lib/delivery-note-status`. Tokens semánticos, sin
 * literales de paleta (el gate `token-contrast-aa` los custodia).
 */
import React from "react"
import { describe, it, expect } from "vitest"
import { render, screen } from "@testing-library/react"
import "@testing-library/jest-dom"

import { DeliveryNoteStatusBadge } from "@/components/delivery-notes/DeliveryNoteStatusBadge"
import { DELIVERY_NOTE_STATUS_LABELS } from "@/lib/delivery-note-status"
import { DELIVERY_NOTE_STATUSES } from "@/lib/delivery-note-types"

describe("DeliveryNoteStatusBadge", () => {
  it.each([
    ["issued", "Pendiente"],
    ["converted", "Convertido en venta"],
    ["canceled", "Anulado"],
  ] as const)("el estado %s se rotula '%s'", (status, label) => {
    render(<DeliveryNoteStatusBadge status={status} />)
    expect(screen.getByText(label)).toBeInTheDocument()
  })

  it.each([
    ["issued", "Pendiente"],
    ["converted", "Convertido en compra"],
    ["canceled", "Anulado"],
  ] as const)("remitos-compra: con direction purchase el estado %s se rotula '%s'", (status, label) => {
    render(<DeliveryNoteStatusBadge status={status} direction="purchase" />)
    expect(screen.getByText(label)).toBeInTheDocument()
  })

  it("remitos-compra: con direction sale (explícito) el convertido sigue siendo 'en venta'", () => {
    render(<DeliveryNoteStatusBadge status="converted" direction="sale" />)
    expect(screen.getByText("Convertido en venta")).toBeInTheDocument()
  })

  it("expone el estado para pruebas y lectores (data-status)", () => {
    const { container } = render(<DeliveryNoteStatusBadge status="converted" />)
    expect(container.firstElementChild).toHaveAttribute("data-status", "converted")
  })

  it("cada estado tiene rótulo y ninguno usa literales de paleta de Tailwind", () => {
    for (const status of DELIVERY_NOTE_STATUSES) {
      expect(DELIVERY_NOTE_STATUS_LABELS.sale[status]).toBeTruthy()
      const { container, unmount } = render(<DeliveryNoteStatusBadge status={status} />)
      const classes = container.firstElementChild?.className ?? ""
      expect(classes).not.toMatch(/\b(bg|text|border)-(red|green|yellow|blue|amber|emerald|slate|gray)-\d{2,3}\b/)
      unmount()
    }
  })

  it("los tres estados se distinguen por clases distintas (no sólo por el texto)", () => {
    const classes = DELIVERY_NOTE_STATUSES.map((status) => {
      const { container, unmount } = render(<DeliveryNoteStatusBadge status={status} />)
      const value = container.firstElementChild?.className ?? ""
      unmount()
      return value
    })
    expect(new Set(classes).size).toBe(3)
  })
})
