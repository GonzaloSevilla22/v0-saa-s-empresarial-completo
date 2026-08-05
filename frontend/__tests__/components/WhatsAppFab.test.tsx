/**
 * Tests para `WhatsAppFab` (components/landing/WhatsAppFab.tsx) — change
 * `landing-whatsapp-fab`.
 *
 * El componente es un Server Component (sin `"use client"`): no usa hooks ni
 * estado, así que es una función sincrónica y se renderiza con RTL igual que
 * cualquier otro componente. Eso es justamente lo que verifica que no se le
 * coló JavaScript de cliente (design.md D2).
 *
 * No se mockea `lib/phone-utils` a propósito: el valor del test está en
 * confirmar el cableado real con `normalizeWhatsAppPhone`/`buildWhatsAppUrl`,
 * que son la lógica canónica de teléfonos del proyecto y ya existían.
 *
 * Sobre los asserts de clases (tamaño táctil y reduced-motion): jsdom no
 * aplica Tailwind, así que no hay geometría ni media queries que medir. Se
 * asertan las clases como *proxy* del contrato visual — sirven de guardia de
 * regresión si alguien achica el botón o le saca la degradación de motion.
 * La verificación real de ambas cosas es en browser (tasks 5.2/5.4/5.5).
 *
 * Ciclo: RED (WhatsAppFab.tsx no existe) → GREEN → TRIANGULATE (degradación,
 * formato local, mensaje, seguridad, a11y) → REFACTOR.
 */

import { describe, it, expect } from "vitest"
import { render, screen } from "@testing-library/react"
import { WhatsAppFab } from "@/components/landing/WhatsAppFab"

/** Número real de ALIADATA confirmado por el PO. */
const PHONE = "+54 9 2617 63-5174"
/** Su forma canónica según `normalizeWhatsAppPhone`. */
const CANONICAL = "5492617635174"

describe("WhatsAppFab", () => {
  // ── RED/GREEN: happy path — enlace al número real de ALIADATA ──────────────
  it("renders a link to the configured ALIADATA WhatsApp number", () => {
    render(<WhatsAppFab phone={PHONE} />)

    const link = screen.getByRole("link")
    expect(link).toHaveAttribute("href", expect.stringContaining(`https://wa.me/${CANONICAL}`))
  })

  // ── TRIANGULATE: normalización de un formato de escritura distinto ─────────
  // Mismo número en formato local (con 0 de discado nacional) → mismo destino.
  it("normalizes a local Argentine format to the same canonical wa.me link", () => {
    render(<WhatsAppFab phone="0261 763-5174" />)

    const link = screen.getByRole("link")
    expect(link).toHaveAttribute("href", expect.stringContaining(`https://wa.me/${CANONICAL}`))
  })

  // ── TRIANGULATE: degradación silenciosa (design.md D3) ────────────────────
  // El fallback de `buildWhatsAppUrl` con teléfono inválido es `wa.me/?text=`,
  // que abre el SELECTOR DE CONTACTOS. Correcto para mandar un comprobante a un
  // cliente sin teléfono cargado, pero un bug de cara al público: por eso acá
  // el componente no debe renderizar nada en vez de emitir ese enlace.
  it.each([
    ["undefined", undefined],
    ["empty", ""],
    ["blank", "   "],
    ["not normalizable", "123"],
  ])("renders nothing when the configured number is %s", (_label, phone) => {
    const { container } = render(<WhatsAppFab phone={phone} />)

    expect(container).toBeEmptyDOMElement()
    expect(container.innerHTML).not.toContain("wa.me")
  })

  // ── TRIANGULATE: mensaje inicial pre-cargado y codificado ─────────────────
  it("preloads an initial message, URL-encoded so the link stays valid", () => {
    render(<WhatsAppFab phone={PHONE} />)

    const href = screen.getByRole("link").getAttribute("href") as string
    // Ni espacios ni caracteres crudos fuera de ASCII en la URL emitida.
    expect(href).not.toMatch(/\s/)
    const text = new URL(href).searchParams.get("text")
    expect(text).toContain("ALIADATA")
  })

  // ── TRIANGULATE: seguridad del enlace saliente (tabnabbing) ───────────────
  it("opens in a new tab with noopener and noreferrer", () => {
    render(<WhatsAppFab phone={PHONE} />)

    const link = screen.getByRole("link")
    expect(link).toHaveAttribute("target", "_blank")
    const rel = link.getAttribute("rel") ?? ""
    expect(rel).toContain("noopener")
    expect(rel).toContain("noreferrer")
  })

  // ── TRIANGULATE: accesibilidad ────────────────────────────────────────────
  it("exposes an accessible name naming WhatsApp and warning about the new tab", () => {
    render(<WhatsAppFab phone={PHONE} />)

    const link = screen.getByRole("link", { name: /whatsapp/i })
    expect(link).toHaveAccessibleName(/pestaña nueva/i)
  })

  it("marks the WhatsApp glyph as decorative so it is not announced separately", () => {
    const { container } = render(<WhatsAppFab phone={PHONE} />)

    const svg = container.querySelector("svg")
    expect(svg).not.toBeNull()
    expect(svg).toHaveAttribute("aria-hidden", "true")
    expect(svg).toHaveAttribute("focusable", "false")
  })

  // ── TRIANGULATE: contrato visual (proxy por clases — ver cabecera) ────────
  it("keeps a touch target of at least 44px and stays under the fixed navbar", () => {
    render(<WhatsAppFab phone={PHONE} />)

    const className = screen.getByRole("link").className
    // h-14/w-14 = 56px > 44px mínimo táctil.
    expect(className).toContain("h-14")
    expect(className).toContain("w-14")
    // El navbar de la landing y los overlays de shadcn viven en z-50.
    expect(className).toContain("z-40")
    expect(className).toContain("fixed")
  })

  it("drops the scale transition when the OS asks for reduced motion", () => {
    render(<WhatsAppFab phone={PHONE} />)

    const className = screen.getByRole("link").className
    expect(className).toContain("motion-reduce:transition-none")
    expect(className).toContain("motion-reduce:hover:scale-100")
  })
})
