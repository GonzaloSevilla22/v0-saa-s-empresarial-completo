/**
 * auth-hardening-jwt-cookies — Parte C, task 18.4 (soporte).
 *
 * Al mover las operaciones de auth al servidor, el `emailRedirectTo` deja de
 * poder salir de `window.location.origin`. La resolución existía **cuatro
 * veces** copiada —`contexts/auth-context.tsx:219-226`,
 * `app/auth/forgot-password/page.tsx:22-27`,
 * `app/auth/verify-email/page.tsx:39-42` y `app/auth/callback/route.ts:48-50`,
 * esta última con una regla distinta de las otras tres— así que en vez de
 * escribir una quinta se extrae una sola, pura y testeable, con la regla del
 * callback (que es la que ya corre en el servidor).
 *
 * Regla de la que parte: el origen de la petición manda, **salvo** en local,
 * donde se prefiere `NEXT_PUBLIC_SITE_URL` si está — así el enlace por email de
 * un stack local apunta a donde el desarrollador puede abrirlo.
 */
import { describe, it, expect } from "vitest"
import { isLocalOrigin, resolveSiteUrl } from "@/lib/auth/site-url"

describe("resolveSiteUrl", () => {
  it("en producción manda el origen de la petición", () => {
    expect(resolveSiteUrl("https://aliadata.com.ar", "https://otro.example")).toBe(
      "https://aliadata.com.ar",
    )
  })

  it("y un preview de Vercel también resuelve a su propio origen", () => {
    expect(
      resolveSiteUrl("https://v0-saa-s-empresarial-completo-eie-abc123.vercel.app", undefined),
    ).toBe("https://v0-saa-s-empresarial-completo-eie-abc123.vercel.app")
  })

  it("en local prefiere NEXT_PUBLIC_SITE_URL (misma regla que el callback)", () => {
    expect(resolveSiteUrl("http://localhost:3000", "http://127.0.0.1:3000")).toBe(
      "http://127.0.0.1:3000",
    )
  })

  it("en local sin NEXT_PUBLIC_SITE_URL se queda con el origen", () => {
    expect(resolveSiteUrl("http://localhost:3000", undefined)).toBe("http://localhost:3000")
    expect(resolveSiteUrl("http://localhost:3000", "")).toBe("http://localhost:3000")
  })

  it("sin origen cae a NEXT_PUBLIC_SITE_URL y, sin ella, al localhost de desarrollo", () => {
    expect(resolveSiteUrl(null, "https://aliadata.com.ar")).toBe("https://aliadata.com.ar")
    expect(resolveSiteUrl(null, undefined)).toBe("http://localhost:3000")
  })

  it("nunca devuelve barra final (se le concatena un path)", () => {
    expect(resolveSiteUrl("https://aliadata.com.ar/", undefined)).toBe("https://aliadata.com.ar")
    expect(resolveSiteUrl(null, "https://aliadata.com.ar/")).toBe("https://aliadata.com.ar")
  })
})

describe("isLocalOrigin", () => {
  it("reconoce localhost y 127.0.0.1, con y sin puerto", () => {
    expect(isLocalOrigin("http://localhost:3000")).toBe(true)
    expect(isLocalOrigin("http://localhost")).toBe(true)
    expect(isLocalOrigin("http://127.0.0.1:54321")).toBe(true)
  })

  it("y NO se deja engañar por un host que sólo contiene 'localhost'", () => {
    // El `origin.includes('localhost')` que tenía el callback daba `true` para
    // esto. No era explotable ahí (el origen lo pone el servidor, no el
    // atacante), pero la comprobación correcta es por hostname y cuesta lo
    // mismo.
    expect(isLocalOrigin("https://localhost.evil.example")).toBe(false)
    expect(isLocalOrigin("https://mi-localhost.com.ar")).toBe(false)
  })

  it("un valor que no es URL no es local", () => {
    expect(isLocalOrigin("")).toBe(false)
    expect(isLocalOrigin("no-una-url")).toBe(false)
  })
})
