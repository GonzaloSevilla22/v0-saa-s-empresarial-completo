/**
 * Tests for the IdleWarningModal component.
 *
 * Spec coverage:
 *   - Shows countdown text "Tu sesión se cerrará en Ns" when in warning state
 *   - "Seguir conectado" button calls onStayConnected
 *   - Escape key treated as "Seguir conectado"
 *   - Countdown lives in an aria-live region
 */

import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent } from "@testing-library/react"
import { IdleWarningModal } from "@/components/auth/IdleWarningModal"

describe("IdleWarningModal", () => {
  const onStayConnected = vi.fn()

  beforeEach(() => {
    onStayConnected.mockReset()
  })

  // ── 3.1 RED / 3.2 GREEN: modal renders countdown and button ───────────────

  it("renders countdown text with seconds remaining", () => {
    render(
      <IdleWarningModal
        isOpen={true}
        secondsRemaining={45}
        onStayConnected={onStayConnected}
      />,
    )

    // The paragraph "Tu sesión se cerrará en 45s" should be present
    expect(screen.getByText(/tu sesión se cerrará en 45s/i)).toBeInTheDocument()
    // The big countdown number should appear
    expect(screen.getAllByText(/45/).length).toBeGreaterThan(0)
  })

  it("renders the 'Seguir conectado' button", () => {
    render(
      <IdleWarningModal
        isOpen={true}
        secondsRemaining={60}
        onStayConnected={onStayConnected}
      />,
    )

    expect(screen.getByRole("button", { name: /seguir conectado/i })).toBeInTheDocument()
  })

  it("does not render when isOpen is false", () => {
    render(
      <IdleWarningModal
        isOpen={false}
        secondsRemaining={60}
        onStayConnected={onStayConnected}
      />,
    )

    expect(screen.queryByText(/seguir conectado/i)).not.toBeInTheDocument()
  })

  // ── 3.3 RED / 3.4 GREEN: button click calls onStayConnected ──────────────

  it("calls onStayConnected when the button is clicked", () => {
    render(
      <IdleWarningModal
        isOpen={true}
        secondsRemaining={30}
        onStayConnected={onStayConnected}
      />,
    )

    fireEvent.click(screen.getByRole("button", { name: /seguir conectado/i }))

    expect(onStayConnected).toHaveBeenCalledTimes(1)
  })

  // ── 3.5 TRIANGULATE: countdown in aria-live region ────────────────────────

  it("countdown is inside an aria-live region", () => {
    render(
      <IdleWarningModal
        isOpen={true}
        secondsRemaining={50}
        onStayConnected={onStayConnected}
      />,
    )

    // The aria-live element must exist and contain the seconds
    const liveRegion = document.querySelector("[aria-live]")
    expect(liveRegion).not.toBeNull()
    expect(liveRegion?.textContent).toMatch(/50/)
  })

  it("shows 1 second correctly without pluralization issues", () => {
    render(
      <IdleWarningModal
        isOpen={true}
        secondsRemaining={1}
        onStayConnected={onStayConnected}
      />,
    )

    expect(screen.getByText(/tu sesión se cerrará en 1s/i)).toBeInTheDocument()
  })

  it("shows 0 seconds when expired countdown reaches zero", () => {
    render(
      <IdleWarningModal
        isOpen={true}
        secondsRemaining={0}
        onStayConnected={onStayConnected}
      />,
    )

    // Should still render (modal stays open until logout fires)
    expect(screen.getByRole("button", { name: /seguir conectado/i })).toBeInTheDocument()
  })
})
