"use client"

import { TrendingUp } from "lucide-react"

interface SupplierAccountBalanceProps {
  balance: number
  supplierName?: string
}

export function SupplierAccountBalance({ balance, supplierName }: SupplierAccountBalanceProps) {
  const isDebt = balance > 0
  const isZero = balance === 0

  return (
    <div className="rounded-lg border border-border bg-card p-6">
      <div className="flex items-start justify-between gap-4">
        <div>
          <p className="text-sm text-muted-foreground">Saldo a pagar</p>
          {supplierName && (
            <p className="text-xs text-muted-foreground mt-0.5">{supplierName}</p>
          )}
          <p
            className={`text-3xl font-bold mt-2 tabular-nums ${
              isZero ? "text-foreground" : isDebt ? "text-yellow-400" : "text-emerald-400"
            }`}
          >
            $ {Math.abs(balance).toLocaleString("es-AR", {
              minimumFractionDigits: 2,
              maximumFractionDigits: 2,
            })}
          </p>
          <p className="text-xs text-muted-foreground mt-1">
            {isZero
              ? "Sin deuda pendiente"
              : isDebt
              ? "El negocio debe al proveedor"
              : "Saldo a favor del negocio"}
          </p>
        </div>
        <div
          className={`rounded-full p-3 ${
            isZero ? "bg-accent" : isDebt ? "bg-yellow-500/10" : "bg-emerald-500/10"
          }`}
        >
          <TrendingUp
            className={`h-5 w-5 ${isDebt ? "text-yellow-400" : "text-emerald-400"}`}
          />
        </div>
      </div>
    </div>
  )
}
