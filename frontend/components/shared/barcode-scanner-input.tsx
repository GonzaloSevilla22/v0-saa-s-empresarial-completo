"use client"

import { useState, useCallback } from "react"
import { toast } from "sonner"
import { ScanLine, Check, AlertCircle } from "lucide-react"
import { cn } from "@/lib/utils"
import { useBarcodeScanner, type ScanFeedback, type UseBarcodeScannerOptions } from "@/hooks/use-barcode-scanner"

interface BarcodeScannerInputProps {
  /**
   * balanza-etiquetas-pos (D9): puede devolver `{ ok, label }` para que el
   * indicador muestre el producto agregado o el motivo del error — un
   * `onScan` que no devuelve nada (purchase-form, sale-form antes de este
   * change) se sigue tratando como éxito silencioso.
   */
  onScan: (barcode: string) => ScanFeedback | void
  /** When false the scanner listener is suspended (e.g. while a modal is closed). */
  enabled?: boolean
  /** Additional CSS classes for the container badge. */
  className?: string
  /** balanza-etiquetas-pos (D9): ver `UseBarcodeScannerOptions.scopeRef`. */
  scopeRef?: UseBarcodeScannerOptions["scopeRef"]
  /** balanza-etiquetas-pos (D9): ver `UseBarcodeScannerOptions.guardFocusedInput`. */
  guardFocusedInput?: boolean
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
 * balanza-etiquetas-pos (D9): el texto del estado vive en una región
 * `role="status" aria-live="polite"` — es el único canal del resultado de
 * una etiqueta agregada en el POS. Los errores se anuncian ADEMÁS por
 * `toast.error` con el mensaje completo; la píldora sólo muestra un resumen
 * truncado que nunca desborda en móvil.
 *
 * Usage:
 *   <BarcodeScannerInput onScan={handleBarcodeScan} />
 */
export function BarcodeScannerInput({
  onScan,
  enabled = true,
  className,
  scopeRef,
  guardFocusedInput,
}: BarcodeScannerInputProps) {
  const [state, setState] = useState<ScanState>("idle")
  const [label, setLabel] = useState<string>("")

  const handleScan = useCallback((barcode: string) => {
    const feedback = onScan(barcode)
    if (feedback) {
      setState(feedback.ok ? "success" : "error")
      setLabel(feedback.label)
      if (!feedback.ok) toast.error(feedback.label)
    } else {
      // Retrocompatible: sin feedback explícito, se asume éxito (comportamiento
      // previo de purchase-form/sale-form antes de este change).
      setState("success")
      setLabel(barcode)
    }
    // Reset to idle after 1.5 s
    setTimeout(() => setState("idle"), 1500)
  }, [onScan])

  useBarcodeScanner({ onScan: handleScan, enabled, scopeRef, guardFocusedInput })

  // ── Visual states — tokens semánticos con pares ya medidos por
  // token-contrast-aa (text-success/bg-success/15, text-destructive/
  // bg-destructive/15, text-primary SIN alpha). ─────────────────────────────

  const variants: Record<ScanState, { icon: React.ReactNode; label: string; cls: string }> = {
    idle: {
      icon:  <ScanLine className="h-3 w-3" />,
      label: "Scanner listo",
      cls:   "border-primary/30 bg-primary/5 text-primary",
    },
    success: {
      icon:  <Check className="h-3 w-3" />,
      label: label ? `✓ ${label}` : "Escaneado",
      cls:   "border-success/40 bg-success/15 text-success",
    },
    error: {
      icon:  <AlertCircle className="h-3 w-3" />,
      label: label || "No encontrado",
      cls:   "border-destructive/40 bg-destructive/15 text-destructive",
    },
  }

  const v = variants[state]

  return (
    <div
      role="status"
      aria-live="polite"
      className={cn(
        "inline-flex max-w-[220px] items-center gap-1.5 rounded-full border px-2.5 py-1 text-[11px] font-medium",
        "transition-all duration-300",
        enabled ? v.cls : "border-border/30 bg-muted/30 text-muted-foreground",
        className,
      )}
    >
      {enabled ? v.icon : <ScanLine className="h-3 w-3 opacity-30 shrink-0" />}
      <span className="truncate">{enabled ? v.label : "Scanner inactivo"}</span>
    </div>
  )
}
