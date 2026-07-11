/**
 * Tests for the contextual "Ver tutorial" button in BreadcrumbNav
 * (frontend/components/dashboard/breadcrumb-nav.tsx) — appears only on
 * routes that have a tutorial with an available video in the catalog.
 *
 * The real catalog (frontend/lib/tutorials.ts) ships today with every
 * youtubeVideoId set to null (OQ1 — videos not recorded yet), so the
 * "shows the button" case is exercised here against a mocked catalog entry
 * that does have a video id; `getTutorialByPathname` itself stays real.
 *
 * Cycle: RED → GREEN → TRIANGULATE
 */

import { describe, it, expect, vi, beforeEach, beforeAll } from "vitest"
import { render, screen } from "@testing-library/react"
import { SidebarProvider } from "@/components/ui/sidebar"
import type { Tutorial } from "@/lib/tutorials"

// jsdom no implementa matchMedia; lo necesitan SidebarProvider (use-mobile) y
// ResponsiveModal (useIsMobile) para decidir su layout responsive.
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
const mockGetTutorialByPathname = vi.fn<(pathname: string) => Tutorial | undefined>()

vi.mock("next/navigation", () => ({
  usePathname: () => mockUsePathname(),
}))

// Aísla el test del árbol real de NotificationBell (React Query + Supabase
// Realtime) — no es lo que este test verifica.
vi.mock("@/components/dashboard/NotificationBell", () => ({
  NotificationBell: () => <div data-testid="notification-bell" />,
}))

// Aísla el test del player real de YouTube.
vi.mock("@next/third-parties/google", () => ({
  YouTubeEmbed: () => <div data-testid="youtube-embed" />,
}))

// Controla el lookup de tutorial por ruta; hasTutorialVideo se mantiene real
// (es pura y trivial: youtubeVideoId !== null).
vi.mock("@/lib/tutorials", async () => {
  const actual = await vi.importActual<typeof import("@/lib/tutorials")>("@/lib/tutorials")
  return {
    ...actual,
    getTutorialByPathname: (pathname: string) => mockGetTutorialByPathname(pathname),
  }
})

import { BreadcrumbNav } from "@/components/dashboard/breadcrumb-nav"

function renderBreadcrumbNav() {
  return render(
    <SidebarProvider>
      <BreadcrumbNav />
    </SidebarProvider>
  )
}

describe("BreadcrumbNav — botón contextual 'Ver tutorial'", () => {
  beforeEach(() => {
    mockUsePathname.mockReset()
    mockGetTutorialByPathname.mockReset()
  })

  // ── RED → GREEN: ruta sin tutorial en el catálogo → no hay botón ──────
  it("no muestra el botón cuando la ruta no tiene tutorial en el catálogo", () => {
    mockUsePathname.mockReturnValue("/dashboard")
    mockGetTutorialByPathname.mockReturnValue(undefined)
    renderBreadcrumbNav()
    expect(screen.queryByRole("button", { name: /ver tutorial/i })).not.toBeInTheDocument()
  })

  // ── TRIANGULATE: tutorial existe pero youtubeVideoId es null → sigue sin botón ──
  it("no muestra el botón cuando el tutorial de la ruta todavía no tiene video (youtubeVideoId null)", () => {
    mockUsePathname.mockReturnValue("/ventas")
    mockGetTutorialByPathname.mockReturnValue({
      moduleKey: "ventas",
      title: "Cómo registrar una venta",
      description: "desc",
      durationLabel: "3 min",
      youtubeVideoId: null,
      pathname: "/ventas",
    })
    renderBreadcrumbNav()
    expect(screen.queryByRole("button", { name: /ver tutorial/i })).not.toBeInTheDocument()
  })

  // ── TRIANGULATE: tutorial con video disponible → muestra el botón ──────
  it("muestra el botón 'Ver tutorial' cuando la ruta tiene un tutorial con video disponible", () => {
    mockUsePathname.mockReturnValue("/ventas")
    mockGetTutorialByPathname.mockReturnValue({
      moduleKey: "ventas",
      title: "Cómo registrar una venta",
      description: "desc",
      durationLabel: "3 min",
      youtubeVideoId: "dQw4w9WgXcQ",
      pathname: "/ventas",
    })
    renderBreadcrumbNav()
    expect(screen.getByRole("button", { name: /ver tutorial/i })).toBeInTheDocument()
  })
})
