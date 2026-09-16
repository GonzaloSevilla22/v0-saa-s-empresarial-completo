/**
 * Tests de la capa de auth (auth-context) — change register-name-terms-captcha.
 *
 * register(): propaga last_name / terms_version / email_notifications_opt_in en
 * options.data y el captchaToken en options.captchaToken del signUp.
 * login(): propaga el captchaToken en options.captchaToken de signInWithPassword.
 *
 * Cycle: RED → GREEN → TRIANGULATE
 * Mock: @/lib/supabase/client, next/navigation
 */

import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"
import { AuthProvider, useAuth } from "@/contexts/auth-context"

// ── Dobles ──────────────────────────────────────────────────────────────────
//
// auth-hardening-jwt-cookies (Parte C, tasks 18.3/18.4a/18.4b): `signUp`,
// `signInWithPassword` y `signInWithOtp` pasaron a acciones de SERVIDOR, así que
// el doble se mueve con ellas. Las aserciones son las mismas de siempre (el
// captchaToken y el user_metadata del registro llegan completos): lo único que
// cambia es dónde se observan.
//
// `getUser`/`onAuthStateChange` siguen en el cliente de navegador **a
// propósito**: los mueven 19.8a y 20.3, no este grupo.
const signUpMock = vi.fn()
const signInWithPasswordMock = vi.fn()
const signInWithOtpMock = vi.fn()
// Logged-out: getUser returns no user so refreshSession resolves and children render.
const getUserMock = vi.fn().mockResolvedValue({ data: { user: null }, error: null })

vi.mock("@/app/auth/actions", () => ({
  signUpAction: (...args: unknown[]) => signUpMock(...args),
  signInWithPasswordAction: (...args: unknown[]) => signInWithPasswordMock(...args),
  signInWithMagicLinkAction: (...args: unknown[]) => signInWithOtpMock(...args),
  signOutAction: vi.fn().mockResolvedValue({ ok: true }),
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
  useRouter: () => ({ push: vi.fn() }),
}))

// ── Test consumer ───────────────────────────────────────────────────────────
function Consumer() {
  const { register, login } = useAuth()
  // auth-hardening-jwt-cookies (Parte C): las pantallas de auth muestran
  // `error.message` en un toast, así que lo que el contexto haga con un
  // `{ ok: false }` es observable. Este botón lo captura como lo hace una
  // pantalla real.
  const [failure, setFailure] = React.useState("")
  return (
    <div>
      <button
        onClick={() =>
          register("Susana", "susana@test.com", "Passw0rd!", { captchaToken: "captcha-xyz" }).catch(
            (error: Error) => setFailure(error.message),
          )
        }
      >
        register-failing
      </button>
      {failure && <span data-testid="register-failure">{failure}</span>}
      <button
        onClick={() =>
          register("Susana", "susana@test.com", "Passw0rd!", {
            phone: "+54 9 261 5555555",
            locality: "Godoy Cruz, Mendoza",
            province: "Mendoza",
            lastName: "Giménez",
            termsVersion: "2026-06-v1",
            emailOptIn: true,
            captchaToken: "captcha-xyz",
          })
        }
      >
        register-full
      </button>
      <button
        onClick={() =>
          register("Susana", "susana@test.com", "Passw0rd!", {
            phone: "+54 9 261 5555555",
            locality: "Godoy Cruz, Mendoza",
            lastName: "Giménez",
            termsVersion: "2026-06-v1",
            captchaToken: "captcha-xyz",
          })
        }
      >
        register-no-optin
      </button>
      <button onClick={() => login("susana@test.com", "Passw0rd!", "login-captcha")}>
        login-captcha
      </button>
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
  signUpMock.mockReset().mockResolvedValue({ ok: true })
  signInWithPasswordMock.mockReset().mockResolvedValue({ ok: true })
  signInWithOtpMock.mockReset().mockResolvedValue({ ok: true })
})

describe("auth-context register()", () => {
  it("propaga last_name, terms_version, email_notifications_opt_in y captchaToken al signUp", async () => {
    renderWithAuth()
    fireEvent.click(await screen.findByText("register-full"))

    await waitFor(() => expect(signUpMock).toHaveBeenCalled())
    // El user_metadata lo arma la acción (`signUpAction`, cubierto por
    // `__tests__/app/auth-actions.test.ts`); lo que este test fija es que el
    // contexto no pierda ningún campo en el camino.
    expect(signUpMock).toHaveBeenCalledWith(
      expect.objectContaining({
        email: "susana@test.com",
        password: "Passw0rd!",
        captchaToken: "captcha-xyz",
        profile: expect.objectContaining({
          name: "Susana",
          lastName: "Giménez",
          phone: "+54 9 261 5555555",
          locality: "Godoy Cruz, Mendoza",
          province: "Mendoza",
          termsVersion: "2026-06-v1",
          emailOptIn: true,
        }),
      }),
    )
  })

  it("(triangulate) emailOptIn ausente → email_notifications_opt_in = false", async () => {
    renderWithAuth()
    fireEvent.click(await screen.findByText("register-no-optin"))

    await waitFor(() => expect(signUpMock).toHaveBeenCalled())
    const arg = signUpMock.mock.calls[0][0]
    // El contexto no inventa un `true`: pasa la ausencia tal cual, y es la
    // acción la que la resuelve a `false` contra el default de la columna.
    expect(arg.profile.emailOptIn).toBeUndefined()
  })

  it("un error de la acción vuelve como excepción con el mensaje del proveedor", async () => {
    // El contrato que las cuatro pantallas de auth ya tienen: `error.message` en
    // un toast. Si el contexto se tragara el `{ ok: false }` que ahora devuelve
    // la acción, un registro fallido se vería como exitoso y el usuario
    // terminaría esperando un email que nunca se mandó.
    signUpMock.mockResolvedValue({ ok: false, error: "User already registered" })
    renderWithAuth()

    fireEvent.click(await screen.findByText("register-failing"))

    expect(await screen.findByTestId("register-failure")).toHaveTextContent(
      "User already registered",
    )
  })

  it("(control) con la acción en ok no aparece ningún error", async () => {
    renderWithAuth()
    fireEvent.click(await screen.findByText("register-failing"))

    await waitFor(() => expect(signUpMock).toHaveBeenCalled())
    expect(screen.queryByTestId("register-failure")).toBeNull()
  })
})

describe("auth-context login()", () => {
  it("propaga el captchaToken a signInWithPassword", async () => {
    renderWithAuth()
    fireEvent.click(await screen.findByText("login-captcha"))

    await waitFor(() => expect(signInWithPasswordMock).toHaveBeenCalled())
    expect(signInWithPasswordMock).toHaveBeenCalledWith(
      expect.objectContaining({
        email: "susana@test.com",
        password: "Passw0rd!",
        captchaToken: "login-captcha",
      }),
    )
  })
})
