/**
 * tablero-explicable (D6, task 3.1): destino de cada notificación de la
 * campana, derivado del `type` y del `payload` con un único mapeo. Los
 * payloads son los reales de prod (medidos el 2026-11-06).
 */
import { describe, it, expect } from "vitest"
import {
  notificationDestinationLabel,
  notificationHref,
} from "@/lib/notification-routes"

const UUID = "5f1c2b3e-8a4d-4c6e-9b7a-0123456789ab"
const UUID2 = "9a8b7c6d-1e2f-4a3b-8c5d-abcdef012345"

describe("notificationHref", () => {
  it("StockBelowMinimum → /stock?product=<product_id>", () => {
    expect(
      notificationHref({
        type: "StockBelowMinimum",
        payload: { product_id: UUID, branch_id: UUID2, current_qty: 2, min_qty: 5 },
      }),
    ).toBe(`/stock?product=${UUID}`)
  })

  it("StockBelowMinimum sin product_id cae a /stock", () => {
    expect(notificationHref({ type: "StockBelowMinimum", payload: { current_qty: 2 } })).toBe("/stock")
  })

  it("CashSessionClosed → /caja?branch=<branch_id>, o /caja sin sucursal", () => {
    expect(
      notificationHref({ type: "CashSessionClosed", payload: { session_id: UUID, branch_id: UUID2, difference: -150 } }),
    ).toBe(`/caja?branch=${UUID2}`)
    expect(notificationHref({ type: "CashSessionClosed", payload: { session_id: UUID } })).toBe("/caja")
  })

  it("FiscalDocumentRejected → /ventas", () => {
    expect(
      notificationHref({ type: "FiscalDocumentRejected", payload: { fiscal_document_id: UUID, error: "x", branch_id: UUID2 } }),
    ).toBe("/ventas")
  })

  it("QuoteAccepted → /presupuestos/<quote_id>, o /presupuestos sin id", () => {
    expect(
      notificationHref({ type: "QuoteAccepted", payload: { quote_id: UUID, total: 1000, branch_id: UUID2, seller_id: UUID2 } }),
    ).toBe(`/presupuestos/${UUID}`)
    expect(notificationHref({ type: "QuoteAccepted", payload: { total: 1000 } })).toBe("/presupuestos")
  })

  it("los destinos sin parámetro: transferencia, límite de plan, suscripción, cobranzas", () => {
    expect(notificationHref({ type: "TransferDispatched", payload: {} })).toBe("/stock")
    expect(notificationHref({ type: "PlanLimitExceeded", payload: { resource: "products" } })).toBe("/planes")
    expect(notificationHref({ type: "SubscriptionPaymentFailed", payload: {} })).toBe("/facturacion")
    expect(notificationHref({ type: "SubscriptionExpiringSoon", payload: {} })).toBe("/facturacion")
    expect(notificationHref({ type: "ReceivablesOverdueDigest", payload: {} })).toBe("/cobranzas")
    expect(notificationHref({ type: "PayablesOverdueDigest", payload: {} })).toBe("/cobranzas?tab=payables")
  })

  it("un id que no es UUID nunca se interpola: cae al destino sin parámetro", () => {
    expect(notificationHref({ type: "QuoteAccepted", payload: { quote_id: "../../admin" } })).toBe("/presupuestos")
    expect(notificationHref({ type: "StockBelowMinimum", payload: { product_id: "1; drop table" } })).toBe("/stock")
    expect(notificationHref({ type: "CashSessionClosed", payload: { branch_id: "x&y=1" } })).toBe("/caja")
  })

  it("un id con tipo no string (número, objeto) tampoco se interpola", () => {
    expect(notificationHref({ type: "QuoteAccepted", payload: { quote_id: 123 } })).toBe("/presupuestos")
    expect(notificationHref({ type: "StockBelowMinimum", payload: { product_id: { a: 1 } } })).toBe("/stock")
  })

  it("un tipo desconocido no tiene destino", () => {
    expect(notificationHref({ type: "AlgoNuevo" as never, payload: {} })).toBeNull()
  })
})

describe("notificationDestinationLabel", () => {
  it("rotula el destino de cada tipo con destino", () => {
    expect(notificationDestinationLabel("StockBelowMinimum")).toBe("Ir a Stock")
    expect(notificationDestinationLabel("CashSessionClosed")).toBe("Ir a Caja")
    expect(notificationDestinationLabel("FiscalDocumentRejected")).toBe("Ir a Ventas")
    expect(notificationDestinationLabel("QuoteAccepted")).toBe("Ir al presupuesto")
    expect(notificationDestinationLabel("TransferDispatched")).toBe("Ir a Stock")
    expect(notificationDestinationLabel("PlanLimitExceeded")).toBe("Ir a Planes")
    expect(notificationDestinationLabel("SubscriptionPaymentFailed")).toBe("Ir a Facturación")
    expect(notificationDestinationLabel("SubscriptionExpiringSoon")).toBe("Ir a Facturación")
    expect(notificationDestinationLabel("ReceivablesOverdueDigest")).toBe("Ir a Cobranzas")
    expect(notificationDestinationLabel("PayablesOverdueDigest")).toBe("Ir a Cobranzas")
  })

  it("un tipo desconocido no tiene rótulo de destino", () => {
    expect(notificationDestinationLabel("AlgoNuevo")).toBeNull()
  })
})
