/**
 * CashOptinBlock — el bloque «Registrar en caja» compartido (fix `caja-optin-carga`).
 *
 * El bloque estaba copiado a mano en cinco consumidores (venta, gasto, compra,
 * cobro, pago a proveedor) con los mismos tres estados. Al agregar el cuarto —
 * «Verificando la caja…» mientras se averigua dónde está la sesión — se extrae a
 * un único componente en vez de copiar el cambio cinco veces.
 */
import { describe, it, expect, vi } from "vitest"
import { render, screen, fireEvent } from "@testing-library/react"
import { CashOptinBlock } from "@/components/cash/CashOptinBlock"
import type { CashOptinState } from "@/hooks/use-cash-optin"
import type { CashSession } from "@/lib/types"

function state(overrides: Partial<CashOptinState> = {}): CashOptinState {
  return {
    isCashSelected: true,
    isDateToday: true,
    effectiveBranchId: "branch-1",
    cashboxId: "cashbox-1",
    session: null,
    eligible: false,
    isLoading: false,
    reason: "No hay caja abierta en esta sucursal — el efectivo no se registrará en el arqueo.",
    ...overrides,
  }
}

const SESSION = { id: "session-abc12345-zzzz" } as CashSession

describe("CashOptinBlock", () => {
  it("cargando: muestra «Verificando la caja…» como estado (role=status, aria-live) y NO muestra checkbox ni motivo", () => {
    render(
      <CashOptinBlock cash={state({ isLoading: true })} registerInCash onRegisterInCashChange={vi.fn()} />,
    )

    const status = screen.getByRole("status")
    expect(status).toHaveTextContent("Verificando la caja…")
    expect(status).toHaveAttribute("aria-live", "polite")
    expect(screen.queryByRole("checkbox")).not.toBeInTheDocument()
    expect(screen.queryByText(/no hay caja abierta/i)).not.toBeInTheDocument()
  })

  it("elegible: checkbox con el prefijo de la sesión y refleja el valor recibido", () => {
    render(
      <CashOptinBlock
        cash={state({ eligible: true, session: SESSION })}
        registerInCash
        onRegisterInCashChange={vi.fn()}
      />,
    )

    const checkbox = screen.getByRole("checkbox")
    expect(checkbox).toHaveAttribute("data-state", "checked")
    expect(screen.getByText("Registrar en caja — sesión session-…")).toBeInTheDocument()
    expect(screen.queryByRole("status")).not.toBeInTheDocument()
  })

  it("elegible y desmarcado: el checkbox nace desmarcado (el padre decide el default) y notifica el cambio", () => {
    const onChange = vi.fn()
    render(
      <CashOptinBlock
        cash={state({ eligible: true, session: SESSION })}
        registerInCash={false}
        onRegisterInCashChange={onChange}
      />,
    )

    const checkbox = screen.getByRole("checkbox")
    expect(checkbox).toHaveAttribute("data-state", "unchecked")
    fireEvent.click(checkbox)
    expect(onChange).toHaveBeenCalledWith(true)
  })

  it("no elegible y sin carga: muestra el motivo (nunca oculto en silencio) como nota, sin checkbox", () => {
    render(
      <CashOptinBlock cash={state({ reason: "Sólo se puede registrar en caja una venta fechada hoy." })} registerInCash onRegisterInCashChange={vi.fn()} />,
    )

    expect(screen.getByRole("note")).toHaveTextContent("Sólo se puede registrar en caja una venta fechada hoy.")
    expect(screen.queryByRole("checkbox")).not.toBeInTheDocument()
    expect(screen.queryByRole("status")).not.toBeInTheDocument()
  })

  it("la carga gana sobre el motivo: aunque eligible=false traiga un motivo de caja cerrada, mientras carga no se afirma «no hay caja»", () => {
    render(
      <CashOptinBlock
        cash={state({ isLoading: true, eligible: false })}
        registerInCash
        onRegisterInCashChange={vi.fn()}
      />,
    )

    expect(screen.queryByText(/no hay caja abierta/i)).not.toBeInTheDocument()
    expect(screen.getByText("Verificando la caja…")).toBeInTheDocument()
  })
})
