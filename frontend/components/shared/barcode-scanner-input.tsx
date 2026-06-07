"use client"

import { useState, useCallback } from "react"
import { ScanLine, Check, AlertCircle } from "lucide-react"
import { cn } from "@/lib/utils"
import { useBarcodeScanner } from "@/hooks/use-barcode-scanner"

interface BarcodeScannerInputProps {
  /** Called with the normalized barcode string on every successful scan. */
  onScan: (barcode: string) => void
  /** When false the scanner listener is suspended (e.g. while a modal is closed). */
  enabled?: boolean
  /** Additional CSS classes for the container badge. */
  className?: string
}

type ScanState = "idle" | "success" | "error"

/**
 * Non-blocking barcode scanner indicator for sale / purchase forms.
 *
 * Renders a small status badge that shows whether the document-level
 * scanner is active and provides visual feedback on each scan event.
 * It does not render an <input> element — it relies on the global
 * `useBarcodeScanner` hook which captures scanner keystrokes regardless
 * of which element currently has focus.
 *
 * Usage:
 *   <BarcodeScannerInput onScan={handleBarcodeScan} />
 */
export function BarcodeScannerInput({
  onScan,
  enabled = true,
  className,
}: BarcodeScannerInputProps) {
  const [state,        setState]        = useState<ScanState>("idle")
  const [lastCode,     setLastCode]     = useState<string>("")

  const handleScan = useCallback((barcode: string) => {
    setLastCode(barcode)
    setState("success")
    onScan(barcode)
    // Reset to idle after 1.5 s
    setTimeout(() => setState("idle"), 1500)
  }, [onScan])

  useBarcodeScanner({ onScan: handleScan, enabled })

  // ── Visual states ─────────────────────────────────────────────────────────

  const variants: Record<ScanState, { icon: React.ReactNode; label: string; cls: string }> = {
    idle: {
      icon:  <ScanLine className="h-3 w-3" />,
      label: "Scanner listo",
      cls:   "border-primary/30 bg-primary/5 text-primary/70",
    },
    success: {
      icon:  <Check className="h-3 w-3" />,
      label: lastCode ? `✓ ${lastCode}` : "Escaneado",
      cls:   "border-emerald-500/40 bg-emerald-500/10 text-emerald-400",
    },
    error: {
      icon:  <AlertCircle className="h-3 w-3" />,
      label: "No encontrado",
      cls:   "border-red-500/40 bg-red-500/10 text-red-400",
    },
  }

  const v = variants[state]

  return (
    <div
      className={cn(
        "inline-flex items-center gap-1.5 rounded-full border px-2.5 py-1 text-[11px] font-medium",
        "transition-all duration-300",
        enabled ? v.cls : "border-border/30 bg-muted/30 text-muted-foreground/40",
        className,
      )}
    >
      {enabled ? v.icon : <ScanLine className="h-3 w-3 opacity-30" />}
      <span>{enabled ? v.label : "Scanner inactivo"}</span>
    </div>
  )
}