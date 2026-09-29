/**
 * balanza-etiquetas-pos — cierre del defecto de foco (tasks.md 11.4 ítem 6).
 *
 * Causa raíz (medida en Chromium real con un emulador de lector HID, ver
 * tasks.md): el hook medía el gap entre teclas con `Date.now()` leído DENTRO
 * del handler de `keydown` — cuándo el hilo principal PUDO procesar la tecla,
 * no cuándo LLEGÓ. Con el foco en un input controlado del POS, el primer
 * carácter (el único que el guard deja escribir) dispara un `onChange` y un
 * re-render síncrono de la página; las teclas siguientes del lector ya
 * llegaron (el lector no espera a la página) pero esperan en la cola del
 * navegador. Si ese re-render dura más que el umbral, la segunda tecla se
 * procesa "tarde", la ráfaga se parte, el código queda escrito en el campo y
 * la línea no se agrega.
 *
 * Modelo de estos tests — determinista, sin depender de la carga de la CPU:
 *  - LLEGADA de cada tecla = `timeStamp` del evento, sellado a mano
 *    (`keydownAt`), como lo sella el navegador cuando la tecla entra;
 *  - PROCESAMIENTO = reloj falso de vitest (`Date` y `performance`), que el
 *    `onChange` del input avanza `renderCostMs` para simular el re-render.
 * Cada tecla se despacha en su propio `act()`, recién cuando "terminó" de
 * procesarse la anterior y nunca antes de haber llegado — la cola del
 * navegador, tecla por tecla.
 */
import React, { useState } from "react"
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import { render, screen, act } from "@testing-library/react"
import "@testing-library/jest-dom"
import { useBarcodeScanner } from "@/hooks/use-barcode-scanner"
import { keydownAt, dispatchKeydown } from "../helpers/scanner-keys"

/** Re-render del POS medido en Chromium con CPU x4 (PC de mostrador lenta): la 2ª tecla esperó 64-72 ms en cola. */
const RENDER_COST_MS = 70
/** Ritmo de un lector HID real. */
const HID_GAP_MS = 10
/** Ritmo de un humano rápido. */
const HUMAN_GAP_MS = 200
const CODE = "2002610013638"

let renderCostMs = RENDER_COST_MS

/**
 * Inserción de texto que el navegador hace como acción por defecto de un
 * `keydown` NO prevenido (jsdom no la hace): setter nativo + `input` real,
 * para que el `onChange` del input controlado lo vea — y re-renderice.
 */
function insertNativeChar(el: HTMLInputElement, ch: string): void {
  const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")?.set
  setter?.call(el, el.value + ch)
  el.dispatchEvent(new Event("input", { bubbles: true }))
}

/** Input controlado cuyo `onChange` "tarda" `renderCostMs` en el reloj de procesamiento. */
function SlowControlledInput({ onScan }: { onScan: (code: string) => void }) {
  const [value, setValue] = useState("1")
  useBarcodeScanner({ onScan, guardFocusedInput: true })
  return (
    <input
      aria-label="Cantidad"
      value={value}
      onChange={(e) => {
        setValue(e.target.value)
        vi.advanceTimersByTime(renderCostMs)
      }}
    />
  )
}

type Arrival = { key: string; at: number; init?: Partial<KeyboardEventInit> }

/**
 * Despacha las teclas en orden de llegada, como la cola del navegador: una
 * tecla se procesa cuando llegó Y el hilo principal terminó con la anterior.
 */
function deliver(input: HTMLInputElement, arrivals: Arrival[]): KeyboardEvent[] {
  const events: KeyboardEvent[] = []
  const origin = performance.now() - arrivals[0].at
  for (const { key, at, init } of arrivals) {
    const idle = origin + at - performance.now()
    if (idle > 0) act(() => vi.advanceTimersByTime(idle))
    const event = keydownAt(key, at, init)
    act(() => {
      const { defaultPrevented } = dispatchKeydown(event)
      if (!defaultPrevented && key.length === 1) insertNativeChar(input, key)
    })
    events.push(event)
  }
  return events
}

function burst(code: string, gapMs: number, start = 10_000): Arrival[] {
  return [...code, "Enter"].map((key, i) => ({ key, at: start + i * gapMs }))
}

function mountFocused(onScan: (code: string) => void): HTMLInputElement {
  render(<SlowControlledInput onScan={onScan} />)
  const input = screen.getByLabelText("Cantidad") as HTMLInputElement
  input.focus()
  return input
}

beforeEach(() => {
  vi.useFakeTimers()
  renderCostMs = RENDER_COST_MS
})
afterEach(() => {
  vi.useRealTimers()
})

describe("useBarcodeScanner — mide la ráfaga por la LLEGADA de la tecla, no por su procesamiento", () => {
  it("13 dígitos + Enter a ritmo de lector, con un re-render de 70 ms tras el primer carácter: se decodifica entero, sin residuo y sin submit", () => {
    const onScan = vi.fn()
    const input = mountFocused(onScan)

    const events = deliver(input, burst(CODE, HID_GAP_MS))

    expect(onScan).toHaveBeenCalledTimes(1)
    expect(onScan).toHaveBeenCalledWith(CODE)
    expect(input.value).toBe("1")
    // El Enter del lector se consume: nunca llega a enviar el <form> del POS.
    expect(events[events.length - 1].defaultPrevented).toBe(true)
    // Sólo el primer carácter llegó al campo; del segundo en adelante, prevenidos.
    expect(events.slice(1, CODE.length).every((e) => e.defaultPrevented)).toBe(true)
  })

  it("un re-render todavía más lento (250 ms, por encima del auto-flush de 200 ms) tampoco parte la ráfaga", () => {
    renderCostMs = 250
    const onScan = vi.fn()
    const input = mountFocused(onScan)

    deliver(input, burst(CODE, HID_GAP_MS))

    expect(onScan).toHaveBeenCalledWith(CODE)
    expect(input.value).toBe("1")
  })

  it("tipeo humano (una tecla cada 200 ms) con el mismo re-render lento: nada se previene ni se escanea", () => {
    const onScan = vi.fn()
    const input = mountFocused(onScan)

    const events = deliver(input, burst("23456", HUMAN_GAP_MS))

    expect(events.some((e) => e.defaultPrevented)).toBe(false)
    expect(onScan).not.toHaveBeenCalled()
    expect(input.value).toBe("123456")
  })

  it("una tecla mantenida (repeat) que autorrepite a ritmo de lector sigue ignorada", () => {
    const onScan = vi.fn()
    const input = mountFocused(onScan)

    const repeats: Arrival[] = Array.from({ length: 8 }, (_, i) => ({
      key: "0",
      at: 10_000 + i * HID_GAP_MS,
      init: { repeat: true },
    }))
    const events = deliver(input, [...repeats, { key: "Enter", at: 10_000 + 8 * HID_GAP_MS }])
    act(() => vi.advanceTimersByTime(1_000))

    expect(events.some((e) => e.defaultPrevented)).toBe(false)
    expect(onScan).not.toHaveBeenCalled()
  })

  it("un timeStamp que retrocede (otra fuente de reloj) arranca una ráfaga nueva: nunca se come la tecla", () => {
    // Sin re-render: la 2ª tecla se procesa en el mismo instante que la 1ª —
    // sólo el sello que retrocede distingue este caso de una ráfaga.
    renderCostMs = 0
    const onScan = vi.fn()
    const input = mountFocused(onScan)

    const events = deliver(input, [
      { key: "5", at: 10_000 },
      { key: "6", at: 1_000 },
    ])

    expect(events[1].defaultPrevented).toBe(false)
    expect(input.value).toBe("156")
  })

  it("sin timeStamp (0), cae a performance.now(): la ráfaga sin pausas se decodifica y el tipeo lento no", () => {
    renderCostMs = 0
    const onScan = vi.fn()
    const input = mountFocused(onScan)

    for (const key of [...CODE, "Enter"]) {
      act(() => {
        const { defaultPrevented } = dispatchKeydown(keydownAt(key, 0))
        if (!defaultPrevented && key.length === 1) insertNativeChar(input, key)
      })
    }
    expect(onScan).toHaveBeenCalledWith(CODE)
    expect(input.value).toBe("1")

    onScan.mockClear()
    for (const key of [..."7890", "Enter"]) {
      act(() => vi.advanceTimersByTime(HUMAN_GAP_MS))
      act(() => {
        const { defaultPrevented } = dispatchKeydown(keydownAt(key, 0))
        if (!defaultPrevented && key.length === 1) insertNativeChar(input, key)
      })
    }
    expect(onScan).not.toHaveBeenCalled()
    expect(input.value).toBe("17890")
  })
})
