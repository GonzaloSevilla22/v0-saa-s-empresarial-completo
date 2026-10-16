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
 * El cierre de la conversión (candado contra el doble clic, aviso accionable sin
 * cerrar, clave de idempotencia por presupuesto y su reset, recarga del presupuesto
 * y de las sesiones de caja) vive en `ConvertDocumentDialogShell`, compartido con
 * los dos remitos (Regla de Tres, remitos-compra tanda B). Acá queda lo de DOMINIO:
 * qué payload se manda, la sucursal por defecto y qué se exige.
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
 *     clave (un fallo revierte todo, incluida la clave); la excepción es
 *     `idempotency_key_conflict`, donde la clave chocó con otro documento y se renueva.
 *   - Doble clic: un candado síncrono (ref) deja pasar una sola request; el
 *     estado `submitting` llega tarde para dos clics en el mismo tick.
 */

import { useMemo, useState } from "react"
import { ConvertDocumentDialogShell } from "@/components/shared/ConvertDocumentDialogShell"
import { SaleCheckoutFields, SALE_CHECKOUT_REASON_ID } from "@/components/ventas/SaleCheckoutFields"
import { SaleCheckoutSuccess } from "@/components/ventas/SaleCheckoutSuccess"
import { useBranches } from "@/hooks/data/use-branches"
import { useProducts } from "@/hooks/data/use-products"
import { useConvertQuote } from "@/hooks/data/use-quotes"
import { useSaleCheckout } from "@/hooks/use-sale-checkout"
import { resolveDefaultBranch } from "@/lib/default-branch"
import { formatMoney, formatNumber } from "@/lib/format"
import { humanizeOperationError } from "@/lib/operation-errors"
import { queryKeys } from "@/lib/query-keys"
import type { QuoteApiRow, QuoteConvertResult } from "@/lib/quote-types"

interface ConvertQuoteDialogProps {
  quote: QuoteApiRow
  open: boolean
  onOpenChange: (open: boolean) => void
}

/** Rechazos tras los cuales el presupuesto mostrado ya no es el vigente. */
const RELOAD_QUOTE_ERROR = /quote_changed|quote_invalid_state/

function ConvertQuoteDialogBody({ quote, open, onOpenChange }: ConvertQuoteDialogProps) {
  const convert = useConvertQuote()
  const { products } = useProducts()
  const { branches } = useBranches()

  const [branchId, setBranchId] = useState<string | null>(null)
  const [paymentMethodId, setPaymentMethodId] = useState<string | null>(null)
  const [bankAccountId, setBankAccountId] = useState<string | null>(null)

  // La sucursal de la venta: la elegida, la del presupuesto o, si no hay ninguna,
  // la por defecto — `resolveDefaultBranch` (lib/default-branch.ts, ventas-sucursal-
  // por-defecto D10): la más antigua ACTIVA y ABIERTA, el mismo criterio de
  // `c26_default_branch` (el hook de sucursales sólo filtra `is_active`, así que
  // una sucursal cerrada podía quedar primera). Es la MISMA que se usa para
  // resolver la caja y la que viaja en el payload: el servidor aplica
  // `COALESCE(p_branch_id, quote.branch_id, default)`, así que resolverla
  // distinto acá dejaría la sesión de una sucursal y la venta en otra (P0422).
  // El selector (`SaleCheckoutFields`, `allowUnassigned={false}`) muestra siempre
  // esta sucursal: lo que se ve es lo que se guarda. Sin ninguna abierta,
  // `resolveDefaultBranch` cae en la más antigua a secas, como el servidor.
  const defaultBranchId = resolveDefaultBranch(branches)?.id ?? null
  const resolvedBranchId = branchId ?? quote.branch_id ?? defaultBranchId
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

  async function handleConfirm(idempotencyKey: string): Promise<QuoteConvertResult> {
    // El botón sólo se habilita con una forma de pago elegida; esto es la red de seguridad.
    if (!paymentMethodId) throw new Error("payment_method_required")
    return convert.mutateAsync({
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
  }

  const numberLabel = quote.number_label ?? "Presupuesto"
  const total = Number(quote.total)

  return (
    <ConvertDocumentDialogShell<QuoteConvertResult>
      open={open}
      onOpenChange={onOpenChange}
      title="Pasar a venta"
      idempotencyScope={`quote-convert:${quote.id}`}
      summary={
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
      }
      renderFields={({ submitting }) => (
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
        humanizeOperationError(source, (productId) => productNameById.get(productId), branchName)
      }
      reload={{ pattern: RELOAD_QUOTE_ERROR, queryKey: queryKeys.quotes.detail(quote.id) }}
    />
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
