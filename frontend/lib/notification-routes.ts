/**
 * tablero-explicable (D6) — destino de cada notificación de la campana.
 *
 * Mapeo ÚNICO `type` (+ `payload`) → ruta de la aplicación. Puro: sin
 * dependencias de React ni de Next, para testearlo y reutilizarlo.
 *
 * Los identificadores del payload se validan como UUID ANTES de interpolarlos
 * en la ruta: un payload raro (o malicioso) cae al destino sin parámetro y
 * nunca arma una URL con texto arbitrario. Un `type` desconocido no tiene
 * destino (`null`): la fila sólo se puede descartar.
 */

import type { Notification, NotificationType } from "@/lib/types"

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

/** El valor sólo si es un UUID en string; cualquier otra cosa → `null`. */
function uuidOrNull(value: unknown): string | null {
  return typeof value === "string" && UUID_RE.test(value) ? value : null
}

export function notificationHref(n: Pick<Notification, "type" | "payload">): string | null {
  const payload = n.payload ?? {}
  switch (n.type) {
    case "StockBelowMinimum": {
      const productId = uuidOrNull(payload.product_id)
      return productId ? `/stock?product=${productId}` : "/stock"
    }
    case "CashSessionClosed": {
      const branchId = uuidOrNull(payload.branch_id)
      return branchId ? `/caja?branch=${branchId}` : "/caja"
    }
    case "FiscalDocumentRejected":
      return "/ventas"
    case "QuoteAccepted": {
      const quoteId = uuidOrNull(payload.quote_id)
      return quoteId ? `/presupuestos/${quoteId}` : "/presupuestos"
    }
    case "TransferDispatched":
      return "/stock"
    case "PlanLimitExceeded":
      return "/planes"
    case "SubscriptionPaymentFailed":
    case "SubscriptionExpiringSoon":
      return "/facturacion"
    case "ReceivablesOverdueDigest":
      return "/cobranzas"
    case "PayablesOverdueDigest":
      return "/cobranzas?tab=payables"
    default:
      return null
  }
}

const DESTINATION_LABELS: Record<NotificationType, string> = {
  StockBelowMinimum: "Ir a Stock",
  CashSessionClosed: "Ir a Caja",
  FiscalDocumentRejected: "Ir a Ventas",
  QuoteAccepted: "Ir al presupuesto",
  TransferDispatched: "Ir a Stock",
  PlanLimitExceeded: "Ir a Planes",
  SubscriptionPaymentFailed: "Ir a Facturación",
  SubscriptionExpiringSoon: "Ir a Facturación",
  ReceivablesOverdueDigest: "Ir a Cobranzas",
  PayablesOverdueDigest: "Ir a Cobranzas",
}

/** Rótulo del destino («Ir a Stock»…); `null` si el tipo no tiene destino. */
export function notificationDestinationLabel(type: string): string | null {
  return (DESTINATION_LABELS as Record<string, string>)[type] ?? null
}
