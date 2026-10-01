/**
 * sidebar-menu-grupos — decisión del PO (2026-09-30): la etiqueta en español es
 * "IA", no "AI". La pantalla de `/insights` debe titularse igual que su entrada
 * del menú lateral ("Consejos IA") y que su nombre en el breadcrumb.
 *
 * Sólo se prueba el título: las dependencias de datos se reemplazan por dobles
 * mínimos para que el test no dependa de red ni de la sesión.
 */

import React from "react"
import { describe, it, expect, vi } from "vitest"
import { render, screen } from "@testing-library/react"
import "@testing-library/jest-dom"

vi.mock("@/hooks/data/use-insights", () => ({
  useInsights: () => ({ insights: [], refreshInsights: vi.fn() }),
}))
vi.mock("@/contexts/auth-context", () => ({
  useAuth: () => ({ user: { aiQueriesUsed: 0 } }),
}))
vi.mock("@/hooks/auth/use-plan-limits", () => ({
  usePlanLimits: () => ({ limits: { maxAiQueriesPerMonth: 20 } }),
}))
vi.mock("@/lib/services/aiInsightService", () => ({
  aiInsightService: { generateInsights: vi.fn() },
}))
vi.mock("sonner", () => ({
  toast: { warning: vi.fn(), success: vi.fn(), error: vi.fn() },
}))

const { default: InsightsPage } = await import("@/app/(dashboard)/insights/page")

describe("InsightsPage — título (etiqueta «IA»)", () => {
  it("el h1 dice «Consejos IA»", () => {
    render(<InsightsPage />)
    expect(screen.getByRole("heading", { level: 1, name: "Consejos IA" })).toBeInTheDocument()
  })
})
