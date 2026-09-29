/**
 * Teclas de lector de códigos para los tests de `useBarcodeScanner` y de sus
 * callers (POS, formulario de venta, `BarcodeScannerInput`).
 *
 * balanza-etiquetas-pos — cierre del defecto de foco (tasks.md 11.4 ítem 6):
 * el hook mide la ráfaga por el instante de LLEGADA de cada tecla
 * (`KeyboardEvent.timeStamp`), no por cuándo corre su handler. Estos helpers
 * sellan ese instante a mano en cada evento — una propiedad propia que tapa
 * el getter de `Event.prototype` — con un reloj virtual monótono, así el
 * resultado NO depende de la carga de CPU de la corrida. (jsdom sella
 * `timeStamp` con `Date.now()` real al construir el evento: bajo
 * `maxWorkers: 8`, dos teclas "seguidas" podían quedar a más de 50 ms y la
 * ráfaga se partía — la intermitencia histórica de
 * `sale-form-scale-scanner.test.tsx`.)
 */

/** Separación entre teclas de un lector HID típico (5-20 ms). */
export const SCANNER_KEY_GAP_MS = 5
/** Pausa que separa dos ráfagas sucesivas (muy por encima del umbral). */
const BETWEEN_BURSTS_MS = 1_000

let arrivalClockMs = 1_000

/** Avanza el reloj de llegada y devuelve el instante nuevo. */
export function advanceArrival(ms: number): number {
  arrivalClockMs += ms
  return arrivalClockMs
}

/** Un `keydown` que "llegó" al navegador en `arrivalMs` (su `timeStamp`). */
export function keydownAt(key: string, arrivalMs: number, init: Partial<KeyboardEventInit> = {}): KeyboardEvent {
  const event = new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...init })
  Object.defineProperty(event, "timeStamp", { value: arrivalMs })
  return event
}

/** Despacha el evento en `document` (como el lector físico) y devuelve si el hook lo previno. */
export function dispatchKeydown(event: KeyboardEvent): { event: KeyboardEvent; defaultPrevented: boolean } {
  const defaultPrevented = !document.dispatchEvent(event)
  return { event, defaultPrevented }
}

/** Una tecla que llega `gapMs` después de la anterior (por defecto, a ritmo de lector). */
export function pressScannerKey(
  key: string,
  init: Partial<KeyboardEventInit> = {},
  gapMs: number = SCANNER_KEY_GAP_MS,
): { event: KeyboardEvent; defaultPrevented: boolean } {
  return dispatchKeydown(keydownAt(key, advanceArrival(gapMs), init))
}

/** Ráfaga completa de lector: los caracteres a ritmo HID + Enter. */
export function scanBurst(code: string): void {
  advanceArrival(BETWEEN_BURSTS_MS)
  for (const ch of code) pressScannerKey(ch)
  pressScannerKey("Enter")
}
