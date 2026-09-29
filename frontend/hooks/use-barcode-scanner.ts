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
   * Maximum milliseconds between consecutive keystrokes to be considered
   * scanner input. Hardware scanners emit characters at < 20 ms intervals;
   * human typing is typically > 50 ms. Default: 50.
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
 * between hardware scanner input (rapid burst < scannerThreshold ms per char)
 * and human keyboard typing (slower).
 *
 * When a burst of chars ends with an Enter/Tab key (scanner terminator) or
 * times out after 3× scannerThreshold ms, `onScan` is called if the buffer
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
  const lastKeyTimeRef   = useRef<number>(0)
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
    lastKeyTimeRef.current = 0
    fromScannerRef.current = true
    guardedElementRef.current  = null
    guardedPrevValueRef.current = ""
    if (flushTimerRef.current !== null) {
      clearTimeout(flushTimerRef.current)
      flushTimerRef.current = null
    }
  }, [])

  const flush = useCallback(() => {
    const code = normalizeBarcode(bufferRef.current)
    if (code.length >= minLength && fromScannerRef.current) {
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

      const now = Date.now()
      const gap = lastKeyTimeRef.current > 0
        ? now - lastKeyTimeRef.current
        : Infinity
      const isNewBurst = gap > scannerThreshold

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
