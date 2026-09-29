"use client"

import { useEffect, useRef, useCallback } from "react"
import { normalizeBarcode } from "@/lib/barcode-utils"

/**
 * balanza-etiquetas-pos (D9): resultado opcional de un escaneo, para que el
 * indicador (`BarcodeScannerInput`) muestre el producto agregado o el motivo
 * del error. Retrocompatible: `purchase-form`/`product-form` siguen pasando
 * un `onScan` que no devuelve nada.
 */
export interface ScanFeedback {
  ok: boolean
  label: string
}

export interface UseBarcodeScannerOptions {
  /** Called when a complete barcode has been scanned. */
  onScan: (barcode: string) => ScanFeedback | void
  /** Enables or disables the scanner listener. Default: true. */
  enabled?: boolean
  /**
   * Maximum milliseconds between the ARRIVAL of two consecutive keystrokes
   * (`KeyboardEvent.timeStamp`, see `keyArrivalTime`) for them to count as
   * scanner input. USB/HID scanners emit a character every 5-20 ms; human
   * typing stays well above 50 ms between keys. Default: 50.
   *
   * balanza-etiquetas-pos (11.4 ítem 6): se queda en 50 ms a propósito.
   * Medido en Chromium con un emulador HID (CDP sin esperar el ack): con la
   * CPU del renderer frenada x6, las llegadas de una ráfaga a 8 ms siguieron
   * a 8 ms mientras el procesamiento de la 2ª tecla se atrasaba 70-150 ms —
   * el defecto era el reloj (se medía el PROCESAMIENTO), no el umbral.
   * Subirlo no hace falta y encarece el error opuesto: con
   * `guardFocusedInput`, dos teclas humanas "rodadas" dentro del umbral se
   * toman por ráfaga y la segunda se previene.
   */
  scannerThreshold?: number
  /**
   * Minimum character count before onScan is triggered. Prevents
   * single-key presses or short sequences from firing. Default: 4.
   */
  minLength?: number
  /**
   * Regex for characters allowed in the barcode buffer.
   * Default: alphanumeric + common barcode separators.
   */
  allowedCharsRegex?: RegExp
  /**
   * balanza-etiquetas-pos (D9): el hook se suspende (ignora todo escaneo)
   * mientras exista un `[data-scanner-modal]:not([data-state="closed"])` que
   * NO contenga a `scopeRef.current` — Radix no expone `aria-modal`, así que
   * ningún selector por rol distingue un diálogo modal de un `Popover`
   * (`ProductPicker`, `SearchableSelect`), que nunca debe suspender. Sin
   * `scopeRef`, esta suspensión no aplica (retrocompatible: `purchase-form` y
   * `product-form` no la pasan y viven dentro de su propio diálogo).
   */
  scopeRef?: React.RefObject<HTMLElement | null>
  /**
   * balanza-etiquetas-pos (D9): evita que el PRIMER carácter de una ráfaga de
   * escáner quede escrito en el campo con foco (el hook no puede saber, en
   * esa primera tecla, si es un escaneo). Opt-in — el formulario de producto
   * NO la activa: ahí el escaneo SÍ debe escribir en el campo del código.
   *
   * Reglas: un evento con `repeat: true` (tecla mantenida) se ignora por
   * completo; desde el SEGUNDO carácter de una ráfaga se llama
   * `preventDefault()` sobre cada carácter siguiente y el terminador; al
   * confirmarse el escaneo, se deshace el primer carácter restaurando el
   * valor previo del campo (setter nativo + evento `input`, compatible con
   * inputs controlados de React) — sólo si el valor difiere.
   */
  guardFocusedInput?: boolean
}

/** Un elemento con `.value` nativo restaurable (input/textarea). */
type GuardableElement = HTMLInputElement | HTMLTextAreaElement

function isGuardableElement(el: Element | null): el is GuardableElement {
  return !!el && (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement)
}

/**
 * `true` cuando existe al menos un diálogo modal marcado abierto que NO
 * contiene `scopeRef.current` — el lector debe suspenderse. Sin `scopeRef`,
 * siempre `false` (retrocompatibilidad).
 */
function isSuspendedByModal(scopeRef?: React.RefObject<HTMLElement | null>): boolean {
  if (!scopeRef) return false
  if (typeof document === "undefined") return false
  const modals = document.querySelectorAll('[data-scanner-modal]:not([data-state="closed"])')
  for (let i = 0; i < modals.length; i++) {
    const modal = modals[i]
    if (!scopeRef.current || !modal.contains(scopeRef.current)) return true
  }
  return false
}

/**
 * Restaura el valor de un input/textarea controlado por React usando el
 * setter nativo del prototipo (React envuelve `.value` con su propio setter,
 * que no dispara el ciclo de reconciliación si se asigna directo) + un evento
 * `input` real para que el `onChange` del campo lo vea.
 */
function restoreNativeValue(el: GuardableElement, value: string): void {
  const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype
  const setter = Object.getOwnPropertyDescriptor(proto, "value")?.set
  if (setter) setter.call(el, value)
  else el.value = value
  el.dispatchEvent(new Event("input", { bubbles: true }))
}

/**
 * balanza-etiquetas-pos — cierre del defecto de foco (tasks.md 11.4 ítem 6):
 * el instante en que la tecla LLEGÓ al navegador, no el instante en que su
 * handler pudo correr.
 *
 * Con el foco en un input controlado del POS, el primer carácter de una
 * ráfaga (el único que `guardFocusedInput` deja escribir) dispara un
 * `onChange` y un re-render síncrono de la página. Un lector HID real no
 * espera a la página: las teclas siguientes ya llegaron y esperan en la cola
 * del navegador. Medido en Chromium con la CPU del renderer frenada x4: la
 * 2ª tecla esperó 64-72 ms en cola con llegadas a ≤ 25 ms — un `Date.now()`
 * leído en el handler veía un gap de 70 ms, partía la ráfaga, dejaba el
 * código escrito en el campo y no agregaba la línea.
 *
 * `e.timeStamp` es el sello que el navegador pone al recibir la tecla (en el
 * mismo reloj que `performance.now()`), independiente de cuánto tardó React.
 * Sin sello (0 — algún evento sintético de un entorno viejo), cae a
 * `performance.now()`: monótono, a diferencia de `Date.now()`.
 */
function keyArrivalTime(e: KeyboardEvent): number {
  return e.timeStamp > 0 ? e.timeStamp : performance.now()
}

/**
 * Fix post-revisión-adversarial-#599 (F1, segunda causa raíz): un valor por
 * `default` en la desestructuración de parámetros es una expresión que se
 * evalúa de NUEVO en cada llamada — con `allowedCharsRegex = /…/` inline,
 * cada render del caller que no pasa esta prop (todos: `BarcodeScannerInput`
 * no la expone) creaba un `RegExp` con identidad nueva, que quedaba en las
 * deps del efecto y lo resuscribía en CADA render sin importar el fix de
 * `onScanRef` de más abajo. Constante de módulo = misma identidad siempre.
 */
const DEFAULT_ALLOWED_CHARS_REGEX = /^[A-Za-z0-9\-_.]$/

/**
 * Document-level barcode scanner hook.
 *
 * Listens to `keydown` events at the document level and differentiates
 * between hardware scanner input (rapid burst: < scannerThreshold ms between
 * the ARRIVAL of consecutive keys, `keyArrivalTime`) and human keyboard
 * typing (slower).
 *
 * When a burst of chars ends with an Enter/Tab key (scanner terminator) or
 * times out after 4× scannerThreshold ms, `onScan` is called if the buffer
 * meets `minLength`.
 *
 * Does NOT intercept human keystrokes — only calls preventDefault on Enter
 * when the buffer came from scanner-speed input, so forms behave normally.
 */
export function useBarcodeScanner({
  onScan,
  enabled = true,
  scannerThreshold = 50,
  minLength = 4,
  allowedCharsRegex = DEFAULT_ALLOWED_CHARS_REGEX,
  scopeRef,
  guardFocusedInput = false,
}: UseBarcodeScannerOptions) {
  const bufferRef        = useRef<string>("")
  // Llegada (`keyArrivalTime`) de la última tecla de la ráfaga en curso;
  // `null` = no hay ráfaga (un sello real puede valer casi 0 en una página
  // recién cargada, así que 0 no sirve de centinela).
  const lastKeyTimeRef   = useRef<number | null>(null)
  const flushTimerRef    = useRef<ReturnType<typeof setTimeout> | null>(null)
  // True only when ALL buffered chars arrived at scanner speed
  const fromScannerRef   = useRef<boolean>(true)
  // balanza-etiquetas-pos (D9, guardFocusedInput): el elemento y el valor que
  // tenía ANTES del primer carácter de la ráfaga en curso.
  const guardedElementRef  = useRef<GuardableElement | null>(null)
  const guardedPrevValueRef = useRef<string>("")

  // Fix post-revisión-adversarial-#599 (F1): `onScan` NO puede ser una
  // dependencia del efecto que suscribe el listener de `document` — en el
  // POS y el formulario de venta llega como una función SIN memoizar (nueva
  // identidad en cada render), y cada tecla que llega al campo con foco
  // dispara un `onChange` que re-renderiza al padre. Si el efecto tuviera
  // `onScan` en sus deps, se RE-SUSCRIBIRÍA en cada una de esas teclas, y su
  // cleanup (`resetBuffer`) vaciaría el buffer a mitad de la ráfaga — la
  // etiqueta nunca junta `minLength` y queda escrita entera en el campo. La
  // ref siempre apunta a la versión más reciente sin forzar la resuscripción.
  const onScanRef = useRef(onScan)
  onScanRef.current = onScan

  const resetBuffer = useCallback(() => {
    bufferRef.current      = ""
    lastKeyTimeRef.current = null
    fromScannerRef.current = true
    guardedElementRef.current  = null
    guardedPrevValueRef.current = ""
    if (flushTimerRef.current !== null) {
      clearTimeout(flushTimerRef.current)
      flushTimerRef.current = null
    }
  }, [])

  // Auto-flush por temporizador: SÓLO para lectores configurados sin
  // terminador (Enter/Tab).
  const flush = useCallback(() => {
    flushTimerRef.current = null
    const code = normalizeBarcode(bufferRef.current)
    // balanza-etiquetas-pos (11.4 ítem 6): un buffer más corto que
    // `minLength` no puede ser un escaneo, así que el temporizador no tiene
    // nada que decidir — y NO debe vaciar la ráfaga: si el re-render que
    // disparó el primer carácter tardó más que el temporizador, éste puede
    // correr ANTES que las teclas del lector que ya llegaron y esperan en la
    // cola; vaciarla ahí partía la etiqueta igual que el reloj viejo. La
    // próxima tecla se juzga por su propia llegada (`keyArrivalTime`): si
    // es tipeo humano, abre una ráfaga nueva y descarta este resto.
    if (code.length < minLength) return
    if (fromScannerRef.current) {
      if (guardFocusedInput && guardedElementRef.current) {
        const el = guardedElementRef.current
        if (el.value !== guardedPrevValueRef.current) {
          restoreNativeValue(el, guardedPrevValueRef.current)
        }
      }
      onScanRef.current(code)
    }
    resetBuffer()
    // `onScan` deliberadamente AFUERA de las deps (ver `onScanRef` arriba) —
    // `flush` debe quedar ESTABLE aunque el `onScan` del caller cambie de
    // identidad en cada render.
  }, [minLength, resetBuffer, guardFocusedInput])

  useEffect(() => {
    if (!enabled) return

    function handleKeyDown(e: KeyboardEvent) {
      if (isSuspendedByModal(scopeRef)) {
        resetBuffer()
        return
      }

      // balanza-etiquetas-pos (D9): una tecla mantenida autorrepite cada
      // ~33 ms (por debajo del umbral de 50 ms) — sin esto, un "0" mantenido
      // en un campo numérico se tomaría como escaneo.
      if (e.repeat) return

      const now = keyArrivalTime(e)
      const last = lastKeyTimeRef.current
      // Un sello que RETROCEDE (dos fuentes de reloj distintas) no prueba
      // una ráfaga: se trata como tecla nueva, nunca como "rápida" — lo
      // contrario haría que `guardFocusedInput` se comiera una tecla humana.
      const gap = last === null ? Infinity : now - last
      const isNewBurst = gap < 0 || gap > scannerThreshold

      // ── Terminator keys: Enter or Tab ────────────────────────────────────
      if (e.key === "Enter" || e.key === "Tab") {
        if (bufferRef.current.length >= minLength && fromScannerRef.current) {
          // This Enter came after scanner-speed input — consume it
          e.preventDefault()
          e.stopPropagation()
          const code = normalizeBarcode(bufferRef.current)
          if (guardFocusedInput && guardedElementRef.current) {
            const el = guardedElementRef.current
            if (el.value !== guardedPrevValueRef.current) {
              restoreNativeValue(el, guardedPrevValueRef.current)
            }
          }
          onScanRef.current(code)
        }
        resetBuffer()
        return
      }

      // ── Only accumulate allowed characters ───────────────────────────────
      if (e.key.length !== 1 || !allowedCharsRegex.test(e.key)) return

      // ── guardFocusedInput: capturar el foco ANTES del primer carácter ────
      if (guardFocusedInput && isNewBurst) {
        const active = typeof document !== "undefined" ? document.activeElement : null
        if (isGuardableElement(active)) {
          guardedElementRef.current   = active
          guardedPrevValueRef.current = active.value
        } else {
          guardedElementRef.current = null
        }
      } else if (guardFocusedInput && !isNewBurst) {
        // Desde el SEGUNDO carácter rápido: no debe llegar al campo.
        e.preventDefault()
      }

      // ── Gap analysis ─────────────────────────────────────────────────────
      if (isNewBurst) {
        // Human-speed gap — reset buffer (prior chars were human typed)
        bufferRef.current      = ""
        fromScannerRef.current = true
      } else {
        // Scanner-speed — continue accumulating; mark as human if gap is large
        // (fromScannerRef is only set false when gap exceeds threshold, which
        // we already handled above by resetting, so this branch is always fast)
      }

      bufferRef.current    += e.key
      lastKeyTimeRef.current = now

      // Schedule auto-flush in case terminator is never sent
      if (flushTimerRef.current !== null) clearTimeout(flushTimerRef.current)
      flushTimerRef.current = setTimeout(flush, scannerThreshold * 4)
    }

    document.addEventListener("keydown", handleKeyDown, { capture: true })
    return () => {
      document.removeEventListener("keydown", handleKeyDown, { capture: true })
      resetBuffer()
    }
    // `onScan` deliberadamente AFUERA de las deps — ver `onScanRef` arriba.
    // Con `onScan` acá, un caller que lo pasa sin memoizar (POS, formulario
    // de venta) resuscribiría este efecto en cada tecla que llega a un
    // campo con foco, y el cleanup (`resetBuffer`) vaciaría el buffer a
    // mitad de la ráfaga (F1, revisión adversarial PR #599).
  }, [enabled, flush, resetBuffer, minLength, scannerThreshold, allowedCharsRegex, scopeRef, guardFocusedInput])
}
