/**
 * Tests for ResponsiveModal's optional `contentClassName` extension — added
 * so the tutorial-video modal can request a wider (16:9) desktop dialog
 * without changing the default width used by every existing caller.
 *
 * Desktop-only here: `useIsMobile` defaults to false in jsdom (matchMedia
 * false), so these tests exercise the Dialog branch.
 *
 * Cycle: RED → GREEN → TRIANGULATE
 */

import { describe, it, expect, beforeAll } from "vitest"
import { render, screen } from "@testing-library/react"
import { ResponsiveModal } from "@/components/shared/responsive-modal"

// jsdom no implementa matchMedia; useIsMobile (usado por ResponsiveModal) lo
// necesita para decidir Dialog (desktop) vs Sheet (mobile). Se fuerza
// "no coincide" para que estos tests siempre ejerciten la rama Dialog.
beforeAll(() => {
  window.matchMedia = (query: string): MediaQueryList =>
    ({
      matches: false,
      media: query,
      onchange: null,
      addEventListener: () => {},
      removeEventListener: () => {},
      addListener: () => {},
      removeListener: () => {},
      dispatchEvent: () => false,
    }) as MediaQueryList
})

describe("ResponsiveModal", () => {
  // ── RED → GREEN: default behavior unchanged (retrocompatibilidad) ─────
  it("defaults to sm:max-w-xl when contentClassName is not provided (existing callers)", () => {
    render(
      <ResponsiveModal open={true} onOpenChange={() => {}} title="Titulo">
        <p>contenido</p>
      </ResponsiveModal>
    )
    const dialogContent = screen.getByRole("dialog")
    expect(dialogContent.className).toContain("sm:max-w-xl")
  })

  // ── TRIANGULATE: opt-in wider content for 16:9 video ───────────────────
  it("merges contentClassName (e.g. sm:max-w-3xl) when provided, without dropping base classes", () => {
    render(
      <ResponsiveModal
        open={true}
        onOpenChange={() => {}}
        title="Ver tutorial"
        contentClassName="sm:max-w-3xl"
      >
        <p>video</p>
      </ResponsiveModal>
    )
    const dialogContent = screen.getByRole("dialog")
    expect(dialogContent.className).toContain("sm:max-w-3xl")
    expect(dialogContent.className).toContain("overflow-hidden")
  })
})
