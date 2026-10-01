/**
 * sidebar-menu-grupos — decisión del PO (2026-09-30): la etiqueta en español es
 * "IA", no "AI". El comparativo de planes de `/configuracion` (pestaña Plan)
 * nombra la función igual que la entrada del menú lateral: "Consejos IA".
 *
 * La fila aparece una vez en la tarjeta Gratis y otra en la tarjeta Pro. Las
 * demás pestañas se mockean a un stub: este test es sólo sobre la etiqueta.
 */

import React from "react"
import { describe, it, expect, vi } from "vitest"
import { render, screen } from "@testing-library/react"
import "@testing-library/jest-dom"

vi.mock("next/navigation", () => ({
  useSearchParams: () => new URLSearchParams("tab=plan"),
}))
vi.mock("@/contexts/auth-context", () => ({
  useAuth: () => ({ user: { name: "Ana", email: "ana@test.local", aiAdviceUsed: 0 }, effectivePlan: "gratis" }),
}))
vi.mock("@/hooks/data/use-products", () => ({ useProducts: () => ({ products: [] }) }))
vi.mock("@/hooks/data/use-clients", () => ({ useClients: () => ({ clients: [] }) }))
vi.mock("@/hooks/auth/use-plan-limits", () => ({ usePlanLimits: () => ({ limits: null }) }))

vi.mock("@/components/settings/ProfileForm", () => ({ ProfileForm: () => <div /> }))
vi.mock("@/components/settings/AccountForm", () => ({ AccountForm: () => <div /> }))
vi.mock("@/components/settings/SystemForm", () => ({ SystemForm: () => <div /> }))
vi.mock("@/components/settings/TeamSection", () => ({ TeamSection: () => <div /> }))
vi.mock("@/components/settings/FiscalSettings", () => ({ FiscalSettings: () => <div /> }))
vi.mock("@/components/cost-centers/CostCenterManager", () => ({ CostCenterManager: () => <div /> }))
vi.mock("@/components/settings/CollectionSettingsForm", () => ({ CollectionSettingsForm: () => <div /> }))
vi.mock("@/components/payment-methods/PaymentMethodManager", () => ({ PaymentMethodManager: () => <div /> }))
vi.mock("@/components/product-categories/ProductCategoryManager", () => ({ ProductCategoryManager: () => <div /> }))
vi.mock("@/components/settings/ScaleSettings", () => ({ ScaleSettings: () => <div /> }))

const { default: ConfiguracionPage } = await import("@/app/(dashboard)/configuracion/page")

describe("ConfiguracionPage — comparativo de planes (etiqueta «IA»)", () => {
  it("la fila de consejos se llama «Consejos IA» en las dos tarjetas (Gratis y Pro)", () => {
    render(<ConfiguracionPage />)
    expect(screen.getAllByText("Consejos IA")).toHaveLength(2)
  })
})
