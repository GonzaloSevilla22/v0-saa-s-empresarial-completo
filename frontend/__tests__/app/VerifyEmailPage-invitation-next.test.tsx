/**
 * multiusuario-operativo tanda C (17.2, D12) — la verificación de email vuelve a la invitación.
 *
 * Quien abre un link de invitación sin cuenta se registra desde ahí (`/auth/register?next=
 * /invitacion/<token>`). El registro manda un email de verificación (cuyo enlace ya vuelve a la
 * invitación por `/auth/callback?next=…`), y mientras tanto el usuario mira ESTA pantalla,
 * que sondea el estado y, al verificarse, lo lleva al dashboard. Sin este cambio quien confirmó
 * en la misma pestaña terminaba en el Tablero de su cuenta personal, sin rastro de la invitación.
 *
 * Fija: con `?next=/invitacion/<token>` el destino al verificarse es la invitación; con cualquier
 * otro `next` (o ninguno) el destino sigue siendo `/dashboard`. Y si no hay sesión viva, el login
 * (`/auth/login`) conserva la invitación para volver después de ingresar.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import { render, screen, act } from "@testing-library/react"
import React from "react"

const TOKEN = "0123456789abcdef".repeat(4)

const h = vi.hoisted(() => ({
  push: vi.fn(),
  fetch: vi.fn(),
  refreshSession: vi.fn<() => Promise<boolean>>(),
  params: new URLSearchParams(),
}))

vi.mock("@/contexts/auth-context", () => ({
  useAuth: () => ({ refreshSession: h.refreshSession }),
}))

vi.mock("@/app/auth/actions", () => ({
  resendVerificationEmailAction: vi.fn().mockResolvedValue({ ok: true }),
}))

const routerDoble = { push: h.push }

vi.mock("next/navigation", () => ({
  useRouter: () => routerDoble,
  useSearchParams: () => h.params,
}))

vi.mock("next/link", () => ({
  default: ({ href, children }: { href: string; children: React.ReactNode }) => <a href={href}>{children}</a>,
}))

vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn(), info: vi.fn() } }))

import VerifyEmailPage from "@/app/auth/verify-email/page"

const VERIFICADO = { email: "susana@test.local", email_confirmed_at: "2026-10-17T12:00:00Z" }

function statusResponse(body: Record<string, unknown>): Response {
  return { ok: true, status: 200, json: async () => body } as unknown as Response
}

async function verifyAndNavigate() {
  vi.useFakeTimers({ shouldAdvanceTime: true })
  h.fetch.mockResolvedValue(statusResponse(VERIFICADO))
  render(<VerifyEmailPage />)
  expect(await screen.findByText("Email verificado")).toBeInTheDocument()
  await act(async () => {
    vi.advanceTimersByTime(1600)
  })
}

beforeEach(() => {
  h.push.mockReset()
  h.refreshSession.mockReset().mockResolvedValue(true)
  h.fetch.mockReset()
  h.params = new URLSearchParams()
  vi.stubGlobal("fetch", h.fetch)
})

afterEach(() => {
  vi.unstubAllGlobals()
  vi.useRealTimers()
})

describe("/auth/verify-email — destino tras verificarse", () => {
  it("con ?next=/invitacion/<token> navega a la invitación", async () => {
    h.params = new URLSearchParams({ email: "susana@test.local", next: `/invitacion/${TOKEN}` })

    await verifyAndNavigate()

    expect(h.push).toHaveBeenCalledWith(`/invitacion/${TOKEN}`)
    expect(h.push).not.toHaveBeenCalledWith("/dashboard")
  })

  it("sin next sigue yendo al dashboard (no-regresión)", async () => {
    h.params = new URLSearchParams({ email: "susana@test.local" })

    await verifyAndNavigate()

    expect(h.push).toHaveBeenCalledWith("/dashboard")
  })

  it.each([
    "/ventas",
    `//evil.example/invitacion/${TOKEN}`,
    `https://evil.example/invitacion/${TOKEN}`,
    "/invitacion/corto",
    `/invitacion/${TOKEN}/extra`,
  ])("descarta el destino %s: va al dashboard", async (next) => {
    h.params = new URLSearchParams({ email: "susana@test.local", next })

    await verifyAndNavigate()

    expect(h.push).toHaveBeenCalledWith("/dashboard")
    expect(h.push).not.toHaveBeenCalledWith(next)
  })

  it("si no hay sesión viva tras verificar, el login conserva la invitación para volver", async () => {
    h.params = new URLSearchParams({ email: "susana@test.local", next: `/invitacion/${TOKEN}` })
    h.refreshSession.mockResolvedValue(false)

    await verifyAndNavigate()

    expect(h.push).toHaveBeenCalledWith(`/auth/login?next=${encodeURIComponent(`/invitacion/${TOKEN}`)}`)
  })

  it("sin sesión y sin invitación el login es el de siempre", async () => {
    h.params = new URLSearchParams({ email: "susana@test.local" })
    h.refreshSession.mockResolvedValue(false)

    await verifyAndNavigate()

    expect(h.push).toHaveBeenCalledWith("/auth/login")
  })
})
