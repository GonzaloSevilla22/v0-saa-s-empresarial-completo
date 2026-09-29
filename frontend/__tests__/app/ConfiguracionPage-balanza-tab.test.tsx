/**
 * balanza-etiquetas-pos (task 9.2 RED→GREEN) — pestaña "Balanza" en
 * `/configuracion` (D11): TAB_VALUES gana "balanza", el trigger y el
 * contenido existen, y `?tab=balanza` la abre directamente (mismo patrón que
 * `?tab=cobranzas`, cobranzas-vencimientos D10).
 *
 * Todas las subpantallas de las demás pestañas se mockean a un stub: este
 * test es sólo sobre el ENRUTADO de pestañas, no sobre su contenido (que
 * tiene sus propios tests).
 */

import React from "react"
import { describe, it, expect, vi } from "vitest"
import { render, screen } from "@testing-library/react"
import "@testing-library/jest-dom"

let searchParamsFixture = new URLSearchParams()
vi.mock("next/navigation", () => ({
  useSearchParams: () => searchParamsFixture,
}))
vi.mock("@/contexts/auth-context", () => ({
  useAuth: () => ({ user: { name: "Ana", email: "ana@test.local", aiAdviceUsed: 0 }, effectivePlan: "gratis" }),
}))
vi.mock("@/hooks/data/use-products", () => ({ useProducts: () => ({ products: [] }) }))
vi.mock("@/hooks/data/use-clients", () => ({ useClients: () => ({ clients: [] }) }))
vi.mock("@/hooks/auth/use-plan-limits", () => ({ usePlanLimits: () => ({ limits: null }) }))

vi.mock("@/components/settings/ProfileForm", () => ({ ProfileForm: () => <div data-testid="stub-perfil" /> }))
vi.mock("@/components/settings/AccountForm", () => ({ AccountForm: () => <div data-testid="stub-cuenta" /> }))
vi.mock("@/components/settings/SystemForm", () => ({ SystemForm: () => <div data-testid="stub-sistema" /> }))
vi.mock("@/components/settings/TeamSection", () => ({ TeamSection: () => <div data-testid="stub-equipo" /> }))
vi.mock("@/components/settings/FiscalSettings", () => ({ FiscalSettings: () => <div data-testid="stub-fiscal" /> }))
vi.mock("@/components/cost-centers/CostCenterManager", () => ({
  CostCenterManager: () => <div data-testid="stub-centros-costo" />,
}))
vi.mock("@/components/settings/CollectionSettingsForm", () => ({
  CollectionSettingsForm: () => <div data-testid="stub-cobranzas" />,
}))
vi.mock("@/components/payment-methods/PaymentMethodManager", () => ({
  PaymentMethodManager: () => <div data-testid="stub-formas-pago" />,
}))
vi.mock("@/components/product-categories/ProductCategoryManager", () => ({
  ProductCategoryManager: () => <div data-testid="stub-categorias" />,
}))
vi.mock("@/components/settings/ScaleSettings", () => ({
  ScaleSettings: () => <div data-testid="stub-balanza" />,
}))

const { default: ConfiguracionPage } = await import("@/app/(dashboard)/configuracion/page")

describe("ConfiguracionPage — pestaña Balanza (balanza-etiquetas-pos D11)", () => {
  it("muestra el trigger 'Balanza' en la lista de pestañas", () => {
    render(<ConfiguracionPage />)
    expect(screen.getByRole("tab", { name: /balanza/i })).toBeInTheDocument()
  })

  it("?tab=balanza abre la pestaña Balanza directamente", () => {
    searchParamsFixture = new URLSearchParams("tab=balanza")
    render(<ConfiguracionPage />)
    expect(screen.getByTestId("stub-balanza")).toBeInTheDocument()
  })

  it("sin ?tab, el default sigue siendo Perfil (no se rompe el comportamiento existente)", () => {
    searchParamsFixture = new URLSearchParams()
    render(<ConfiguracionPage />)
    expect(screen.getByTestId("stub-perfil")).toBeInTheDocument()
  })
})
