"use client"

import { useEffect, useRef, useCallback } from "react"
import { normalizeBarcode } from "@/lib/barcode-utils"

export interface UseBarcodeScannerOptions {
  /** Called when a complete barcode has been scanned. */
  onScan: (barcode: string) => void
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
}

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
  allowedCharsRegex = /^[A-Za-z0-9\-_.]$/,
}: UseBarcodeScannerOptions) {
  const bufferRef        = useRef<string>("")
  const lastKeyTimeRef   = useRef<number>(0)
  const flushTimerRef    = useRef<ReturnType<typeof setTimeout> | null>(null)
  // True only when ALL buffered chars arrived at scanner speed
  const fromScannerRef   = useRef<boolean>(true)

  const resetBuffer = useCallback(() => {
    bufferRef.current      = ""
    lastKeyTimeRef.current = 0
    fromScannerRef.current = true
    if (flushTimerRef.current !== null) {
      clearTimeout(flushTimerRef.current)
      flushTimerRef.current = null
    }
  }, [])

  const flush = useCallback(() => {
    const code = normalizeBarcode(bufferRef.current)
    if (code.length >= minLength && fromScannerRef.current) {
      onScan(code)
    }
    resetBuffer()
  }, [onScan, minLength, resetBuffer])

  useEffect(() => {
    if (!enabled) return

    function handleKeyDown(e: KeyboardEvent) {
      const now = Date.now()
      const gap = lastKeyTimeRef.current > 0
        ? now - lastKeyTimeRef.current
        : Infinity

      // ── Terminator keys: Enter or Tab ────────────────────────────────────
      if (e.key === "Enter" || e.key === "Tab") {
        if (bufferRef.current.length >= minLength && fromScannerRef.current) {
          // This Enter came after scanner-speed input — consume it
          e.preventDefault()
          e.stopPropagation()
          const code = normalizeBarcode(bufferRef.current)
          onScan(code)
        }
        resetBuffer()
        return
      }

      // ── Only accumulate allowed characters ───────────────────────────────
      if (e.key.length !== 1 || !allowedCharsRegex.test(e.key)) return

      // ── Gap analysis ─────────────────────────────────────────────────────
      if (gap > scannerThreshold) {
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
  }, [enabled, flush, resetBuffer, onScan, minLength, scannerThreshold, allowedCharsRegex])
}