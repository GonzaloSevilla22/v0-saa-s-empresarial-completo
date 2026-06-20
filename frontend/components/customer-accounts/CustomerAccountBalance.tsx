"use client"

import { TrendingDown, TrendingUp } from "lucide-react"

interface CustomerAccountBalanceProps {
  balance: number
  clientName?: string
}

export function CustomerAccountBalance({ balance, clientName }: CustomerAccountBalanceProps) {
  const isDebt = balance > 0
  const isZero = balance === 0

  return (
    <div className="rounded-lg border border-border bg-card p-6">
      <div className="flex items-start justify-between gap-4">
        <div>
          <p className="text-sm text-muted-foreground">Saldo deudor</p>
          {clientName && (
            <p className="text-xs text-muted-foreground mt-0.5">{clientName}</p>
          )}
          <p
            className={`text-3xl font-bold mt-2 tabular-nums ${
              isZero
                ? "text-foreground"
                : isDebt
                ? "text-yellow-400"
                : "text-emerald-400"
            }`}
          >
            {balance < 0 ? "-" : ""}$ {Math.abs(balance).toLocaleString("es-AR", {
              minimumFractionDigits: 2,
              maximumFractionDigits: 2,
            })}
          </p>
          <p className="text-xs text-muted-foreground mt-1">
            {isZero
              ? "Sin deuda pendiente"
              : isDebt
              ? "Debe al negocio"
              : "Saldo a favor del cliente"}
          </p>
        </div>
        <div
          className={`rounded-full p-3 ${
            isZero
              ? "bg-accent"
              : isDebt
              ? "bg-yellow-500/10"
              : "bg-emerald-500/10"
          }`}
        >
          {isDebt ? (
            <TrendingDown className="h-5 w-5 text-yellow-400" />
          ) : (
            <TrendingUp className="h-5 w-5 text-emerald-400" />
          )}
        </div>
      </div>
    </div>
  )
}
