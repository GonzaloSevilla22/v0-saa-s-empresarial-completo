"use client"

import { useState } from "react"
import { ArrowDownLeft, ArrowUpRight, SlidersHorizontal, Undo2 } from "lucide-react"
import { toast } from "sonner"
import type { SupplierAccountMovement } from "@/hooks/data/use-supplier-account"
import { useReversePaymentMade } from "@/hooks/data/use-supplier-account"
import { DeleteOperationDialog } from "@/components/shared/delete-operation-dialog"
import { getDeleteCompensation } from "@/lib/delete-compensation"
import { humanizeOperationError } from "@/lib/operation-errors"

const MOVEMENT_LABELS: Record<SupplierAccountMovement["movementType"], string> = {
  purchase:     "Compra / cargo",
  payment_made: "Pago al proveedor",
  // fix-supplier-account-ui-post-delete (bug 2): un debit_note es la reversa
  // de un cargo (SupplierAccountChargeReversed) — no un cargo nuevo. La
  // etiqueta lo deja explícito.
  debit_note:   "Nota de débito / reversa",
  // cobranzas-reverso (task 13.2): el Record es CERRADO — agregar
  // payment_made_reversal acá o el build rompe.
  payment_made_reversal: "Anulación de pago",
  adjustment:   "Ajuste",
}

interface SupplierAccountHistoryProps {
  movements: SupplierAccountMovement[]
  loading?: boolean
  /** cobranzas-reverso (task 13.2): requerido para ofrecer "Anular" por fila. */
  supplierId: string
}

export function SupplierAccountHistory({ movements, loading, supplierId }: SupplierAccountHistoryProps) {
  const [reason, setReason] = useState("")
  const reverseMutation = useReversePaymentMade(supplierId)

  async function handleReverse(movement: SupplierAccountMovement) {
    try {
      await reverseMutation.mutateAsync({ paymentId: movement.referenceId ?? "", reason: reason || undefined })
      toast.success("Pago anulado")
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

      <div className="hidden sm:grid grid-cols-[auto_1fr_140px_140px_100px_auto] gap-3 px-4 py-2 border-b border-border text-[10px] uppercase tracking-wider text-muted-foreground font-semibold">
        <span className="w-8" />
        <span>Tipo</span>
        <span className="text-right">Importe</span>
        <span className="text-right">Saldo después</span>
        <span>Fecha</span>
        <span className="w-8" />
      </div>

      {movements.map((m) => {
        // fix-supplier-account-ui-post-delete (bug 2): la dirección visual
        // (+/−, color, ícono) se deriva del SIGNO del monto, no del TIPO de
        // movimiento — un debit_note de reversa (monto negativo) REDUCE la
        // deuda, aunque su tipo sea el mismo que un cargo nuevo. Reporte PO
        // 2026-08-22: la reversa de un cargo borrado se hubiera pintado como
        // cargo positivo si se seguía clasificando por tipo.
        const isPositive = m.amount > 0
        // El signo visual lo pone el componente ("+"/"−") según el signo del
        // monto; el importe se formatea en valor absoluto para no
        // duplicarlo (mismo fix que CustomerAccountHistory, PR #437: "Cobro
        // −$-58.750,00").
        const formattedAmount = Math.abs(m.amount).toLocaleString("es-AR", {
          minimumFractionDigits: 2,
          maximumFractionDigits: 2,
        })
        // cobranzas-reverso (task 13.2): a diferencia de las filas
        // preexistentes (colores literales, de antes del token-contrast-aa),
        // el ícono de la anulación de pago usa el token semántico —
        // consistente con CustomerAccountHistory.tsx y con el resto de la
        // superficie NUEVA de este change (D10: es un ingreso — repone la
        // caja — mismo tono "success" que CASH_MOVEMENT_META.payment_made_reversal).
        const icon = m.movementType === "adjustment"
          ? <SlidersHorizontal className="h-4 w-4 text-muted-foreground" />
          : m.movementType === "payment_made_reversal"
            ? <Undo2 className="h-4 w-4 text-success" />
            : isPositive
              ? <ArrowUpRight className="h-4 w-4 text-yellow-400" />
              : <ArrowDownLeft className="h-4 w-4 text-emerald-400" />
        const formattedBalance = m.balanceAfter.toLocaleString("es-AR", {
          minimumFractionDigits: 2,
          maximumFractionDigits: 2,
        })
        const formattedDate = new Date(m.createdAt).toLocaleDateString("es-AR", {
          day:   "2-digit",
          month: "short",
          year:  "numeric",
        })

        const compensationInfo = getDeleteCompensation(
          {
            isDeleteBlocked: m.isReversalBlocked,
            hasCashMovement: m.hasCashMovement,
            hasBankMovement: m.hasBankMovement,
          },
          "proveedor",
          "pago",
        )

        return (
          <div
            key={m.id}
            className="border-t border-border/50 first:border-t-0 hover:bg-accent/20 transition-colors"
          >
            {/* Mobile */}
            <div className="sm:hidden flex items-center gap-3 px-4 py-3">
              <div className="shrink-0 rounded-full bg-accent p-2">
                {icon}
              </div>
              <div className="flex-1 min-w-0">
                <p className="text-sm font-medium text-foreground">
                  {MOVEMENT_LABELS[m.movementType]}
                </p>
                <p className="text-xs text-muted-foreground">{formattedDate}</p>
              </div>
              <div className="text-right shrink-0">
                <p
                  className={`text-sm font-semibold tabular-nums ${
                    isPositive ? "text-yellow-400" : "text-emerald-400"
                  }`}
                >
                  {isPositive ? "+" : "−"}${formattedAmount}
                </p>
                <p className="text-xs text-muted-foreground tabular-nums">
                  saldo: ${formattedBalance}
                </p>
              </div>
              {m.isReversible && (
                <DeleteOperationDialog
                  label="este pago"
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
                  {icon}
                </div>
              </div>
              <span className="text-sm text-foreground">
                {MOVEMENT_LABELS[m.movementType]}
              </span>
              <span
                className={`text-sm font-semibold tabular-nums text-right ${
                  isPositive ? "text-yellow-400" : "text-emerald-400"
                }`}
              >
                {isPositive ? "+" : "−"}${formattedAmount}
              </span>
              <span className="text-sm text-muted-foreground tabular-nums text-right">
                ${formattedBalance}
              </span>
              <span className="text-xs text-muted-foreground">{formattedDate}</span>
              <div className="w-8 flex justify-center">
                {m.isReversible && (
                  <DeleteOperationDialog
                    label="este pago"
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
