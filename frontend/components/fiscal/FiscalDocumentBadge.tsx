"use client"

/**
 * C-27 v21-fiscal-profile — FiscalDocumentBadge.
 *
 * Badge con estado de un comprobante fiscal
 * (`pending_cae | authorized | rejected | voided`).
 * Se suscribe a cambios Realtime en `fiscal_documents` para el documento dado
 * y actualiza el badge automáticamente cuando el relay cambia `pending_cae → authorized`.
 *
 * venta-editable-sin-cae: `voided` es el 4o estado terminal — el comprobante se
 * anuló al editar o borrar su venta, antes de que el pedido saliera hacia ARCA.
 * El `useEffect` de Realtime sólo abre canal mientras `status === "pending_cae"`,
 * así que un anulado no se suscribe a nada (correcto, sin cambios).
 *
 * Design ref: D5 (async CAE machine), D6 (relay idempotente), DEC-16 (Realtime en Supabase).
 *
 * Usage:
 *   <FiscalDocumentBadge documentId="uuid" initialStatus="pending_cae" />
 */

import { useEffect, useRef, useState } from "react"
import { createClient } from "@/lib/supabase/client"
import { Badge } from "@/components/ui/badge"
import { AlertTriangle, Ban, Loader2 } from "lucide-react"
import type { FiscalDocumentStatus } from "@/lib/types"

// ── Types ─────────────────────────────────────────────────────────────────────

// venta-editable-sin-cae: el tipo vive ahora en la capa canónica (lib/types.ts)
// porque `Sale.fiscal` lo necesita y `lib/` no debe importar de `components/`.
// Se re-exporta acá para no tocar a sus otros importadores.
export type { FiscalDocumentStatus } from "@/lib/types"

interface FiscalDocumentBadgeProps {
  documentId: string
  initialStatus: FiscalDocumentStatus
  /** Si es true, muestra el estado en texto largo. Default: false (compact). */
  verbose?: boolean
  /**
   * fiscal-emision-segura (M-4, red team 2026-09-22): true si el comprobante
   * está CONGELADO (G4 — un FECAESolicitar salió y su resultado nunca se
   * confirmó). Un congelado sigue reportando `status='pending_cae'` — sin
   * esta bandera, el badge lo mostraría "En trámite" para siempre y nadie
   * sabría que necesita revisión manual en ARCA. Es el estado inicial (page
   * load); el badge también lo detecta en vivo por Realtime más abajo, así
   * que el caller puede omitirlo si su endpoint todavía no lo trae.
   */
  initialFrozen?: boolean
  /**
   * venta-editable-vs-promocion-legacy: se llama cuando Realtime trae un status
   * NUEVO (p.ej. pending_cae → authorized), para que el contenedor refresque
   * lo que deriva del estado (en /ventas, el texto lateral de la fila). Se
   * guarda en una ref: si entrara en las deps del efecto, cada render del
   * contenedor (que pasa una arrow nueva) re-suscribiría el canal.
   */
  onStatusChange?: (status: FiscalDocumentStatus) => void
}

// ── Config ────────────────────────────────────────────────────────────────────

const STATUS_CONFIG: Record<
  FiscalDocumentStatus,
  { label: string; labelVerbose: string; className: string }
> = {
  pending_cae: {
    label:        "En trámite",
    labelVerbose: "En trámite (esperando CAE)",
    className:    "bg-yellow-500/10 text-yellow-600 border-yellow-500/30",
  },
  authorized: {
    label:        "Autorizado",
    labelVerbose: "Autorizado por AFIP",
    className:    "bg-green-500/10 text-green-500 border-green-500/30",
  },
  rejected: {
    label:        "Rechazado",
    labelVerbose: "Rechazado por AFIP",
    className:    "bg-red-500/10 text-red-500 border-red-500/30",
  },
  // venta-editable-sin-cae (D1): 4o estado terminal. Un anulado es INERTE, no
  // un error — nunca llegó a ARCA. De ahí el gris de superficie neutra y no el
  // rojo de `rejected`.
  // Tokens semánticos (regla dura del proyecto). Las 3 entradas de arriba usan
  // colores literales y NO se reescriben acá (fuera de alcance, mismo criterio
  // con el que CustomerAccountBalance quedó como candidato); la entrada nueva
  // sí nace con tokens, así que su contraste lo cubre el gate token-contrast-aa.
  voided: {
    label:        "Anulado",
    labelVerbose: "Anulado (no se envió a ARCA)",
    className:    "bg-muted text-muted-foreground border-border",
  },
}

// ── Component ─────────────────────────────────────────────────────────────────

export function FiscalDocumentBadge({
  documentId,
  initialStatus,
  verbose = false,
  initialFrozen = false,
  onStatusChange,
}: FiscalDocumentBadgeProps) {
  const [status, setStatus] = useState<FiscalDocumentStatus>(initialStatus)
  const [frozen, setFrozen] = useState<boolean>(initialFrozen)
  const onStatusChangeRef = useRef(onStatusChange)
  useEffect(() => {
    onStatusChangeRef.current = onStatusChange
  }, [onStatusChange])

  useEffect(() => {
    // Reset cuando el documento cambia (ej. la tabla re-renderiza otra fila)
    setStatus(initialStatus)
    setFrozen(initialFrozen)
  }, [documentId, initialStatus, initialFrozen])

  useEffect(() => {
    // Solo suscribirse si el estado es aún transitorio (pending_cae).
    // Si ya está en estado final (authorized | rejected), no hace falta Realtime.
    if (status !== "pending_cae") return

    const supabase = createClient()

    const channel = supabase
      .channel(`fiscal_document_status_${documentId}`)
      .on(
        "postgres_changes",
        {
          event:  "UPDATE",
          schema: "public",
          table:  "fiscal_documents",
          filter: `id=eq.${documentId}`,
        },
        (payload) => {
          const newStatus = payload.new?.status as FiscalDocumentStatus | undefined
          if (newStatus && newStatus !== status) {
            setStatus(newStatus)
            onStatusChangeRef.current?.(newStatus)
          }
          // fiscal-emision-segura (M-4, red team 2026-09-22): el mismo UPDATE
          // que congela (G4) trae `cae_submit_unconfirmed_at` en el payload —
          // reutiliza la suscripción que ya existía, sin un canal aparte.
          if (payload.new?.cae_submit_unconfirmed_at) {
            setFrozen(true)
          }
        },
      )
      .subscribe()

    return () => {
      supabase.removeChannel(channel)
    }
  }, [documentId, status])

  // Un congelado sigue siendo status='pending_cae' — la bandera manda por
  // encima del status para no mostrar "En trámite" indefinidamente.
  //
  // B2-3 (segundo red team, 2026-09-22): sólo MIENTRAS siga en pending_cae.
  // `cae_submit_unconfirmed_at` no la limpia ningún camino, así que un
  // comprobante resuelto a mano —la única salida prevista del congelamiento—
  // llega con la marca puesta y el status nuevo (por props o por el UPDATE de
  // Realtime): sin esta condición, el badge tapaba para siempre el CAE y el
  // número que el humano acababa de cargar.
  if (frozen && status === "pending_cae") {
    return (
      <Badge
        variant="outline"
        className="inline-flex items-center gap-1 text-xs bg-red-500/10 text-red-600 border-red-500/30 dark:text-red-400"
        title="El envío a ARCA no se confirmó (pudo haber sido aprobado sin registro local). Requiere verificación manual en ARCA antes de reintentar."
      >
        <AlertTriangle className="h-3 w-3" />
        {verbose ? "Congelado — requiere revisión manual" : "Congelado"}
      </Badge>
    )
  }

  // Fallback fail-closed: sin esto, un status que el cliente no conoce (el
  // CHECK de fiscal_documents puede ganar un valor nuevo antes que este bundle)
  // daba `undefined` y el badge rompía el render de la fila ENTERA con un
  // TypeError. Mostrar "Estado desconocido" es peor que mostrar el estado, pero
  // es muchísimo mejor que no mostrar la venta.
  const config = STATUS_CONFIG[status] ?? {
    label:        "Estado desconocido",
    labelVerbose: `Estado desconocido (${String(status)})`,
    className:    "bg-muted text-muted-foreground border-border",
  }

  return (
    <Badge variant="outline" className={`inline-flex items-center gap-1 text-xs ${config.className}`}>
      {status === "pending_cae" && (
        <Loader2 className="h-3 w-3 animate-spin" />
      )}
      {status === "voided" && <Ban className="h-3 w-3" />}
      {verbose ? config.labelVerbose : config.label}
    </Badge>
  )
}
