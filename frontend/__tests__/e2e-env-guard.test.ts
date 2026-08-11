import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

import { runEnvGuard } from "@/e2e/fixtures/env-guard"

const requiredEnv = {
  PLAYWRIGHT_BASE_URL: "http://localhost:3000",
  NEXT_PUBLIC_SUPABASE_URL_LOCAL: "http://127.0.0.1:54321",
  NEXT_PUBLIC_SUPABASE_ANON_KEY_LOCAL: "public-local-anon-key",
  NEXT_PUBLIC_BACKEND_URL_LOCAL: "http://localhost:8000",
  QA_TEST_USER_EMAIL: "qa.user@local.test",
  QA_TEST_USER_PASSWORD: "local-password-placeholder",
  QA_LOGOUT_USER_EMAIL: "qa.logout@local.test",
  QA_LOGOUT_USER_PASSWORD: "local-password-placeholder",
}

beforeEach(() => {
  for (const [name, value] of Object.entries(requiredEnv)) {
    vi.stubEnv(name, value)
  }
})

afterEach(() => {
  vi.unstubAllEnvs()
})

describe("Playwright env guard", () => {
  it("acepta exclusivamente los endpoints locales esperados", () => {
    expect(() => runEnvGuard()).not.toThrow()
  })

  it("rechaza un hostname que sólo contiene la palabra localhost", () => {
    vi.stubEnv("NEXT_PUBLIC_BACKEND_URL_LOCAL", "https://localhost.example.test")

    expect(() => runEnvGuard()).toThrow(/NEXT_PUBLIC_BACKEND_URL_LOCAL no apunta/)
  })

  it("rechaza credenciales QA faltantes sin incluir su valor en el error", () => {
    vi.stubEnv("QA_TEST_USER_PASSWORD", "")

    expect(() => runEnvGuard()).toThrow("QA_TEST_USER_PASSWORD no esta definida")
  })

  it("rechaza referencias a infraestructura real en variables relevantes", () => {
    vi.stubEnv("NEXT_PUBLIC_EXTERNAL_URL", "https://example.supabase.co")

    expect(() => runEnvGuard()).toThrow(/supabase\.co/)
  })
})
