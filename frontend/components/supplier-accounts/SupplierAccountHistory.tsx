"use client"

import { ArrowDownLeft, ArrowUpRight, SlidersHorizontal } from "lucide-react"
import type { SupplierAccountMovement } from "@/hooks/data/use-supplier-account"

const MOVEMENT_LABELS: Record<SupplierAccountMovement["movementType"], string> = {
  purchase:    "Compra / cargo",
  payment_made: "Pago al proveedor",
  debit_note:  "Nota de débito",
  adjustment:  "Ajuste",
}

const MOVEMENT_ICONS: Record<SupplierAccountMovement["movementType"], React.ReactNode> = {
  purchase:    <ArrowUpRight className="h-4 w-4 text-yellow-400" />,
  payment_made: <ArrowDownLeft className="h-4 w-4 text-emerald-400" />,
  debit_note:  <ArrowUpRight className="h-4 w-4 text-red-400" />,
  adjustment:  <SlidersHorizontal className="h-4 w-4 text-muted-foreground" />,
}

interface SupplierAccountHistoryProps {
  movements: SupplierAccountMovement[]
  loading?: boolean
}

export function SupplierAccountHistory({ movements, loading }: SupplierAccountHistoryProps) {
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

      <div className="hidden sm:grid grid-cols-[auto_1fr_140px_140px_100px] gap-3 px-4 py-2 border-b border-border text-[10px] uppercase tracking-wider text-muted-foreground font-semibold">
        <span className="w-8" />
        <span>Tipo</span>
        <span className="text-right">Importe</span>
        <span className="text-right">Saldo después</span>
        <span>Fecha</span>
      </div>

      {movements.map((m) => {
        const isDebit = m.movementType === "purchase" || m.movementType === "debit_note"
        const formattedAmount = m.amount.toLocaleString("es-AR", {
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
                </p>
                <p className="text-xs text-muted-foreground">{formattedDate}</p>
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
            </div>

            {/* Desktop */}
            <div className="hidden sm:grid grid-cols-[auto_1fr_140px_140px_100px] gap-3 px-4 py-3 items-center">
              <div className="w-8 flex justify-center">
                <div className="rounded-full bg-accent p-1.5">
                  {MOVEMENT_ICONS[m.movementType]}
                </div>
              </div>
              <span className="text-sm text-foreground">
                {MOVEMENT_LABELS[m.movementType]}
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
            </div>
          </div>
        )
      })}
    </div>
  )
}
