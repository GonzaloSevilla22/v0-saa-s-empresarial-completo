/**
 * multiusuario-operativo TANDA B (10.3) — los listados de /ventas y /compras ofrecen
 * "Editar" y "Eliminar" sólo sobre las operaciones que el usuario puede modificar
 * (`canModifyOperation`, que las páginas arman con la capacidad del dominio y la regla de autor):
 *
 *   - sin la prop, el comportamiento no cambia (default: todas);
 *   - con la prop, una operación que no se puede modificar NO muestra ni el lápiz ni "Eliminar"
 *     (no es un botón deshabilitado: no se ofrece), y las demás filas siguen igual;
 *   - el resto de la fila (producto, importe, el detalle) se sigue viendo: la lectura no cambia.
 */
import { describe, it, expect, vi } from "vitest"
import { render, screen } from "@testing-library/react"
import "@testing-library/jest-dom"
import { SaleOperationsList } from "@/components/ventas/sale-operations-list"
import { PurchaseOperationsList } from "@/components/compras/purchase-operations-list"
import type { Purchase, Sale } from "@/lib/types"
import type { PaginationMeta } from "@/lib/pagination-utils"

vi.mock("@/hooks/data/use-fiscal-profile", () => ({ useFiscalProfile: () => ({ profile: null }) }))
vi.mock("@/hooks/data/use-points-of-sale", () => ({ usePointsOfSale: () => ({ pointsOfSale: [] }) }))
vi.mock("@/hooks/data/use-promote-to-order", () => ({ usePromoteToOrder: () => ({ mutateAsync: vi.fn() }) }))
vi.mock("@/components/fiscal/EmitInvoiceButton", () => ({ EmitInvoiceButton: () => null }))
vi.mock("@/components/fiscal/FiscalDocumentBadge", () => ({ FiscalDocumentBadge: () => null }))
vi.mock("@/components/payment-methods/PaymentMethodSelect", () => ({ PaymentMethodSelect: () => null }))
vi.mock("@/components/cost-centers/CostCenterSelect", () => ({ CostCenterSelect: () => null }))
vi.mock("@/components/ventas/sale-receipt-button", () => ({ SaleReceiptButton: () => null }))

const meta: PaginationMeta = { page: 0, pageSize: 25, totalCount: 2, pageCount: 1, from: 1, to: 2 }

function sale(id: string, op: string, name: string, createdBy: string): Sale {
  return {
    id, date: "2026-10-16", productId: `p-${id}`, productName: name, clientId: "c1", clientName: "Cliente",
    quantity: 1, unitPrice: 100, total: 100, currency: "ARS", operationId: op, createdBy,
  }
}

function purchase(id: string, op: string, name: string, createdBy: string): Purchase {
  return {
    id, date: "2026-10-16", productId: `p-${id}`, productName: name,
    quantity: 1, unitCost: 50, total: 50, operationId: op, createdBy,
  }
}

function saleProps(sales: Sale[], extra: Record<string, unknown> = {}) {
  return {
    sales, meta, loading: false, error: null,
    dateFrom: "", setDateFrom: vi.fn(), dateTo: "", setDateTo: vi.fn(),
    paymentMethodId: null, setPaymentMethodId: vi.fn(), clearFilters: vi.fn(),
    onPageChange: vi.fn(), onPageSizeChange: vi.fn(),
    clients: [], onDeleteOperation: vi.fn(), onEditOperation: vi.fn(), onRefetch: vi.fn(),
    ...extra,
  }
}

function purchaseProps(purchases: Purchase[], extra: Record<string, unknown> = {}) {
  return {
    purchases, meta, loading: false, error: null,
    dateFrom: "", setDateFrom: vi.fn(), dateTo: "", setDateTo: vi.fn(),
    costCenterId: null, setCostCenterId: vi.fn(),
    paymentMethodId: null, setPaymentMethodId: vi.fn(), clearFilters: vi.fn(),
    onPageChange: vi.fn(), onPageSizeChange: vi.fn(),
    onDeleteOperation: vi.fn(), onEditOperation: vi.fn(), onRefetch: vi.fn(),
    ...extra,
  }
}

const pencils = () =>
  screen.queryAllByRole("button").filter((b) => b.tagName === "BUTTON" && b.querySelector("svg.lucide-pencil"))

describe("SaleOperationsList — canModifyOperation", () => {
  const mine = sale("s1", "op1", "Producto Mío", "me")
  const theirs = sale("s2", "op2", "Producto Ajeno", "other")

  it("sin la prop, todas las operaciones ofrecen Editar y Eliminar (no cambia nada)", () => {
    render(<SaleOperationsList {...saleProps([mine, theirs])} />)
    expect(pencils().length).toBe(4) // móvil + escritorio, por 2 operaciones
    expect(screen.getAllByRole("button", { name: "Eliminar esta venta" }).length).toBe(4)
  })

  it("una operación que no se puede modificar no ofrece ni el lápiz ni Eliminar; las otras sí", () => {
    render(
      <SaleOperationsList
        {...saleProps([mine, theirs], { canModifyOperation: (op: { items: Sale[] }) => op.items[0].createdBy === "me" })}
      />,
    )
    expect(pencils().length).toBe(2) // sólo la mía (móvil + escritorio)
    expect(screen.getAllByRole("button", { name: "Eliminar esta venta" }).length).toBe(2)
    // la lectura no cambia: las dos filas se ven
    expect(screen.getAllByText(/Producto Mío/).length).toBeGreaterThan(0)
    expect(screen.getAllByText(/Producto Ajeno/).length).toBeGreaterThan(0)
  })

  it("si no se puede modificar ninguna, no hay lápices ni Eliminar", () => {
    render(<SaleOperationsList {...saleProps([mine, theirs], { canModifyOperation: () => false })} />)
    expect(pencils()).toHaveLength(0)
    expect(screen.queryAllByRole("button", { name: /^Eliminar / })).toHaveLength(0)
  })

  it("el botón «Nueva venta» sólo aparece si la página pasa onAdd", () => {
    const { rerender } = render(<SaleOperationsList {...saleProps([mine])} />)
    expect(screen.queryByRole("button", { name: /nueva venta/i })).not.toBeInTheDocument()
    rerender(<SaleOperationsList {...saleProps([mine], { onAdd: vi.fn() })} />)
    expect(screen.getAllByRole("button", { name: /nueva venta/i }).length).toBeGreaterThan(0)
  })
})

describe("PurchaseOperationsList — canModifyOperation", () => {
  const mine = purchase("u1", "pop1", "Insumo Mío", "me")
  const theirs = purchase("u2", "pop2", "Insumo Ajeno", "other")

  it("sin la prop, todas las operaciones ofrecen Editar y Eliminar (no cambia nada)", () => {
    render(<PurchaseOperationsList {...purchaseProps([mine, theirs])} />)
    expect(pencils().length).toBe(4)
    expect(screen.getAllByRole("button", { name: "Eliminar esta compra" }).length).toBe(4)
  })

  it("una operación que no se puede modificar no ofrece ni el lápiz ni Eliminar; las otras sí", () => {
    render(
      <PurchaseOperationsList
        {...purchaseProps([mine, theirs], { canModifyOperation: (op: { items: Purchase[] }) => op.items[0].createdBy === "me" })}
      />,
    )
    expect(pencils().length).toBe(2)
    expect(screen.getAllByRole("button", { name: "Eliminar esta compra" }).length).toBe(2)
    expect(screen.getAllByText(/Insumo Mío/).length).toBeGreaterThan(0)
    expect(screen.getAllByText(/Insumo Ajeno/).length).toBeGreaterThan(0)
  })

  it("si no se puede modificar ninguna, no hay lápices ni Eliminar", () => {
    render(<PurchaseOperationsList {...purchaseProps([mine, theirs], { canModifyOperation: () => false })} />)
    expect(pencils()).toHaveLength(0)
    expect(screen.queryAllByRole("button", { name: /^Eliminar / })).toHaveLength(0)
  })
})
