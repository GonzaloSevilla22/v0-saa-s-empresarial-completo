/**
 * balanza-etiquetas-pos (task 5.1) — RED→GREEN de las extensiones a
 * `useBarcodeScanner` (D9): feedback de retorno, `scopeRef` (suspensión por
 * modal), `guardFocusedInput` (e.repeat, preventDefault desde el 2º carácter,
 * restauración del valor previo).
 *
 * `scopeRef` se ejercita con los componentes REALES del sistema de diseño
 * (ResponsiveModal → Dialog/Sheet, AlertDialog, Popover) — nunca un <div> con
 * atributos sintéticos.
 */
import React, { useRef, useState } from "react"
import { describe, it, expect, vi, beforeAll, beforeEach, afterEach } from "vitest"
import { render, screen, act } from "@testing-library/react"
import "@testing-library/jest-dom"
import { useBarcodeScanner, type ScanFeedback } from "@/hooks/use-barcode-scanner"
import { ResponsiveModal } from "@/components/shared/responsive-modal"
import {
  AlertDialog,
  AlertDialogContent,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog"
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover"

beforeAll(() => {
  // ResponsiveModal (useIsMobile) necesita matchMedia — fuerza la rama Dialog.
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

/** Dispara un keydown real en `document`, como lo haría el lector físico. */
function pressKey(key: string, extra: Partial<KeyboardEventInit> = {}) {
  const event = new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...extra })
  const defaultPrevented = !document.dispatchEvent(event)
  return { event, defaultPrevented }
}

/** Escanea un código completo (ráfaga rápida + Enter) sin terminador aparte. */
function scanCode(code: string) {
  for (const ch of code) pressKey(ch)
  pressKey("Enter")
}

// ── Harness genérico (sin diálogos) ─────────────────────────────────────────

function ScannerHarness({
  onScan,
  scopeRef,
  guardFocusedInput,
  enabled = true,
}: {
  onScan: (code: string) => ScanFeedback | void
  scopeRef?: React.RefObject<HTMLElement | null>
  guardFocusedInput?: boolean
  enabled?: boolean
}) {
  useBarcodeScanner({ onScan, scopeRef, guardFocusedInput, enabled })
  return <div data-testid="scope" ref={scopeRef as React.RefObject<HTMLDivElement>} />
}

describe("useBarcodeScanner — feedback de retorno (D9)", () => {
  it("onScan puede devolver { ok, label } sin que el hook lo exija", () => {
    const onScan = vi.fn((_code: string): ScanFeedback => ({ ok: true, label: "Tomate agregado" }))
    render(<ScannerHarness onScan={onScan} />)
    act(() => scanCode("7791234567898"))
    expect(onScan).toHaveBeenCalledWith("7791234567898")
  })

  it("retrocompatible: un onScan que no devuelve nada sigue funcionando", () => {
    const onScan = vi.fn()
    render(<ScannerHarness onScan={onScan} />)
    act(() => scanCode("7791234567898"))
    expect(onScan).toHaveBeenCalledTimes(1)
  })
})

describe("useBarcodeScanner — enabled", () => {
  it("enabled = false ignora todo escaneo", () => {
    const onScan = vi.fn()
    render(<ScannerHarness onScan={onScan} enabled={false} />)
    act(() => scanCode("7791234567898"))
    expect(onScan).not.toHaveBeenCalled()
  })
})

describe("useBarcodeScanner — e.repeat (D9)", () => {
  it("una tecla mantenida (repeat: true) no se toma como escaneo", () => {
    const onScan = vi.fn()
    render(<ScannerHarness onScan={onScan} />)
    act(() => {
      for (let i = 0; i < 6; i++) pressKey("0", { repeat: true })
    })
    expect(onScan).not.toHaveBeenCalled()
  })
})

describe("useBarcodeScanner — guardFocusedInput (D9)", () => {
  function InputHarness({ onScan }: { onScan: (code: string) => void }) {
    useBarcodeScanner({ onScan, guardFocusedInput: true })
    return <input aria-label="Cantidad" defaultValue="1" />
  }

  it("desde el segundo carácter rápido, el evento llega con defaultPrevented", () => {
    render(<InputHarness onScan={vi.fn()} />)
    const input = screen.getByLabelText("Cantidad") as HTMLInputElement
    input.focus()

    let firstPrevented = true
    let secondPrevented = false
    act(() => {
      firstPrevented = pressKey("7").defaultPrevented
      secondPrevented = pressKey("7").defaultPrevented
    })
    expect(firstPrevented).toBe(false)
    expect(secondPrevented).toBe(true)
  })

  it("al confirmarse el escaneo, el valor del input controlado se restaura y dispara 'input'", () => {
    function ControlledInputHarness({ onScan }: { onScan: (code: string) => void }) {
      const [value, setValue] = useState("1")
      useBarcodeScanner({ onScan, guardFocusedInput: true })
      return (
        <input
          aria-label="Cantidad"
          value={value}
          onChange={(e) => setValue(e.target.value)}
        />
      )
    }
    render(<ControlledInputHarness onScan={vi.fn()} />)
    const input = screen.getByLabelText("Cantidad") as HTMLInputElement
    input.focus()

    act(() => scanCode("7791234567898"))

    expect(input.value).toBe("1")
  })

  it("una tecla mantenida (repeat) no revierte lo tipeado ni aparece error de no encontrado", () => {
    const onScan = vi.fn()
    render(<InputHarness onScan={onScan} />)
    const input = screen.getByLabelText("Cantidad") as HTMLInputElement
    input.value = "5"
    input.focus()

    act(() => {
      for (let i = 0; i < 5; i++) pressKey("0", { repeat: true })
    })

    expect(input.value).toBe("5")
    expect(onScan).not.toHaveBeenCalled()
  })

  it("sin la opción (product-form), ningún carácter se previene — el navegador lo escribe en el campo con foco", () => {
    function PlainInputHarness({ onScan }: { onScan: (code: string) => void }) {
      useBarcodeScanner({ onScan }) // guardFocusedInput NO activado
      return <input aria-label="Código" defaultValue="" />
    }
    const onScan = vi.fn()
    render(<PlainInputHarness onScan={onScan} />)
    const input = screen.getByLabelText("Código") as HTMLInputElement
    input.focus()

    // jsdom no simula la inserción de texto por defecto de un keydown (eso lo
    // hace el motor de renderizado del navegador, no el DOM); lo que SÍ se
    // puede verificar acá es el contrato de `product-form`: sin la opción,
    // el hook nunca llama `preventDefault()` sobre los caracteres del código
    // — así que el navegador real los escribe en el campo con foco.
    let anyPrevented = false
    act(() => {
      for (const ch of "7791234567898") {
        if (pressKey(ch).defaultPrevented) anyPrevented = true
      }
      pressKey("Enter")
    })

    expect(anyPrevented).toBe(false)
    expect(onScan).toHaveBeenCalledWith("7791234567898")
  })
})

describe("useBarcodeScanner — scopeRef y diálogos reales (D9)", () => {
  it("un ResponsiveModal (Dialog) abierto que NO contiene el scope suspende la lectura", () => {
    const onScanSpy = vi.fn()
    function HarnessWithSpy() {
      const scopeRef = useRef<HTMLDivElement>(null)
      useBarcodeScanner({ onScan: onScanSpy, scopeRef })
      return (
        <div>
          <div data-testid="scope" ref={scopeRef} />
          <ResponsiveModal open={true} onOpenChange={() => {}} title="Cuenta bancaria">
            <p>contenido</p>
          </ResponsiveModal>
        </div>
      )
    }
    render(<HarnessWithSpy />)
    expect(screen.getByRole("dialog")).toBeInTheDocument()

    act(() => scanCode("7791234567898"))
    expect(onScanSpy).not.toHaveBeenCalled()
  })

  it("un ResponsiveModal que SÍ contiene el scope (formulario dentro del diálogo) sigue leyendo", () => {
    const onScan = vi.fn()
    function HarnessInsideDialog() {
      const scopeRef = useRef<HTMLDivElement>(null)
      useBarcodeScanner({ onScan, scopeRef })
      return (
        <ResponsiveModal open={true} onOpenChange={() => {}} title="Nueva venta">
          <div data-testid="scope" ref={scopeRef}>
            formulario de venta
          </div>
        </ResponsiveModal>
      )
    }
    render(<HarnessInsideDialog />)
    act(() => scanCode("7791234567898"))
    expect(onScan).toHaveBeenCalledWith("7791234567898")
  })

  it("un AlertDialog abierto ENCIMA del que contiene el scope suspende la lectura", () => {
    const onScan = vi.fn()
    function HarnessWithAlert() {
      const scopeRef = useRef<HTMLDivElement>(null)
      useBarcodeScanner({ onScan, scopeRef })
      return (
        <ResponsiveModal open={true} onOpenChange={() => {}} title="Editar venta">
          <div data-testid="scope" ref={scopeRef}>
            formulario
            <AlertDialog open={true}>
              <AlertDialogContent>
                <AlertDialogTitle>¿Anular la venta?</AlertDialogTitle>
              </AlertDialogContent>
            </AlertDialog>
          </div>
        </ResponsiveModal>
      )
    }
    render(<HarnessWithAlert />)
    expect(screen.getByText("¿Anular la venta?")).toBeInTheDocument()

    act(() => scanCode("7791234567898"))
    expect(onScan).not.toHaveBeenCalled()
  })

  it("con el ProductPicker (Popover) abierto SÍ se lee — el Popover no lleva data-scanner-modal", () => {
    const onScan = vi.fn()
    function HarnessWithPopover() {
      const scopeRef = useRef<HTMLDivElement>(null)
      useBarcodeScanner({ onScan, scopeRef })
      return (
        <div data-testid="scope" ref={scopeRef}>
          <Popover open={true}>
            <PopoverTrigger>abrir</PopoverTrigger>
            <PopoverContent>buscador de productos</PopoverContent>
          </Popover>
        </div>
      )
    }
    render(<HarnessWithPopover />)
    expect(screen.getByText("buscador de productos")).toBeInTheDocument()

    act(() => scanCode("7791234567898"))
    expect(onScan).toHaveBeenCalledWith("7791234567898")
  })

  it("sin ningún diálogo abierto, con scopeRef definido, la lectura funciona normalmente", () => {
    const onScan = vi.fn()
    function Harness() {
      const scopeRef = useRef<HTMLDivElement>(null)
      useBarcodeScanner({ onScan, scopeRef })
      return <div data-testid="scope" ref={scopeRef} />
    }
    render(<Harness />)
    act(() => scanCode("7791234567898"))
    expect(onScan).toHaveBeenCalledWith("7791234567898")
  })
})
