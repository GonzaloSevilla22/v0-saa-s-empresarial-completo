"use client"

import { useState } from "react"
import { ArrowDownLeft, ArrowUpRight, SlidersHorizontal, Undo2 } from "lucide-react"
import { toast } from "sonner"
import type { CustomerAccountMovement } from "@/hooks/data/use-customer-account"
import { useReversePaymentReceived } from "@/hooks/data/use-customer-account"
import { DeleteOperationDialog } from "@/components/shared/delete-operation-dialog"
import { getDeleteCompensation } from "@/lib/delete-compensation"
import { humanizeOperationError } from "@/lib/operation-errors"
import { formatMovementDueStatus } from "@/lib/receivables-aging"

const MOVEMENT_LABELS: Record<CustomerAccountMovement["movementType"], string> = {
  sale:             "Venta a crédito",
  payment_received: "Cobro",
  // cobranzas-reverso (task 13.1): el Record es CERRADO sobre los tipos de
  // movementType — agregar payment_received_reversal acá o el build rompe.
  payment_received_reversal: "Anulación de cobro",
  credit_note:      "Nota de crédito",
  adjustment:       "Ajuste",
}

const MOVEMENT_ICONS: Record<CustomerAccountMovement["movementType"], React.ReactNode> = {
  sale:             <ArrowUpRight className="h-4 w-4 text-yellow-400" />,
  payment_received: <ArrowDownLeft className="h-4 w-4 text-emerald-400" />,
  payment_received_reversal: <Undo2 className="h-4 w-4 text-destructive" />,
  credit_note:      <ArrowDownLeft className="h-4 w-4 text-blue-400" />,
  adjustment:       <SlidersHorizontal className="h-4 w-4 text-muted-foreground" />,
}

/**
 * cobranzas-vencimientos (D7, task 9.8): línea de vencimiento por CARGO —
 * derivados del SERVIDOR (due_date/is_overdue/days_overdue/open_amount por
 * imputación FIFO), nunca reglas locales. Devuelve null para movimientos que
 * no son cargo ("no aplica" no es un estado).
 */
function dueLine(m: {
  dueDate: string | null
  openAmount: number | null
  isOverdue: boolean | null
  daysOverdue: number | null
}): { text: string; overdue: boolean } | null {
  const status = formatMovementDueStatus({
    isOverdue: m.isOverdue,
    daysOverdue: m.daysOverdue,
    openAmount: m.openAmount,
  })
  if (status === null) return null
  const parts: string[] = []
  if (m.dueDate) {
    const [y, mo, d] = m.dueDate.split("-")
    parts.push(`Vence ${d}/${mo}/${y}`)
  }
  parts.push(status)
  if (m.openAmount !== null && m.openAmount > 0) {
    parts.push(
      `$${m.openAmount.toLocaleString("es-AR", { minimumFractionDigits: 2, maximumFractionDigits: 2 })} abiertos`,
    )
  }
  return { text: parts.join(" · "), overdue: m.isOverdue === true }
}

interface CustomerAccountHistoryProps {
  movements: CustomerAccountMovement[]
  loading?: boolean
  /** cobranzas-reverso (task 13.1): requerido para ofrecer "Anular" por
   * fila — la mutación necesita el clientId para invalidar la cuenta
   * correcta. */
  clientId: string
}

export function CustomerAccountHistory({ movements, loading, clientId }: CustomerAccountHistoryProps) {
  const [reason, setReason] = useState("")
  const reverseMutation = useReversePaymentReceived(clientId)

  async function handleReverse(movement: CustomerAccountMovement) {
    try {
      await reverseMutation.mutateAsync({ paymentId: movement.referenceId ?? "", reason: reason || undefined })
      toast.success("Cobro anulado")
      setReason("")
    } catch (err) {
      const { message } = humanizeOperationError((err as Error).message)
      toast.error(message)
    }
  }

  if (loading) {
    return (
      <div className="rounded-lg border border-border overflow-hidden">
        <div className="px-4 py-3 bg-accent/40 border-b border-border">
          <p className="text-xs font-semibold uppercase tracking-wider text-muted-foreground">
            Historial de movimientos
          </p>
        </div>
        {Array.from({ length: 4 }).map((_, i) => (
          <div key={i} className="border-t border-border/50 first:border-t-0 px-4 py-3">
            <div className="flex items-center gap-3">
              <div className="h-8 w-8 rounded-full bg-accent animate-pulse shrink-0" />
              <div className="flex-1 space-y-1.5">
                <div className="h-3 rounded bg-accent animate-pulse w-32" />
                <div className="h-2.5 rounded bg-accent animate-pulse w-20" />
              </div>
              <div className="h-3.5 rounded bg-accent animate-pulse w-24" />
            </div>
          </div>
        ))}
      </div>
    )
  }

  if (movements.length === 0) {
    return (
      <div className="rounded-lg border border-border overflow-hidden">
        <div className="px-4 py-3 bg-accent/40 border-b border-border">
          <p className="text-xs font-semibold uppercase tracking-wider text-muted-foreground">
            Historial de movimientos
          </p>
        </div>
        <div className="py-12 text-center text-muted-foreground text-sm">
          Sin movimientos registrados
        </div>
      </div>
    )
  }

  return (
    <div className="rounded-lg border border-border overflow-hidden">
      <div className="px-4 py-3 bg-accent/40 border-b border-border">
        <p className="text-xs font-semibold uppercase tracking-wider text-muted-foreground">
          Historial de movimientos
        </p>
      </div>

      {/* Header (desktop) */}
      <div className="hidden sm:grid grid-cols-[auto_1fr_140px_140px_100px_auto] gap-3 px-4 py-2 border-b border-border text-[10px] uppercase tracking-wider text-muted-foreground font-semibold">
        <span className="w-8" />
        <span>Tipo</span>
        <span className="text-right">Importe</span>
        <span className="text-right">Saldo después</span>
        <span>Fecha</span>
        <span className="w-8" />
      </div>

      {movements.map((m) => {
        const isDebit = m.movementType === "sale"
        // El signo visual lo pone el componente ("+"/"−") según el tipo; el
        // monto se formatea en valor absoluto para no duplicarlo (los cobros,
        // NC y ajustes viven NEGATIVOS en el ledger — reporte PO 2026-08-21:
        // "Cobro −$-58.750,00").
        const formattedAmount = Math.abs(m.amount).toLocaleString("es-AR", {
          minimumFractionDigits: 2,
          maximumFractionDigits: 2,
        })
        const formattedBalance = m.balanceAfter.toLocaleString("es-AR", {
          minimumFractionDigits: 2,
          maximumFractionDigits: 2,
        })
        const formattedDate = new Date(m.createdAt).toLocaleDateString("es-AR", {
          day:   "2-digit",
          month: "short",
          year:  "numeric",
        })

        // cobranzas-reverso (task 13.1): la acción de anular sólo se ofrece
        // en filas de cobro cuyo documento sigue vivo (is_reversible,
        // derivado del servidor — D12).
        const compensationInfo = getDeleteCompensation(
          {
            isDeleteBlocked: m.isReversalBlocked,
            hasCashMovement: m.hasCashMovement,
            hasBankMovement: m.hasBankMovement,
          },
          "cliente",
          "cobro",
        )

        return (
          <div
            key={m.id}
            className="border-t border-border/50 first:border-t-0 hover:bg-accent/20 transition-colors"
          >
            {/* Mobile */}
            <div className="sm:hidden flex items-center gap-3 px-4 py-3">
              <div className="shrink-0 rounded-full bg-accent p-2">
                {MOVEMENT_ICONS[m.movementType]}
              </div>
              <div className="flex-1 min-w-0">
                <p className="text-sm font-medium text-foreground">
                  {MOVEMENT_LABELS[m.movementType]}
                  {/* cobranzas-catalogo-pagos (D3, task 10.1): nombre real de
                      la forma de pago configurada por el usuario — se omite
                      cuando no hay imputación (históricos), nunca se inventa
                      un valor. */}
                  {m.movementType === "payment_received" && m.paymentMethod && (
                    <span className="ml-1.5 font-normal text-muted-foreground">
                      · {m.paymentMethod}
                    </span>
                  )}
                </p>
                <p className="text-xs text-muted-foreground">{formattedDate}</p>
                {(() => {
                  const line = dueLine(m)
                  return line ? (
                    <p className={`text-xs ${line.overdue ? "text-destructive" : "text-muted-foreground"}`}>
                      {line.text}
                    </p>
                  ) : null
                })()}
              </div>
              <div className="text-right shrink-0">
                <p
                  className={`text-sm font-semibold tabular-nums ${
                    isDebit ? "text-yellow-400" : "text-emerald-400"
                  }`}
                >
                  {isDebit ? "+" : "−"}${formattedAmount}
                </p>
                <p className="text-xs text-muted-foreground tabular-nums">
                  saldo: ${formattedBalance}
                </p>
              </div>
              {m.isReversible && (
                <DeleteOperationDialog
                  label="este cobro"
                  info={compensationInfo}
                  onConfirm={() => handleReverse(m)}
                  isDeleting={reverseMutation.isPending}
                  actionVerb="Anular"
                  actionVerbGerund="Anulando"
                  icon={<Undo2 className="h-3.5 w-3.5" />}
                  reasonField={{ value: reason, onChange: setReason }}
                />
              )}
            </div>

            {/* Desktop */}
            <div className="hidden sm:grid grid-cols-[auto_1fr_140px_140px_100px_auto] gap-3 px-4 py-3 items-center">
              <div className="w-8 flex justify-center">
                <div className="rounded-full bg-accent p-1.5">
                  {MOVEMENT_ICONS[m.movementType]}
                </div>
              </div>
              <span className="text-sm text-foreground">
                {MOVEMENT_LABELS[m.movementType]}
                {m.movementType === "payment_received" && m.paymentMethod && (
                  <span className="ml-1.5 font-normal text-muted-foreground">
                    · {m.paymentMethod}
                  </span>
                )}
                {(() => {
                  const line = dueLine(m)
                  return line ? (
                    <span
                      className={`block text-xs font-normal ${line.overdue ? "text-destructive" : "text-muted-foreground"}`}
                    >
                      {line.text}
                    </span>
                  ) : null
                })()}
              </span>
              <span
                className={`text-sm font-semibold tabular-nums text-right ${
                  isDebit ? "text-yellow-400" : "text-emerald-400"
                }`}
              >
                {isDebit ? "+" : "−"}${formattedAmount}
              </span>
              <span className="text-sm text-muted-foreground tabular-nums text-right">
                ${formattedBalance}
              </span>
              <span className="text-xs text-muted-foreground">{formattedDate}</span>
              <div className="w-8 flex justify-center">
                {m.isReversible && (
                  <DeleteOperationDialog
                    label="este cobro"
                    info={compensationInfo}
                    onConfirm={() => handleReverse(m)}
                    isDeleting={reverseMutation.isPending}
                    actionVerb="Anular"
                    actionVerbGerund="Anulando"
                    icon={<Undo2 className="h-3.5 w-3.5" />}
                    reasonField={{ value: reason, onChange: setReason }}
                  />
                )}
              </div>
            </div>
          </div>
        )
      })}
    </div>
  )
}
