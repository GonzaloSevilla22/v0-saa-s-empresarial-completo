export type Currency = "ARS" | "USD" | "EUR" | "BRL"

export const CURRENCIES: { value: Currency; label: string; symbol: string }[] = [
  { value: "ARS", label: "Peso Argentino", symbol: "$" },
  { value: "USD", label: "Dolar Estadounidense", symbol: "US$" },
  { value: "EUR", label: "Euro", symbol: "EUR" },
  { value: "BRL", label: "Real Brasileno", symbol: "R$" },
]

export function formatMoney(value: number, currency: Currency = "ARS"): string {
  const config: Record<Currency, { locale: string; currency: string }> = {
    ARS: { locale: "es-AR", currency: "ARS" },
    USD: { locale: "en-US", currency: "USD" },
    EUR: { locale: "de-DE", currency: "EUR" },
    BRL: { locale: "pt-BR", currency: "BRL" },
  }
  const c = config[currency]
  return new Intl.NumberFormat(c.locale, {
    style: "currency",
    currency: c.currency,
    minimumFractionDigits: 0,
    maximumFractionDigits: 2,
  }).format(value)
}

export function formatNumber(value: number): string {
  return new Intl.NumberFormat("es-AR").format(value)
}

export function formatDate(dateStr: string): string {
  return new Date(dateStr + "T12:00:00").toLocaleDateString("es-AR", {
    day: "2-digit",
    month: "2-digit",
    year: "numeric",
  })
}
