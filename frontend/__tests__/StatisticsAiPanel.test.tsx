/**
 * estadisticas-ventas E3 (grupo 10, task 10.5) — StatisticsAiPanel: botón
 * "Analizar con IA" de /estadisticas con su cuota, estado de carga, el
 * panel del último insight y las recomendaciones del análisis recién hecho.
 *
 * - La cuota se lee con useAiUsage(): con 0 consultas restantes el botón se
 *   deshabilita y el motivo es visible (nunca un botón muerto sin explicación).
 * - Click → mutación con el período y la sucursal de la pantalla.
 * - Resultado ok → recomendaciones listadas + toast de éxito; cuota agotada
 *   y fallback → aviso, sin recomendaciones.
 * - El último insight persistido se muestra con su fecha.
 *
 * Run: pnpm vitest run __tests__/StatisticsAiPanel.test.tsx
 */

import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent, waitFor } from "@testing-library/react"
import "@testing-library/jest-dom"

const useAiUsageMock = vi.fn()
vi.mock("@/hooks/auth/use-ai-usage", () => ({ useAiUsage: () => useAiUsageMock() }))

const mutateAsyncMock = vi.fn()
const useAnalyzeMock = vi.fn()
const useLastInsightMock = vi.fn()
vi.mock("@/hooks/data/use-statistics-ai", () => ({
  useAnalyzeStatistics: () => useAnalyzeMock(),
  useLastStatisticsInsight: () => useLastInsightMock(),
}))

const toastMock = vi.hoisted(() => ({ success: vi.fn(), warning: vi.fn(), error: vi.fn() }))
vi.mock("sonner", () => ({ toast: toastMock }))

import { StatisticsAiPanel } from "@/components/statistics/StatisticsAiPanel"

const PROPS = { start: "2026-08-01", end: "2026-08-31", branchId: "b-9" as string | null }

describe("StatisticsAiPanel", () => {
  beforeEach(() => {
    useAiUsageMock.mockReset()
    useAnalyzeMock.mockReset()
    useLastInsightMock.mockReset()
    mutateAsyncMock.mockReset()
    toastMock.success.mockReset(); toastMock.warning.mockReset(); toastMock.error.mockReset()
    useAiUsageMock.mockReturnValue({ queriesUsed: 2, queriesRemaining: 3, isLoading: false })
    useAnalyzeMock.mockReturnValue({ mutateAsync: mutateAsyncMock, isPending: false })
    useLastInsightMock.mockReturnValue({ data: { id: "i-1", message: "Los sábados concentran el 40% de la facturación.", createdAt: "2026-09-03T12:00:00Z" }, isLoading: false })
  })

  it("muestra el último análisis persistido con su fecha y la cuota restante", () => {
    render(<StatisticsAiPanel {...PROPS} />)
    expect(screen.getByText("Los sábados concentran el 40% de la facturación.")).toBeInTheDocument()
    expect(screen.getByText(/último análisis/i)).toBeInTheDocument()
    expect(screen.getByText(/3 consultas? IA restantes?/i)).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /analizar con ia/i })).toBeEnabled()
  })

  it("sin cuota el botón se deshabilita y el motivo es visible", () => {
    useAiUsageMock.mockReturnValue({ queriesUsed: 5, queriesRemaining: 0, isLoading: false })
    render(<StatisticsAiPanel {...PROPS} />)
    expect(screen.getByRole("button", { name: /analizar con ia/i })).toBeDisabled()
    expect(screen.getByText(/límite de consultas ia/i)).toBeInTheDocument()
  })

  it("click → analiza con el período y la sucursal de la pantalla; al éxito lista las recomendaciones", async () => {
    mutateAsyncMock.mockResolvedValue({ status: "ok", insight: "Nuevo insight", recommendations: ["Reponé Remera M", "Promocioná los martes", "Revisá el canal Instagram"] })
    render(<StatisticsAiPanel {...PROPS} />)
    fireEvent.click(screen.getByRole("button", { name: /analizar con ia/i }))
    expect(mutateAsyncMock).toHaveBeenCalledWith({ start: "2026-08-01", end: "2026-08-31", branchId: "b-9" })
    await waitFor(() => expect(screen.getByText("Reponé Remera M")).toBeInTheDocument())
    expect(screen.getByRole("list", { name: /recomendaciones/i }).children).toHaveLength(3)
    expect(toastMock.success).toHaveBeenCalled()
  })

  it("cuota agotada en el servidor → aviso, sin recomendaciones", async () => {
    mutateAsyncMock.mockResolvedValue({ status: "quota_exceeded" })
    render(<StatisticsAiPanel {...PROPS} />)
    fireEvent.click(screen.getByRole("button", { name: /analizar con ia/i }))
    await waitFor(() => expect(toastMock.warning).toHaveBeenCalled())
    expect(screen.queryByRole("list", { name: /recomendaciones/i })).not.toBeInTheDocument()
  })

  it("fallback (el modelo no respondió) → aviso con el mensaje del servidor, sin recomendaciones", async () => {
    mutateAsyncMock.mockResolvedValue({ status: "fallback", message: "El análisis tardó demasiado. Intentá de nuevo." })
    render(<StatisticsAiPanel {...PROPS} />)
    fireEvent.click(screen.getByRole("button", { name: /analizar con ia/i }))
    await waitFor(() => expect(toastMock.warning).toHaveBeenCalledWith(expect.stringMatching(/tardó demasiado/)))
    expect(screen.queryByRole("list", { name: /recomendaciones/i })).not.toBeInTheDocument()
  })

  it("error del servidor → toast de error", async () => {
    mutateAsyncMock.mockResolvedValue({ status: "error", message: "Sin ventas en el período seleccionado" })
    render(<StatisticsAiPanel {...PROPS} />)
    fireEvent.click(screen.getByRole("button", { name: /analizar con ia/i }))
    await waitFor(() => expect(toastMock.error).toHaveBeenCalledWith("Sin ventas en el período seleccionado"))
  })

  it("mientras analiza el botón queda deshabilitado y lo dice", () => {
    useAnalyzeMock.mockReturnValue({ mutateAsync: mutateAsyncMock, isPending: true })
    render(<StatisticsAiPanel {...PROPS} />)
    const btn = screen.getByRole("button", { name: /analizando/i })
    expect(btn).toBeDisabled()
  })

  it("sin insight previo muestra la invitación, no un panel vacío", () => {
    useLastInsightMock.mockReturnValue({ data: null, isLoading: false })
    render(<StatisticsAiPanel {...PROPS} />)
    expect(screen.getByText(/todavía no hay un análisis/i)).toBeInTheDocument()
  })
})
