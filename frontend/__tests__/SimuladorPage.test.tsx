/**
 * productos-costo-nullable (task 7.8 RED/GREEN) — /simulador: sin costo
 * cargado, avisa "este producto no tiene costo cargado" y deshabilita la
 * simulación de margen (nunca inventa un margen desde un costo imputado a 0).
 */
import React from "react"
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import { render, screen, waitFor } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import "@testing-library/jest-dom"
import type { Product } from "@/lib/types"

let productsMock: Product[] = []
vi.mock("@/hooks/data/use-products", () => ({ useProducts: () => ({ products: productsMock }) }))
vi.mock("@/hooks/data/use-sales", () => ({ useSales: () => ({ sales: [] }) }))
// task 19.7b: el doble ya no ofrece `auth` (con `accessToken` configurado
// `supabase.auth` LANZA, `supabase-js/index.mjs:389`). El token de la Edge
// Function lo resuelve `getAuthHeaders()`.
vi.mock("@/lib/supabase/client", () => ({ createClient: () => ({}) }))

// task 19.11: el Bearer de `ai-simulador` sale del store, por el helper compartido.
const resolveAccessTokenMock = vi.hoisted(() => vi.fn())
vi.mock("@/lib/auth/access-token-store", () => ({
  resolveAccessToken: () => resolveAccessTokenMock(),
}))

const { default: SimuladorPage } = await import("@/app/(dashboard)/simulador/page")

function product(overrides: Partial<Product>): Product {
  return {
    id: "p-1", name: "Producto", category: "General", categoryId: null,
    cost: 50, price: 100, margin: 50, stock: 5, minStock: 1,
    isVariant: false, stockControlType: "tracked",
    ...overrides,
  }
}

describe("/simulador — costo opcional", () => {
  it("un producto sin costo cargado avisa y no muestra un margen inventado", () => {
    productsMock = [product({ id: "sin-costo", name: "Sin Costo", cost: null })]
    render(<SimuladorPage />)
    expect(screen.getByText(/este producto no tiene costo cargado/i)).toBeInTheDocument()
    // Ningún margen (ni "0%" ni el 100% que ((price-0)/price) produciría).
    expect(screen.queryByText("100%")).not.toBeInTheDocument()
  })

  it("un producto con costo real muestra el margen normalmente", () => {
    productsMock = [product({ id: "con-costo", name: "Con Costo", cost: 50, price: 100 })]
    render(<SimuladorPage />)
    expect(screen.queryByText(/este producto no tiene costo cargado/i)).not.toBeInTheDocument()
    expect(screen.getAllByText("50%").length).toBeGreaterThan(0)
  })
})

// ─── auth-hardening-jwt-cookies, Parte C, task 19.11 ─────────────────────────
//
// El `fetch` a mano de esta pantalla existe por una razón que no cambia: mide su
// propio timeout y lee el cuerpo real del error, que `functions.invoke` se traga.
// Lo que cambia es de dónde sale el Bearer.
describe("/simulador — el fetch a mano lleva el Bearer del store", () => {
  const fetchMock = vi.fn()

  beforeEach(() => {
    process.env.NEXT_PUBLIC_SUPABASE_URL = "http://127.0.0.1:54321"
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY = "anon-key-de-prueba"
    productsMock = [product({ id: "p-1", name: "Producto" })]
    fetchMock.mockReset()
    fetchMock.mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => ({ data: { analysis: "listo" } }),
    })
    resolveAccessTokenMock.mockReset()
    resolveAccessTokenMock.mockResolvedValue({ status: "active", token: "tok-simulador" })
    vi.stubGlobal("fetch", fetchMock)
  })

  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it("manda Authorization con el token, y conserva apikey y Content-Type del caller", async () => {
    const user = userEvent.setup()
    render(<SimuladorPage />)

    await user.click(screen.getByRole("button", { name: /pedir análisis ia/i }))

    await waitFor(() => expect(fetchMock).toHaveBeenCalled())
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url).toContain("/functions/v1/ai-simulador")
    const headers = init.headers as Record<string, string>
    expect(headers.Authorization).toBe("Bearer tok-simulador")
    // Los encabezados de auth se aplican ÚLTIMOS, no en lugar de los del caller:
    // sin `apikey` el gateway de Supabase rechaza la llamada.
    expect(headers.apikey).toBe("anon-key-de-prueba")
    expect(headers["Content-Type"]).toBe("application/json")
  })

  it("sin sesión avisa y no llama a la Edge Function", async () => {
    resolveAccessTokenMock.mockResolvedValue({ status: "absent" })
    const user = userEvent.setup()
    render(<SimuladorPage />)

    await user.click(screen.getByRole("button", { name: /pedir análisis ia/i }))

    await waitFor(() => expect(screen.getByText(/tu sesión expiró/i)).toBeInTheDocument())
    expect(fetchMock).not.toHaveBeenCalled()
  })
})
