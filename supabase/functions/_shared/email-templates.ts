// Email templates of the `send-email` Edge Function — email-logs-cierre-insert
// (OQ-7 de multiusuario-operativo, governance CRÍTICO).
//
// Extracted from `send-email/index.ts` (a pure move plus the escaping below) so
// the templates can be unit-tested: index.ts runs `Deno.serve` at module scope
// and imports `npm:`/`jsr:` specifiers, so vitest cannot load it.
//
// Security contract (what frontend/__tests__/send-email-templates.test.ts pins):
//   1. EVERY value that comes from `metadata` (a name typed at sign-up, a product
//      name, a community notice title, numbers, dates, the plan label…) goes
//      through `escapeHtml` before it is placed in an HTML slot. `layout()` also
//      escapes its two plain-text slots (`title`, `ctaText`); `intro` and
//      `bodyHtml` are HTML slots whose DATA the caller escapes.
//   2. A link is NEVER taken from `metadata`. Every CTA is built from the fixed
//      `APP_URL`, and `layout()` refuses (drops the button) any `ctaUrl` that is
//      not under `APP_URL`, so a future template that forgets the rule cannot
//      turn into a phishing link. `meeting_notice` used to take `metadata.url`.
//   3. The attachment file name never carries raw `metadata`.
//
// D5/D6 pattern (same as email-fanout-policy.ts): pure and injectable — ZERO
// references to `Deno.*` at module scope.

import { escapeHtml, safeFilenamePart } from "./html-escape.ts"
import { buildOverdueDigestContent } from "./overdue-digest-template.ts"

// ── Branding ──────────────────────────────────────────────────────────────────
export const APP_URL = "https://www.aliadata.com.ar"
export const LOGO_URL = "https://www.aliadata.com.ar/aliadata-logo.png"
const GREEN = "#10b981"
const DARK = "#0f172a"

type Meta = Record<string, unknown>

function asMeta(raw: unknown): Meta {
  return raw !== null && typeof raw === "object" && !Array.isArray(raw) ? (raw as Meta) : {}
}

/** A CTA may only point inside the application: never at a metadata-supplied URL. */
function isAppUrl(url: string): boolean {
  return url === APP_URL || url.startsWith(`${APP_URL}/`)
}

/**
 * Envuelve el contenido en el layout de marca ALIADATA (logo + verde/negro).
 * HTML compatible con clientes de email (tablas + estilos inline).
 *
 * `title` y `ctaText` son TEXTO PLANO (se escapan acá). `intro` y `bodyHtml` son
 * HTML: quien llama escapa los DATOS que interpola. `ctaUrl` sólo se acepta si
 * apunta a `APP_URL`; si no, el botón no se dibuja.
 */
export function layout(opts: {
  title: string
  intro?: string
  bodyHtml?: string
  ctaText?: string
  ctaUrl?: string
  accent?: string
}): string {
  const accent = opts.accent ?? GREEN
  const showCta = Boolean(opts.ctaText && opts.ctaUrl && isAppUrl(opts.ctaUrl))
  return `
  <div style="margin:0;padding:0;background:#f3f4f6;">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f3f4f6;padding:24px 0;font-family:Arial,Helvetica,sans-serif;">
      <tr><td align="center">
        <table role="presentation" width="600" cellpadding="0" cellspacing="0" style="max-width:600px;width:100%;background:#ffffff;border-radius:12px;overflow:hidden;box-shadow:0 1px 4px rgba(0,0,0,0.12);">
          <tr><td style="background:${DARK};padding:22px 32px;text-align:center;border-bottom:3px solid ${accent};">
            <img src="${LOGO_URL}" width="40" height="40" alt="ALIADATA" style="display:inline-block;vertical-align:middle;border:0;" />
            <span style="display:inline-block;vertical-align:middle;margin-left:10px;font-size:21px;font-weight:bold;letter-spacing:3px;color:#ffffff;">ALIADATA</span>
          </td></tr>
          <tr><td style="padding:32px;color:#334155;font-size:15px;line-height:1.6;">
            <h1 style="margin:0 0 16px;font-size:22px;color:${DARK};">${escapeHtml(opts.title)}</h1>
            ${opts.intro ? `<p style="margin:0 0 16px;">${opts.intro}</p>` : ""}
            ${opts.bodyHtml ?? ""}
            ${showCta ? `
            <table role="presentation" cellpadding="0" cellspacing="0" style="margin:26px 0 8px;"><tr>
              <td style="border-radius:8px;background:${accent};">
                <a href="${escapeHtml(opts.ctaUrl)}" style="display:inline-block;padding:13px 30px;font-size:15px;font-weight:bold;color:#ffffff;text-decoration:none;border-radius:8px;">${escapeHtml(opts.ctaText)}</a>
              </td></tr></table>` : ""}
          </td></tr>
          <tr><td style="background:${DARK};padding:22px 32px;text-align:center;">
            <p style="margin:0 0 4px;font-size:13px;font-weight:bold;letter-spacing:2px;color:${accent};">ALIADATA</p>
            <p style="margin:0;font-size:11px;color:#94a3b8;">Gestión inteligente para tu negocio</p>
            <p style="margin:10px 0 0;font-size:11px;color:#64748b;">© 2026 ALIADATA · Mendoza, Argentina</p>
          </td></tr>
        </table>
      </td></tr>
    </table>
  </div>`
}

/** Fila de una tabla de datos: etiqueta y valor son TEXTO PLANO (se escapan). */
export function infoRow(label: string, value: unknown): string {
  return infoRowHtml(label, escapeHtml(value))
}

/**
 * Igual que `infoRow` pero el valor ya es HTML (por ejemplo un `<span>` con color):
 * quien llama es responsable de haber escapado los datos que contiene.
 */
export function infoRowHtml(label: string, valueHtml: string): string {
  return `<tr>
    <td style="padding:7px 0;color:#64748b;width:130px;vertical-align:top;">${escapeHtml(label)}</td>
    <td style="padding:7px 0;color:${DARK};font-weight:bold;">${valueHtml}</td>
  </tr>`
}

function capitalize(value: unknown): string {
  const s = String(value ?? "")
  return s ? s.charAt(0).toUpperCase() + s.slice(1) : ""
}

function formatMoney(value: unknown): string {
  return value != null ? `$${Number(value).toLocaleString("es-AR")}` : ""
}

function formatDate(value: unknown): string {
  return new Date(String(value)).toLocaleDateString("es-AR")
}

/**
 * Nombre del adjunto del recibo. El número de recibo viene de `metadata`:
 * sólo letras, dígitos, `_` y `-` llegan al nombre del archivo.
 */
export function receiptAttachmentFilename(receiptNumber: unknown): string {
  return `recibo-${safeFilenamePart(receiptNumber, "aliadata")}.pdf`
}

/**
 * Renders the HTML body of the email for one `email_logs` row. `metadata` is
 * untrusted: it is escaped slot by slot and never read for a URL.
 */
export function renderEmailHtml(eventType: string, rawMetadata: unknown): string {
  const m = asMeta(rawMetadata)
  const planDisplayOf = (fallback: string): string => capitalize((m.plan as unknown) ?? fallback)

  let htmlContent = layout({
    title: "Notificación de ALIADATA",
    intro: `Recibiste un nuevo aviso: ${escapeHtml(eventType)}.`,
  })

  if (eventType === "welcome") {
    htmlContent = layout({
      title: "¡Te damos la bienvenida! 🚀",
      intro: `Hola ${escapeHtml(m.name ?? "")}, ¡gracias por sumarte a ALIADATA!`,
      bodyHtml: `<p style="margin:0 0 16px;">Ya podés empezar a ordenar tu negocio: registrá ventas, compras y stock, y dejá que la inteligencia artificial te dé información útil para crecer.</p>`,
      ctaText: "Ir a mi panel",
      ctaUrl: `${APP_URL}/dashboard`,
    })
  } else if (eventType === "new_user_admin_notice") {
    htmlContent = layout({
      title: "Nuevo registro en ALIADATA",
      intro: "Se registró un nuevo usuario en la app:",
      bodyHtml: `<table role="presentation" cellpadding="0" cellspacing="0" style="width:100%;font-size:15px;">
          ${infoRow("Nombre", m.name ?? "-")}
          ${infoRow("Apellido", m.last_name ?? "-")}
          ${infoRow("Email", m.email ?? "-")}
          ${infoRow("Teléfono", m.phone ?? "-")}
          ${infoRow("Provincia", m.province ?? "-")}
          ${infoRow("Localidad", m.locality ?? "-")}
        </table>`,
    })
  } else if (eventType === "meeting_notice") {
    // El enlace NUNCA sale de la metadata (antes `metadata.url`): un título o una
    // URL hostiles no pueden convertir este aviso en un enlace a otro sitio.
    htmlContent = layout({
      title: "📅 Nueva reunión programada",
      intro: `Se agendó una nueva reunión en la comunidad: <strong>${escapeHtml(m.title)}</strong>.`,
      bodyHtml: `<p style="margin:0;"><strong>Fecha/Hora (UTC):</strong> ${escapeHtml(new Date(String(m.start_time)).toLocaleString())}</p>`,
      ctaText: "Ver la reunión",
      ctaUrl: `${APP_URL}/comunidad`,
    })
  } else if (eventType === "pool_notice") {
    htmlContent = layout({
      title: "🛒 Nuevo pool de compra abierto",
      intro: `Hay un nuevo pool de compra disponible: <strong>${escapeHtml(m.title)}</strong>.`,
      bodyHtml: `<p style="margin:0;"><strong>Cierra el:</strong> ${escapeHtml(new Date(String(m.closes_at)).toLocaleDateString())}</p>`,
      ctaText: "Ver pool",
      ctaUrl: `${APP_URL}/comunidad`,
    })
  } else if (eventType === "low_stock_alert") {
    htmlContent = layout({
      title: "⚠️ Alerta de stock bajo",
      intro: `El producto <strong>${escapeHtml(m.product_name)}</strong> tiene poco inventario.`,
      bodyHtml: `<p style="margin:0 0 8px;"><strong>Stock actual:</strong> <span style="color:#ef4444;font-weight:bold;">${escapeHtml(m.current_stock)}</span> unidades.</p>
          <p style="margin:0;color:#64748b;">Te recomendamos reabastecer pronto para no perder ventas.</p>`,
      ctaText: "Ver stock",
      ctaUrl: `${APP_URL}/stock`,
    })
  } else if (eventType === "low_margin_alert") {
    htmlContent = layout({
      title: "📉 Alerta de margen crítico",
      intro: "Se registró una venta con un margen de ganancia inferior al 15%.",
      bodyHtml: `<table role="presentation" cellpadding="0" cellspacing="0" style="width:100%;font-size:15px;">
          ${infoRow("Producto", m.product_name ?? "-")}
          ${infoRow("Monto de venta", `$${String(m.amount ?? "")}`)}
          ${infoRow("Costo base", `$${String(m.cost_basis ?? "")}`)}
          ${infoRowHtml("Margen", `<span style="color:#ef4444;">${escapeHtml(m.margin_percentage)}%</span>`)}
        </table>
        <p style="margin:16px 0 0;color:#64748b;">Revisá tus costos o ajustá el precio para mantener la rentabilidad.</p>`,
    })
  } else if (eventType === "trial_expiring_soon") {
    const umbral = m.umbral ?? "7d"
    const diasLabel = umbral === "1d" ? "1 día" : "7 días"
    htmlContent = layout({
      title: `⏰ Te quedan ${diasLabel} de prueba`,
      intro: "Tu período de prueba del plan Avanzado está por terminar.",
      bodyHtml: `<p style="margin:0;">Cuando venza, vas a seguir usando ALIADATA con el plan Gratis. Si querés mantener todas las funciones avanzadas, elegí un plan pago.</p>`,
      ctaText: "Ver planes y precios",
      ctaUrl: `${APP_URL}/planes`,
    })
  } else if (eventType === "plan_upgraded") {
    const planDisplay = planDisplayOf("pago")
    const amountDisplay = formatMoney(m.amount)
    const activatedAt = m.activated_at
      ? formatDate(m.activated_at)
      : new Date().toLocaleDateString("es-AR")
    htmlContent = layout({
      title: `¡Tu plan ${planDisplay} ya está activo!`,
      intro: "¡Hola! Tu pago se procesó correctamente y tu plan ya está activo en ALIADATA.",
      bodyHtml: `<table role="presentation" cellpadding="0" cellspacing="0" style="width:100%;font-size:15px;">
          ${infoRow("Plan", planDisplay)}
          ${amountDisplay ? infoRow("Monto abonado", amountDisplay) : ""}
          ${infoRow("Fecha de activación", activatedAt)}
        </table>
        ${m.receipt_pdf_base64 ? `<p style="margin:18px 0 0;color:#64748b;">Adjuntamos tu <strong>comprobante de pago</strong> en PDF.</p>` : ""}`,
      ctaText: "Ir a mi panel",
      ctaUrl: `${APP_URL}/dashboard`,
    })
  } else if (eventType === "payment_receipt") {
    const planDisplay = planDisplayOf("")
    const amountDisplay = formatMoney(m.amount)
    htmlContent = layout({
      title: "Tu comprobante de pago",
      intro: "¡Gracias por tu pago! Adjuntamos el comprobante de tu suscripción a ALIADATA.",
      bodyHtml: `<table role="presentation" cellpadding="0" cellspacing="0" style="width:100%;font-size:15px;">
          ${m.receipt_number ? infoRow("N° de recibo", m.receipt_number) : ""}
          ${planDisplay ? infoRow("Plan", planDisplay) : ""}
          ${amountDisplay ? infoRow("Monto", amountDisplay) : ""}
        </table>
        <p style="margin:18px 0 0;color:#64748b;">El comprobante en PDF va adjunto a este correo. Es un comprobante de pago, no una factura.</p>`,
    })
  } else if (eventType === "plan_downgraded") {
    const planDisplay = planDisplayOf("")
    const reason = String(m.reason ?? "user_requested")
    const isUserRequested = reason === "user_requested"
    const expiresAt = m.plan_expires_at ? formatDate(m.plan_expires_at) : ""
    htmlContent = layout({
      title: `Tu suscripción fue ${isUserRequested ? "cancelada" : "dada de baja"}`,
      intro: isUserRequested
        ? `Registramos la cancelación de tu plan ${escapeHtml(planDisplay)}.`
        : `Tu plan ${escapeHtml(planDisplay)} venció y tu cuenta pasó al plan Gratis.`,
      bodyHtml: isUserRequested && expiresAt
        ? `<p style="margin:0;">Tu plan sigue activo hasta el <strong>${escapeHtml(expiresAt)}</strong>; después vas a usar ALIADATA con el plan Gratis. Si fue un error, podés reactivar cuando quieras.</p>`
        : `<p style="margin:0;">Si querés seguir con las funciones avanzadas, podés elegir un nuevo plan.</p>`,
      ctaText: "Ver planes y precios",
      ctaUrl: `${APP_URL}/planes`,
    })
  } else if (eventType === "trial_expired") {
    htmlContent = layout({
      title: "Tu período de prueba terminó",
      intro: "Tu prueba del plan Avanzado terminó. A partir de ahora usás el plan Gratis.",
      bodyHtml: `<p style="margin:0;">Con el plan Gratis seguís registrando ventas, compras y gastos. Si necesitás reportes comparativos, IA ilimitada o más usuarios, elegí el plan que mejor se adapte a tu negocio.</p>`,
      ctaText: "Ver planes y precios",
      ctaUrl: `${APP_URL}/planes`,
    })
  } else if (eventType === "subscription_payment_approved") {
    // mp-real-subscriptions (D2bis/PR4) — cobro mensual recurrente
    // aprobado. Distinto de "plan_upgraded" (alta única) y de
    // "payment_receipt" (comprobante con PDF adjunto) — este es el aviso
    // liviano de "te renovamos" que se dispara TODOS los meses.
    const planDisplay = planDisplayOf("")
    const amountDisplay = formatMoney(m.amount)
    const nextExpiry = m.plan_expires_at ? formatDate(m.plan_expires_at) : ""
    htmlContent = layout({
      title: "✅ Renovamos tu suscripción",
      intro: `Tu plan ${escapeHtml(planDisplay)} se renovó correctamente. ¡Gracias por seguir con ALIADATA!`,
      bodyHtml: `<table role="presentation" cellpadding="0" cellspacing="0" style="width:100%;font-size:15px;">
          ${planDisplay ? infoRow("Plan", planDisplay) : ""}
          ${amountDisplay ? infoRow("Monto cobrado", amountDisplay) : ""}
          ${nextExpiry ? infoRow("Próximo cobro", nextExpiry) : ""}
        </table>`,
      ctaText: "Ir a mi panel",
      ctaUrl: `${APP_URL}/dashboard`,
    })
  } else if (eventType === "subscription_payment_failed") {
    // mp-real-subscriptions (D7/D10) — cobro rechazado. MercadoPago
    // reintenta solo (hasta 4 veces en 10 días); acá SOLO avisamos, no
    // se toca el plan todavía.
    htmlContent = layout({
      title: "⚠️ No pudimos procesar tu pago",
      accent: "#ef4444",
      intro: "Intentamos cobrar tu suscripción y el pago fue rechazado por MercadoPago.",
      bodyHtml: `<p style="margin:0 0 16px;">No te preocupes: MercadoPago va a reintentar automáticamente en los próximos días. Mientras tanto, tu acceso sigue activo.</p>
          <p style="margin:0;color:#64748b;">Si el problema persiste, te recomendamos revisar el medio de pago asociado a tu suscripción directamente en MercadoPago.</p>`,
      ctaText: "Ver mi facturación",
      ctaUrl: `${APP_URL}/facturacion`,
    })
  } else if (eventType === "subscription_expiring_soon") {
    // mp-real-subscriptions (4.7/7.6) — último aviso antes de que
    // plan_expires_at venza (ya pasó la ventana de gracia/reintentos de MP).
    const expiresAt = m.plan_expires_at ? formatDate(m.plan_expires_at) : ""
    htmlContent = layout({
      title: "⏰ Tu suscripción está por vencer",
      accent: "#f59e0b",
      intro: expiresAt
        ? `Tu plan pago vence el <strong>${escapeHtml(expiresAt)}</strong> y todavía no pudimos confirmar el cobro.`
        : "Tu plan pago está por vencer y todavía no pudimos confirmar el cobro.",
      bodyHtml: `<p style="margin:0;">Si tu medio de pago sigue vigente, no necesitás hacer nada — MercadoPago va a seguir intentando. Si querés revisar o actualizar tu método de pago, podés hacerlo desde MercadoPago.</p>`,
      ctaText: "Ver mi facturación",
      ctaUrl: `${APP_URL}/facturacion`,
    })
  } else if (eventType === "receivables_overdue_digest" || eventType === "payables_overdue_digest") {
    // cobranzas-vencimientos (grupo 6, D8) — resumen diario de deuda
    // vencida (un aviso por cuenta, por lado y por día argentino). Las
    // cifras viajan en metadata (party_count, overdue_total, as_of); el
    // armado vive en el módulo puro _shared/overdue-digest-template.ts,
    // testeado desde frontend/__tests__/send-email-overdue-digest.test.ts.
    // Sus cifras se coercionan con Number(): no pasan texto del usuario.
    const digest = buildOverdueDigestContent(
      eventType === "receivables_overdue_digest" ? "receivables" : "payables",
      m,
      APP_URL,
    )
    htmlContent = layout({
      title: digest.title,
      accent: digest.accent,
      intro: digest.intro,
      bodyHtml: digest.bodyHtml,
      ctaText: digest.ctaText,
      ctaUrl: digest.ctaUrl,
    })
  } else if (eventType === "subscription_cancelled") {
    // mp-real-subscriptions (task 7.2) — baja voluntaria o reportada por
    // MercadoPago (impago tras 3 rechazos). Mismo aviso para ambos
    // orígenes — lo que le importa al usuario es el resultado, no la causa.
    const expiresAt = m.plan_expires_at ? formatDate(m.plan_expires_at) : ""
    const isUserRequested = m.reason === "user_requested"
    htmlContent = layout({
      title: "Tu suscripción fue cancelada",
      intro: isUserRequested
        ? "Registramos la cancelación de tu suscripción."
        : "Tu suscripción fue cancelada por MercadoPago (no se pudo confirmar el pago).",
      bodyHtml: expiresAt
        ? `<p style="margin:0;">Tu plan sigue activo hasta el <strong>${escapeHtml(expiresAt)}</strong>; después vas a usar ALIADATA con el plan Gratis. Si querés, podés volver a suscribirte cuando quieras.</p>`
        : `<p style="margin:0;">Si querés seguir con las funciones avanzadas, podés suscribirte de nuevo cuando quieras.</p>`,
      ctaText: "Ver planes y precios",
      ctaUrl: `${APP_URL}/planes`,
    })
  }

  return htmlContent
}
