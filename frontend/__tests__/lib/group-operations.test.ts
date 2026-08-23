import { describe, it, expect } from "vitest"
import { groupSalesByOperation, groupPurchasesByOperation } from "@/lib/group-operations"
import type { Sale, Purchase } from "@/lib/types"

// edicion-preserva-contexto (F1/F2): branchId/canal/unitId/isInvoiced viajan
// desde la fila (Sale/Purchase) hacia la SaleOperation/PurchaseOperation
// agrupada — sin esto SaleForm/PurchaseForm no tienen con qué prefillear ni
// con qué decidir el bloqueo fiscal.

function makeSale(overrides: Partial<Sale> = {}): Sale {
  return {
    id: "s1",
    date: "2026-08-20",
    productId: "p1",
    productName: "Producto",
    clientId: "c1",
    clientName: "Cliente",
    quantity: 1,
    unitPrice: 100,
    total: 100,
    currency: "ARS",
    operationId: "op1",
    ...overrides,
  }
}

function makePurchase(overrides: Partial<Purchase> = {}): Purchase {
  return {
    id: "pu1",
    date: "2026-08-20",
    productId: "p1",
    productName: "Producto",
    quantity: 1,
    unitCost: 50,
    total: 50,
    operationId: "op1",
    ...overrides,
  }
}

describe("groupSalesByOperation — contexto edicion-preserva-contexto", () => {
  it("expone branchId/canal/unitId de la operación agrupada", () => {
    const [op] = groupSalesByOperation([
      makeSale({ branchId: "b1", canal: "instagram", unitId: "u1" }),
    ])
    expect(op.branchId).toBe("b1")
    expect(op.canal).toBe("instagram")
    expect(op.unitId).toBe("u1")
  })

  it("branchId/canal/unitId ausentes → null, no undefined (contrato tri-estado del form)", () => {
    const [op] = groupSalesByOperation([makeSale({ branchId: undefined, canal: undefined, unitId: undefined })])
    expect(op.branchId).toBeNull()
    expect(op.canal).toBeNull()
    expect(op.unitId).toBeNull()
  })

  it("isInvoiced=false por defecto cuando la fila no lo trae", () => {
    const [op] = groupSalesByOperation([makeSale({ isInvoiced: undefined })])
    expect(op.isInvoiced).toBe(false)
  })

  it("isInvoiced=true se propaga a la operación agrupada", () => {
    const [op] = groupSalesByOperation([makeSale({ isInvoiced: true })])
    expect(op.isInvoiced).toBe(true)
  })

  it("TRIANGULATE: en una operación multi-línea, si CUALQUIER línea está facturada, la operación queda marcada facturada", () => {
    const [op] = groupSalesByOperation([
      makeSale({ id: "s1", isInvoiced: false }),
      makeSale({ id: "s2", isInvoiced: true }),
    ])
    expect(op.isGrouped).toBe(true)
    expect(op.isInvoiced).toBe(true)
  })

  // pagos-cableados-restantes (D6): mismo contrato que isInvoiced, para el
  // guard de inmutabilidad por cargo de cuenta corriente / movimiento de caja.
  it("isPaymentLocked=false por defecto cuando la fila no lo trae", () => {
    const [op] = groupSalesByOperation([makeSale({ isPaymentLocked: undefined })])
    expect(op.isPaymentLocked).toBe(false)
  })

  it("isPaymentLocked=true se propaga a la operación agrupada", () => {
    const [op] = groupSalesByOperation([makeSale({ isPaymentLocked: true })])
    expect(op.isPaymentLocked).toBe(true)
  })

  it("TRIANGULATE: en una operación multi-línea, si CUALQUIER línea tiene cargo/movimiento posteado, la operación queda bloqueada", () => {
    const [op] = groupSalesByOperation([
      makeSale({ id: "s1", isPaymentLocked: false }),
      makeSale({ id: "s2", isPaymentLocked: true }),
    ])
    expect(op.isGrouped).toBe(true)
    expect(op.isPaymentLocked).toBe(true)
  })
})

describe("groupPurchasesByOperation — contexto edicion-preserva-contexto", () => {
  it("expone branchId/unitId de la operación agrupada", () => {
    const [op] = groupPurchasesByOperation([makePurchase({ branchId: "b1", unitId: "u1" })])
    expect(op.branchId).toBe("b1")
    expect(op.unitId).toBe("u1")
  })

  it("branchId/unitId ausentes → null", () => {
    const [op] = groupPurchasesByOperation([makePurchase({ branchId: undefined, unitId: undefined })])
    expect(op.branchId).toBeNull()
    expect(op.unitId).toBeNull()
  })

  // pagos-cableados-restantes (D6, task 9.3): espejo de sales — inmutabilidad
  // por cargo de cuenta corriente posteado.
  it("isPaymentLocked=false por defecto cuando la fila no lo trae", () => {
    const [op] = groupPurchasesByOperation([makePurchase({ isPaymentLocked: undefined })])
    expect(op.isPaymentLocked).toBe(false)
  })

  it("isPaymentLocked=true se propaga a la operación agrupada", () => {
    const [op] = groupPurchasesByOperation([makePurchase({ isPaymentLocked: true })])
    expect(op.isPaymentLocked).toBe(true)
  })

  it("TRIANGULATE: en una operación multi-línea, si CUALQUIER línea tiene cargo posteado, la operación queda bloqueada", () => {
    const [op] = groupPurchasesByOperation([
      makePurchase({ id: "pu1", isPaymentLocked: false }),
      makePurchase({ id: "pu2", isPaymentLocked: true }),
    ])
    expect(op.isGrouped).toBe(true)
    expect(op.isPaymentLocked).toBe(true)
  })

  // compras-proveedor-cuenta-corriente (D4/D10, task 10.3): supplierId/
  // supplierName viajan desde la fila (Purchase) hacia la PurchaseOperation
  // agrupada — sin esto PurchaseForm no tiene con qué prefillear el selector
  // de proveedor al editar, ni el listado con qué armar el badge.
  it("expone supplierId/supplierName de la operación agrupada", () => {
    const [op] = groupPurchasesByOperation([
      makePurchase({ supplierId: "sup-1", supplierName: "Distribuidora Mendoza" }),
    ])
    expect(op.supplierId).toBe("sup-1")
    expect(op.supplierName).toBe("Distribuidora Mendoza")
  })

  it("supplierId/supplierName ausentes → null (sin proveedor imputado)", () => {
    const [op] = groupPurchasesByOperation([
      makePurchase({ supplierId: undefined, supplierName: undefined }),
    ])
    expect(op.supplierId).toBeNull()
    expect(op.supplierName).toBeNull()
  })

  it("TRIANGULATE: en una operación multi-línea, todas las líneas comparten el mismo proveedor de la primera", () => {
    const [op] = groupPurchasesByOperation([
      makePurchase({ id: "pu1", supplierId: "sup-1", supplierName: "Proveedor A" }),
      makePurchase({ id: "pu2", supplierId: "sup-1", supplierName: "Proveedor A" }),
    ])
    expect(op.isGrouped).toBe(true)
    expect(op.supplierId).toBe("sup-1")
    expect(op.supplierName).toBe("Proveedor A")
  })
})
