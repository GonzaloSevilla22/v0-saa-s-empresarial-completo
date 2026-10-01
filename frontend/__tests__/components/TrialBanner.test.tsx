import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import { render, screen } from "@testing-library/react"

// tablero-menu-pulido (P3): el aviso decía "prueba del plan Avanzado" con el
// texto fijo en el componente, aunque la prueba fuera de Pro. Ahora nombra el
// plan REAL de la prueba (`user.trialPlan`) con PLAN_DISPLAY_NAMES, y si la
// cuenta no trae plan de prueba dice sólo "de prueba" (nunca inventa uno).

const h = vi.hoisted(() => ({
  user: null as Record<string, unknown> | null,
}))

vi.mock("@/contexts/auth-context", () => ({
  useAuth: () => ({ user: h.user }),
}))

import { TrialBanner } from "@/components/dashboard/TrialBanner"

// Reloj fijo: 2026-10-01 12:00 ART.
const NOW = new Date("2026-10-01T15:00:00.000Z")
const enDias = (dias: number): string => new Date(NOW.getTime() + dias * 86_400_000).toISOString()

function trialUser(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    billingStatus: "trialing",
    trialPlan: "pro",
    trialExpiresAt: enDias(5),
    ...overrides,
  }
}

describe("TrialBanner — plan real de la prueba (tablero-menu-pulido P3)", () => {
  beforeEach(() => {
    vi.useFakeTimers({ toFake: ["Date"] })
    vi.setSystemTime(NOW)
    h.user = null
  })
  afterEach(() => {
    vi.useRealTimers()
  })

  it("prueba de Pro: dice 'del plan Pro' y no 'Avanzado'", () => {
    h.user = trialUser({ trialPlan: "pro" })
    render(<TrialBanner />)

    expect(screen.getByRole("alert")).toHaveTextContent("Te quedan 5 días de prueba del plan Pro")
    expect(screen.queryByText(/Avanzado/)).toBeNull()
  })

  it("prueba de Avanzado: sigue diciendo 'del plan Avanzado' (el texto sale del plan, no es fijo)", () => {
    h.user = trialUser({ trialPlan: "avanzado" })
    render(<TrialBanner />)

    expect(screen.getByRole("alert")).toHaveTextContent("Te quedan 5 días de prueba del plan Avanzado")
  })

  it("prueba de Inicial con 1 día: singular y plan 'Inicial'", () => {
    h.user = trialUser({ trialPlan: "inicial", trialExpiresAt: enDias(1) })
    render(<TrialBanner />)

    expect(screen.getByRole("alert")).toHaveTextContent("Te queda 1 día de prueba del plan Inicial")
  })

  it("sin plan de prueba (null) no nombra ningún plan: 'de prueba' a secas", () => {
    h.user = trialUser({ trialPlan: null })
    render(<TrialBanner />)

    // Se mira sólo el rótulo del mensaje (el link "Ver planes" también dice "plan").
    const rotulo = screen.getByText(/^Te quedan/)
    expect(rotulo.textContent).toBe("Te quedan 5 días de prueba")
  })

  it.each(["enterprise", "constructor", ""])(
    "un plan de prueba desconocido (%j) tampoco se inventa: 'de prueba' a secas",
    (trialPlan) => {
      h.user = trialUser({ trialPlan })
      render(<TrialBanner />)

      const rotulo = screen.getByText(/^Te quedan/)
      expect(rotulo.textContent).toBe("Te quedan 5 días de prueba")
    },
  )

  it("conserva el link a /planes y el cierre del aviso", () => {
    h.user = trialUser()
    render(<TrialBanner />)

    expect(screen.getByRole("link", { name: "Ver planes" })).toHaveAttribute("href", "/planes")
    expect(screen.getByRole("button", { name: "Cerrar aviso de prueba" })).toBeInTheDocument()
  })

  describe("cuándo NO se muestra (sin cambios)", () => {
    it("sin usuario", () => {
      h.user = null
      render(<TrialBanner />)
      expect(screen.queryByRole("alert")).toBeNull()
    })

    it("cuenta que no está en prueba (billingStatus != trialing)", () => {
      h.user = trialUser({ billingStatus: "active" })
      render(<TrialBanner />)
      expect(screen.queryByRole("alert")).toBeNull()
    })

    it("prueba ya vencida o sin fecha de vencimiento", () => {
      h.user = trialUser({ trialExpiresAt: enDias(-1) })
      const { unmount } = render(<TrialBanner />)
      expect(screen.queryByRole("alert")).toBeNull()
      unmount()

      h.user = trialUser({ trialExpiresAt: null })
      render(<TrialBanner />)
      expect(screen.queryByRole("alert")).toBeNull()
    })
  })
})
