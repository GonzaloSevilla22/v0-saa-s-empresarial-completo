/**
 * cobranzas-vencimientos (task 8.3, D12) — recordatorio de deuda por
 * WhatsApp: función PURA que arma el texto (testeable sin DOM) y deep-link
 * vía buildWhatsAppUrl — el MISMO helper que usa el envío de comprobantes
 * (regla de reutilización: nada de normalizadores nuevos). Sin teléfono
 * utilizable, buildWhatsAppUrl ya cae al selector de contactos: el botón
 * nunca queda muerto.
 *
 * El envío NO se registra en ninguna bitácora (alcance declarado): es una
 * acción asistida del usuario, no un envío del sistema.
 */

import { buildWhatsAppUrl } from "@/lib/phone-utils"
import { formatMoney } from "@/lib/format"
import type { ReceivableRow } from "@/lib/types"

/** Lo que el mensaje necesita de la fila del deudor. */
export type DebtReminderRow = Pick<
  ReceivableRow,
  "clientName" | "clientPhone" | "balance" | "overdueTotal" | "daysOverdueMax"
>

/**
 * Texto del recordatorio. Con importe vencido menciona la mora (cuánto y
 * hace cuántos días la parte más vieja); sin vencidos, sólo el saldo — no
 * se declara moroso a nadie que no lo esté.
 */
export function buildDebtReminderMessage(row: DebtReminderRow): string {
  const saldo = formatMoney(row.balance)
  const lines = [
    `Hola ${row.clientName}! Te escribimos para recordarte que tenés un saldo pendiente de ${saldo} con nosotros.`,
  ]
  if (row.overdueTotal > 0) {
    const vencido = formatMoney(row.overdueTotal)
    const days = row.daysOverdueMax
    const desde =
      days !== null && days > 0
        ? days === 1
          ? " desde hace 1 día"
          : ` desde hace ${days} días`
        : ""
    lines.push(`De ese saldo, ${vencido} está vencido${desde}.`)
  }
  lines.push("¿Coordinamos el pago? ¡Gracias!")
  return lines.join(" ")
}

/** Deep-link wa.me con el mensaje prearmado. */
export function buildDebtReminderUrl(row: DebtReminderRow): string {
  return buildWhatsAppUrl(row.clientPhone, buildDebtReminderMessage(row))
}
