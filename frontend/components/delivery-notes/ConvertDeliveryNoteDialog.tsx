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
 * El cierre de la conversión (candado contra el doble clic, aviso accionable sin
 * cerrar, clave de idempotencia por remito y su reset, recarga del remito y de las
 * sesiones de caja) vive en `ConvertDocumentDialogShell`, compartido con el
 * presupuesto y el remito de compra (Regla de Tres, remitos-compra tanda B). Acá
 * queda lo de DOMINIO de la venta: qué payload se manda y qué se exige.
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

import { useMemo, useState } from "react"
import { ConvertDocumentDialogShell } from "@/components/shared/ConvertDocumentDialogShell"
import { SaleCheckoutFields, SALE_CHECKOUT_REASON_ID } from "@/components/ventas/SaleCheckoutFields"
import { SaleCheckoutSuccess } from "@/components/ventas/SaleCheckoutSuccess"
import { useConvertDeliveryNote } from "@/hooks/data/use-delivery-notes"
import { useSaleCheckout } from "@/hooks/use-sale-checkout"
import type { DeliveryNoteApiRow, DeliveryNoteConvertResult } from "@/lib/delivery-note-types"
import { formatMoney, formatNumber } from "@/lib/format"
import { humanizeOperationError } from "@/lib/operation-errors"
import { queryKeys } from "@/lib/query-keys"

interface ConvertDeliveryNoteDialogProps {
  deliveryNote: DeliveryNoteApiRow
  open: boolean
  onOpenChange: (open: boolean) => void
}

/** Rechazos tras los cuales el remito mostrado ya no es el vigente. */
const RELOAD_DELIVERY_NOTE_ERROR = /delivery_note_changed|delivery_note_invalid_state/

function ConvertDeliveryNoteDialogBody({ deliveryNote, open, onOpenChange }: ConvertDeliveryNoteDialogProps) {
  const convert = useConvertDeliveryNote()

  const [paymentMethodId, setPaymentMethodId] = useState<string | null>(null)
  const [bankAccountId, setBankAccountId] = useState<string | null>(null)

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

  async function handleConfirm(idempotencyKey: string): Promise<DeliveryNoteConvertResult> {
    // El botón sólo se habilita con una forma de pago elegida; esto es la red de seguridad.
    if (!paymentMethodId) throw new Error("payment_method_required")
    return convert.mutateAsync({
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
  }

  const numberLabel = deliveryNote.number_label
  const total = Number(deliveryNote.total)
  // El remito de la pantalla ya no es el pendiente que se abrió (otro usuario lo
  // convirtió o lo anuló y el detalle se recargó): no se ofrece una confirmación
  // que fallaría con el mismo error en cada reintento. El éxito propio manda (la
  // cáscara lo respeta): tras convertir el remito también pasa a `converted` y se
  // sigue viendo el recibo.
  const staleMessage =
    deliveryNote.status === "issued"
      ? null
      : `El remito${numberLabel ? ` ${numberLabel}` : ""} ${
          deliveryNote.status === "converted" ? "ya fue convertido en venta" : "ya fue anulado"
        }: no hay nada para registrar.`

  return (
    <ConvertDocumentDialogShell<DeliveryNoteConvertResult>
      open={open}
      onOpenChange={onOpenChange}
      title="Pasar a venta"
      idempotencyScope={`delivery-note-convert:${deliveryNote.id}`}
      summary={
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
      }
      renderFields={({ submitting }) => (
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
      )}
      confirmLabel="Registrar venta"
      confirmDisabled={checkout.block !== null || !paymentMethodId}
      confirmDescribedBy={SALE_CHECKOUT_REASON_ID}
      onConfirm={handleConfirm}
      renderSuccess={(result, close) => (
        <SaleCheckoutSuccess
          salesOrderId={result.sales_order_id}
          total={Number(result.total)}
          replayed={result.replayed}
          onClose={close}
        />
      )}
      humanizeError={(source) =>
        humanizeOperationError(
          source,
          (productId) => productNameById.get(productId) || undefined,
          deliveryNote.branch_name,
          { documentLabel: "remito" },
        )
      }
      reload={{ pattern: RELOAD_DELIVERY_NOTE_ERROR, queryKey: queryKeys.deliveryNotes.detail(deliveryNote.id) }}
      staleMessage={staleMessage}
    />
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
