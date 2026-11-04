/**
 * multiusuario-operativo TANDA B (10.3) — /ventas y /compras ofrecen "Nueva", "Editar" y
 * "Eliminar" sólo a quien el ROL habilita, y sobre lo ajeno sólo a dueño y administrador.
 *
 * Contrato (spec operation-member-authorization):
 *   - "Nueva venta" / "Nueva compra" se deciden con `CAN_SELL` / `CAN_PURCHASE` sobre el CONJUNTO de
 *     roles activos (`useOrgRole().roles`), además de `isWriter`: un depósito o un contador son
 *     escritores, pero ni venden ni compran por el formulario;
 *   - "Editar" y "Eliminar" de cada operación exigen la misma capacidad y, salvo dueño y
 *     administrador, que la operación sea del propio usuario (`createdBy`);
 *   - mientras el conjunto de roles no resolvió la decisión es optimista (la barrera real es la base).
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen } from "@testing-library/react"
import "@testing-library/jest-dom"
import type { Purchase, Sale } from "@/lib/types"

type OrgRoleState = {
  role: string | null
  roles: string[]
  rolesResolved: boolean
  isWriter: boolean
  isLoading: boolean
}

const org = vi.hoisted(() => ({
  value: { role: "member", roles: ["seller"], rolesResolved: true, isWriter: true, isLoading: false } as OrgRoleState,
}))
const data = vi.hoisted(() => ({ sales: [] as unknown[], purchases: [] as unknown[] }))

vi.mock("@/hooks/useOrgRole", () => ({ useOrgRole: () => org.value }))
vi.mock("@/contexts/auth-context", () => ({ useAuth: () => ({ isAdmin: false, user: { id: "me", accountId: "acc" } }) }))
vi.mock("@/hooks/data/use-clients", () => ({ useClients: () => ({ clients: [] }) }))
vi.mock("@/hooks/use-units-of-measure", () => ({ useUnitsOfMeasure: () => ({ units: [], unitsById: new Map() }) }))

const metaStub = { page: 0, pageSize: 25, totalCount: 2, pageCount: 1, from: 1, to: 2 }
vi.mock("@/hooks/data/use-sales", () => ({
  useSales: () => ({
    sales: data.sales, meta: metaStub, isLoading: false, error: null,
    dateFrom: "", setDateFrom: vi.fn(), dateTo: "", setDateTo: vi.fn(),
    paymentMethodId: null, setPaymentMethodId: vi.fn(), clearFilters: vi.fn(),
    setPage: vi.fn(), setPageSize: vi.fn(), refetch: vi.fn(),
    deleteSale: vi.fn(), deleteSalesByOperation: vi.fn(),
  }),
}))
vi.mock("@/hooks/data/use-purchases", () => ({
  usePurchases: () => ({
    purchases: data.purchases, meta: metaStub, isLoading: false, error: null,
    dateFrom: "", setDateFrom: vi.fn(), dateTo: "", setDateTo: vi.fn(),
    costCenterId: null, setCostCenterId: vi.fn(),
    paymentMethodId: null, setPaymentMethodId: vi.fn(), clearFilters: vi.fn(),
    setPage: vi.fn(), setPageSize: vi.fn(), refetch: vi.fn(),
    deletePurchase: vi.fn(), deletePurchasesByOperation: vi.fn(),
  }),
}))

vi.mock("@/components/forms/sale-form", () => ({ SaleForm: () => null }))
vi.mock("@/components/forms/purchase-form", () => ({ PurchaseForm: () => null }))
vi.mock("@/components/shared/responsive-modal", () => ({ ResponsiveModal: () => null }))
vi.mock("@/components/admin/ModuleMetricsWrapper", () => ({ ModuleMetricsWrapper: () => null }))
vi.mock("@/components/export/ExportButton", () => ({ ExportButton: () => null }))
vi.mock("@/components/invoice/InvoiceAIButton", () => ({ InvoiceAIButton: () => <button type="button">Factura IA</button> }))
vi.mock("@/hooks/data/use-fiscal-profile", () => ({ useFiscalProfile: () => ({ profile: null }) }))
vi.mock("@/hooks/data/use-points-of-sale", () => ({ usePointsOfSale: () => ({ pointsOfSale: [] }) }))
vi.mock("@/hooks/data/use-promote-to-order", () => ({ usePromoteToOrder: () => ({ mutateAsync: vi.fn() }) }))
vi.mock("@/components/fiscal/EmitInvoiceButton", () => ({ EmitInvoiceButton: () => null }))
vi.mock("@/components/fiscal/FiscalDocumentBadge", () => ({ FiscalDocumentBadge: () => null }))
vi.mock("@/components/payment-methods/PaymentMethodSelect", () => ({ PaymentMethodSelect: () => null }))
vi.mock("@/components/cost-centers/CostCenterSelect", () => ({ CostCenterSelect: () => null }))
vi.mock("@/components/ventas/sale-receipt-button", () => ({ SaleReceiptButton: () => null }))

import VentasPage from "@/app/(dashboard)/ventas/page"
import ComprasPage from "@/app/(dashboard)/compras/page"

function sale(id: string, op: string, createdBy: string): Sale {
  return {
    id, date: "2026-10-16", productId: `p-${id}`, productName: `Producto ${id}`, clientId: "c1", clientName: "Cliente",
    quantity: 1, unitPrice: 100, total: 100, currency: "ARS", operationId: op, createdBy,
  }
}
function purchase(id: string, op: string, createdBy: string): Purchase {
  return {
    id, date: "2026-10-16", productId: `p-${id}`, productName: `Insumo ${id}`,
    quantity: 1, unitCost: 50, total: 50, operationId: op, createdBy,
  }
}

function setRoles(roles: string[], opts: { resolved?: boolean; isWriter?: boolean } = {}) {
  org.value = {
    role: "member", roles, rolesResolved: opts.resolved ?? true, isWriter: opts.isWriter ?? true, isLoading: false,
  }
}

const pencils = () =>
  screen.queryAllByRole("button").filter((b) => b.tagName === "BUTTON" && b.querySelector("svg.lucide-pencil"))
const deleteButtons = (what: "venta" | "compra") => screen.queryAllByRole("button", { name: `Eliminar esta ${what}` })

beforeEach(() => {
  data.sales = [sale("mia", "op-mia", "me"), sale("ajena", "op-ajena", "other")]
  data.purchases = [purchase("mia", "pop-mia", "me"), purchase("ajena", "pop-ajena", "other")]
  setRoles(["seller"])
})

describe("/ventas — Nueva venta, Editar y Eliminar según el rol (CAN_SELL) y el autor", () => {
  it.each([["seller"], ["cashier"]])("%s: ve «Nueva venta» y modifica sólo la propia", (role) => {
    setRoles([role])
    render(<VentasPage />)
    expect(screen.getAllByRole("button", { name: /nueva venta/i }).length).toBeGreaterThan(0)
    expect(pencils()).toHaveLength(2) // la propia (móvil + escritorio); la ajena no se ofrece
    expect(deleteButtons("venta")).toHaveLength(2)
    // la lectura no cambia: ve las dos operaciones
    expect(screen.getAllByText(/Producto mia/).length).toBeGreaterThan(0)
    expect(screen.getAllByText(/Producto ajena/).length).toBeGreaterThan(0)
  })

  it.each([["owner"], ["admin"]])("%s: modifica cualquier venta", (role) => {
    setRoles([role])
    render(<VentasPage />)
    expect(screen.getAllByRole("button", { name: /nueva venta/i }).length).toBeGreaterThan(0)
    expect(pencils()).toHaveLength(4)
    expect(deleteButtons("venta")).toHaveLength(4)
  })

  it.each([
    ["stock", true],
    ["accountant", true],
    ["purchases", true],
    ["viewer", false],
  ])("%s (escritor: %s): ni «Nueva venta» ni Editar ni Eliminar", (role, isWriter) => {
    setRoles([role], { isWriter })
    render(<VentasPage />)
    expect(screen.queryByRole("button", { name: /nueva venta/i })).not.toBeInTheDocument()
    expect(pencils()).toHaveLength(0)
    expect(deleteButtons("venta")).toHaveLength(0)
    expect(screen.getAllByText(/Producto mia/).length).toBeGreaterThan(0)
  })

  it("un multirol (vendedor + compras) vende y modifica lo propio", () => {
    setRoles(["seller", "purchases"])
    render(<VentasPage />)
    expect(screen.getAllByRole("button", { name: /nueva venta/i }).length).toBeGreaterThan(0)
    expect(pencils()).toHaveLength(2)
  })

  it("con el conjunto de roles sin resolver la decisión es optimista", () => {
    setRoles(["member"], { resolved: false })
    render(<VentasPage />)
    expect(screen.getAllByRole("button", { name: /nueva venta/i }).length).toBeGreaterThan(0)
    expect(pencils()).toHaveLength(4)
  })
})

describe("/compras — Nueva compra, Editar y Eliminar según el rol (CAN_PURCHASE) y el autor", () => {
  it("compras: ve «Nueva compra» y la Factura IA, y modifica sólo la propia", () => {
    setRoles(["purchases"])
    render(<ComprasPage />)
    expect(screen.getAllByRole("button", { name: /nueva compra/i }).length).toBeGreaterThan(0)
    expect(screen.getByRole("button", { name: "Factura IA" })).toBeInTheDocument()
    expect(pencils()).toHaveLength(2)
    expect(deleteButtons("compra")).toHaveLength(2)
    expect(screen.getAllByText(/Insumo mia/).length).toBeGreaterThan(0)
    expect(screen.getAllByText(/Insumo ajena/).length).toBeGreaterThan(0)
  })

  it.each([["owner"], ["admin"]])("%s: modifica cualquier compra", (role) => {
    setRoles([role])
    render(<ComprasPage />)
    expect(screen.getAllByRole("button", { name: /nueva compra/i }).length).toBeGreaterThan(0)
    expect(pencils()).toHaveLength(4)
    expect(deleteButtons("compra")).toHaveLength(4)
  })

  it.each([
    ["seller", true],
    ["cashier", true],
    ["stock", true], // el depósito NO compra: recibe mercadería por remito (OQ-3)
    ["accountant", true],
    ["viewer", false],
  ])("%s (escritor: %s): ni «Nueva compra» ni Editar ni Eliminar", (role, isWriter) => {
    setRoles([role], { isWriter })
    render(<ComprasPage />)
    expect(screen.queryByRole("button", { name: /nueva compra/i })).not.toBeInTheDocument()
    // la Factura IA termina en un alta de compra: tampoco se ofrece
    expect(screen.queryByRole("button", { name: "Factura IA" })).not.toBeInTheDocument()
    expect(pencils()).toHaveLength(0)
    expect(deleteButtons("compra")).toHaveLength(0)
    expect(screen.getAllByText(/Insumo mia/).length).toBeGreaterThan(0)
  })

  it("con el conjunto de roles sin resolver la decisión es optimista", () => {
    setRoles(["member"], { resolved: false })
    render(<ComprasPage />)
    expect(screen.getAllByRole("button", { name: /nueva compra/i }).length).toBeGreaterThan(0)
    expect(pencils()).toHaveLength(4)
  })
})
