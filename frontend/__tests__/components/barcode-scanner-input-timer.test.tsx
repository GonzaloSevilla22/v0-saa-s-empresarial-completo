/**
 * El temporizador de 1,5 s que devuelve el indicador a "idle" no sobrevive al
 * desmontaje (flake de vitest: «window is not defined» en la CI del PR #652,
 * originado en `pos-scale-scanner.test.tsx`).
 */
import React from "react"
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import { render, screen, act } from "@testing-library/react"
import "@testing-library/jest-dom"

vi.mock("sonner", () => ({ toast: { error: vi.fn(), success: vi.fn() } }))

import { BarcodeScannerInput } from "@/components/shared/barcode-scanner-input"
import { scanBurst } from "../helpers/scanner-keys"

function dispatchScan(code: string) {
  act(() => scanBurst(code))
}

beforeEach(() => {
  vi.useFakeTimers()
})
afterEach(() => {
  vi.useRealTimers()
  vi.restoreAllMocks()
})

describe("BarcodeScannerInput — temporizador de reposo", () => {
  it("(c) comportamiento intacto: tras un escaneo el estado vuelve a idle a los 1,5 s", () => {
    render(<BarcodeScannerInput onScan={() => ({ ok: true, label: "Tomate" })} />)
    dispatchScan("7791234567898")
    expect(screen.getByRole("status")).toHaveTextContent("✓ Tomate")
    act(() => {
      vi.advanceTimersByTime(1499)
    })
    expect(screen.getByRole("status")).toHaveTextContent("✓ Tomate")
    act(() => {
      vi.advanceTimersByTime(1)
    })
    expect(screen.getByRole("status")).toHaveTextContent("Scanner listo")
  })

  it("(a) al desmontar con el temporizador pendiente se cancela: no queda ningún timer vivo", () => {
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {})
    const { unmount } = render(<BarcodeScannerInput onScan={() => ({ ok: true, label: "Tomate" })} />)
    dispatchScan("7791234567898")
    const pendingBefore = vi.getTimerCount()
    expect(pendingBefore).toBeGreaterThan(0)
    const clearSpy = vi.spyOn(globalThis, "clearTimeout")
    unmount()
    expect(clearSpy).toHaveBeenCalled()
    expect(vi.getTimerCount()).toBe(0)
    act(() => {
      vi.advanceTimersByTime(1500)
    })
    expect(errorSpy).not.toHaveBeenCalled()
  })

  it("(b) dos escaneos seguidos dejan un solo temporizador y un único retorno a idle", () => {
    render(<BarcodeScannerInput onScan={() => ({ ok: true, label: "Tomate" })} />)
    dispatchScan("7791234567898")
    const afterFirst = vi.getTimerCount()
    act(() => {
      vi.advanceTimersByTime(1000)
    })
    dispatchScan("7791234567898")
    expect(vi.getTimerCount()).toBe(afterFirst)
    // El primer temporizador (vencía a los 1,5 s) ya no debe cortar el segundo.
    act(() => {
      vi.advanceTimersByTime(600)
    })
    expect(screen.getByRole("status")).toHaveTextContent("✓ Tomate")
    act(() => {
      vi.advanceTimersByTime(900)
    })
    expect(screen.getByRole("status")).toHaveTextContent("Scanner listo")
  })
})
