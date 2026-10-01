/**
 * Decisión del PO (2026-10-01): la etiqueta en español es "IA", no "AI". La
 * insignia de cada tarjeta de recomendación de `/ferias/ia` dice «Sugerencia IA».
 *
 * La insignia sólo se pinta cuando hay recomendaciones: se mockea el servicio
 * para devolver una y se espera a que la pantalla la cargue (camino real).
 */

import React from "react"
import { describe, it, expect, vi } from "vitest"
import { render, screen } from "@testing-library/react"
import "@testing-library/jest-dom"
import type { FairRecommendation } from "@/lib/services/fairAdvisorService"

const RECOMMENDATIONS: FairRecommendation[] = [
  { product: "Remera básica", reason: "Alta rotación en ferias", recommendedUnits: 12, suggestedPrice: 8500 },
  { product: "Short deportivo", reason: "Buen margen", recommendedUnits: 6, suggestedPrice: 12000 },
]

vi.mock("@/lib/services/fairAdvisorService", () => ({
  fairAdvisorService: {
    getLastRecommendation: vi.fn().mockResolvedValue(RECOMMENDATIONS),
    generateFairRecommendation: vi.fn(),
  },
}))
vi.mock("sonner", () => ({
  toast: { success: vi.fn(), error: vi.fn() },
}))

const { default: FeriaIAPage } = await import("@/app/(dashboard)/ferias/ia/page")

describe("FeriaIAPage — insignia de sugerencia (etiqueta «IA»)", () => {
  it("cada recomendación lleva la insignia «Sugerencia IA» y ninguna dice «Sugerencia AI»", async () => {
    render(<FeriaIAPage />)

    expect(await screen.findAllByText("Sugerencia IA")).toHaveLength(RECOMMENDATIONS.length)
    expect(screen.queryByText("Sugerencia AI")).toBeNull()
  })
})
