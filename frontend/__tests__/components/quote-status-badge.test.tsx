/**
 * presupuestos-modulo (tarea 5.5) — `QuoteStatusBadge`: los 5 estados del
 * presupuesto más "Vencido" derivado (`is_expired`: abierto con la validez
 * pasada que el barrido todavía no marcó). Tokens semánticos, sin literales de
 * paleta (el gate `token-contrast-aa` los custodia).
 */
import React from "react"
import { describe, it, expect } from "vitest"
import { render, screen } from "@testing-library/react"
import "@testing-library/jest-dom"

import { QuoteStatusBadge } from "@/components/quotes/QuoteStatusBadge"
import { effectiveQuoteStatus, QUOTE_STATUS_LABELS } from "@/lib/quote-status"
import { QUOTE_STATUSES } from "@/lib/quote-types"

describe("effectiveQuoteStatus", () => {
  it("un borrador o enviado con la validez pasada se muestra como vencido", () => {
    expect(effectiveQuoteStatus("draft", true)).toBe("expired")
    expect(effectiveQuoteStatus("sent", true)).toBe("expired")
  })

  it("los demás estados no cambian aunque is_expired llegue en true", () => {
    expect(effectiveQuoteStatus("accepted", true)).toBe("accepted")
    expect(effectiveQuoteStatus("rejected", true)).toBe("rejected")
    expect(effectiveQuoteStatus("expired", true)).toBe("expired")
  })

  it("sin is_expired el estado queda como vino", () => {
    expect(effectiveQuoteStatus("draft", false)).toBe("draft")
    expect(effectiveQuoteStatus("sent", false)).toBe("sent")
    expect(effectiveQuoteStatus("sent", undefined)).toBe("sent")
  })
})

describe("QuoteStatusBadge", () => {
  it.each([
    ["draft", "Borrador"],
    ["sent", "Enviado"],
    ["accepted", "Aceptado"],
    ["expired", "Vencido"],
    ["rejected", "Rechazado"],
  ] as const)("el estado %s se rotula '%s'", (status, label) => {
    render(<QuoteStatusBadge status={status} />)
    expect(screen.getByText(label)).toBeInTheDocument()
  })

  it("is_expired sobre un enviado muestra 'Vencido' y no 'Enviado'", () => {
    render(<QuoteStatusBadge status="sent" isExpired />)
    expect(screen.getByText("Vencido")).toBeInTheDocument()
    expect(screen.queryByText("Enviado")).not.toBeInTheDocument()
  })

  it("cada estado tiene rótulo y ninguno usa literales de paleta de Tailwind", () => {
    for (const status of QUOTE_STATUSES) {
      expect(QUOTE_STATUS_LABELS[status]).toBeTruthy()
      const { container, unmount } = render(<QuoteStatusBadge status={status} />)
      const classes = container.firstElementChild?.className ?? ""
      expect(classes).not.toMatch(/\b(bg|text|border)-(red|green|yellow|blue|amber|emerald|slate|gray)-\d{2,3}\b/)
      unmount()
    }
  })

  it("expone el estado efectivo para pruebas y lectores (data-status)", () => {
    const { container } = render(<QuoteStatusBadge status="draft" isExpired />)
    expect(container.firstElementChild).toHaveAttribute("data-status", "expired")
  })
})
