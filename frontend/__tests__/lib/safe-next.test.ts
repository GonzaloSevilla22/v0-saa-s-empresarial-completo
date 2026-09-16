/**
 * auth-hardening-jwt-cookies — D5, task 13.1.
 *
 * `safeNext()` es la ÚNICA validación del destino de retorno. Antes de este
 * change existían dos criterios distintos para el mismo parámetro:
 *   - el middleware validaba (`url.pathname = next.startsWith("/") ? next : "/dashboard"`),
 *   - `app/auth/callback/route.ts` concatenaba sin validar (`${siteUrl}${next}`),
 *     un open redirect latente: `@evil.example/` cambia el host.
 *
 * Ningún productor del repo alimenta hoy `next` con input del usuario, pero el
 * contraste entre dos caminos con criterios distintos es exactamente cómo nace
 * el bug.
 */
import { describe, it, expect } from "vitest"
import { safeNext, DEFAULT_NEXT } from "@/lib/auth/safe-next"

describe("safeNext — destinos externos se descartan", () => {
  it.each([
    "@evil.example/",
    "//evil.example",
    "//evil.example/path",
    "\\\\evil.example",
    "/\\evil.example",
    "https://evil.example/",
    "http://evil.example/",
    "javascript:alert(1)",
    "evil.example",
    "dashboard",
  ])("%j resuelve a la ruta principal", (next) => {
    expect(safeNext(next)).toBe(DEFAULT_NEXT)
  })

  it("una barra invertida detrás de la barra inicial no cuela (los navegadores la normalizan como //)", () => {
    expect(safeNext("/\\/evil.example")).toBe(DEFAULT_NEXT)
  })

  it("ausente, vacío o nulo resuelve a la ruta principal", () => {
    expect(safeNext(null)).toBe(DEFAULT_NEXT)
    expect(safeNext(undefined)).toBe(DEFAULT_NEXT)
    expect(safeNext("")).toBe(DEFAULT_NEXT)
  })
})

describe("safeNext — destinos internos se conservan", () => {
  it.each([
    "/dashboard",
    "/caja",
    "/ventas/ordenes/2b9f4f5e-0000-4000-8000-000000000000",
    "/reportes/comparativo?desde=2026-01-01&hasta=2026-01-31",
    "/estadisticas#ranking",
    "/",
  ])("%j se conserva tal cual", (next) => {
    expect(safeNext(next)).toBe(next)
  })
})

describe("safeNext — fallback explícito", () => {
  it("admite un fallback propio para quien no quiera el dashboard", () => {
    expect(safeNext("//evil.example", "/planes")).toBe("/planes")
  })

  it("el fallback sólo aplica cuando el destino se descarta", () => {
    expect(safeNext("/caja", "/planes")).toBe("/caja")
  })
})
