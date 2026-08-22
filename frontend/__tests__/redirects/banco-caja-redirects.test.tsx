/**
 * banco-caja-historial-ajustes (D8) — las rutas viejas quedan como
 * redirects de servidor (Server Component, `redirect()` de Next — no
 * `useEffect`, sin pantalla intermedia, task 8.5/9.4).
 */
import { describe, it, expect, vi, beforeEach } from "vitest"

const mockRedirect = vi.fn()

vi.mock("next/navigation", () => ({
  redirect: (url: string) => mockRedirect(url),
}))

beforeEach(() => {
  mockRedirect.mockClear()
})

describe("/sucursales/[id]/caja → /caja?branch=<id>", () => {
  it("redirige preservando el id de sucursal", async () => {
    const { default: Page } = await import(
      "@/app/(dashboard)/sucursales/[id]/caja/page"
    )
    await Page({ params: Promise.resolve({ id: "branch-123" }) })
    expect(mockRedirect).toHaveBeenCalledWith("/caja?branch=branch-123")
  })

  it("no renderiza ninguna pantalla intermedia (Server Component puro)", async () => {
    const { default: Page } = await import(
      "@/app/(dashboard)/sucursales/[id]/caja/page"
    )
    const result = await Page({ params: Promise.resolve({ id: "branch-456" }) })
    // redirect() no devuelve JSX — el componente delega 100% en la redirección.
    expect(result).toBeUndefined()
  })
})

describe("/finanzas/conciliacion → /banco?tab=conciliacion", () => {
  it("redirige a la tab de conciliación del módulo Banco", async () => {
    const { default: Page } = await import(
      "@/app/(dashboard)/finanzas/conciliacion/page"
    )
    Page()
    expect(mockRedirect).toHaveBeenCalledWith("/banco?tab=conciliacion")
  })
})
