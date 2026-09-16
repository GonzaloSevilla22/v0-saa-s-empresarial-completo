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
import { safeNext, resolveSafeRedirect, DEFAULT_NEXT } from "@/lib/auth/safe-next"

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

// ── Revisión adversarial de la Parte B (BLOCKER 1) ─────────────────────────
// El parser WHATWG de URL **borra** tabulador, salto de línea y retorno de
// carro del input ANTES de parsear, así que `/\t/evil.example` es idéntico a
// `//evil.example` para `new URL()`. Medido en el node de este repo:
//
//   new URL("/\t/evil.example", "https://app.test/auth/login").href
//     → "https://evil.example/"
//
// El criterio "segundo carácter distinto de / y \" no lo veía, y la Parte B
// cambió `url.pathname = next` (cuyo setter NO puede cambiar el host) por
// `new URL(next, base)` (que sí) — así que la validación tiene que cubrirlo.
describe("safeNext — caracteres de control que el parser de URL borra", () => {
  it.each([
    "/\t/evil.example",
    "/\n/evil.example",
    "/\r/evil.example",
    "/\t\\evil.example",
    "/caja\nHeader-Inyectado: 1",
    "\t//evil.example",
  ])("%j resuelve a la ruta principal", (next) => {
    expect(safeNext(next)).toBe(DEFAULT_NEXT)
  })

  it("el detector no es vacuo: sin el filtro, el destino colapsa en otro host", () => {
    // Control diferencial del caso de arriba: si `safeNext` devolviera el valor
    // crudo, esto es lo que el navegador recibiría en el header `Location`.
    expect(new URL("/\t/evil.example", "https://app.test/auth/login").origin).toBe(
      "https://evil.example",
    )
    // Y con el criterio anterior al filtro (sólo mirar `next[1]`), pasaba:
    expect("/\t/evil.example"[1]).not.toBe("/")
    expect("/\t/evil.example"[1]).not.toBe("\\")
  })
})

// ── resolveSafeRedirect: defensa en profundidad en los consumidores ─────────
// `safeNext()` decide sobre la cadena; `resolveSafeRedirect()` decide sobre la
// URL ya resuelta contra la base, que es la que viaja en `Location`. Los dos
// consumidores del middleware y del callback usan éste, para que ninguna forma
// futura de colapso de host pueda salir del sitio.
describe("resolveSafeRedirect — el resultado nunca sale del origen", () => {
  const BASE = "https://app.test/auth/login?next=x"

  it.each([
    "/\t/evil.example",
    "//evil.example",
    "https://evil.example/",
    "@evil.example/",
    "/\\evil.example",
  ])("%j resuelve dentro del propio origen", (next) => {
    const url = resolveSafeRedirect(next, BASE)
    expect(url.origin).toBe("https://app.test")
    expect(url.pathname).toBe(DEFAULT_NEXT)
  })

  it("conserva el destino interno con su query y su fragmento", () => {
    const url = resolveSafeRedirect("/reportes/comparativo?desde=2026-01-01", BASE)
    expect(url.origin).toBe("https://app.test")
    expect(url.pathname).toBe("/reportes/comparativo")
    expect(url.searchParams.get("desde")).toBe("2026-01-01")
  })

  it("admite un fallback propio", () => {
    expect(resolveSafeRedirect("//evil.example", BASE, "/planes").pathname).toBe("/planes")
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
