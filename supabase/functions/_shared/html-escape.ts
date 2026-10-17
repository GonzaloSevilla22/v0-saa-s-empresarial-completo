// Shared HTML-escaping helpers for Edge Functions — email-logs-cierre-insert
// (OQ-7 de multiusuario-operativo, governance CRÍTICO).
//
// Why this exists: the `send-email` templates interpolated `metadata.*` straight
// into the HTML they hand to Resend. `metadata` ends up holding data a user
// authored (a business name at sign-up, a product name, a community notice
// title), so a name such as `<a href="https://evil.example">Verificá tu
// cuenta</a>` was rendered as live markup inside an email sent from
// no-reply@aliadata.com.ar. Every value that does not come from a constant in
// the code goes through `escapeHtml` before it is placed in an HTML slot.
//
// D5/D6 pattern (same as email-fanout-policy.ts): pure and injectable — ZERO
// references to `Deno.*` at module scope — so vitest imports the REAL file by
// relative path (frontend/__tests__/send-email-templates.test.ts).

const HTML_ESCAPES: Record<string, string> = {
  "&": "&amp;",
  "<": "&lt;",
  ">": "&gt;",
  '"': "&quot;",
  "'": "&#39;",
  "`": "&#96;",
}

/**
 * Escapes a value for use as TEXT or as a double/single-quoted ATTRIBUTE value
 * in HTML. `null`/`undefined` become the empty string; anything that is not a
 * string is converted with `String()` first (numbers, booleans, objects), so a
 * caller can never smuggle markup through a non-string `metadata` field.
 */
export function escapeHtml(value: unknown): string {
  if (value === null || value === undefined) return ""
  return String(value).replace(/[&<>"'`]/g, (ch) => HTML_ESCAPES[ch])
}

/**
 * Reduces an arbitrary value to something safe to embed in a file name: only
 * letters, digits, `_` and `-`, at most `maxLength` characters. Returns
 * `fallback` when nothing usable remains. Prevents path separators, quotes,
 * control characters and `..` from reaching an attachment name.
 */
export function safeFilenamePart(value: unknown, fallback: string, maxLength = 40): string {
  const cleaned = String(value ?? "").replace(/[^A-Za-z0-9_-]/g, "").slice(0, maxLength)
  return cleaned.length > 0 ? cleaned : fallback
}
