/**
 * qa-integral-modulos G13 / H17: el breadcrumb decía "ALIADATA" en 11 de 24
 * rutas (incluidas Caja, Banco y Sucursales) — en móvil, con el menú cerrado,
 * ese breadcrumb es lo único que indica dónde estás.
 *
 * Contrato (spec responsive-shell):
 *  - Las rutas del dashboard tienen nombre propio en PAGE_NAMES.
 *  - Una ruta no mapeada NO muestra el literal "ALIADATA": cae a un fallback
 *    legible derivado del último segmento de la URL.
 *
 * Cycle: RED → GREEN → TRIANGULATE
 */

import { describe, it, expect, vi, beforeEach, beforeAll } from "vitest"
import { render, screen } from "@testing-library/react"
import { SidebarProvider } from "@/components/ui/sidebar"

beforeAll(() => {
  window.matchMedia = (query: string): MediaQueryList =>
    ({
      matches: false,
      media: query,
      onchange: null,
      addEventListener: () => {},
      removeEventListener: () => {},
      addListener: () => {},
      removeListener: () => {},
      dispatchEvent: () => false,
    }) as MediaQueryList
})

const mockUsePathname = vi.fn()

vi.mock("next/navigation", () => ({
  usePathname: () => mockUsePathname(),
}))

vi.mock("@/components/dashboard/NotificationBell", () => ({
  NotificationBell: () => <div data-testid="notification-bell" />,
}))

import { BreadcrumbNav } from "@/components/dashboard/breadcrumb-nav"

function renderAt(pathname: string) {
  mockUsePathname.mockReturnValue(pathname)
  return render(
    <SidebarProvider>
      <BreadcrumbNav />
    </SidebarProvider>,
  )
}

describe("BreadcrumbNav — nombres de página (H17)", () => {
  beforeEach(() => {
    mockUsePathname.mockReset()
  })

  // Las 11 rutas que el QA midió cayendo al literal "ALIADATA", con el nombre
  // que ya usan la entrada de menú / el h1 de cada pantalla.
  const RUTAS_FALTANTES: Array<[string, string]> = [
    ["/ventas/pos", "POS — Venta Rápida"],
    ["/caja", "Caja"],
    ["/banco", "Banco"],
    ["/sucursales", "Sucursales"],
    ["/reportes/formas-pago", "Formas de pago"],
    ["/reportes/centros-costo", "Centros de costo"],
    ["/rentabilidad", "Rentabilidad"],
    ["/planes", "Planes"],
    ["/facturacion", "Facturación"],
    ["/exportaciones", "Exportaciones"],
    ["/configuracion/fiscal", "Configuración fiscal"],
  ]

  it.each(RUTAS_FALTANTES)("%s muestra «%s», no ALIADATA", (ruta, nombre) => {
    renderAt(ruta)
    expect(screen.getByText(nombre)).toBeInTheDocument()
    expect(screen.queryByText("ALIADATA")).not.toBeInTheDocument()
  })

  // TRIANGULATE: rutas hermanas de reportes que tampoco estaban mapeadas
  it.each([
    ["/reportes/comparativo", "Comparativo"],
    ["/reportes/sucursal", "Por Sucursal"],
  ] as Array<[string, string]>)("%s muestra «%s»", (ruta, nombre) => {
    renderAt(ruta)
    expect(screen.getByText(nombre)).toBeInTheDocument()
  })

  // TRIANGULATE: fallback legible — nunca el literal de marca
  it("una ruta no mapeada deriva un nombre legible del último segmento", () => {
    renderAt("/modulo-nuevo/detalle-final")
    expect(screen.queryByText("ALIADATA")).not.toBeInTheDocument()
    expect(screen.getByText("Detalle final")).toBeInTheDocument()
  })

  // Las rutas ya mapeadas no cambian
  it("las rutas ya mapeadas conservan su nombre", () => {
    renderAt("/ventas")
    expect(screen.getByText("Ventas")).toBeInTheDocument()
  })
})
