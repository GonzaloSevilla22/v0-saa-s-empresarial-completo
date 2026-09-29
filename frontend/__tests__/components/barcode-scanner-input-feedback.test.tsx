/**
 * balanza-etiquetas-pos (task 5.1/5.2) — `BarcodeScannerInput` muestra el
 * resultado de la lectura (D9): éxito con el nombre del producto, error con
 * el motivo resumido en la píldora y el mensaje completo por `toast.error`.
 */
import React from "react"
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import { render, screen, act } from "@testing-library/react"
import "@testing-library/jest-dom"

vi.mock("sonner", () => ({ toast: { error: vi.fn(), success: vi.fn() } }))

import { toast } from "sonner"
import { BarcodeScannerInput } from "@/components/shared/barcode-scanner-input"
import { scanBurst } from "../helpers/scanner-keys"

/** Ráfaga de lector sellada a ritmo HID (ver `__tests__/helpers/scanner-keys.ts`). */
function dispatchScan(code: string) {
  act(() => scanBurst(code))
}

beforeEach(() => vi.clearAllMocks())
afterEach(() => vi.useRealTimers())

describe("BarcodeScannerInput — feedback (D9)", () => {
  it("éxito: muestra el nombre del producto agregado y NO llama a toast.error", () => {
    const onScan = vi.fn(() => ({ ok: true, label: "Tomate agregado" }))
    render(<BarcodeScannerInput onScan={onScan} />)
    dispatchScan("7791234567898")
    expect(screen.getByRole("status")).toHaveTextContent("Tomate agregado")
    expect(toast.error).not.toHaveBeenCalled()
  })

  it("error: muestra el motivo resumido y llama a toast.error con el mensaje completo", () => {
    const fullMessage = "El PLU 509 no está asignado a ningún producto. Asignalo en Productos → Código de balanza."
    const onScan = vi.fn(() => ({ ok: false, label: fullMessage }))
    render(<BarcodeScannerInput onScan={onScan} />)
    dispatchScan("2005090012504")
    expect(screen.getByRole("status")).toHaveTextContent("PLU 509")
    expect(toast.error).toHaveBeenCalledWith(fullMessage)
  })

  // Fix F9 (revisión adversarial PR #599): el POS y el formulario de venta
  // devolvían `label: `✓ ${nombre}`` — el componente YA antepone su propio
  // "✓ " en el estado `success`, así que el indicador terminaba mostrando
  // "✓ ✓ Tomate" (tilde duplicado). El caller sólo debe devolver el nombre.
  it("el caller NO debe anteponer su propio tilde — el indicador nunca muestra dos (F9)", () => {
    const onScan = vi.fn(() => ({ ok: true, label: "Tomate" }))
    render(<BarcodeScannerInput onScan={onScan} />)
    dispatchScan("7791234567898")
    const status = screen.getByRole("status")
    expect(status).toHaveTextContent("✓ Tomate")
    expect(status.textContent).not.toMatch(/✓\s*✓/)
  })

  it("retrocompatible: un onScan sin feedback (purchase-form/sale-form) se trata como éxito silencioso", () => {
    const onScan = vi.fn() // no devuelve nada
    render(<BarcodeScannerInput onScan={onScan} />)
    dispatchScan("7791234567898")
    expect(onScan).toHaveBeenCalledWith("7791234567898")
    expect(toast.error).not.toHaveBeenCalled()
  })

  it("disabled: muestra 'Scanner inactivo' y no escucha eventos", () => {
    const onScan = vi.fn()
    render(<BarcodeScannerInput onScan={onScan} enabled={false} />)
    expect(screen.getByRole("status")).toHaveTextContent("Scanner inactivo")
    dispatchScan("7791234567898")
    expect(onScan).not.toHaveBeenCalled()
  })
})
