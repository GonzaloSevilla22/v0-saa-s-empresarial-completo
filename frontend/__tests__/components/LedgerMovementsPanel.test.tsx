/**
 * ledger-movement-history — LedgerMovementsPanel (task 7.2, 7.8).
 *
 * Patrón calcado del molde de Stock (componentes/stock/stock-movements-panel.tsx,
 * sin test propio previo — este archivo es el primero para el patrón de
 * panel de historial en general). Corridos con DOS descriptores (cash y
 * bank, per la regla del brief) para probar que el componente es
 * verdaderamente genérico y no tiene ningún `if (book === 'cash')` oculto.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import { render, screen, fireEvent, waitFor, within } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import React from "react"
import { Coins, HelpCircle } from "lucide-react"

import { LedgerMovementsPanel } from "@/components/ledger/LedgerMovementsPanel"
import type { LedgerBookConfig, LedgerRowBase } from "@/lib/ledger/types"

interface FakeRow extends LedgerRowBase {
  extra: string
}

function makeRow(overrides: Partial<FakeRow> = {}): FakeRow {
  return {
    id: "row-1",
    amount: 100,
    movementType: "income",
    description: "motivo de prueba",
    balanceAfter: 1000,
    createdAt: "2026-08-22T10:00:00Z",
    extra: "sesión abierta",
    ...overrides,
  }
}

function makeConfig(fetchPage: ReturnType<typeof vi.fn>): LedgerBookConfig<FakeRow> {
  return {
    book: "cash",
    meta: {
      income: { label: "Ingreso", icon: Coins, tone: "success", family: "income" },
    },
    families: [
      { key: "all", label: "Todos", types: [] },
      { key: "income", label: "Ingresos", types: ["income"] },
    ],
    extraColumn: { header: "Extra", render: (row) => row.extra },
    fetchPage,
    csvName: "test_movements",
    csvHeader: ["Fecha", "Motivo"],
    csvRow: (row) => [row.createdAt, row.description ?? ""],
  }
}

async function openPanel() {
  const user = userEvent.setup({ delay: null })
  await user.click(screen.getByText("Historial de movimientos"))
}

describe.each([
  ["cash", "book=cash"],
  ["bank", "book=bank"],
])("LedgerMovementsPanel — descriptor %s", (book) => {
  let fetchPage: ReturnType<typeof vi.fn>

  beforeEach(() => {
    vi.useFakeTimers({ shouldAdvanceTime: true })
    fetchPage = vi.fn().mockResolvedValue({
      items: [makeRow()],
      total: 1,
      page: 0,
      pages: 1,
    })
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it("no hace fetch mientras el panel está cerrado", () => {
    const config = { ...makeConfig(fetchPage), book: book as "cash" | "bank" }
    render(<LedgerMovementsPanel config={config} scopeKey="scope-1" />)
    expect(fetchPage).not.toHaveBeenCalled()
  })

  it("renderiza filas con badge por tipo al abrir el panel", async () => {
    const config = { ...makeConfig(fetchPage), book: book as "cash" | "bank" }
    render(<LedgerMovementsPanel config={config} scopeKey="scope-1" />)

    await openPanel()
    await waitFor(() => expect(fetchPage).toHaveBeenCalledTimes(1))
    await waitFor(() => expect(screen.getByText("Ingreso")).toBeInTheDocument())
    expect(screen.getByText("motivo de prueba")).toBeInTheDocument()
    expect(screen.getByText("sesión abierta")).toBeInTheDocument()
  })

  it("un tipo desconocido no rompe la fila — cae al fallback neutro (task 7.8)", async () => {
    fetchPage.mockResolvedValue({
      items: [makeRow({ movementType: "un_tipo_que_no_existe" })],
      total: 1,
      page: 0,
      pages: 1,
    })
    const config = { ...makeConfig(fetchPage), book: book as "cash" | "bank" }
    render(<LedgerMovementsPanel config={config} scopeKey="scope-1" />)

    await openPanel()
    await waitFor(() => expect(screen.getByText("Otro")).toBeInTheDocument())
  })

  it("filtro de familia dispara refetch server-side con los types correctos", async () => {
    const config = { ...makeConfig(fetchPage), book: book as "cash" | "bank" }
    render(<LedgerMovementsPanel config={config} scopeKey="scope-1" />)
    await openPanel()
    await waitFor(() => expect(fetchPage).toHaveBeenCalledTimes(1))

    const user = userEvent.setup({ delay: null })
    await user.click(screen.getByText("Ingresos"))

    await waitFor(() => expect(fetchPage).toHaveBeenCalledTimes(2))
    expect(fetchPage).toHaveBeenLastCalledWith(
      expect.objectContaining({ types: ["income"], page: 0 })
    )
  })

  it("el buscador va al SERVIDOR (q en fetchPage), no filtra solo lo cargado", async () => {
    const config = { ...makeConfig(fetchPage), book: book as "cash" | "bank" }
    render(<LedgerMovementsPanel config={config} scopeKey="scope-1" />)
    await openPanel()
    await waitFor(() => expect(fetchPage).toHaveBeenCalledTimes(1))

    const input = screen.getByPlaceholderText("Buscar por motivo…")
    fireEvent.change(input, { target: { value: "sobrante" } })

    // Debounce — no dispara inmediatamente
    expect(fetchPage).toHaveBeenCalledTimes(1)

    await vi.advanceTimersByTimeAsync(400)

    await waitFor(() => expect(fetchPage).toHaveBeenCalledTimes(2))
    expect(fetchPage).toHaveBeenLastCalledWith(expect.objectContaining({ q: "sobrante" }))
  })

  it('"Ver más" pide la página siguiente', async () => {
    fetchPage.mockResolvedValue({ items: [makeRow()], total: 40, page: 0, pages: 2 })
    const config = { ...makeConfig(fetchPage), book: book as "cash" | "bank" }
    render(<LedgerMovementsPanel config={config} scopeKey="scope-1" />)
    await openPanel()
    await waitFor(() => expect(fetchPage).toHaveBeenCalledTimes(1))

    const user = userEvent.setup({ delay: null })
    await user.click(screen.getByText("Ver más movimientos"))

    await waitFor(() => expect(fetchPage).toHaveBeenCalledTimes(2))
    expect(fetchPage).toHaveBeenLastCalledWith(expect.objectContaining({ page: 1 }))
  })

  it("filtro sin resultados muestra el estado vacío correcto", async () => {
    fetchPage.mockResolvedValue({ items: [], total: 0, page: 0, pages: 0 })
    const config = { ...makeConfig(fetchPage), book: book as "cash" | "bank" }
    render(<LedgerMovementsPanel config={config} scopeKey="scope-1" />)
    await openPanel()

    await waitFor(() =>
      expect(screen.getByText("Aún no hay movimientos registrados.")).toBeInTheDocument()
    )
  })

  it("cambiar de scopeKey (p. ej. otra caja/cuenta) re-arma el fetch desde la página 0", async () => {
    const config = { ...makeConfig(fetchPage), book: book as "cash" | "bank" }
    const { rerender } = render(<LedgerMovementsPanel config={config} scopeKey="scope-1" />)
    await openPanel()
    await waitFor(() => expect(fetchPage).toHaveBeenCalledTimes(1))

    rerender(<LedgerMovementsPanel config={config} scopeKey="scope-2" />)
    await waitFor(() => expect(fetchPage).toHaveBeenCalledTimes(2))
    expect(fetchPage).toHaveBeenLastCalledWith(expect.objectContaining({ page: 0 }))
  })
})
