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

// ── Supabase client mock ────────────────────────────────────────────────────
const signUpMock = vi.fn()
const signInWithPasswordMock = vi.fn()
const signInWithOtpMock = vi.fn()
// Logged-out: getUser returns no user so refreshSession resolves and children render.
const getUserMock = vi.fn().mockResolvedValue({ data: { user: null }, error: null })

vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({
    auth: {
      getUser: getUserMock,
      signUp: signUpMock,
      signInWithPassword: signInWithPasswordMock,
      signInWithOtp: signInWithOtpMock,
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
  return (
    <div>
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
  signUpMock.mockReset().mockResolvedValue({ error: null })
  signInWithPasswordMock.mockReset().mockResolvedValue({ error: null })
  signInWithOtpMock.mockReset().mockResolvedValue({ error: null })
})

describe("auth-context register()", () => {
  it("propaga last_name, terms_version, email_notifications_opt_in y captchaToken al signUp", async () => {
    renderWithAuth()
    fireEvent.click(await screen.findByText("register-full"))

    await waitFor(() => expect(signUpMock).toHaveBeenCalled())
    expect(signUpMock).toHaveBeenCalledWith(
      expect.objectContaining({
        email: "susana@test.com",
        password: "Passw0rd!",
        options: expect.objectContaining({
          data: expect.objectContaining({
            name: "Susana",
            last_name: "Giménez",
            phone: "+54 9 261 5555555",
            locality: "Godoy Cruz, Mendoza",
            province: "Mendoza",
            terms_version: "2026-06-v1",
            email_notifications_opt_in: true,
          }),
          captchaToken: "captcha-xyz",
        }),
      }),
    )
  })

  it("(triangulate) emailOptIn ausente → email_notifications_opt_in = false", async () => {
    renderWithAuth()
    fireEvent.click(await screen.findByText("register-no-optin"))

    await waitFor(() => expect(signUpMock).toHaveBeenCalled())
    const arg = signUpMock.mock.calls[0][0]
    expect(arg.options.data.email_notifications_opt_in).toBe(false)
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
        options: expect.objectContaining({ captchaToken: "login-captcha" }),
      }),
    )
  })
})
