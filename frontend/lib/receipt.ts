/**
 * Receipt / Invoice HTML generator.
 *
 * Generates a self-contained HTML string that:
 *  - Renders a professional sales receipt.
 *  - Auto-triggers window.print() on load so the user can Save as PDF
 *    or send to a printer directly.
 *  - Uses only inline CSS — zero external dependencies, zero network calls.
 *  - Is fully print-optimised (A4, 1cm margins, proper page breaks).
 *
 * Usage:
 *   const html = generateReceiptHTML(op, { businessName: user.businessName })
 *   const blob = new Blob([html], { type: "text/html;charset=utf-8" })
 *   const url  = URL.createObjectURL(blob)
 *   window.open(url, "_blank")
 */

import { formatMoney } from "@/lib/format"
import type { SaleOperation } from "@/lib/group-operations"
import type { Currency } from "@/lib/format"

export interface ReceiptOptions {
  businessName: string
  businessPhone?: string
  businessEmail?: string
  /** Avatar URL — used as logo when available */
  logoUrl?: string
}

// ── Helpers ───────────────────────────────────────────────────────────────────

function esc(str: string | undefined | null): string {
  if (!str) return ""
  return str
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
}

function receiptNumber(op: SaleOperation): string {
  const raw = (op.operationId ?? op.key).replace(/-/g, "")
  return raw.slice(-8).toUpperCase()
}

function longDate(isoDate: string): string {
  return new Date(isoDate + "T12:00:00").toLocaleDateString("es-AR", {
    weekday: "long",
    year:    "numeric",
    month:   "long",
    day:     "numeric",
  })
}

// Capitalise first letter (weekday comes lowercase from es-AR locale)
function capitalise(str: string): string {
  return str.charAt(0).toUpperCase() + str.slice(1)
}

// ── CSS ───────────────────────────────────────────────────────────────────────

const CSS = `
  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

  :root {
    --ink:      #111111;
    --muted:    #6b7280;
    --border:   #e5e7eb;
    --accent:   #f9fafb;
    --primary:  #0f172a;
    --emerald:  #059669;
    --radius:   8px;
  }

  html, body {
    background: #ffffff;
    color: var(--ink);
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
    font-size: 14px;
    line-height: 1.5;
    -webkit-print-color-adjust: exact;
    print-color-adjust: exact;
  }

  body {
    padding: 32px 24px;
    max-width: 680px;
    margin: 0 auto;
  }

  /* ── Header ── */
  .receipt-header {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    gap: 16px;
    padding-bottom: 20px;
    border-bottom: 2px solid var(--primary);
    margin-bottom: 20px;
  }

  .business-block {
    display: flex;
    align-items: center;
    gap: 12px;
  }

  .business-logo {
    width: 48px;
    height: 48px;
    border-radius: 50%;
    object-fit: cover;
    flex-shrink: 0;
  }

  .business-initial {
    width: 48px;
    height: 48px;
    border-radius: 50%;
    background: var(--primary);
    color: #ffffff;
    font-size: 22px;
    font-weight: 700;
    display: flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
    letter-spacing: -1px;
  }

  .business-name {
    font-size: 20px;
    font-weight: 700;
    color: var(--primary);
    line-height: 1.2;
  }

  .business-contact {
    font-size: 12px;
    color: var(--muted);
    margin-top: 3px;
  }

  .receipt-meta {
    text-align: right;
    flex-shrink: 0;
  }

  .receipt-label {
    font-size: 11px;
    font-weight: 600;
    letter-spacing: 0.08em;
    text-transform: uppercase;
    color: var(--muted);
  }

  .receipt-number {
    font-size: 22px;
    font-weight: 800;
    color: var(--primary);
    letter-spacing: -0.5px;
    font-variant-numeric: tabular-nums;
  }

  .receipt-type {
    font-size: 12px;
    color: var(--muted);
    margin-top: 2px;
  }

  /* ── Info section ── */
  .info-grid {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 12px 24px;
    padding: 16px 0;
    border-bottom: 1px solid var(--border);
    margin-bottom: 20px;
  }

  .info-block {}
  .info-label {
    font-size: 10px;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.08em;
    color: var(--muted);
    margin-bottom: 3px;
  }
  .info-value {
    font-size: 14px;
    font-weight: 600;
    color: var(--ink);
  }
  .info-value.muted {
    font-weight: 400;
    color: var(--muted);
    font-style: italic;
  }

  /* ── Items table ── */
  .items-section {
    margin-bottom: 0;
  }

  .items-table {
    width: 100%;
    border-collapse: collapse;
  }

  .items-table thead tr {
    background: var(--accent);
    border-top: 1px solid var(--border);
    border-bottom: 1px solid var(--border);
  }

  .items-table th {
    padding: 8px 10px;
    font-size: 10px;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.08em;
    color: var(--muted);
    text-align: left;
  }

  .items-table th.right, .items-table td.right { text-align: right; }
  .items-table th.center, .items-table td.center { text-align: center; }

  .items-table tbody tr {
    border-bottom: 1px solid var(--border);
  }

  .items-table tbody tr:last-child {
    border-bottom: none;
  }

  .items-table td {
    padding: 10px 10px;
    font-size: 13px;
    color: var(--ink);
    vertical-align: middle;
  }

  .items-table td.product-name {
    font-weight: 600;
  }

  .items-table td.subtotal {
    font-weight: 700;
    color: var(--emerald);
    font-variant-numeric: tabular-nums;
  }

  /* ── Total footer ── */
  .total-section {
    border-top: 2px solid var(--primary);
    margin-top: 0;
    padding-top: 12px;
    display: flex;
    justify-content: flex-end;
    gap: 24px;
    align-items: baseline;
  }

  .total-label {
    font-size: 13px;
    font-weight: 600;
    color: var(--muted);
    text-transform: uppercase;
    letter-spacing: 0.06em;
  }

  .total-amount {
    font-size: 26px;
    font-weight: 800;
    color: var(--primary);
    font-variant-numeric: tabular-nums;
    letter-spacing: -1px;
  }

  /* ── Footer ── */
  .receipt-footer {
    margin-top: 28px;
    padding-top: 16px;
    border-top: 1px solid var(--border);
    display: flex;
    justify-content: space-between;
    align-items: flex-end;
    gap: 12px;
  }

  .footer-thanks {
    font-size: 13px;
    font-weight: 600;
    color: var(--primary);
  }
  .footer-thanks-sub {
    font-size: 11px;
    color: var(--muted);
    margin-top: 2px;
  }

  .footer-id {
    text-align: right;
    font-size: 10px;
    color: var(--border);
    font-variant-numeric: tabular-nums;
    word-break: break-all;
    max-width: 240px;
  }

  /* ── Print optimisation ── */
  @page {
    size: A4 portrait;
    margin: 1.5cm 1.5cm 2cm;
  }

  @media print {
    body { padding: 0; }
    .no-print { display: none !important; }
    .receipt-footer { page-break-inside: avoid; }
    .total-section  { page-break-inside: avoid; }
  }
`

// ── Main generator ────────────────────────────────────────────────────────────

export function generateReceiptHTML(
  op: SaleOperation,
  opts: ReceiptOptions,
): string {
  const num       = receiptNumber(op)
  const dateLabel = capitalise(longDate(op.date))
  const biz       = opts.businessName || "Mi Negocio"
  const initial   = biz.charAt(0).toUpperCase()
  const hasClient = op.clientName && op.clientName !== "Consumidor Final"

  // ── Logo / initial ──────────────────────────────────────────────────────
  const logoHTML = opts.logoUrl
    ? `<img class="business-logo" src="${esc(opts.logoUrl)}" alt="Logo" />`
    : `<div class="business-initial">${esc(initial)}</div>`

  // ── Contact line ────────────────────────────────────────────────────────
  const contactParts: string[] = []
  if (opts.businessPhone) contactParts.push(esc(opts.businessPhone))
  if (opts.businessEmail) contactParts.push(esc(opts.businessEmail))
  const contactHTML = contactParts.length
    ? `<div class="business-contact">${contactParts.join(" &nbsp;·&nbsp; ")}</div>`
    : ""

  // ── Items rows ──────────────────────────────────────────────────────────
  const itemsHTML = op.items
    .map(
      (item) => `
      <tr>
        <td class="product-name">${esc(item.productName)}</td>
        <td class="center">${item.quantity}</td>
        <td class="right">${esc(formatMoney(item.unitPrice, op.currency as Currency))}</td>
        <td class="right subtotal">${esc(formatMoney(item.total, op.currency as Currency))}</td>
      </tr>`,
    )
    .join("")

  // ── Total ───────────────────────────────────────────────────────────────
  const totalFormatted = formatMoney(op.total, op.currency as Currency)

  // ── Client block ────────────────────────────────────────────────────────
  const clientValueClass = hasClient ? "info-value" : "info-value muted"
  const clientValueText  = hasClient ? esc(op.clientName) : "Consumidor final"

  // ── Operation ID (for footer reference) ────────────────────────────────
  const opId = op.operationId ?? op.key

  return `<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>Comprobante ${num} — ${esc(biz)}</title>
  <style>${CSS}</style>
</head>
<body>

  <!-- ── Header ─────────────────────────────────────────────────────── -->
  <div class="receipt-header">
    <div class="business-block">
      ${logoHTML}
      <div>
        <div class="business-name">${esc(biz)}</div>
        ${contactHTML}
      </div>
    </div>
    <div class="receipt-meta">
      <div class="receipt-label">Comprobante</div>
      <div class="receipt-number">#${num}</div>
      <div class="receipt-type">Comprobante de venta</div>
    </div>
  </div>

  <!-- ── Info grid ───────────────────────────────────────────────────── -->
  <div class="info-grid">
    <div class="info-block">
      <div class="info-label">Cliente</div>
      <div class="${clientValueClass}">${clientValueText}</div>
    </div>
    <div class="info-block">
      <div class="info-label">Fecha</div>
      <div class="info-value">${dateLabel}</div>
    </div>
  </div>

  <!-- ── Items ───────────────────────────────────────────────────────── -->
  <div class="items-section">
    <table class="items-table">
      <thead>
        <tr>
          <th>Descripción</th>
          <th class="center">Cant.</th>
          <th class="right">Precio unit.</th>
          <th class="right">Subtotal</th>
        </tr>
      </thead>
      <tbody>
        ${itemsHTML}
      </tbody>
    </table>
  </div>

  <!-- ── Total ───────────────────────────────────────────────────────── -->
  <div class="total-section">
    <span class="total-label">Total</span>
    <span class="total-amount">${esc(totalFormatted)}</span>
  </div>

  <!-- ── Footer ──────────────────────────────────────────────────────── -->
  <div class="receipt-footer">
    <div>
      <div class="footer-thanks">¡Gracias por su compra!</div>
      <div class="footer-thanks-sub">Este documento es su comprobante de venta.</div>
    </div>
    <div class="footer-id">ID: ${esc(opId)}</div>
  </div>

  <script>
    // Auto-open print dialog. The user can choose "Guardar como PDF"
    // or send to a physical printer.
    window.onload = function () { window.print() }
  </script>

</body>
</html>`
}

// ── Text summary (for WhatsApp / clipboard sharing) ──────────────────────────

export interface ReceiptTextOptions extends ReceiptOptions {
  /**
   * First name of the client, used for the personalised greeting.
   * If omitted or the sale has no named client, the greeting is generic.
   */
  clientFirstName?: string
}

export function generateReceiptText(
  op: SaleOperation,
  opts: ReceiptTextOptions,
): string {
  const biz   = opts.businessName || "Mi Negocio"
  const num   = receiptNumber(op)
  const date  = capitalise(longDate(op.date))
  const lines: string[] = []

  // ── Personalised greeting ──────────────────────────────────────────────────
  const firstName = opts.clientFirstName?.split(" ")[0].trim()
  const hasClient = op.clientName && op.clientName !== "Consumidor Final"

  if (firstName) {
    lines.push(`Hola ${firstName} 👋`)
    lines.push("")
    lines.push(`Te enviamos el comprobante de tu compra en *${biz}*.`)
  } else {
    lines.push(`🧾 *Comprobante de Venta — ${biz}*`)
  }

  lines.push("")
  lines.push(`📋 *Comprobante N° ${num}*`)
  lines.push(`📅 ${date}`)

  if (hasClient && !firstName) {
    lines.push(`👤 ${op.clientName}`)
  }

  // ── Items detail ──────────────────────────────────────────────────────────
  lines.push("")
  lines.push("*Detalle de la compra:*")
  for (const item of op.items) {
    const sub = formatMoney(item.total, op.currency as Currency)
    lines.push(`  • ${item.productName} x${item.quantity} → ${sub}`)
  }

  // ── Total ─────────────────────────────────────────────────────────────────
  lines.push("")
  lines.push(`💰 *TOTAL: ${formatMoney(op.total, op.currency as Currency)}*`)

  // ── Business contact ──────────────────────────────────────────────────────
  if (opts.businessPhone || opts.businessEmail) {
    lines.push("")
    lines.push("📞 Contacto:")
    if (opts.businessPhone) lines.push(`  ${opts.businessPhone}`)
    if (opts.businessEmail) lines.push(`  ${opts.businessEmail}`)
  }

  lines.push("")
  lines.push("¡Gracias por tu compra! 🙌")

  return lines.join("\n")
}

// ── Short WhatsApp message (the PDF carries the detail) ──────────────────────

/**
 * Mensaje corto para WhatsApp cuando se adjunta el PDF: saludo + negocio +
 * agradecimiento, sin el detalle (que va en el comprobante PDF adjunto).
 */
export function generateReceiptShortText(
  op: SaleOperation,
  opts: ReceiptTextOptions,
): string {
  const biz = opts.businessName || "Mi Negocio"
  const firstName = opts.clientFirstName?.split(" ")[0].trim()
  const lines: string[] = []

  if (firstName) {
    lines.push(`Hola ${firstName} 👋`)
    lines.push("")
  }
  lines.push(`Te enviamos el comprobante de tu compra en *${biz}*.`)
  lines.push("")
  lines.push("¡Gracias por tu compra! 🙌")

  return lines.join("\n")
}

// ── Payload for the backend sales-receipt PDF endpoint ───────────────────────

export interface SalesReceiptPdfPayload {
  business_name: string
  receipt_number: string
  date_label: string
  items: { name: string; quantity: string; unit_price: string; subtotal: string }[]
  total: string
  currency: string
  client_name?: string | null
  business_phone?: string | null
  business_email?: string | null
}

export function buildSalesReceiptPdfPayload(
  op: SaleOperation,
  opts: ReceiptOptions,
): SalesReceiptPdfPayload {
  const hasClient = op.clientName && op.clientName !== "Consumidor Final"
  return {
    business_name:  opts.businessName || "Mi Negocio",
    receipt_number: receiptNumber(op),
    date_label:     capitalise(longDate(op.date)),
    items: op.items.map((i) => ({
      name:       i.productName,
      quantity:   String(i.quantity),
      unit_price: String(i.unitPrice),
      subtotal:   String(i.total),
    })),
    total:          String(op.total),
    currency:       op.currency,
    client_name:    hasClient ? op.clientName : null,
    business_phone: opts.businessPhone ?? null,
    business_email: opts.businessEmail ?? null,
  }
}
