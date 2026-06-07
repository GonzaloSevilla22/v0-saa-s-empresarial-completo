"use client"

import { useEffect, useRef, useState } from "react"
import { createClient } from "@/lib/supabase/client"
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogDescription,
} from "@/components/ui/dialog"
import { Button } from "@/components/ui/button"
import { Loader2, Sparkles, AlertTriangle, Info, Clock, TrendingUp } from "lucide-react"
import Link from "next/link"

// ─── Types ────────────────────────────────────────────────────────────────────

interface PriceSuggestionModalProps {
  productId:   string
  productName: string
  isOpen:      boolean
  onClose:     () => void
}

type ModalState =
  | { status: "loading" }
  | { status: "success"; suggestedPrice: number; marginPct: number; argument: string }
  | { status: "fallback"; reason: "insufficient_data" | "timeout" }
  | { status: "error"; reason: "quota_exceeded" }
  | { status: "error_generic"; message: string }

// ─── Formatters ───────────────────────────────────────────────────────────────

const fmtARS = (n: number) =>
  new Intl.NumberFormat("es-AR", {
    style:                 "currency",
    currency:              "ARS",
    maximumFractionDigits: 0,
  }).format(n)

// ─── Component ────────────────────────────────────────────────────────────────

export function PriceSuggestionModal({
  productId,
  productName,
  isOpen,
  onClose,
}: PriceSuggestionModalProps) {
  const [state, setState] = useState<ModalState>({ status: "loading" })
  const hasFetched = useRef(false)

  // Call the Edge Function when the modal opens (task 2.2)
  useEffect(() => {
    if (!isOpen) {
      hasFetched.current = false
      return
    }
    if (hasFetched.current) return
    hasFetched.current = true

    setState({ status: "loading" })

    async function fetchSuggestion() {
      try {
        const supabase = createClient()
        const { data: session } = await supabase.auth.getSession()
        const token = session?.session?.access_token
        if (!token) {
          setState({ status: "error_generic", message: "Sin sesión activa" })
          return
        }

        const res = await fetch(
          `${process.env.NEXT_PUBLIC_SUPABASE_URL}/functions/v1/ai-precio`,
          {
            method:  "POST",
            headers: {
              "Content-Type": "application/json",
              Authorization:  `Bearer ${token}`,
            },
            body: JSON.stringify({ product_id: productId }),
          }
        )

        const json: Record<string, unknown> = await res.json()

        // 429 — quota exceeded (task 2.7)
        if (res.status === 429) {
          setState({ status: "error", reason: "quota_exceeded" })
          return
        }

        // 403 — plan required
        if (res.status === 403) {
          setState({ status: "error_generic", message: "No tenés acceso a esta función con tu plan actual." })
          return
        }

        // Fallback responses (tasks 2.5, 2.6)
        if (json?.fallback === true) {
          const reason = json.reason === "insufficient_data" ? "insufficient_data" : "timeout"
          setState({ status: "fallback", reason })
          return
        }

        // Success (task 2.4)
        if (json?.ok === true && typeof json.suggested_price === "number") {
          setState({
            status:        "success",
            suggestedPrice: json.suggested_price as number,
            marginPct:      typeof json.margin_pct === "number" ? (json.margin_pct as number) : 0,
            argument:       typeof json.argument === "string"   ? (json.argument   as string) : "",
          })
          return
        }

        // Generic error
        const msg = typeof json?.error === "string" ? json.error : "Error inesperado al obtener la sugerencia"
        setState({ status: "error_generic", message: msg })

      } catch (err: unknown) {
        const msg = err instanceof Error ? err.message : "Error de red"
        setState({ status: "error_generic", message: msg })
      }
    }

    fetchSuggestion()
  }, [isOpen, productId])

  // task 2.3: disable close while loading
  const isLoading = state.status === "loading"

  function handleOpenChange(open: boolean) {
    if (!open && !isLoading) {
      onClose()
    }
  }

  return (
    <Dialog open={isOpen} onOpenChange={handleOpenChange}>
      {/* task 2.8: aria-modal, role dialog are handled by Radix Dialog */}
      <DialogContent
        className="sm:max-w-md"
        aria-modal="true"
        onEscapeKeyDown={(e) => {
          if (isLoading) e.preventDefault()
        }}
        onPointerDownOutside={(e) => {
          if (isLoading) e.preventDefault()
        }}
        onInteractOutside={(e) => {
          if (isLoading) e.preventDefault()
        }}
      >
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2">
            <Sparkles className="h-4 w-4 text-primary" />
            Sugerencia de precio IA
          </DialogTitle>
          <DialogDescription className="text-xs text-muted-foreground">
            {productName}
          </DialogDescription>
        </DialogHeader>

        <div className="py-2">
          {/* ── Loading (task 2.3) ── */}
          {state.status === "loading" && (
            <div
              className="flex flex-col items-center justify-center gap-3 py-8"
              role="status"
              aria-live="polite"
              aria-label="Analizando datos del producto"
            >
              <Loader2 className="h-8 w-8 animate-spin text-primary" aria-hidden="true" />
              <p className="text-sm text-muted-foreground text-center">
                Analizando historial de ventas…
              </p>
              <p className="text-xs text-muted-foreground/60 text-center max-w-xs">
                Esto puede tomar algunos segundos
              </p>
            </div>
          )}

          {/* ── Success (task 2.4) ── */}
          {state.status === "success" && (
            <div className="flex flex-col gap-4">
              <div className="rounded-lg border border-primary/20 bg-primary/5 p-4 text-center">
                <p className="text-xs text-muted-foreground mb-1">Precio sugerido</p>
                <p className="text-3xl font-bold text-primary tabular-nums">
                  {fmtARS(state.suggestedPrice)}
                </p>
                <p className="text-sm text-muted-foreground mt-1">
                  Margen proyectado:{" "}
                  <span
                    className={
                      state.marginPct >= 30
                        ? "text-green-500 font-semibold"
                        : state.marginPct >= 10
                        ? "text-yellow-500 font-semibold"
                        : "text-destructive font-semibold"
                    }
                  >
                    {state.marginPct.toFixed(1)}%
                  </span>
                </p>
              </div>

              {state.argument && (
                <div className="flex items-start gap-2 rounded-lg bg-muted/50 p-3">
                  <TrendingUp className="h-4 w-4 text-primary shrink-0 mt-0.5" />
                  <p className="text-sm text-foreground leading-relaxed">{state.argument}</p>
                </div>
              )}

              <p className="text-xs text-muted-foreground text-center px-2">
                Esta es una sugerencia basada en tu historial de ventas. La decisión final es tuya.
              </p>

              <Button onClick={onClose} className="w-full">
                Entendido
              </Button>
            </div>
          )}

          {/* ── Fallback: insufficient_data (task 2.5) ── */}
          {state.status === "fallback" && state.reason === "insufficient_data" && (
            <div className="flex flex-col items-center gap-4 py-4 text-center">
              <div className="flex h-12 w-12 items-center justify-center rounded-full bg-yellow-500/10">
                <Info className="h-6 w-6 text-yellow-500" aria-hidden="true" />
              </div>
              <p className="text-sm text-foreground font-medium">Sin historial suficiente</p>
              <p className="text-sm text-muted-foreground max-w-xs">
                No hay suficiente historial de ventas para sugerir un precio. Registrá al menos 3
                ventas en los últimos 90 días.
              </p>
              <Button variant="outline" onClick={onClose} className="w-full">
                Cerrar
              </Button>
            </div>
          )}

          {/* ── Fallback: timeout (task 2.6) ── */}
          {state.status === "fallback" && state.reason === "timeout" && (
            <div className="flex flex-col items-center gap-4 py-4 text-center">
              <div className="flex h-12 w-12 items-center justify-center rounded-full bg-orange-500/10">
                <Clock className="h-6 w-6 text-orange-500" aria-hidden="true" />
              </div>
              <p className="text-sm text-foreground font-medium">Análisis demorado</p>
              <p className="text-sm text-muted-foreground max-w-xs">
                El análisis está tardando más de lo esperado. Intentá de nuevo en unos minutos.
              </p>
              <Button variant="outline" onClick={onClose} className="w-full">
                Cerrar
              </Button>
            </div>
          )}

          {/* ── Error: quota_exceeded (task 2.7) ── */}
          {state.status === "error" && state.reason === "quota_exceeded" && (
            <div className="flex flex-col items-center gap-4 py-4 text-center">
              <div className="flex h-12 w-12 items-center justify-center rounded-full bg-destructive/10">
                <AlertTriangle className="h-6 w-6 text-destructive" aria-hidden="true" />
              </div>
              <p className="text-sm text-foreground font-medium">Límite mensual alcanzado</p>
              <p className="text-sm text-muted-foreground max-w-xs">
                Alcanzaste el límite mensual de consultas IA. Actualizá tu plan para seguir usándola.
              </p>
              <div className="flex w-full gap-2">
                <Button variant="outline" onClick={onClose} className="flex-1">
                  Cerrar
                </Button>
                <Button asChild className="flex-1">
                  <Link href="/planes">Ver planes</Link>
                </Button>
              </div>
            </div>
          )}

          {/* ── Generic error ── */}
          {state.status === "error_generic" && (
            <div className="flex flex-col items-center gap-4 py-4 text-center">
              <div className="flex h-12 w-12 items-center justify-center rounded-full bg-destructive/10">
                <AlertTriangle className="h-6 w-6 text-destructive" aria-hidden="true" />
              </div>
              <p className="text-sm text-foreground font-medium">Algo salió mal</p>
              <p className="text-sm text-muted-foreground max-w-xs">{state.message}</p>
              <Button variant="outline" onClick={onClose} className="w-full">
                Cerrar
              </Button>
            </div>
          )}
        </div>
      </DialogContent>
    </Dialog>
  )
}
