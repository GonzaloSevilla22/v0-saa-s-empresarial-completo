"use client"

/**
 * ConvertDocumentDialogShell — la cáscara compartida de los diálogos que convierten
 * un documento en una operación de forma atómica (remitos-compra tanda B, 7.5;
 * Regla de Tres: presupuesto → venta, remito de venta → venta y remito de compra →
 * compra la repetían casi línea por línea).
 *
 * Es de CIERRE, no de dominio: no sabe qué es una venta ni una compra, qué payload se
 * manda ni qué campos se exigen. Eso lo deciden los diálogos, que le entregan por
 * slots el resumen, los campos de cierre y el panel de éxito, y por callbacks la
 * conversión y la traducción del error. Lo que sí hace, igual para los tres:
 *
 *   - Un fallo deja el diálogo abierto, con el mensaje en `role="alert"` y, si el
 *     error lo trae, el enlace de acción; no se registró nada (la conversión es una
 *     transacción).
 *   - La clave de idempotencia es POR documento (`idempotencyScope`) y se resetea
 *     tras cada éxito, incluido el replay: una respuesta perdida de la conversión de A
 *     no contamina la de B. Reintentar tras un fallo la conserva (un fallo revierte
 *     todo, incluida la clave); la excepción es `idempotency_key_conflict`, donde la
 *     clave chocó con OTRO documento y reintentar con ella repetiría el choque para
 *     siempre.
 *   - Doble clic: un candado síncrono (ref) deja pasar una sola request; el estado
 *     `submitting` llega tarde para dos clics en el mismo tick. Con la request en
 *     vuelo no se cierra: la respuesta tiene que verse.
 *   - Si el error indica que el documento mostrado ya no es el vigente
 *     (`reload.pattern`), recarga ESA consulta (`reload.queryKey`) sin cerrar: la
 *     confirmación siguiente usa la revisión y el total vigentes. Si la caja se cerró
 *     mientras se confirmaba, recarga las sesiones de caja.
 *   - El éxito (`done`) manda sobre `staleMessage`: tras la conversión propia el
 *     documento también pasa a convertido y se tiene que seguir viendo el recibo.
 *
 * El diálogo que lo usa se monta con `key={documento.id}`: la clave y los campos son
 * de UN documento, y el estado de uno no puede pasar al otro.
 */

import { useCallback, useRef, useState, type ReactNode } from "react"
import Link from "next/link"
import { useQueryClient } from "@tanstack/react-query"
import { Button } from "@/components/ui/button"
import { ResponsiveModal } from "@/components/shared/responsive-modal"
import { useIdempotencyKey } from "@/hooks/use-idempotency-key"
import { PythonApiError } from "@/lib/api/python-api-error"
import type { HumanizedOperationError } from "@/lib/operation-errors"
import { queryKeys } from "@/lib/query-keys"

/**
 * El `code` estable y el texto del servidor, juntos: el mapa de errores
 * (`humanizeOperationError`) reconoce cualquiera de los dos.
 */
export function conversionErrorSource(err: unknown): string {
  if (err instanceof PythonApiError) {
    const code = err.code ?? ""
    return code && !err.message.includes(code) ? `${err.message} ${code}` : err.message
  }
  return err instanceof Error ? err.message : ""
}

const CASH_SESSION_CLOSED_ERROR = /cash_optin_requires_open_session|cash_requires_session/
const IDEMPOTENCY_CONFLICT_ERROR = /idempotency_key_conflict/

export interface ConvertDocumentDialogShellProps<TResult> {
  open: boolean
  onOpenChange: (open: boolean) => void
  title: string
  /** Alcance de la clave de idempotencia: UNA por documento (`delivery-note-convert:<id>`). */
  idempotencyScope: string
  /** El resumen de líneas y total del documento, en sólo lectura. */
  summary: ReactNode
  /** Los campos de cierre; reciben `submitting` para deshabilitarse con la request en vuelo. */
  renderFields: (state: { submitting: boolean }) => ReactNode
  /** Rótulo del botón de confirmar (`Registrar venta`). */
  confirmLabel: string
  /** El botón queda deshabilitado (falta la forma de pago, caja cerrada, crédito sin cliente…). */
  confirmDisabled: boolean
  /** Con el botón deshabilitado, el id del texto que dice por qué (accesibilidad). */
  confirmDescribedBy?: string
  /**
   * Hace la conversión con la clave que corresponde. Si falla, debe lanzar: el
   * diálogo conserva el estado y muestra el aviso.
   */
  onConfirm: (idempotencyKey: string) => Promise<TResult>
  /** El panel final tras convertir; `close` cierra el diálogo. */
  renderSuccess: (result: TResult, close: () => void) => ReactNode
  /** Traduce el error del servidor (ya normalizado con `conversionErrorSource`) a un aviso accionable. */
  humanizeError: (source: string) => HumanizedOperationError
  /** Cuando el error coincide con `pattern`, el documento mostrado no es el vigente: se recarga `queryKey`. */
  reload: { pattern: RegExp; queryKey: readonly unknown[] }
  /** El documento ya no está pendiente (lo convirtió o anuló otro usuario): el aviso, y sólo Cerrar. */
  staleMessage?: string | null
}

export function ConvertDocumentDialogShell<TResult>({
  open,
  onOpenChange,
  title,
  idempotencyScope,
  summary,
  renderFields,
  confirmLabel,
  confirmDisabled,
  confirmDescribedBy,
  onConfirm,
  renderSuccess,
  humanizeError,
  reload,
  staleMessage = null,
}: ConvertDocumentDialogShellProps<TResult>) {
  const queryClient = useQueryClient()
  const { idempotencyKey, resetIdempotencyKey } = useIdempotencyKey(idempotencyScope)

  const [error, setError] = useState<HumanizedOperationError | null>(null)
  const [done, setDone] = useState<{ result: TResult } | null>(null)
  const [submitting, setSubmitting] = useState(false)
  const submittingRef = useRef(false)

  const handleOpenChange = useCallback(
    (next: boolean) => {
      // Con la request en vuelo no se cierra: la respuesta tiene que verse.
      if (!next && submittingRef.current) return
      onOpenChange(next)
    },
    [onOpenChange],
  )

  async function handleConfirm() {
    if (submittingRef.current || confirmDisabled) return
    submittingRef.current = true
    setSubmitting(true)
    setError(null)
    try {
      const result = await onConfirm(idempotencyKey)
      // Tras cada éxito (también el replay) la próxima operación nace con otra clave.
      resetIdempotencyKey()
      setDone({ result })
    } catch (err: unknown) {
      const source = conversionErrorSource(err)
      if (reload.pattern.test(source)) {
        // Otro usuario lo editó, lo convirtió o lo anuló: se recarga el documento
        // para que el resumen refleje el estado real. El diálogo sigue abierto.
        void queryClient.invalidateQueries({ queryKey: reload.queryKey })
      }
      if (CASH_SESSION_CLOSED_ERROR.test(source)) {
        // La caja se cerró entre que se abrió el diálogo y se confirmó: sin
        // recargar, el diálogo seguiría mostrando una sesión que ya no existe.
        void queryClient.invalidateQueries({ queryKey: queryKeys.cashSessions.all() })
      }
      if (IDEMPOTENCY_CONFLICT_ERROR.test(source)) {
        // La clave chocó con OTRO documento y la conversión falló entera: no quedó
        // asociada a nada de este. Reintentar con la misma clave repetiría el choque
        // para siempre; una nueva es segura.
        resetIdempotencyKey()
      }
      setError(humanizeError(source))
    } finally {
      submittingRef.current = false
      setSubmitting(false)
    }
  }

  return (
    <ResponsiveModal open={open} onOpenChange={handleOpenChange} title={title}>
      <div className="flex max-h-[75dvh] min-w-0 flex-col gap-4 overflow-y-auto pr-1">
        {done ? (
          renderSuccess(done.result, () => onOpenChange(false))
        ) : staleMessage ? (
          <div className="flex min-w-0 flex-col gap-4">
            <p role="status" className="rounded-lg border border-border bg-muted/40 px-3 py-2 text-sm text-foreground">
              {staleMessage}
            </p>
            <div className="flex justify-end">
              <Button type="button" variant="outline" onClick={() => onOpenChange(false)}>
                Cerrar
              </Button>
            </div>
          </div>
        ) : (
          <>
            {summary}

            {renderFields({ submitting })}

            {error && (
              <div
                role="alert"
                className="flex flex-col gap-1 rounded-lg border border-destructive/40 bg-destructive/10 px-4 py-3 text-sm text-foreground"
              >
                <p>{error.message}</p>
                {error.action && (
                  <Link href={error.action.href} className="w-fit text-xs text-primary underline underline-offset-2">
                    {error.action.label}
                  </Link>
                )}
              </div>
            )}

            <div className="flex justify-end gap-2">
              <Button type="button" variant="outline" onClick={() => handleOpenChange(false)} disabled={submitting}>
                Cancelar
              </Button>
              <Button
                type="button"
                onClick={() => void handleConfirm()}
                disabled={submitting || confirmDisabled}
                aria-describedby={confirmDisabled ? confirmDescribedBy : undefined}
              >
                {submitting ? "Registrando…" : confirmLabel}
              </Button>
            </div>
          </>
        )}
      </div>
    </ResponsiveModal>
  )
}
