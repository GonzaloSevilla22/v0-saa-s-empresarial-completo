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
import { BarcodeScannerInput } from "@/components/shared/barcode-scanner-input"
import { ResponsiveModal } from "@/components/shared/responsive-modal"
import {
  AlertDialog,
  AlertDialogContent,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog"
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover"
import { advanceArrival, pressScannerKey, scanBurst } from "../helpers/scanner-keys"

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

/**
 * Dispara un keydown real en `document`, como lo haría el lector físico: cada
 * tecla llega sellada (`timeStamp`) a ritmo de lector HID — ver
 * `__tests__/helpers/scanner-keys.ts` y el cierre del defecto de foco
 * (tasks.md 11.4 ítem 6).
 */
function pressKey(key: string, extra: Partial<KeyboardEventInit> = {}) {
  return pressScannerKey(key, extra)
}

/** Escanea un código completo (ráfaga rápida + Enter). */
function scanCode(code: string) {
  scanBurst(code)
}

/**
 * Simula la ÚNICA parte del "escribir en el campo" que jsdom no hace sola: la
 * inserción de texto que el navegador ejecuta como acción por defecto de un
 * `keydown` no prevenido. Usa el setter nativo del prototipo (como
 * `restoreNativeValue` en producción) + un evento `input` real para que el
 * `onChange` de un input CONTROLADO lo vea y re-renderice — exactamente lo
 * que pasa en un navegador real entre dos teclas de una ráfaga.
 */
function insertNativeChar(el: HTMLInputElement, ch: string): void {
  const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")?.set
  const next = el.value + ch
  if (setter) setter.call(el, next)
  else el.value = next
  el.dispatchEvent(new Event("input", { bubbles: true }))
}

/**
 * Escanea un código como lo vería un navegador REAL con `guardFocusedInput`:
 * cada tecla es un evento de `document` separado (no un único `act()` que
 * agrupa todo), y el carácter que el hook NO previno se escribe en el campo
 * con foco — que es justo lo que puede disparar el re-render del padre que
 * F1 (revisión adversarial PR #599) encontró rompiendo el buffer a mitad de
 * ráfaga. `act()` por tecla es necesario: agrupar todo en un solo `act()`
 * batchea los `setState` y nunca deja correr el efecto entre caracteres,
 * ocultando el bug (mismo motivo que F2 señala sobre los tests existentes).
 *
 * Reloj: cada tecla llega sellada a ritmo de lector (`pressScannerKey`), así
 * que el overhead del propio `act()`/re-render entre dos teclas no cuenta —
 * el hook mide la LLEGADA, no el procesamiento (tasks.md 11.4 ítem 6). Antes
 * de ese fix este helper congelaba el reloj con `vi.useFakeTimers()` para
 * esquivar justamente ese defecto; el caso con un re-render lento de verdad
 * vive en `use-barcode-scanner-arrival-time.test.tsx`.
 */
function scanCodeAsRealBrowser(input: HTMLInputElement, code: string): void {
  advanceArrival(1_000)
  for (const ch of code) {
    act(() => {
      const { defaultPrevented } = pressKey(ch)
      if (!defaultPrevented) insertNativeChar(input, ch)
    })
  }
  act(() => {
    pressKey("Enter")
  })
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
  // Fix F2 (revisión adversarial PR #599): sin fake timers, esta aserción
  // pasaba aunque se borrara `if (e.repeat) return` — el auto-flush del
  // buffer corre a los `scannerThreshold * 4` = 200 ms, DESPUÉS de que el
  // `expect` ya se había evaluado. Con el reloj avanzado 250 ms, el test
  // exige de verdad que ninguna tecla mantenida haya quedado en el buffer.
  beforeEach(() => {
    vi.useFakeTimers()
  })
  afterEach(() => {
    vi.useRealTimers()
  })

  it("una tecla mantenida (repeat: true) no se toma como escaneo", () => {
    const onScan = vi.fn()
    render(<ScannerHarness onScan={onScan} />)
    act(() => {
      for (let i = 0; i < 6; i++) pressKey("0", { repeat: true })
    })
    act(() => {
      vi.advanceTimersByTime(250)
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

    // Fix F2 (revisión adversarial PR #599): jsdom no inserta texto por sí
    // solo en un keydown — sin escribir el PRIMER carácter (el único que el
    // hook no previene) a mano, `input.value` nunca cambiaba de "1" y el
    // `expect` de abajo pasaba aunque se borrara `restoreNativeValue` por
    // completo. `scanCodeAsRealBrowser` simula esa inserción y usa un
    // `act()` por tecla (no uno solo agrupando toda la ráfaga).
    scanCodeAsRealBrowser(input, "7791234567898")

    expect(input.value).toBe("1")
  })

  it("una tecla mantenida (repeat) no revierte lo tipeado ni aparece error de no encontrado", () => {
    const onScan = vi.fn()
    render(<InputHarness onScan={onScan} />)
    const input = screen.getByLabelText("Cantidad") as HTMLInputElement
    input.value = "5"
    input.focus()

    vi.useFakeTimers()
    try {
      act(() => {
        for (let i = 0; i < 5; i++) pressKey("0", { repeat: true })
      })
      // Fix F2: sin avanzar el reloj más allá del auto-flush (200 ms), este
      // test pasaba aunque se borrara `if (e.repeat) return` — el buffer
      // nunca llegaba a vaciarse por timer ANTES del `expect`.
      act(() => {
        vi.advanceTimersByTime(250)
      })
    } finally {
      vi.useRealTimers()
    }

    expect(input.value).toBe("5")
    expect(onScan).not.toHaveBeenCalled()
  })

  // ── Regresión F1 (revisión adversarial PR #599) ───────────────────────────
  //
  // El POS y el formulario de venta pasan un `onScan` SIN memoizar (una
  // `function handleScan(code) {...}` declarada en el cuerpo del componente,
  // nueva identidad en cada render) y montan un campo controlado (Cantidad,
  // Precio, Descuento) que re-renderiza el componente en cada carácter que
  // llega a escribirse. Antes del fix, `onScan` estaba en las deps del
  // efecto que suscribe `document` — cada re-render resuscribía el efecto,
  // y su cleanup (`resetBuffer`) vaciaba el buffer a mitad de la ráfaga: la
  // etiqueta nunca llegaba a `minLength` y quedaba escrita entera en el
  // campo (y el Enter final, sin prevenir, podía enviar el <form>).
  describe("useBarcodeScanner — onScan inestable + input controlado (regresión F1)", () => {
    it("un onScan sin memoizar, recreado en cada render por el propio estado del input, igual completa el escaneo", () => {
      const scanned: string[] = []
      function InstableParentHarness() {
        const [quantity, setQuantity] = useState("1")
        // A propósito NO es un useCallback — así es exactamente como
        // `pos/page.tsx` y `sale-form.tsx` declaran `handleScan` (F1).
        function handleScan(code: string): void {
          scanned.push(code)
        }
        useBarcodeScanner({ onScan: handleScan, guardFocusedInput: true })
        return (
          <input
            aria-label="Cantidad"
            value={quantity}
            onChange={(e) => setQuantity(e.target.value)}
          />
        )
      }
      render(<InstableParentHarness />)
      const input = screen.getByLabelText("Cantidad") as HTMLInputElement
      input.focus()

      scanCodeAsRealBrowser(input, "7791234567898")

      expect(scanned).toEqual(["7791234567898"])
      // El primer carácter (el único no prevenido) queda restaurado.
      expect(input.value).toBe("1")
    })

    it("el mismo escenario a través de BarcodeScannerInput (POS/sale-form reales)", () => {
      const scanned: string[] = []
      function InstableParentHarness() {
        const [quantity, setQuantity] = useState("1")
        // Igual que `pos/page.tsx`: `function handleScan(code) { ... }` sin
        // memoizar, pasada directo como prop `onScan`.
        function handleScan(code: string): ScanFeedback {
          scanned.push(code)
          return { ok: true, label: "Tomate" }
        }
        return (
          <div>
            <input
              aria-label="Cantidad"
              value={quantity}
              onChange={(e) => setQuantity(e.target.value)}
            />
            <BarcodeScannerInput onScan={handleScan} guardFocusedInput />
          </div>
        )
      }
      render(<InstableParentHarness />)
      const input = screen.getByLabelText("Cantidad") as HTMLInputElement
      input.focus()

      scanCodeAsRealBrowser(input, "7791234567898")

      expect(scanned).toEqual(["7791234567898"])
      expect(input.value).toBe("1")
    })
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
