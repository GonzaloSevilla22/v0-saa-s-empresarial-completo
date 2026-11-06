/**
 * Tests del Resumen IA del día — manejo de errores del Edge Function ai-resumen.
 * Bug: el 429 (cuota IA del plan agotada) se mostraba como "Error al conectar",
 * confundiendo un límite del plan con una falla técnica.
 */

import React from "react"
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import { render, screen, waitFor, act } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import "@testing-library/jest-dom"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { AiSummaryCard } from "@/components/dashboard/ai-summary-card"

const invokeMock = vi.fn()

vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({ functions: { invoke: invokeMock } }),
}))

// tablero-explicable (D7): el resumen vive en una consulta por cuenta y día
// (useAiDailySummary) — la tarjeta necesita QueryClient y la cuenta activa.
vi.mock("@/contexts/auth-context", () => ({
  useAuth: () => ({ user: { id: "user-1", accountId: "account-1" } }),
}))

function renderCard(ui: React.ReactElement) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(<QueryClientProvider client={client}>{ui}</QueryClientProvider>)
}

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

    renderCard(<AiSummaryCard todaySales={1000} />)

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
    renderCard(<AiSummaryCard todaySales={todaySales} />)
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

    renderCard(<AiSummaryCard todaySales={1000} />)

    await waitFor(() => {
      expect(screen.getByText(/límite mensual de consultas de IA/i)).toBeInTheDocument()
    })
    expect(screen.getByText(/Se reinicia el 1\.º de cada mes/)).toBeInTheDocument()
  })

  it("muestra el mensaje genérico legible para fallas que no son de cuota", async () => {
    invokeMock.mockResolvedValue({
      data: null,
      error: { name: "FunctionsHttpError", context: { status: 502 } },
    })

    renderCard(<AiSummaryCard todaySales={1000} />)

    await waitFor(() => {
      expect(screen.getByText(/No pudimos generar el resumen/)).toBeInTheDocument()
    })
  })

  it("REGRESIÓN (PO 2026-11-06, «nunca muestra nada»): cuando la función devuelve la fila de insights, el texto está en `message` (columna real de la tabla), no en `content`", async () => {
    invokeMock.mockResolvedValue({
      data: { ok: true, data: { id: "i-1", type: "general", message: "Hoy vendiste $200 y gastaste $0.", priority: "media" } },
      error: null,
    })

    renderCard(<AiSummaryCard todaySales={200} />)

    await waitFor(() => {
      expect(screen.getByText("Hoy vendiste $200 y gastaste $0.")).toBeInTheDocument()
    })
    expect(screen.queryByText(/No se pudo generar/)).not.toBeInTheDocument()
  })

  it("muestra el resumen cuando la función responde bien", async () => {
    invokeMock.mockResolvedValue({
      data: { ok: true, data: "Buen día: ventas estables." },
      error: null,
    })

    renderCard(<AiSummaryCard todaySales={1000} />)

    await waitFor(() => {
      expect(screen.getByText("Buen día: ventas estables.")).toBeInTheDocument()
    })
  })

  it("usa el KPI canónico de stock y respeta la sucursal activa", async () => {
    invokeMock.mockResolvedValue({ data: { ok: true, data: "Resumen" }, error: null })
    useCriticalStockMock.mockReturnValue({ data: 1, isLoading: false })

    renderCard(<AiSummaryCard todaySales={1000} branchId="branch-9" />)

    expect(useCriticalStockMock).toHaveBeenCalledWith("branch-9")
    expect(screen.getByText("1 productos")).toBeInTheDocument()
  })
})

// ── tablero-explicable (D7, task 4.5): estados explícitos de la tarjeta ──────

describe("AiSummaryCard — estados de carga y error (tablero-explicable)", () => {
  afterEach(() => {
    vi.useRealTimers()
  })

  it("el estado inicial NO es el texto «Cargando resumen inteligente...»: es un estado de carga propio, con role=status, y «Regenerar» deshabilitado", () => {
    invokeMock.mockReturnValue(new Promise(() => {}))
    renderCard(<AiSummaryCard todaySales={1000} />)

    expect(screen.queryByText(/Cargando resumen inteligente/)).not.toBeInTheDocument()
    const status = screen.getByRole("status")
    expect(status).toHaveTextContent("Generando el resumen… suele tardar unos segundos")
    expect(screen.getByRole("button", { name: /Regenerar/ })).toBeDisabled()
  })

  it("al llegar el texto reemplaza el estado de carga y habilita «Regenerar»", async () => {
    invokeMock.mockResolvedValue({ data: { ok: true, data: { message: "Hoy vendiste $200." } }, error: null })
    renderCard(<AiSummaryCard todaySales={200} />)

    await waitFor(() => expect(screen.getByText("Hoy vendiste $200.")).toBeInTheDocument())
    expect(screen.queryByRole("status")).not.toBeInTheDocument()
    expect(screen.getByRole("button", { name: /Regenerar/ })).toBeEnabled()
  })

  it("una respuesta exitosa sin texto muestra un error legible y deja «Regenerar» habilitado", async () => {
    invokeMock.mockResolvedValue({ data: { ok: true, data: {} }, error: null })
    renderCard(<AiSummaryCard todaySales={0} />)

    await waitFor(() => expect(screen.getByText(/La IA no devolvió un resumen/)).toBeInTheDocument())
    expect(screen.getByRole("button", { name: /Regenerar/ })).toBeEnabled()
  })

  it("401: sesión vencida", async () => {
    invokeMock.mockResolvedValue({ data: null, error: { name: "FunctionsHttpError", context: { status: 401 } } })
    renderCard(<AiSummaryCard todaySales={0} />)

    await waitFor(() => expect(screen.getByText("Tu sesión venció. Volvé a ingresar.")).toBeInTheDocument())
  })

  it("con la llamada colgada, a los 30 s deja de cargar, muestra el error de tope y «Regenerar» queda habilitado", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true })
    invokeMock.mockReturnValue(new Promise(() => {}))
    renderCard(<AiSummaryCard todaySales={0} />)
    expect(screen.getByRole("status")).toBeInTheDocument()

    await act(async () => {
      await vi.advanceTimersByTimeAsync(30_000)
    })

    await waitFor(() => expect(screen.getByText("La IA tardó demasiado. Probá con Regenerar.")).toBeInTheDocument())
    expect(screen.queryByRole("status")).not.toBeInTheDocument()
    expect(screen.getByRole("button", { name: /Regenerar/ })).toBeEnabled()
  })

  it("«Regenerar» vuelve a invocar la función y muestra el texto nuevo", async () => {
    const user = userEvent.setup()
    invokeMock
      .mockResolvedValueOnce({ data: { ok: true, data: "Primero." }, error: null })
      .mockResolvedValueOnce({ data: { ok: true, data: "Segundo." }, error: null })
    renderCard(<AiSummaryCard todaySales={0} />)
    await waitFor(() => expect(screen.getByText("Primero.")).toBeInTheDocument())

    await user.click(screen.getByRole("button", { name: /Regenerar/ }))

    await waitFor(() => expect(screen.getByText("Segundo.")).toBeInTheDocument())
    expect(invokeMock).toHaveBeenCalledTimes(2)
  })

  it("mientras regenera, «Regenerar» está deshabilitado", async () => {
    const user = userEvent.setup()
    let release!: (v: unknown) => void
    invokeMock
      .mockResolvedValueOnce({ data: { ok: true, data: "Primero." }, error: null })
      .mockReturnValueOnce(new Promise((r) => { release = r }))
    renderCard(<AiSummaryCard todaySales={0} />)
    await waitFor(() => expect(screen.getByText("Primero.")).toBeInTheDocument())

    await user.click(screen.getByRole("button", { name: /Regenerar/ }))

    await waitFor(() => expect(screen.getByRole("button", { name: /Regenerar/ })).toBeDisabled())
    await act(async () => {
      release({ data: { ok: true, data: "Segundo." }, error: null })
    })
    await waitFor(() => expect(screen.getByRole("button", { name: /Regenerar/ })).toBeEnabled())
  })

  it("remontar la tarjeta en la misma sesión no vuelve a invocar la función", async () => {
    invokeMock.mockResolvedValue({ data: { ok: true, data: "Una vez." }, error: null })
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    const tree = (
      <QueryClientProvider client={client}>
        <AiSummaryCard todaySales={0} />
      </QueryClientProvider>
    )
    const first = render(tree)
    await waitFor(() => expect(screen.getByText("Una vez.")).toBeInTheDocument())
    first.unmount()

    render(tree)

    expect(screen.getByText("Una vez.")).toBeInTheDocument()
    expect(invokeMock).toHaveBeenCalledTimes(1)
  })
})
