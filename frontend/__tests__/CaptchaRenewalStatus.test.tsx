/**
 * Tests de `CaptchaRenewalStatus` — change captcha-renewal-feedback (D6 en
 * design.md). Región `aria-live` compartida por las 4 pantallas de auth: un
 * cambio de rótulo dentro de un botón no enfocado no se anuncia solo.
 */

import { describe, it, expect } from "vitest"
import { render, screen, cleanup } from "@testing-library/react"
import { afterEach } from "vitest"
import { CaptchaRenewalStatus } from "@/components/auth/CaptchaRenewalStatus"

afterEach(() => cleanup())

describe("CaptchaRenewalStatus", () => {
  it("con mensaje vacío no anuncia nada", () => {
    render(<CaptchaRenewalStatus message="" />)
    expect(screen.queryByRole("status")).not.toBeInTheDocument()
  })

  it("con mensaje renderiza un nodo role=status aria-live=polite con el texto", () => {
    render(<CaptchaRenewalStatus message="Renovando verificación…" />)
    const status = screen.getByRole("status")
    expect(status).toHaveAttribute("aria-live", "polite")
    expect(status).toHaveTextContent("Renovando verificación…")
  })

  it("(triangulate) cambiar el mensaje actualiza el contenido de la misma región (no se remonta)", () => {
    const { rerender } = render(<CaptchaRenewalStatus message="Renovando verificación…" />)
    const first = screen.getByRole("status")

    rerender(<CaptchaRenewalStatus message="Otro mensaje" />)
    const second = screen.getByRole("status")

    expect(second).toBe(first)
    expect(second).toHaveTextContent("Otro mensaje")
  })
})
