"use client"

/**
 * ConvertDeliveryNoteDialog — convierte un remito pendiente en venta, de forma
 * atómica (remitos-venta D7/D11, tareas 7.3/7.4).
 *
 * Molde de `ConvertQuoteDialog`. Compone, sin lógica propia de cierre de venta:
 *   - el resumen de líneas y total, en sólo lectura (se cobra lo que se entregó:
 *     si hay que cambiar algo, se edita el remito antes de convertirlo);
 *   - `SaleCheckoutFields` + `useSaleCheckout` (forma de pago, cuenta bancaria,
 *     caja con la semántica del POS, saldo del cliente);
 *   - `SaleCheckoutSuccess` (Venta registrada, Facturar, Ver en Ventas);
 *   - `useConvertDeliveryNote` (POST /delivery-notes/{id}/convert, clave por header).
 *
 * Lo que lo distingue del presupuesto:
 *   - EL STOCK NO SE VUELVE A DESCONTAR: ya salió al emitir el remito. La línea
 *     fija lo dice, para que nadie crea que la venta lo descuenta de nuevo.
 *   - LA SUCURSAL ES FIJA: la del remito, de donde salió la mercadería. Una venta
 *     en otra sucursal desalinearía la caja de su stock. No hay selector
 *     (`branchReadOnly`), el payload no lleva `branch_id` y la caja se resuelve
 *     en esa sucursal.
 *
 * Reglas que cuidan el dinero:
 *   - `expected_revision` = la `revision` que muestra el resumen. Si otro usuario
 *     editó el remito, el servidor responde `delivery_note_changed`: se recarga el
 *     detalle, se avisa y NO se cierra; la confirmación siguiente usa la revisión
 *     y el total vigentes.
 *   - Un fallo deja el diálogo abierto, con el mensaje en `role="alert"`; no se
 *     registró nada (la conversión es una transacción).
 *   - La clave de idempotencia es POR remito (`delivery-note-convert:<id>`) y se
 *     resetea tras cada éxito, incluido el replay. Reintentar tras un error la
 *     conserva (un fallo revierte todo, incluida la clave); la excepción es
 *     `idempotency_key_conflict`, donde la clave chocó con otro documento.
 *   - Doble clic: un candado síncrono (ref) deja pasar una sola request; el
 *     estado `submitting` llega tarde para dos clics en el mismo tick.
 *   - Una vez convertido, el remito de la pantalla pasa a `converted` por la
 *     invalidación: el diálogo sigue mostrando "Venta registrada" porque su estado
 *     (`done`) no depende del remito.
 */

import { useCallback, useMemo, useRef, useState } from "react"
import Link from "next/link"
import { useQueryClient } from "@tanstack/react-query"
import { Button } from "@/components/ui/button"
import { ResponsiveModal } from "@/components/shared/responsive-modal"
import { SaleCheckoutFields, SALE_CHECKOUT_REASON_ID } from "@/components/ventas/SaleCheckoutFields"
import { SaleCheckoutSuccess } from "@/components/ventas/SaleCheckoutSuccess"
import { useConvertDeliveryNote } from "@/hooks/data/use-delivery-notes"
import { useIdempotencyKey } from "@/hooks/use-idempotency-key"
import { useSaleCheckout } from "@/hooks/use-sale-checkout"
import { PythonApiError } from "@/lib/api/python-api-error"
import type { DeliveryNoteApiRow, DeliveryNoteConvertResult } from "@/lib/delivery-note-types"
import { formatMoney, formatNumber } from "@/lib/format"
import { humanizeOperationError, type HumanizedOperationError } from "@/lib/operation-errors"
import { queryKeys } from "@/lib/query-keys"

interface ConvertDeliveryNoteDialogProps {
  deliveryNote: DeliveryNoteApiRow
  open: boolean
  onOpenChange: (open: boolean) => void
}

/** El `code` estable y el texto del servidor, juntos: el mapa de errores reconoce cualquiera de los dos. */
function errorSource(err: unknown): string {
  if (err instanceof PythonApiError) {
    const code = err.code ?? ""
    return code && !err.message.includes(code) ? `${err.message} ${code}` : err.message
  }
  return err instanceof Error ? err.message : ""
}

/** Rechazos tras los cuales el remito mostrado ya no es el vigente. */
const RELOAD_DELIVERY_NOTE_ERROR = /delivery_note_changed|delivery_note_invalid_state/
const CASH_SESSION_CLOSED_ERROR = /cash_optin_requires_open_session|cash_requires_session/
const IDEMPOTENCY_CONFLICT_ERROR = /idempotency_key_conflict/

function ConvertDeliveryNoteDialogBody({ deliveryNote, open, onOpenChange }: ConvertDeliveryNoteDialogProps) {
  const queryClient = useQueryClient()
  const convert = useConvertDeliveryNote()
  const { idempotencyKey, resetIdempotencyKey } = useIdempotencyKey(`delivery-note-convert:${deliveryNote.id}`)

  const [paymentMethodId, setPaymentMethodId] = useState<string | null>(null)
  const [bankAccountId, setBankAccountId] = useState<string | null>(null)
  const [error, setError] = useState<HumanizedOperationError | null>(null)
  const [done, setDone] = useState<DeliveryNoteConvertResult | null>(null)
  const [submitting, setSubmitting] = useState(false)
  const submittingRef = useRef(false)

  // La sucursal de la venta ES la del remito (D7): es de donde salió el stock y
  // la que usa el servidor. Es la MISMA que resuelve la sesión de caja: así la
  // venta en efectivo nunca queda con la caja de una sucursal y la venta en otra.
  const checkout = useSaleCheckout({
    paymentMethodId,
    branchId: deliveryNote.branch_id,
    clientId: deliveryNote.client_id,
  })

  const productNameById = useMemo(
    () => new Map(deliveryNote.items.map((item) => [item.product_id, item.name_snapshot ?? ""])),
    [deliveryNote.items],
  )

  function handlePaymentMethodChange(id: string | null) {
    setPaymentMethodId(id)
    // La cuenta bancaria es de la operación, no del método: cambiar de forma de
    // pago descarta la elegida para la anterior.
    setBankAccountId(null)
  }

  const handleOpenChange = useCallback(
    (next: boolean) => {
      // Con la request en vuelo no se cierra: la respuesta tiene que verse.
      if (!next && submittingRef.current) return
      onOpenChange(next)
    },
    [onOpenChange],
  )

  async function handleConfirm() {
    if (submittingRef.current || checkout.block !== null || !paymentMethodId) return
    submittingRef.current = true
    setSubmitting(true)
    setError(null)
    try {
      const result = await convert.mutateAsync({
        deliveryNoteId: deliveryNote.id,
        idempotencyKey,
        payload: {
          expected_revision: deliveryNote.revision,
          payment_method_id: paymentMethodId,
          // Con efectivo, SIEMPRE la sesión abierta de la sucursal del remito.
          cash_session_id: checkout.cashSessionId,
          bank_account_id: bankAccountId,
          canal: null,
        },
      })
      // Tras cada éxito (también el replay) la próxima operación nace con otra clave.
      resetIdempotencyKey()
      setDone(result)
    } catch (err: unknown) {
      const source = errorSource(err)
      if (RELOAD_DELIVERY_NOTE_ERROR.test(source)) {
        // Otro usuario lo editó, lo convirtió o lo anuló: se recarga el remito
        // para que el resumen refleje el estado real. El diálogo sigue abierto.
        void queryClient.invalidateQueries({ queryKey: queryKeys.deliveryNotes.detail(deliveryNote.id) })
      }
      if (CASH_SESSION_CLOSED_ERROR.test(source)) {
        // La caja se cerró entre que se abrió el diálogo y se confirmó: sin
        // recargar, el diálogo seguiría mostrando una sesión que ya no existe.
        void queryClient.invalidateQueries({ queryKey: queryKeys.cashSessions.all() })
      }
      if (IDEMPOTENCY_CONFLICT_ERROR.test(source)) {
        // La clave chocó con OTRO documento y la conversión falló entera: no
        // quedó asociada a nada de este remito. Reintentar con la misma clave
        // repetiría el choque para siempre; una nueva es segura.
        resetIdempotencyKey()
      }
      setError(
        humanizeOperationError(
          source,
          (productId) => productNameById.get(productId) || undefined,
          deliveryNote.branch_name,
          { documentLabel: "remito" },
        ),
      )
    } finally {
      submittingRef.current = false
      setSubmitting(false)
    }
  }

  const numberLabel = deliveryNote.number_label
  const total = Number(deliveryNote.total)

  return (
    <ResponsiveModal open={open} onOpenChange={handleOpenChange} title="Pasar a venta">
      <div className="flex max-h-[75dvh] min-w-0 flex-col gap-4 overflow-y-auto pr-1">
        {done ? (
          <SaleCheckoutSuccess
            salesOrderId={done.sales_order_id}
            total={Number(done.total)}
            replayed={done.replayed}
            onClose={() => onOpenChange(false)}
          />
        ) : (
          <>
            <section aria-label="Resumen del remito" className="flex min-w-0 flex-col gap-2">
              <p className="text-sm text-muted-foreground">
                {numberLabel ?? "Remito"}
                {deliveryNote.client_name ? <> · {deliveryNote.client_name}</> : null}
              </p>
              <ul
                aria-label="Líneas del remito"
                className="flex flex-col divide-y divide-border/60 rounded-lg border border-border bg-background"
              >
                {deliveryNote.items.map((item) => (
                  <li key={item.id} className="flex items-baseline justify-between gap-3 px-3 py-2 text-sm">
                    <span className="min-w-0 break-words text-foreground">
                      {item.name_snapshot ?? "—"}
                      <span className="ml-1 text-xs tabular-nums text-muted-foreground">
                        × {formatNumber(Number(item.quantity), 4)}
                        {item.unit_symbol ? ` ${item.unit_symbol}` : ""}
                      </span>
                    </span>
                    <span className="shrink-0 tabular-nums text-foreground">
                      {formatMoney(Number(item.subtotal), "ARS")}
                    </span>
                  </li>
                ))}
              </ul>
              <div className="flex items-center justify-between gap-4 px-1">
                <span className="text-sm text-muted-foreground">Total a cobrar</span>
                <span data-testid="convert-delivery-note-total" className="text-lg font-bold tabular-nums text-primary">
                  {formatMoney(total, "ARS")}
                </span>
              </div>
              <p className="rounded-lg border border-border bg-muted/40 px-3 py-2 text-sm text-foreground">
                El stock ya se descontó al emitir el remito{numberLabel ? ` ${numberLabel}` : ""}: esta venta no lo
                vuelve a descontar.
              </p>
            </section>

            <SaleCheckoutFields
              branchId={deliveryNote.branch_id}
              onBranchChange={() => undefined}
              branchReadOnly
              branchName={deliveryNote.branch_name}
              paymentMethodId={paymentMethodId}
              onPaymentMethodChange={handlePaymentMethodChange}
              bankAccountId={bankAccountId}
              onBankAccountChange={setBankAccountId}
              clientId={deliveryNote.client_id}
              checkout={checkout}
              disabled={submitting}
            />

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
                disabled={submitting || checkout.block !== null}
                aria-describedby={checkout.block !== null ? SALE_CHECKOUT_REASON_ID : undefined}
              >
                {submitting ? "Registrando…" : "Registrar venta"}
              </Button>
            </div>
          </>
        )}
      </div>
    </ResponsiveModal>
  )
}

/**
 * Se monta con `key={deliveryNote.id}`: la clave de idempotencia y los campos son
 * de UN remito. Si la pantalla reutiliza la instancia al navegar entre remitos,
 * el estado de uno no puede pasar al otro.
 */
export function ConvertDeliveryNoteDialog(props: ConvertDeliveryNoteDialogProps) {
  return <ConvertDeliveryNoteDialogBody key={props.deliveryNote.id} {...props} />
}
