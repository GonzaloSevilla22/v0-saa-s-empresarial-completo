"use client"

/**
 * ConvertQuoteDialog — convierte un presupuesto en venta, de forma atómica
 * (presupuestos-modulo D6/D12, tasks 6.8/6.9).
 *
 * Compone, sin lógica propia de cierre de venta:
 *   - el resumen de líneas y total, en sólo lectura (se cobra lo que se cotizó:
 *     si hay que cambiar algo, se edita el presupuesto);
 *   - `SaleCheckoutFields` + `useSaleCheckout` (sucursal, forma de pago, cuenta
 *     bancaria, caja con la semántica del POS, saldo del cliente);
 *   - `SaleCheckoutSuccess` (Venta registrada, Facturar, Ver en Ventas);
 *   - `useConvertQuote` (POST /quotes/{id}/convert, clave por header).
 *
 * Reglas que cuidan el dinero:
 *   - `expected_revision` = la `revision` que muestra el resumen. Si otro usuario
 *     editó el presupuesto, el servidor responde `quote_changed`: se recarga el
 *     detalle, se avisa y NO se cierra; el usuario confirma de nuevo sobre el
 *     total vigente.
 *   - Un fallo deja el diálogo abierto, con el mensaje en `role="alert"`; no se
 *     registró nada (la conversión es una transacción).
 *   - La clave de idempotencia es POR presupuesto (`quote-convert:<id>`) y se
 *     resetea tras cada éxito, incluido el replay: una respuesta perdida de la
 *     conversión de A no contamina la de B. Reintentar tras un error conserva la
 *     clave (un fallo revierte todo, incluida la clave).
 *   - Doble clic: un candado síncrono (ref) deja pasar una sola request; el
 *     estado `submitting` llega tarde para dos clics en el mismo tick.
 */

import { useCallback, useMemo, useRef, useState } from "react"
import Link from "next/link"
import { useQueryClient } from "@tanstack/react-query"
import { Button } from "@/components/ui/button"
import { ResponsiveModal } from "@/components/shared/responsive-modal"
import { SaleCheckoutFields, SALE_CHECKOUT_REASON_ID } from "@/components/ventas/SaleCheckoutFields"
import { SaleCheckoutSuccess } from "@/components/ventas/SaleCheckoutSuccess"
import { useBranches } from "@/hooks/data/use-branches"
import { useProducts } from "@/hooks/data/use-products"
import { useConvertQuote } from "@/hooks/data/use-quotes"
import { useIdempotencyKey } from "@/hooks/use-idempotency-key"
import { useSaleCheckout } from "@/hooks/use-sale-checkout"
import { PythonApiError } from "@/lib/api/python-api-error"
import { formatMoney, formatNumber } from "@/lib/format"
import { humanizeOperationError, type HumanizedOperationError } from "@/lib/operation-errors"
import { queryKeys } from "@/lib/query-keys"
import type { QuoteApiRow, QuoteConvertResult } from "@/lib/quote-types"

interface ConvertQuoteDialogProps {
  quote: QuoteApiRow
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

function isQuoteChanged(err: unknown): boolean {
  return /quote_changed/.test(errorSource(err))
}

function ConvertQuoteDialogBody({ quote, open, onOpenChange }: ConvertQuoteDialogProps) {
  const queryClient = useQueryClient()
  const convert = useConvertQuote()
  const { idempotencyKey, resetIdempotencyKey } = useIdempotencyKey(`quote-convert:${quote.id}`)
  const { products } = useProducts()
  const { branches } = useBranches()

  const [branchId, setBranchId] = useState<string | null>(null)
  const [paymentMethodId, setPaymentMethodId] = useState<string | null>(null)
  const [bankAccountId, setBankAccountId] = useState<string | null>(null)
  const [error, setError] = useState<HumanizedOperationError | null>(null)
  const [done, setDone] = useState<QuoteConvertResult | null>(null)
  const [submitting, setSubmitting] = useState(false)
  const submittingRef = useRef(false)

  // La sucursal de la venta: la elegida o, si no, la del presupuesto. Es la MISMA
  // que se usa para resolver la caja y la que viaja en el payload: el servidor
  // aplica `COALESCE(p_branch_id, quote.branch_id, default)`, así que resolverla
  // distinto acá dejaría la sesión de una sucursal y la venta en otra.
  const resolvedBranchId = branchId ?? quote.branch_id
  const checkout = useSaleCheckout({
    paymentMethodId,
    branchId: resolvedBranchId,
    clientId: quote.client_id,
  })

  const productNameById = useMemo(() => new Map(products.map((p) => [p.id, p.name])), [products])
  const branchName = branches.find((b) => b.id === (resolvedBranchId ?? checkout.cash.effectiveBranchId))?.name ?? null

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
        quoteId: quote.id,
        idempotencyKey,
        payload: {
          expected_revision: quote.revision,
          payment_method_id: paymentMethodId,
          branch_id: resolvedBranchId,
          // Con efectivo, SIEMPRE la sesión abierta de la sucursal elegida.
          cash_session_id: checkout.cashSessionId,
          bank_account_id: bankAccountId,
          canal: null,
        },
      })
      // Tras cada éxito (también el replay) la próxima operación nace con otra clave.
      resetIdempotencyKey()
      setDone(result)
    } catch (err: unknown) {
      if (isQuoteChanged(err)) {
        // Otro usuario lo editó: se recarga el resumen y se confirma sobre el total vigente.
        void queryClient.invalidateQueries({ queryKey: queryKeys.quotes.detail(quote.id) })
      }
      setError(
        humanizeOperationError(
          errorSource(err),
          (productId) => productNameById.get(productId),
          branchName,
        ),
      )
    } finally {
      submittingRef.current = false
      setSubmitting(false)
    }
  }

  const numberLabel = quote.number_label ?? "Presupuesto"
  const total = Number(quote.total)

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
            <section aria-label="Resumen del presupuesto" className="flex min-w-0 flex-col gap-2">
              <p className="text-sm text-muted-foreground">
                {numberLabel}
                {quote.client_name ? <> · {quote.client_name}</> : null}
              </p>
              <ul aria-label="Líneas del presupuesto" className="flex flex-col divide-y divide-border/60 rounded-lg border border-border bg-background">
                {quote.items.map((item) => (
                  <li key={item.id} className="flex items-baseline justify-between gap-3 px-3 py-2 text-sm">
                    <span className="min-w-0 break-words text-foreground">
                      {item.name_snapshot ?? "—"}
                      <span className="ml-1 text-xs tabular-nums text-muted-foreground">
                        × {formatNumber(Number(item.quantity), 4)}
                        {item.unit_symbol ? ` ${item.unit_symbol}` : ""}
                      </span>
                    </span>
                    <span className="shrink-0 tabular-nums text-foreground">{formatMoney(Number(item.subtotal), "ARS")}</span>
                  </li>
                ))}
              </ul>
              <div className="flex items-center justify-between gap-4 px-1">
                <span className="text-sm text-muted-foreground">Total a cobrar</span>
                <span data-testid="convert-quote-total" className="text-lg font-bold tabular-nums text-primary">
                  {formatMoney(total, "ARS")}
                </span>
              </div>
            </section>

            <SaleCheckoutFields
              branchId={resolvedBranchId}
              onBranchChange={setBranchId}
              paymentMethodId={paymentMethodId}
              onPaymentMethodChange={handlePaymentMethodChange}
              bankAccountId={bankAccountId}
              onBankAccountChange={setBankAccountId}
              clientId={quote.client_id}
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
 * Se monta con `key={quote.id}`: la clave de idempotencia y los campos son de UN
 * presupuesto. Si la pantalla reutiliza la instancia al navegar entre
 * presupuestos, el estado de uno no puede pasar al otro.
 */
export function ConvertQuoteDialog(props: ConvertQuoteDialogProps) {
  return <ConvertQuoteDialogBody key={props.quote.id} {...props} />
}
