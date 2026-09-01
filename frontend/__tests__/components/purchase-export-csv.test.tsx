/**
 * qa-integral-modulos G15 (H24) — el CSV client-side de /compras no llevaba
 * ni forma de pago ni proveedor: exactamente los dos badges con los que el
 * usuario filtra en pantalla. Quien exporta para conciliar en una planilla
 * los perdía. Contraste: el CSV de gastos ya lleva "Forma de pago" (con el
 * mismo literal del badge) y el de proveedores la identidad fiscal.
 */
import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent } from "@testing-library/react"
import "@testing-library/jest-dom"
import type { Purchase } from "@/lib/types"
import type { PaginationMeta } from "@/lib/pagination-utils"

vi.mock("@/components/cost-centers/CostCenterSelect", () => ({ CostCenterSelect: () => null }))
vi.mock("@/components/payment-methods/PaymentMethodSelect", () => ({ PaymentMethodSelect: () => null }))
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }))

const exportToCSVMock = vi.hoisted(() => vi.fn())
vi.mock("@/lib/excel", () => ({ exportToCSV: exportToCSVMock }))

import { PurchaseOperationsList } from "@/components/compras/purchase-operations-list"

const meta: PaginationMeta = { page: 0, pageSize: 25, totalCount: 2, pageCount: 1, from: 1, to: 2 }

const PURCHASES: Purchase[] = [
  {
    id: "pu1",
    date: "2026-08-20",
    productId: "p1",
    productName: "Harina 000",
    quantity: 10,
    unitCost: 890,
    total: 8900,
    operationId: "op1",
    paymentMethodId: "pm-credit",
    paymentMethodName: "Cuenta corriente",
    supplierId: "sup-1",
    supplierName: "Insumos Andinos",
  },
  {
    id: "pu2",
    date: "2026-08-21",
    productId: "p2",
    productName: "Levadura",
    quantity: 2,
    unitCost: 500,
    total: 1000,
    operationId: "op2",
    // Sin forma de pago ni proveedor imputados.
  },
]

function baseProps(purchases: Purchase[]) {
  return {
    purchases, meta, loading: false, error: null,
    dateFrom: "", setDateFrom: vi.fn(),
    dateTo: "", setDateTo: vi.fn(),
    costCenterId: null, setCostCenterId: vi.fn(),
    paymentMethodId: null, setPaymentMethodId: vi.fn(),
    clearFilters: vi.fn(),
    onPageChange: vi.fn(), onPageSizeChange: vi.fn(),
    onDeleteOperation: vi.fn(), onEditOperation: vi.fn(), onRefetch: vi.fn(),
  }
}

beforeEach(() => {
  exportToCSVMock.mockClear()
})

describe("CSV de /compras — forma de pago y proveedor (G15/H24)", () => {
  it("las columnas 'Forma de pago' y 'Proveedor' viajan en el CSV", () => {
    render(<PurchaseOperationsList {...baseProps(PURCHASES)} />)
    fireEvent.click(screen.getByRole("button", { name: /Exportar/ }))

    expect(exportToCSVMock).toHaveBeenCalledTimes(1)
    const [, columns] = exportToCSVMock.mock.calls[0]
    const headers = (columns as { header: string }[]).map((c) => c.header)
    expect(headers).toContain("Forma de pago")
    expect(headers).toContain("Proveedor")
  })

  it("cada fila lleva el MISMO literal que su badge (imputada y sin imputar)", () => {
    render(<PurchaseOperationsList {...baseProps(PURCHASES)} />)
    fireEvent.click(screen.getByRole("button", { name: /Exportar/ }))

    const [rows] = exportToCSVMock.mock.calls[0] as [
      { paymentMethodName: string; supplierName: string; productName: string }[],
    ]
    const conCredito = rows.find((r) => r.productName === "Harina 000")!
    expect(conCredito.paymentMethodName).toBe("Cuenta corriente")
    expect(conCredito.supplierName).toBe("Insumos Andinos")

    const sinImputar = rows.find((r) => r.productName === "Levadura")!
    // Los mismos fallbacks que muestran los badges de la pantalla.
    expect(sinImputar.paymentMethodName).toBe("Sin especificar")
    expect(sinImputar.supplierName).toBe("Sin proveedor")
  })
})
