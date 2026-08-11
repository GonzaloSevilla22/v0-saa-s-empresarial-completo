import { afterEach, describe, expect, it, vi } from "vitest"
import { cleanup, render, screen, waitFor } from "@testing-library/react"

import { CaptchaWidget } from "@/components/auth/CaptchaWidget"

vi.mock("@marsidev/react-turnstile", () => ({
  Turnstile: () => <div data-testid="turnstile-widget" />,
}))

afterEach(() => {
  cleanup()
  vi.unstubAllEnvs()
})

describe("CaptchaWidget — stub local de Playwright", () => {
  it("resuelve sin red únicamente cuando el flag QA está activo en localhost", async () => {
    vi.stubEnv("NEXT_PUBLIC_PLAYWRIGHT_LOCAL", "true")
    const onVerify = vi.fn()

    render(<CaptchaWidget onVerify={onVerify} />)

    await waitFor(() => {
      expect(onVerify).toHaveBeenCalledWith("playwright-local-captcha-stub")
    })
    expect(screen.getByTestId("captcha-local-stub")).toBeInTheDocument()
    expect(screen.queryByTestId("turnstile-widget")).not.toBeInTheDocument()
  })

  it("mantiene el formulario cerrado cuando el flag QA no está activo", () => {
    vi.stubEnv("NEXT_PUBLIC_PLAYWRIGHT_LOCAL", "false")
    vi.stubEnv("NEXT_PUBLIC_TURNSTILE_SITE_KEY", "")
    const onVerify = vi.fn()

    render(<CaptchaWidget onVerify={onVerify} />)

    expect(onVerify).not.toHaveBeenCalled()
    expect(screen.getByRole("note")).toBeInTheDocument()
  })

  it("ignora el bypass en un build de producción", () => {
    vi.stubEnv("NODE_ENV", "production")
    vi.stubEnv("NEXT_PUBLIC_PLAYWRIGHT_LOCAL", "true")
    vi.stubEnv("NEXT_PUBLIC_TURNSTILE_SITE_KEY", "turnstile-public-test-key")
    const onVerify = vi.fn()

    render(<CaptchaWidget onVerify={onVerify} />)

    expect(onVerify).not.toHaveBeenCalled()
    expect(screen.getByTestId("turnstile-widget")).toBeInTheDocument()
  })
})
