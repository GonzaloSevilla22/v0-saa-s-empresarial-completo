/**
 * Tests del Resumen IA del día — manejo de errores del Edge Function ai-resumen.
 * Bug: el 429 (cuota IA del plan agotada) se mostraba como "Error al conectar",
 * confundiendo un límite del plan con una falla técnica.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import { render, screen, waitFor } from "@testing-library/react"
import { AiSummaryCard } from "@/components/dashboard/ai-summary-card"

const invokeMock = vi.fn()

vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({ functions: { invoke: invokeMock } }),
}))

const useCriticalStockMock = vi.fn()
vi.mock("@/hooks/data/use-critical-stock", () => ({
  useCriticalStock: (...args: unknown[]) => useCriticalStockMock(...args),
}))

beforeEach(() => {
  invokeMock.mockReset()
  useCriticalStockMock.mockReset()
  useCriticalStockMock.mockReturnValue({ data: 2, isLoading: false })
})

describe("AiSummaryCard — título (etiqueta «IA»)", () => {
  // Decisión del PO (2026-10-01): la etiqueta en español es "IA", no "AI".
  it("la tarjeta se titula «Resumen IA del día» y no conserva la etiqueta «AI»", async () => {
    invokeMock.mockResolvedValue({ data: { ok: true, data: "Resumen" }, error: null })

    render(<AiSummaryCard todaySales={1000} />)

    expect(screen.getByText("Resumen IA del día")).toBeInTheDocument()
    expect(screen.queryByText(/Resumen AI/)).toBeNull()
    // Deja resolver el efecto de montaje (invoke) para no filtrar estado a otros tests.
    await waitFor(() => expect(screen.getByText("Resumen")).toBeInTheDocument())
  })
})

describe("AiSummaryCard — footer «Ventas hoy» (tablero-menu-pulido P2)", () => {
  // El footer usaba `$${todaySales.toLocaleString()}`: el separador dependía del
  // idioma del navegador y un negativo salía "$-2.066". Ahora usa el mismo
  // formateador es-AR del Bloque Resumen y de la fila de tarjetas.
  afterEach(() => {
    vi.restoreAllMocks()
  })

  async function ventasHoy(todaySales: number): Promise<string> {
    invokeMock.mockResolvedValue({ data: { ok: true, data: "Resumen" }, error: null })
    render(<AiSummaryCard todaySales={todaySales} />)
    const texto = screen.getByText(/Ventas hoy/).textContent ?? ""
    await waitFor(() => expect(screen.getByText("Resumen")).toBeInTheDocument())
    return texto
  }

  it("formatea miles con punto (es-AR): 1234567 -> $1.234.567", async () => {
    expect(await ventasHoy(1234567)).toBe("Ventas hoy: $1.234.567")
  })

  it("cero se muestra $0 (no —) y un importe chico queda sin separador", async () => {
    expect(await ventasHoy(0)).toBe("Ventas hoy: $0")
  })

  it("un importe negativo lleva el signo antes del $: -2066 -> -$2.066", async () => {
    expect(await ventasHoy(-2066)).toBe("Ventas hoy: -$2.066")
  })

  it("no depende del idioma del navegador: no pasa por toLocaleString", async () => {
    vi.spyOn(Number.prototype, "toLocaleString").mockImplementation(() => "CENTINELA")
    expect(await ventasHoy(12222)).toBe("Ventas hoy: $12.222")
  })
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

  it("usa el KPI canónico de stock y respeta la sucursal activa", async () => {
    invokeMock.mockResolvedValue({ data: { ok: true, data: "Resumen" }, error: null })
    useCriticalStockMock.mockReturnValue({ data: 1, isLoading: false })

    render(<AiSummaryCard todaySales={1000} branchId="branch-9" />)

    expect(useCriticalStockMock).toHaveBeenCalledWith("branch-9")
    expect(screen.getByText("1 productos")).toBeInTheDocument()
  })
})
