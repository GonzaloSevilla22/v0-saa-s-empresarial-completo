/**
 * documentos-marca-empresa (task 11.4 RED→GREEN) — pestaña «Documentos» en `/configuracion`
 * (D10): TAB_VALUES gana "documentos" (después de «AFIP», porque el bloque fiscal de la
 * pestaña enlaza ahí), el trigger y el contenido existen, y `?tab=documentos` la abre
 * directamente (mismo patrón que `?tab=balanza` y `?tab=cobranzas`).
 *
 * Las demás pestañas se mockean a un stub: este test es sólo sobre el ENRUTADO de pestañas.
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
vi.mock("@/components/settings/DocumentBrandingSettings", () => ({
  DocumentBrandingSettings: () => <div data-testid="stub-documentos" />,
}))
vi.mock("@/components/cost-centers/CostCenterManager", () => ({
  CostCenterManager: () => <div data-testid="stub-centros-costo" />,
}))
vi.mock("@/components/settings/CollectionSettingsForm", () => ({
  CollectionSettingsForm: () => <div data-testid="stub-cobranzas" />,
}))
vi.mock("@/components/quotes/QuoteSettingsCard", () => ({
  QuoteSettingsCard: () => <div data-testid="stub-validez-presupuestos" />,
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

describe("ConfiguracionPage — pestaña Documentos (documentos-marca-empresa D10)", () => {
  it("muestra el trigger «Documentos» en la lista de pestañas", () => {
    searchParamsFixture = new URLSearchParams()
    render(<ConfiguracionPage />)
    expect(screen.getByRole("tab", { name: /documentos/i })).toBeInTheDocument()
  })

  it("la pestaña va inmediatamente después de «AFIP»", () => {
    searchParamsFixture = new URLSearchParams()
    render(<ConfiguracionPage />)
    const names = screen.getAllByRole("tab").map((tab) => tab.textContent)
    expect(names.indexOf("Documentos")).toBe(names.indexOf("AFIP") + 1)
  })

  it("son 12 pestañas: la nueva no pisa a ninguna de las existentes", () => {
    searchParamsFixture = new URLSearchParams()
    render(<ConfiguracionPage />)
    expect(screen.getAllByRole("tab").map((tab) => tab.textContent)).toEqual([
      "Perfil", "Cuenta", "AFIP", "Documentos", "Sistema", "Equipo",
      "Centros de costo", "Formas de pago", "Categorías", "Cobranzas", "Balanza", "Plan",
    ])
  })

  it("?tab=documentos abre la pestaña Documentos directamente, con su título", () => {
    searchParamsFixture = new URLSearchParams("tab=documentos")
    render(<ConfiguracionPage />)
    expect(screen.getByTestId("stub-documentos")).toBeInTheDocument()
    expect(screen.getByRole("heading", { name: /documentos/i })).toBeInTheDocument()
    expect(screen.queryByTestId("stub-perfil")).toBeNull()
  })

  it("sin ?tab, el default sigue siendo Perfil", () => {
    searchParamsFixture = new URLSearchParams()
    render(<ConfiguracionPage />)
    expect(screen.getByTestId("stub-perfil")).toBeInTheDocument()
    expect(screen.queryByTestId("stub-documentos")).toBeNull()
  })

  it("el enlace del bloque fiscal (?tab=fiscal) sigue abriendo AFIP", () => {
    searchParamsFixture = new URLSearchParams("tab=fiscal")
    render(<ConfiguracionPage />)
    expect(screen.getByTestId("stub-fiscal")).toBeInTheDocument()
  })
})
