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
// Parte C (task 19.8a): la identidad del contexto viene del store del token, no
// de `supabase.auth.getUser()` (que con `accessToken` configurado LANZA,
// `supabase-js/index.mjs:389`). Sin sesión: la resolución dice "absent".
const refreshAccessTokenMock = vi.fn().mockResolvedValue({ status: "absent" })
// task 19.5: el token vive en memoria del modulo; el servidor no puede borrarlo.
const clearAccessTokenMock = vi.fn()
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

vi.mock("@/lib/auth/access-token-store", () => ({
  refreshAccessToken: () => refreshAccessTokenMock(),
  clearAccessToken: () => clearAccessTokenMock(),
}))

vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({
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
  refreshAccessTokenMock.mockResolvedValue({ status: "absent" })
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

  // ── Parte C, D1 (task 19.5) ───────────────────────────────────────────────
  // `logout()` navega con el ROUTER, no recargando: el modulo del store sigue
  // vivo. Sin olvidar el token, la pestana se queda con una credencial que el
  // servidor ya revoco -- valida hasta su `exp`, una hora -- y cualquier
  // refetch pendiente de React Query la usa.
  it("olvida el access token de memoria", async () => {
    renderWithAuth()
    fireEvent.click(await screen.findByText("logout"))

    await waitFor(() => expect(clearAccessTokenMock).toHaveBeenCalledTimes(1))
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

  it("olvida el access token de memoria", async () => {
    // Con alcance global importa mas todavia: el usuario pidio cerrar en TODOS
    // los dispositivos y este es el unico token que el servidor no alcanza.
    renderWithAuth()
    fireEvent.click(await screen.findByText("close-all"))

    await waitFor(() => expect(clearAccessTokenMock).toHaveBeenCalledTimes(1))
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
