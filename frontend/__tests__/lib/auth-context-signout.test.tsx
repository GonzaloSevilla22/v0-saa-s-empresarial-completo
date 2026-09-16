/**
 * auth-hardening-jwt-cookies — D6, tasks 14.3 y 14.4.
 *
 * `logout()` hacía `supabase.auth.signOut()` pelado, y el default de la
 * librería es **global** (`GoTrueClient.js:3150` → `POST /logout?scope=global`):
 * cerrar sesión en el celular revocaba los refresh tokens de todos los
 * dispositivos y tiraba abajo el POS del mostrador. Para una PyME con la
 * tablet abierta todo el día eso no es un detalle de seguridad, es una
 * interrupción de venta. El botón "cerrar todas las sesiones" existe
 * justamente para el otro caso y conserva su alcance global.
 *
 * Además `logout()` borraba `tenant:active` a mano y `closeAllSessions()` no
 * borraba **ninguna** cookie.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"

const signOutMock = vi.fn()
const getUserMock = vi.fn().mockResolvedValue({ data: { user: null }, error: null })
const pushMock = vi.fn()
const clearAuthUxCookiesMock = vi.fn()

// auth-hardening-jwt-cookies (Parte C, task 18.4g): el cierre de sesión pasó a
// una acción de SERVIDOR (es el único que puede borrar las cookies `sb-*`
// httpOnly). El doble se mueve con él; la aserción que importa —el **alcance**—
// es exactamente la misma, ahora sobre el argumento de la acción.
vi.mock("@/app/auth/actions", () => ({
  signOutAction: (...args: unknown[]) => signOutMock(...args),
  signInWithPasswordAction: vi.fn().mockResolvedValue({ ok: true }),
  signInWithMagicLinkAction: vi.fn().mockResolvedValue({ ok: true }),
  signUpAction: vi.fn().mockResolvedValue({ ok: true }),
  updatePasswordAction: vi.fn().mockResolvedValue({ ok: true }),
  requestEmailChangeAction: vi.fn().mockResolvedValue({ ok: true }),
}))

vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({
    auth: {
      getUser: getUserMock,
      onAuthStateChange: () => ({ data: { subscription: { unsubscribe: vi.fn() } } }),
    },
    from: () => ({
      select: () => ({ eq: () => ({ single: () => Promise.resolve({ data: null }) }) }),
    }),
  }),
}))

vi.mock("next/navigation", () => ({
  useRouter: () => ({ push: pushMock }),
}))

vi.mock("@/lib/cookies", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@/lib/cookies")>()
  return {
    ...actual,
    clearAuthUxCookies: (...args: unknown[]) => clearAuthUxCookiesMock(...args),
  }
})

import { AuthProvider, useAuth } from "@/contexts/auth-context"

function Consumer() {
  const { logout, closeAllSessions } = useAuth()
  return (
    <div>
      <button onClick={() => void logout()}>logout</button>
      <button onClick={() => void closeAllSessions()}>close-all</button>
    </div>
  )
}

function renderWithAuth() {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={queryClient}>
      <AuthProvider>
        <Consumer />
      </AuthProvider>
    </QueryClientProvider>,
  )
}

beforeEach(() => {
  vi.clearAllMocks()
  getUserMock.mockResolvedValue({ data: { user: null }, error: null })
  signOutMock.mockResolvedValue({ ok: true })
})

// ── 14.3 ::uses_local_scope ────────────────────────────────────────────────
describe("logout() — alcance local", () => {
  it("revoca únicamente la sesión actual", async () => {
    renderWithAuth()
    fireEvent.click(await screen.findByText("logout"))

    await waitFor(() => expect(signOutMock).toHaveBeenCalled())
    expect(signOutMock).toHaveBeenCalledWith({ scope: "local" })
  })

  it("limpia las cookies de experiencia por el mecanismo compartido", async () => {
    renderWithAuth()
    fireEvent.click(await screen.findByText("logout"))

    await waitFor(() => expect(clearAuthUxCookiesMock).toHaveBeenCalledTimes(1))
  })

  it("navega al login", async () => {
    renderWithAuth()
    fireEvent.click(await screen.findByText("logout"))

    await waitFor(() => expect(pushMock).toHaveBeenCalledWith("/auth/login"))
  })
})

// ── 14.4 ::close_all_sessions_clears_cookies_too ───────────────────────────
describe("closeAllSessions() — alcance global, y también limpia", () => {
  it("conserva el alcance global (es la acción explícita para eso)", async () => {
    renderWithAuth()
    fireEvent.click(await screen.findByText("close-all"))

    await waitFor(() => expect(signOutMock).toHaveBeenCalled())
    expect(signOutMock).toHaveBeenCalledWith({ scope: "global" })
  })

  it("limpia las cookies de experiencia (antes no borraba ninguna)", async () => {
    renderWithAuth()
    fireEvent.click(await screen.findByText("close-all"))

    await waitFor(() => expect(clearAuthUxCookiesMock).toHaveBeenCalledTimes(1))
  })

  it("navega al login", async () => {
    renderWithAuth()
    fireEvent.click(await screen.findByText("close-all"))

    await waitFor(() => expect(pushMock).toHaveBeenCalledWith("/auth/login"))
  })
})

// ── Contraste: los dos caminos no comparten alcance ────────────────────────
describe("los dos cierres no comparten alcance", () => {
  it("logout es local y closeAllSessions es global en la misma sesión de test", async () => {
    renderWithAuth()

    fireEvent.click(await screen.findByText("logout"))
    await waitFor(() => expect(signOutMock).toHaveBeenCalledTimes(1))

    fireEvent.click(screen.getByText("close-all"))
    await waitFor(() => expect(signOutMock).toHaveBeenCalledTimes(2))

    expect(signOutMock.mock.calls[0][0]).toEqual({ scope: "local" })
    expect(signOutMock.mock.calls[1][0]).toEqual({ scope: "global" })
  })
})
