// Shared template builder for the daily overdue-debt digest emails —
// cobranzas-vencimientos (grupo 6, D8).
//
// The sweep `_produce_receivables_overdue_digest()` inserts one `email_logs`
// row per account/side/day with `event_type` `receivables_overdue_digest` or
// `payables_overdue_digest` and `metadata = {account_id, as_of, party_count,
// overdue_total}`. This module turns that metadata into the layout() params
// used by the send-email Edge Function.
//
// D5/D6 pattern (same as email-fanout-policy.ts): pure and injectable — ZERO
// references to `Deno.*` at module scope — so vitest imports the REAL file by
// relative path (frontend/__tests__/send-email-overdue-digest.test.ts).

export type OverdueDigestSide = "receivables" | "payables"

export interface OverdueDigestMetadata {
  party_count?: number | string
  overdue_total?: number | string
  as_of?: string
}

export interface OverdueDigestContent {
  title: string
  accent: string
  intro: string
  bodyHtml: string
  ctaText: string
  ctaUrl: string
}

function formatArs(value: number): string {
  return `$${value.toLocaleString("es-AR", {
    minimumFractionDigits: 0,
    maximumFractionDigits: 2,
  })}`
}

/**
 * Builds the branded-layout params for one side of the overdue digest.
 * Degrades gracefully on incomplete metadata: never renders "undefined"/"NaN".
 */
export function buildOverdueDigestContent(
  side: OverdueDigestSide,
  metadata: OverdueDigestMetadata | null | undefined,
  appUrl: string,
): OverdueDigestContent {
  const count = Number(metadata?.party_count)
  const total = Number(metadata?.overdue_total)
  const hasCount = Number.isFinite(count) && count > 0
  const hasTotal = Number.isFinite(total) && total > 0

  const partyNoun =
    side === "receivables"
      ? hasCount && count === 1 ? "cliente" : "clientes"
      : hasCount && count === 1 ? "proveedor" : "proveedores"

  const summaryLine = hasCount && hasTotal
    ? side === "receivables"
      ? `Tenés <strong>${count} ${partyNoun}</strong> con deuda vencida por un total de <strong>${formatArs(total)}</strong>.`
      : `Tenés deuda vencida con <strong>${count} ${partyNoun}</strong> por un total de <strong>${formatArs(total)}</strong>.`
    : side === "receivables"
      ? "Tenés deuda vencida por cobrar en tu cuenta corriente."
      : "Tenés deuda vencida con proveedores en tu cuenta corriente."

  const followUp =
    side === "receivables"
      ? "Desde el panel de cobranzas podés ver quiénes son, hace cuánto venció cada deuda y mandar un recordatorio."
      : "Desde el panel de cobranzas (pestaña Por pagar) podés ver los importes y registrar los pagos."

  return {
    title:
      side === "receivables"
        ? "⏰ Tenés deuda vencida por cobrar"
        : "⏰ Tenés deuda vencida con proveedores",
    accent: "#f59e0b",
    intro:
      side === "receivables"
        ? "Resumen diario de tus cuentas por cobrar:"
        : "Resumen diario de tus cuentas por pagar:",
    bodyHtml: `<p style="margin:0 0 12px;">${summaryLine}</p><p style="margin:0;">${followUp}</p>`,
    ctaText: "Ver mis cobranzas",
    ctaUrl: `${appUrl}/cobranzas`,
  }
}
