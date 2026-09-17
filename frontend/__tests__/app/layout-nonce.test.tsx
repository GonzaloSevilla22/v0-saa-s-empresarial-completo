/**
 * auth-hardening-jwt-cookies — Parte C, D3, task 21.7.
 *
 * `next-themes` inyecta un `<script>` en línea para evitar el parpadeo de tema
 * (`next-themes/dist/index.js`: `nonce: typeof window === "undefined" ? m : ""`) y,
 * con `disableTransitionOnChange` —que esta app activa—, también un `<style>` con
 * nonce. Bajo `'strict-dynamic'` sin `'unsafe-inline'`, ese script **sin nonce**
 * no se ejecuta: la página carga en claro y recién al hidratar salta a oscuro. Es
 * el parpadeo que el `defaultTheme` leído de la cookie existe para evitar.
 *
 * `components/theme-provider.tsx` es `"use client"` y sólo propaga props: no puede
 * leer los encabezados. Por eso el nonce se lee con `headers()` en el layout raíz
 * —que corre en el servidor— y baja por la prop `nonce`.
 *
 * El árbol se inspecciona sin renderizar: el layout devuelve `<html>`, y lo que
 * esta task tiene que fijar es que el valor **llega como prop**, no cómo se pinta.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import React from "react"

const headerValues = new Map<string, string>()

vi.mock("next/headers", () => ({
  cookies: async () => ({ get: (name: string) => (name === "ui:theme" ? { value: "dark" } : undefined) }),
  headers: async () => ({ get: (name: string) => headerValues.get(name.toLowerCase()) ?? null }),
}))

vi.mock("next/font/google", () => ({
  Geist: () => ({ className: "geist" }),
  Geist_Mono: () => ({ className: "geist-mono" }),
}))

vi.mock("@/components/theme-provider", () => ({
  ThemeProvider: ({ children }: { children: React.ReactNode }) => <>{children}</>,
}))

vi.mock("@/components/theme-sync", () => ({ ThemeSync: () => null }))
vi.mock("@/providers/query-provider", () => ({
  QueryProvider: ({ children }: { children: React.ReactNode }) => <>{children}</>,
}))
vi.mock("@/contexts/auth-context", () => ({
  AuthProvider: ({ children }: { children: React.ReactNode }) => <>{children}</>,
}))
vi.mock("sonner", () => ({ Toaster: () => null }))

import RootLayout from "@/app/layout"
import { ThemeProvider } from "@/components/theme-provider"

/** Props del primer elemento de ese tipo en el árbol devuelto. */
function findProps(node: React.ReactNode, type: unknown): Record<string, unknown> | null {
  if (!node || typeof node !== "object") return null
  if (Array.isArray(node)) {
    for (const child of node) {
      const found = findProps(child, type)
      if (found) return found
    }
    return null
  }
  const element = node as React.ReactElement<{ children?: React.ReactNode }>
  if (!("props" in element)) return null
  if (element.type === type) return element.props as Record<string, unknown>
  return findProps(element.props?.children, type)
}

beforeEach(() => {
  headerValues.clear()
})

describe("app/layout.tsx — nonce hacia next-themes (task 21.7)", () => {
  it("pasa el nonce del encabezado `x-nonce` al proveedor de temas", async () => {
    headerValues.set("x-nonce", "n0nc3-de-esta-peticion")

    const props = findProps(await RootLayout({ children: <div /> }), ThemeProvider)

    expect(props).not.toBeNull()
    expect(props!.nonce).toBe("n0nc3-de-esta-peticion")
    // Y sigue leyendo el tema de la cookie: el nonce no puede haberse llevado por
    // delante el render inicial que evita el parpadeo.
    expect(props!.defaultTheme).toBe("dark")
    expect(props!.disableTransitionOnChange).toBe(true)
  })

  it("sin encabezado no inventa un nonce: la prop queda ausente", async () => {
    const props = findProps(await RootLayout({ children: <div /> }), ThemeProvider)

    // Un nonce inventado en el layout NO coincidiría con el de la política de la
    // respuesta, y el navegador bloquearía el script igual — pero el fallo se
    // volvería invisible en el árbol. `undefined` deja que `next-themes` no emita
    // el atributo, que es el comportamiento honesto.
    expect(props).not.toBeNull()
    expect(props!.nonce).toBeUndefined()
  })
})
