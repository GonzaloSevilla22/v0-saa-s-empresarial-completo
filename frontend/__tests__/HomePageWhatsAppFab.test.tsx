/**
 * Verifica el cableado del botón flotante de WhatsApp en la home pública
 * (`app/page.tsx`) — change `landing-whatsapp-fab`.
 *
 * Por qué un test aparte de `components/WhatsAppFab.test.tsx`: aquel prueba el
 * componente; este prueba la *decisión de montaje* (design.md D2) — que la home
 * lo renderice y que el número salga de `ALIADATA_WHATSAPP_PHONE` y no de un
 * literal. Es lo que rompería si alguien moviera el botón a un layout o
 * hardcodeara el teléfono.
 *
 * `HomePage` es un Server Component async: se lo invoca y se renderiza el
 * elemento que devuelve. Se mockean la server action de landing (no queremos DB
 * en un unit test) y `LandingPageFull` (irrelevante acá, y arrastra la escena 3D).
 */

import { describe, it, expect, vi, beforeEach, afterAll } from "vitest"
import { render, screen } from "@testing-library/react"

vi.mock("@/app/actions/landing", () => ({
  getLandingSectionsAction: vi.fn(async () => []),
}))

vi.mock("@/components/landing/LandingPageFull", () => ({
  LandingPageFull: () => <div data-testid="landing-page-full" />,
}))

import HomePage from "@/app/page"

const ORIGINAL_PHONE = process.env.ALIADATA_WHATSAPP_PHONE

describe("HomePage — botón flotante de WhatsApp", () => {
  beforeEach(() => {
    delete process.env.ALIADATA_WHATSAPP_PHONE
  })

  afterAll(() => {
    if (ORIGINAL_PHONE === undefined) delete process.env.ALIADATA_WHATSAPP_PHONE
    else process.env.ALIADATA_WHATSAPP_PHONE = ORIGINAL_PHONE
  })

  // ── RED/GREEN: la home monta el FAB con el número configurado ──────────────
  it("mounts the WhatsApp FAB using the number from ALIADATA_WHATSAPP_PHONE", async () => {
    process.env.ALIADATA_WHATSAPP_PHONE = "+54 9 2617 63-5174"

    render(await HomePage())

    expect(screen.getByTestId("landing-page-full")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: /whatsapp/i })).toHaveAttribute(
      "href",
      expect.stringContaining("https://wa.me/5492617635174"),
    )
  })

  // ── TRIANGULATE: otro número configurado ⇒ otro destino, sin tocar código ──
  it("follows the configured value instead of a hardcoded number", async () => {
    process.env.ALIADATA_WHATSAPP_PHONE = "+54 9 11 5555-1234"

    render(await HomePage())

    expect(screen.getByRole("link", { name: /whatsapp/i })).toHaveAttribute(
      "href",
      expect.stringContaining("https://wa.me/5491155551234"),
    )
  })

  // ── TRIANGULATE: sin configuración, la landing queda como estaba ───────────
  it("renders the landing without the FAB when the variable is not configured", async () => {
    render(await HomePage())

    expect(screen.getByTestId("landing-page-full")).toBeInTheDocument()
    expect(screen.queryByRole("link", { name: /whatsapp/i })).toBeNull()
  })
})
