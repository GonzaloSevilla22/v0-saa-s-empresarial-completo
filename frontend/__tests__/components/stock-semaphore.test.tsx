/**
 * Render tests for StockSemaphore — proves the visible label matches the
 * canonical stock status, including the neutral "Sin mínimo" state for products
 * with no threshold configured (the bug this change fixes).
 */

import { describe, it, expect } from "vitest"
import { render, screen } from "@testing-library/react"
import { StockSemaphore } from "@/components/stock/stock-semaphore"

describe("StockSemaphore", () => {
  it("shows a neutral 'Sin mínimo' state when no minimum is configured — never 'Crítico'", () => {
    render(<StockSemaphore stock={0} minStock={0} />)
    expect(screen.getByText("Sin mínimo")).toBeInTheDocument()
    expect(screen.queryByText("Crítico")).not.toBeInTheDocument()
  })

  it("shows 'Crítico' at or below the configured minimum", () => {
    render(<StockSemaphore stock={0} minStock={5} />)
    expect(screen.getByText("Crítico")).toBeInTheDocument()
  })

  it("shows 'Bajo' just above the minimum", () => {
    render(<StockSemaphore stock={6} minStock={5} />)
    expect(screen.getByText("Bajo")).toBeInTheDocument()
  })

  it("shows 'OK' comfortably above the minimum", () => {
    render(<StockSemaphore stock={20} minStock={5} />)
    expect(screen.getByText("OK")).toBeInTheDocument()
  })
})
