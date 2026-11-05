/**
 * v31-ia-ratelimit-budget (D8, task 4.7): `OcrQuotaNotice` muestra el saldo de lecturas de
 * factura del mes y, sin saldo, el límite del plan, la fecha de renovación y «Ver planes».
 */
import React from "react"
import { describe, it, expect } from "vitest"
import { render, screen } from "@testing-library/react"
import "@testing-library/jest-dom"

import { OcrQuotaNotice } from "@/components/invoice/OcrQuotaNotice"

const NOW = new Date("2026-11-15T12:00:00.000Z")

describe("OcrQuotaNotice", () => {
  it("con saldo 18 muestra «Te quedan 18 lecturas de factura este mes»", () => {
    render(<OcrQuotaNotice remaining={18} limit={30} now={NOW} />)
    expect(screen.getByText("Te quedan 18 lecturas de factura este mes")).toBeInTheDocument()
    expect(screen.queryByRole("link", { name: /ver planes/i })).not.toBeInTheDocument()
  })

  it("con saldo 1 va en singular", () => {
    render(<OcrQuotaNotice remaining={1} limit={5} now={NOW} />)
    expect(screen.getByText("Te queda 1 lectura de factura este mes")).toBeInTheDocument()
  })

  it("en 0 muestra el límite del plan, la fecha de renovación y «Ver planes» -> /planes", () => {
    render(<OcrQuotaNotice remaining={0} limit={5} now={NOW} />)
    expect(screen.getByText(/Usaste las 5 lecturas de factura de tu plan este mes\. Se renuevan el 1 de diciembre\./)).toBeInTheDocument()
    expect(screen.getByRole("link", { name: /ver planes/i })).toHaveAttribute("href", "/planes")
  })

  it("la fecha de renovación sigue al mes (triangulación: 31 de diciembre -> 1 de enero)", () => {
    render(<OcrQuotaNotice remaining={0} limit={30} now={new Date("2026-12-31T23:00:00.000Z")} />)
    expect(screen.getByText(/Se renuevan el 1 de enero\./)).toBeInTheDocument()
  })
})
