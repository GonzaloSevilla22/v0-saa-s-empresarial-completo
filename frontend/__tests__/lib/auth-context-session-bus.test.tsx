/**
 * auth-hardening-jwt-cookies — Parte C, D1, task 20.3.
 *
 * Acá vivía `supabase.auth.onAuthStateChange` (`contexts/auth-context.tsx:202`),
 * y con `accessToken` configurado ese observador **no existe**
 * (`supabase-js/index.mjs:407`, `:389`). Lo único que hacía y que ninguna otra
 * pieza cubre es la propagación **entre pestañas**: sin reemplazo, cerrar sesión
 * en el celular dejaba la tablet del mostrador mostrando datos como si la sesión
 * siguiera viva, hasta que algo devolviera 401.
 *
 * Estos casos prueban el reemplazo sobre el bus (`lib/auth/session-bus.ts`) desde
 * el lado del contexto: que reacciona al evento ajeno, que **no** lo confunde con
 * un cierre por inactividad, y que anuncia sus propias transiciones.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import { render, screen, fireEvent, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"
import { FakeBroadcastChannel } from "./fake-broadcast-channel"

const pushMock = vi.fn()
const signOutMock = vi.fn().mockResolvedValue({ ok: true })
const signInMock = vi.fn().mockResolvedValue({ ok: true })
const clearAccessTokenMock = vi.fn()
const refreshAccessTokenMock = vi.fn().mockResolvedValue({
  status: "active",
  token: "jwt-de-prueba",
  expiresAt: null,
  user: { id: "u-1", email: "duena@negocio.test", name: "Dueña" },
})
const storeListeners = new Set<(token: string | null) => void>()

vi.mock("@/app/auth/actions", () => ({
  signOutAction: (...args: unknown[]) => signOutMock(...args),
  signInWithPasswordAction: (...args: unknown[]) => signInMock(...args),
  signInWithMagicLinkAction: vi.fn().mockResolvedValue({ ok: true }),
  signUpAction: vi.fn().mockResolvedValue({ ok: true }),
  updatePasswordAction: vi.fn().mockResolvedValue({ ok: true }),
  requestEmailChangeAction: vi.fn().mockResolvedValue({ ok: true }),
}))

vi.mock("@/lib/auth/access-token-store", () => ({
  refreshAccessToken: () => refreshAccessTokenMock(),
  clearAccessToken: () => clearAccessTokenMock(),
  subscribeToAccessToken: (listener: (token: string | null) => void) => {
    storeListeners.add(listener)
    return () => storeListeners.delete(listener)
  },
}))

// El cliente real se cachea por pestaña (`lib/supabase/client.ts`): un doble que
// devuelva un objeto nuevo en cada render cambia la identidad de `refreshSession`
// y deja al efecto del contexto reconsultando sin parar — un lazo del arnés que
// volvería vacua cualquier aserción sobre "se volvió a resolver la identidad".
const clienteDoble = {
  from: () => ({
    select: () => ({
      eq: () => ({
        single: () => Promise.resolve({ data: null }),
        order: () => ({ order: () => ({ limit: () => ({ maybeSingle: () => Promise.resolve({ data: null }) }) }) }),
      }),
    }),
  }),
}

vi.mock("@/lib/supabase/client", () => ({
  createClient: () => clienteDoble,
}))

vi.mock("next/navigation", () => ({
  useRouter: () => ({ push: pushMock }),
}))

vi.stubGlobal("BroadcastChannel", FakeBroadcastChannel)

import { AuthProvider, useAuth } from "@/contexts/auth-context"
import { closeSessionBus } from "@/lib/auth/session-bus"
import { createIdleTransport } from "@/lib/auth/idle-transport"

function Consumer() {
  const { isAuthenticated, login, logout } = useAuth()
  return (
    <div>
      <span data-testid="estado">{isAuthenticated ? "con-sesion" : "sin-sesion"}</span>
      <button onClick={() => void login("duena@negocio.test", "secreto-largo")}>login</button>
      <button onClick={() => void logout()}>logout</button>
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

describe("auth-context — bus de eventos de sesión (task 20.3)", () => {
  beforeEach(() => {
    vi.stubGlobal("BroadcastChannel", FakeBroadcastChannel)
    FakeBroadcastChannel.reset()
    pushMock.mockClear()
    signOutMock.mockClear()
    signInMock.mockClear()
    clearAccessTokenMock.mockClear()
    refreshAccessTokenMock.mockClear()
    storeListeners.clear()
    closeSessionBus()
  })

  afterEach(() => {
    closeSessionBus()
    FakeBroadcastChannel.reset()
  })

  it("el cierre de sesión en otra pestaña deja a esta sin sesión y la manda al login", async () => {
    renderWithAuth()
    await waitFor(() => expect(screen.getByTestId("estado").textContent).toBe("con-sesion"))

    // Otra pestaña cierra sesión: el bus le avisa a esta.
    const peer = createIdleTransport()
    peer.post({ type: "session:signed-out" })

    await waitFor(() => expect(screen.getByTestId("estado").textContent).toBe("sin-sesion"))
    // Sin `reason=idle`: no fue un cierre por inactividad y decirlo sería mentir.
    expect(pushMock).toHaveBeenCalledWith("/auth/login")
    // Y esta pestaña no vuelve a pedirle al servidor que cierre algo ya cerrado.
    expect(signOutMock).not.toHaveBeenCalled()

    peer.close()
  })

  it("una sesión iniciada en otra pestaña hace que esta vuelva a resolver la identidad", async () => {
    renderWithAuth()
    await waitFor(() => expect(screen.getByTestId("estado").textContent).toBe("con-sesion"))
    // El montaje puede resolver la identidad más de una vez (efectos de React):
    // la aserción es sobre el INCREMENTO que produce el evento ajeno, no sobre un
    // total que el montaje ya satisface por su cuenta.
    const antes = refreshAccessTokenMock.mock.calls.length

    const peer = createIdleTransport()
    peer.post({ type: "session:signed-in" })

    await waitFor(() => expect(refreshAccessTokenMock.mock.calls.length).toBeGreaterThan(antes))
    expect(pushMock).not.toHaveBeenCalled()

    peer.close()
  })

  it("el cierre local se anuncia a las demás pestañas, y nunca como inactividad", async () => {
    renderWithAuth()
    await waitFor(() => expect(screen.getByTestId("estado").textContent).toBe("con-sesion"))

    const peer = createIdleTransport()
    const recibidos: string[] = []
    peer.onMessage((msg) => recibidos.push(msg.type))

    fireEvent.click(screen.getByText("logout"))

    await waitFor(() => expect(recibidos).toContain("session:signed-out"))
    expect(recibidos).not.toContain("logout")

    peer.close()
  })

  it("el inicio de sesión local se anuncia a las demás pestañas", async () => {
    renderWithAuth()
    await waitFor(() => expect(screen.getByTestId("estado").textContent).toBe("con-sesion"))

    const peer = createIdleTransport()
    const recibidos: string[] = []
    peer.onMessage((msg) => recibidos.push(msg.type))

    fireEvent.click(screen.getByText("login"))

    await waitFor(() => expect(recibidos).toContain("session:signed-in"))

    peer.close()
  })

  it("los mensajes del temporizador de inactividad no mueven al contexto", async () => {
    renderWithAuth()
    await waitFor(() => expect(screen.getByTestId("estado").textContent).toBe("con-sesion"))

    const peer = createIdleTransport()
    peer.postActivity(Date.now())
    peer.postLogout()

    // `logout` es del temporizador: su consumidor es `IdleTimeoutProvider`, que
    // cierra con `?reason=idle`. El contexto no debe duplicar ese camino.
    await new Promise((resolve) => setTimeout(resolve, 10))
    expect(screen.getByTestId("estado").textContent).toBe("con-sesion")
    expect(pushMock).not.toHaveBeenCalled()

    peer.close()
  })
})
