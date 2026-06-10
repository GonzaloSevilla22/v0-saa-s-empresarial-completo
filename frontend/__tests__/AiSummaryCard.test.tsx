/**
 * Tests del Resumen AI del día — manejo de errores del Edge Function ai-resumen.
 * Bug: el 429 (cuota IA del plan agotada) se mostraba como "Error al conectar",
 * confundiendo un límite del plan con una falla técnica.
 */

import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, waitFor } from "@testing-library/react"
import { AiSummaryCard } from "@/components/dashboard/ai-summary-card"

const invokeMock = vi.fn()

vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({ functions: { invoke: invokeMock } }),
}))

vi.mock("@/hooks/data/use-products", () => ({
  useProducts: () => ({ products: [] }),
}))

beforeEach(() => {
  invokeMock.mockReset()
})

describe("AiSummaryCard — errores", () => {
  it("muestra el mensaje de límite del plan cuando la función devuelve 429 (quota_exceeded)", async () => {
    // supabase.functions.invoke resuelve con error FunctionsHttpError (context = Response)
    invokeMock.mockResolvedValue({
      data: null,
      error: { name: "FunctionsHttpError", context: { status: 429 } },
    })

    render(<AiSummaryCard todaySales={1000} />)

    await waitFor(() => {
      expect(screen.getByText(/límite mensual de consultas IA/i)).toBeInTheDocument()
    })
    expect(screen.queryByText(/Error al conectar/i)).toBeNull()
  })

  it("mantiene el mensaje de error técnico para fallas que no son de cuota", async () => {
    invokeMock.mockResolvedValue({
      data: null,
      error: { name: "FunctionsHttpError", context: { status: 502 } },
    })

    render(<AiSummaryCard todaySales={1000} />)

    await waitFor(() => {
      expect(screen.getByText(/Error al conectar con la IA/i)).toBeInTheDocument()
    })
  })

  it("muestra el resumen cuando la función responde bien", async () => {
    invokeMock.mockResolvedValue({
      data: { ok: true, data: "Buen día: ventas estables." },
      error: null,
    })

    render(<AiSummaryCard todaySales={1000} />)

    await waitFor(() => {
      expect(screen.getByText("Buen día: ventas estables.")).toBeInTheDocument()
    })
  })
})
