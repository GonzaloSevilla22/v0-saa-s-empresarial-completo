"use client"

/**
 * ConvertPurchaseDeliveryNoteDialog — convierte un remito de compra pendiente en
 * compra, de forma atómica (remitos-compra D8/D11, tareas 7.4/7.5). Es el espejo de
 * `ConvertDeliveryNoteDialog` (venta) para el sentido compra.
 *
 * Compone, sin lógica propia de cierre de compra:
 *   - el resumen de líneas y total, en sólo lectura (se paga lo que se recibió: si
 *     hay que cambiar algo, se edita el remito antes de convertirlo);
 *   - `PurchaseCheckoutFields` + `usePurchaseCheckout` (fecha, centro de costo, forma
 *     de pago OBLIGATORIA, cuenta bancaria, opt-in de caja y saldo del proveedor), los
 *     mismos que el formulario de compra directa;
 *   - `useDueDateCascade` (el vencimiento a crédito, con el plazo del proveedor);
 *   - `PurchaseCheckoutSuccess` (Compra registrada, Ver en Compras);
 *   - `useConvertPurchaseDeliveryNote` (POST /delivery-notes/{id}/convert-to-purchase,
 *     clave por header).
 *
 * El cierre de la conversión (candado contra el doble clic, aviso accionable sin
 * cerrar, clave de idempotencia por remito y su reset, recarga del remito y de las
 * sesiones de caja) vive en `ConvertDocumentDialogShell`, compartido con el
 * presupuesto y el remito de venta. Acá queda lo de DOMINIO de la compra: qué
 * payload se manda y qué se exige.
 *
 * Lo que lo distingue de la venta:
 *   - EL STOCK NO SE VUELVE A SUMAR: ya entró al recibir el remito. La línea fija lo
 *     dice, para que nadie crea que la compra lo suma de nuevo.
 *   - PROVEEDOR Y SUCURSAL FIJOS: los del remito (la mercadería entró ahí y la deuda
 *     es con ese proveedor). No hay selectores y el payload no lleva `supplier_id`,
 *     `branch_id` ni líneas: las lee el servidor del remito que bloquea.
 *   - LA CAJA ES UN OPT-IN, como en la compra directa (caja-compras-cobranzas D4), no
 *     el camino único del POS: pre-marcado cuando las tres condiciones se cumplen y,
 *     si no, el motivo se muestra y la compra se registra igual SIN sesión de caja.
 *   - EL VENCIMIENTO sale de la cascada del plazo (el del proveedor, si no el de la
 *     cuenta) y sólo viaja si el usuario lo tocó; sin tocar, el servidor resuelve.
 *
 * Reglas que cuidan el dinero:
 *   - `expected_revision` = la `revision` que muestra el resumen. Si otro usuario
 *     editó el remito, el servidor responde `delivery_note_changed`: se recarga el
 *     detalle, se avisa y NO se cierra; la confirmación siguiente usa la revisión y
 *     el total vigentes.
 *   - La forma de pago es obligatoria (OQ-RC4): la compra nacida del remito es el
 *     momento de decir cómo se paga. Sin ella no se confirma.
 *   - La fecha de la compra no puede preceder a la recepción del remito: el servidor
 *     lo rechaza; acá se evita el viaje de ida y vuelta.
 *   - Una vez convertido, el remito de la pantalla pasa a `converted` por la
 *     invalidación: el diálogo sigue mostrando "Compra registrada" porque su estado
 *     (`done`) no depende del remito.
 *
 * El plazo del proveedor sale de `useSupplier` (el detalle que ya cachea la cuenta
 * corriente del proveedor): el read model del remito no lo trae y no se duplica.
 */

import { useId, useMemo, useState } from "react"
import { ConvertDocumentDialogShell } from "@/components/shared/ConvertDocumentDialogShell"
import { PurchaseCheckoutFields } from "@/components/compras/PurchaseCheckoutFields"
import { PurchaseCheckoutSuccess } from "@/components/compras/PurchaseCheckoutSuccess"
import { useConvertPurchaseDeliveryNote } from "@/hooks/data/use-delivery-notes"
import { useSupplier } from "@/hooks/data/use-suppliers"
import { useDueDateCascade } from "@/hooks/use-due-date-cascade"
import { usePurchaseCheckout } from "@/hooks/use-purchase-checkout"
import { argentinaToday } from "@/lib/date-range"
import type { DeliveryNoteApiRow, PurchaseDeliveryNoteConvertResult } from "@/lib/delivery-note-types"
import { formatDate, formatMoney, formatNumber } from "@/lib/format"
import { humanizeOperationError } from "@/lib/operation-errors"
import { queryKeys } from "@/lib/query-keys"

interface ConvertPurchaseDeliveryNoteDialogProps {
  deliveryNote: DeliveryNoteApiRow
  open: boolean
  onOpenChange: (open: boolean) => void
}

/** Rechazos tras los cuales el remito mostrado ya no es el vigente. */
const RELOAD_DELIVERY_NOTE_ERROR = /delivery_note_changed|delivery_note_invalid_state/

function ConvertPurchaseDeliveryNoteDialogBody({
  deliveryNote,
  open,
  onOpenChange,
}: ConvertPurchaseDeliveryNoteDialogProps) {
  const convert = useConvertPurchaseDeliveryNote()
  const reasonId = useId()

  const [date, setDate] = useState(() => argentinaToday())
  const [costCenterId, setCostCenterId] = useState<string | null>(null)
  const [paymentMethodId, setPaymentMethodId] = useState<string | null>(null)
  const [bankAccountId, setBankAccountId] = useState<string | null>(null)

  const supplierId = deliveryNote.supplier_id ?? null
  const total = Number(deliveryNote.total)

  // La sucursal de la compra ES la del remito (D8): es a la que entró el stock y la
  // que usa el servidor. Es la MISMA que resuelve la sesión de caja.
  const checkout = usePurchaseCheckout({
    paymentMethodId,
    branchId: deliveryNote.branch_id,
    date,
    supplierId,
    total,
  })

  // El plazo del proveedor: primero el suyo, si no el de la cuenta (la cascada).
  const { data: supplier } = useSupplier(supplierId)
  const dueDate = useDueDateCascade({ date, entityTermsDays: supplier?.paymentTermsDays })

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

  const numberLabel = deliveryNote.number_label

  // Por qué no se puede confirmar todavía (se muestra y lo lee el lector de pantalla).
  const blockReason = !paymentMethodId
    ? "Elegí la forma de pago para registrar la compra."
    : !date
      ? "Elegí la fecha de la compra."
      : date < deliveryNote.issued_on
        ? `La fecha de la compra no puede ser anterior a la recepción del remito (${formatDate(deliveryNote.issued_on)}).`
        : null

  async function handleConfirm(idempotencyKey: string): Promise<PurchaseDeliveryNoteConvertResult> {
    // El botón sólo se habilita con una forma de pago elegida; esto es la red de seguridad.
    if (!paymentMethodId) throw new Error("payment_method_required")
    return convert.mutateAsync({
      deliveryNoteId: deliveryNote.id,
      idempotencyKey,
      payload: {
        expected_revision: deliveryNote.revision,
        payment_method_id: paymentMethodId,
        date,
        // Con efectivo, las tres condiciones cumplidas y el opt-in tildado: la sesión
        // abierta de la sucursal del remito. Si no, la compra se registra sin caja.
        cash_session_id: checkout.cashSessionId,
        bank_account_id: bankAccountId,
        cost_center_id: costCenterId,
        // El vencimiento sólo existe a crédito, y sólo viaja si el usuario lo tocó.
        due_date: checkout.isCredit ? dueDate.valueForServer : null,
      },
    })
  }

  // El remito de la pantalla ya no es el pendiente que se abrió (otro usuario lo
  // convirtió o lo anuló y el detalle se recargó): no se ofrece una confirmación
  // que fallaría con el mismo error en cada reintento. El éxito propio manda (la
  // cáscara lo respeta): tras convertir el remito también pasa a `converted` y se
  // sigue viendo el recibo.
  const staleMessage =
    deliveryNote.status === "issued"
      ? null
      : `El remito${numberLabel ? ` ${numberLabel}` : ""} ${
          deliveryNote.status === "converted" ? "ya fue convertido en compra" : "ya fue anulado"
        }: no hay nada para registrar.`

  return (
    <ConvertDocumentDialogShell<PurchaseDeliveryNoteConvertResult>
      open={open}
      onOpenChange={onOpenChange}
      title="Pasar a compra"
      idempotencyScope={`delivery-note-purchase-convert:${deliveryNote.id}`}
      summary={
        <section aria-label="Resumen del remito" className="flex min-w-0 flex-col gap-2">
          <p className="text-sm text-muted-foreground">
            {numberLabel ?? "Remito"}
            {deliveryNote.supplier_name ? <> · {deliveryNote.supplier_name}</> : null}
          </p>
          {deliveryNote.supplier_reference ? (
            <p className="break-all text-xs text-muted-foreground">
              Remito del proveedor N° {deliveryNote.supplier_reference}
            </p>
          ) : null}
          <p className="text-xs text-muted-foreground">
            Ingresa a: <span className="text-foreground">{deliveryNote.branch_name ?? "la sucursal del remito"}</span>
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
            <span className="text-sm text-muted-foreground">Total de la compra</span>
            <span data-testid="convert-delivery-note-total" className="text-lg font-bold tabular-nums text-primary">
              {formatMoney(total, "ARS")}
            </span>
          </div>
          <p className="rounded-lg border border-border bg-muted/40 px-3 py-2 text-sm text-foreground">
            El stock ya se sumó al recibir el remito{numberLabel ? ` ${numberLabel}` : ""}: esta compra no lo vuelve
            a sumar.
          </p>
        </section>
      }
      renderFields={({ submitting }) => (
        <>
          <PurchaseCheckoutFields
            checkout={checkout}
            date={date}
            onDateChange={setDate}
            minDate={deliveryNote.issued_on}
            costCenterId={costCenterId}
            onCostCenterChange={setCostCenterId}
            paymentMethodId={paymentMethodId}
            onPaymentMethodChange={handlePaymentMethodChange}
            paymentRequired
            bankAccountId={bankAccountId}
            onBankAccountChange={setBankAccountId}
            showDueDate
            dueDate={dueDate}
            disabled={submitting}
          />
          {blockReason && (
            <p id={reasonId} className="text-xs text-muted-foreground">
              {blockReason}
            </p>
          )}
        </>
      )}
      confirmLabel="Registrar compra"
      confirmDisabled={blockReason !== null || checkout.creditBlockedNoSupplier}
      confirmDescribedBy={reasonId}
      onConfirm={handleConfirm}
      renderSuccess={(result, close) => (
        <PurchaseCheckoutSuccess total={Number(result.total)} replayed={result.replayed} onClose={close} />
      )}
      humanizeError={(source) =>
        humanizeOperationError(
          source,
          (productId) => productNameById.get(productId) || undefined,
          deliveryNote.branch_name,
          { documentLabel: "remito", direction: "purchase" },
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
export function ConvertPurchaseDeliveryNoteDialog(props: ConvertPurchaseDeliveryNoteDialogProps) {
  return <ConvertPurchaseDeliveryNoteDialogBody key={props.deliveryNote.id} {...props} />
}
