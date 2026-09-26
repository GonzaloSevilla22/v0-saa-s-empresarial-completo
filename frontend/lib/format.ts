export type Currency = "ARS" | "USD" | "EUR" | "BRL"

export const CURRENCIES: { value: Currency; label: string; symbol: string }[] = [
  { value: "ARS", label: "Peso Argentino", symbol: "$" },
  { value: "USD", label: "Dolar Estadounidense", symbol: "US$" },
  { value: "EUR", label: "Euro", symbol: "EUR" },
  { value: "BRL", label: "Real Brasileno", symbol: "R$" },
]

const MONEY_FORMAT: Record<Currency, { locale: string; currency: string }> = {
  ARS: { locale: "es-AR", currency: "ARS" },
  USD: { locale: "en-US", currency: "USD" },
  EUR: { locale: "de-DE", currency: "EUR" },
  BRL: { locale: "pt-BR", currency: "BRL" },
}

export function formatMoney(value: number, currency: Currency = "ARS"): string {
  const c = MONEY_FORMAT[currency]
  return new Intl.NumberFormat(c.locale, {
    style: "currency",
    currency: c.currency,
    minimumFractionDigits: 0,
    maximumFractionDigits: 2,
  }).format(value)
}

/**
 * ventas-unidades-conversion (cuarta revisión, D-F′): precio UNITARIO de una
 * línea con la precisión que tiene. Con D-F el precio es por unidad de la
 * línea — $4.575/kg vendido en gramos es $4,575/g — y `formatMoney` lo
 * cortaba en 2 decimales ("100 g × $4,58 = $457,50"). Un precio al centavo
 * sale idéntico a `formatMoney`; uno sub-centavo, con hasta 5 decimales (la
 * precisión que `roundUnitPrice` conserva) y sin ruido binario. Para
 * IMPORTES (subtotal, total) sigue siendo `formatMoney`.
 *
 * @example
 * formatUnitPrice(4.575)    → "$ 4,575"
 * formatUnitPrice(1.23456)  → "$ 1,23456"
 * formatUnitPrice(1800)     → "$ 1.800"   (igual que formatMoney)
 */
export function formatUnitPrice(value: number, currency: Currency = "ARS"): string {
  const cents = value * 100
  if (!Number.isFinite(value) || Math.abs(cents - Math.round(cents)) < 1e-6) {
    return formatMoney(value, currency)
  }
  const c = MONEY_FORMAT[currency]
  return new Intl.NumberFormat(c.locale, {
    style: "currency",
    currency: c.currency,
    minimumFractionDigits: 2,
    maximumFractionDigits: 5,
  }).format(value)
}

/**
 * Número en es-AR ("1.234,56"). `maximumFractionDigits` opcional: el default
 * de Intl es 3 — una cantidad de stock con 4 decimales (numeric(15,4)) se
 * muestra sin redondear pasando 4.
 */
export function formatNumber(value: number, maximumFractionDigits?: number): string {
  return new Intl.NumberFormat(
    "es-AR",
    maximumFractionDigits === undefined ? undefined : { maximumFractionDigits },
  ).format(value)
}

/**
 * Convierte el `yyyy-mm-dd` de un `<input type="date">` (que el usuario leyó
 * y eligió en SU zona horaria) al instante ISO del FINAL de ese día LOCAL.
 *
 * v3-rbac-multirole Parte C (ronda 1 adversarial): el camino obvio
 * —`new Date("2026-12-31").toISOString()`— interpreta el `yyyy-mm-dd` como
 * medianoche **UTC**, así que en ART (UTC-3) el instante resultante cae el
 * **30/12 a las 21:00**. Reproducido en vivo en /organizacion/roles: eligiendo
 * "31/12/2026" en el selector, el badge quedaba "Compras hasta 30/12/2026" —
 * un día menos del que el administrador concedió, y un valor en pantalla
 * distinto del que acababa de tipear.
 *
 * Se ancla al FINAL del día local (23:59:59.999) para que "vence el 31/12"
 * signifique "tiene acceso durante todo el 31/12", que es como se lee la
 * etiqueta "Vencimiento" y el badge "hasta {fecha}".
 */
export function localDateEndOfDayISO(yyyyMmDd: string): string {
  const [y, m, d] = yyyyMmDd.split("-").map(Number)
  return new Date(y, m - 1, d, 23, 59, 59, 999).toISOString()
}

/**
 * Fecha corta es-AR (dd/mm/aaaa) a partir de:
 *   - una FECHA DE NEGOCIO sin hora ("2026-09-12") → se ancla al mediodía
 *     LOCAL, nunca a la medianoche UTC (que la correría un día atrás en ART);
 *   - un INSTANTE ISO completo ("2026-09-12T03:25:24.042661Z") → se parsea
 *     tal cual y se muestra en la zona del usuario.
 *
 * v3-rbac-multirole Parte C (ronda 1 adversarial): antes concatenaba
 * `"T12:00:00"` SIEMPRE, así que cualquier instante completo producía
 * "2026-09-12T03:25:24.042661ZT12:00:00" → `Invalid Date` en pantalla.
 * Reproducido en vivo en /organizacion/roles ("Desde Invalid Date",
 * "Cajero hasta Invalid Date"); alcanzaba también a /exportaciones y
 * /admin/pagos, que ya pasaban `created_at`/`createdAt` completos.
 *
 * Ronda 2 adversarial (finding NIT, corregido): este JSDoc vivía ENCIMA de
 * `localDateEndOfDayISO` (el bloque quedaba huérfano, sin asociarse a
 * ninguna función) mientras `formatDate` — la función que de verdad cambió
 * de comportamiento y que consume media app — se quedaba sin documentación.
 * Reordenado para que cada bloque preceda a la función que describe.
 */
export function formatDate(dateStr: string): string {
  // Defensa: el cuerpo viejo concatenaba sobre `dateStr` sin mirarlo, así que
  // un `undefined`/`null` de un caller mal tipado degradaba a "Invalid Date"
  // sin romper el render. Al pasar a `dateStr.includes(...)` eso se volvería
  // un TypeError que tumba la página entera — lo detectó la suite completa
  // (`ExportacionesPage.test.tsx` monta la tabla con filas sin `createdAt`).
  // Se conserva el no-lanzar, devolviendo el guion del proyecto para vacío.
  if (typeof dateStr !== "string" || dateStr === "") return "—"
  const parsed = dateStr.includes("T")
    ? new Date(dateStr)
    : new Date(dateStr + "T12:00:00")
  return parsed.toLocaleDateString("es-AR", {
    day: "2-digit",
    month: "2-digit",
    year: "numeric",
  })
}
