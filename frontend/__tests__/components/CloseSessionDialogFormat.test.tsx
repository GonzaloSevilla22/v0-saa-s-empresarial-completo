/**
 * qa-integral-modulos G10 (H26) — "Diferencia (previa)" del cierre de caja
 * imprimía "$-37.200,00" (el signo adentro del importe). El formato canónico
 * de la app — el mismo del "Historial de sesiones" de esa pantalla — es
 * "-$ 37.200,00" (estilo currency de es-AR).
 */
import React from "react"
import { describe, it, expect, vi } from "vitest"
import { render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import "@testing-library/jest-dom"

import { CloseSessionDialog } from "@/components/cash/CloseSessionDialog"

function renderDialog(onClose = vi.fn().mockResolvedValue(undefined)) {
  render(
    <CloseSessionDialog
      open={true}
      onOpenChange={vi.fn()}
      expectedBalance={38200}
      onClose={onClose}
      isLoading={false}
    />,
  )
  return userEvent.setup()
}

describe("CloseSessionDialog — formato del importe negativo (G10/H26)", () => {
  it("diferencia previa negativa: '-$ 37.200,00', nunca '$-37.200,00'", async () => {
    const user = renderDialog()
    await user.type(screen.getByLabelText("Efectivo contado ($)"), "1000")

    expect(screen.getByText(/-\$\s?37\.200,00/)).toBeInTheDocument()
    expect(screen.queryByText(/\$-37\.200,00/)).not.toBeInTheDocument()
  })

  it("diferencia previa positiva conserva el '+' por delante del importe", async () => {
    const user = renderDialog()
    await user.type(screen.getByLabelText("Efectivo contado ($)"), "40000")

    expect(screen.getByText(/\+\s?\$\s?1\.800,00/)).toBeInTheDocument()
  })

  it("el panel de resultado también usa el formato canónico para el faltante", async () => {
    const user = renderDialog()
    await user.type(screen.getByLabelText("Efectivo contado ($)"), "1000")
    await user.click(screen.getByRole("button", { name: "Confirmar cierre" }))

    const panel = await screen.findByText(/Faltante en caja/)
    expect(panel.textContent).toMatch(/-\$\s?37\.200,00/)
    expect(panel.textContent).not.toMatch(/\$-37\.200,00/)
  })
})
