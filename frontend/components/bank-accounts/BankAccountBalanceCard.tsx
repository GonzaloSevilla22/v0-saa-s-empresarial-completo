"use client"

import { Scale } from "lucide-react"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { CURRENCIES, formatDate, formatMoney, type Currency } from "@/lib/format"
import { cn } from "@/lib/utils"
import type { BankAccount } from "@/hooks/data/use-bank-accounts"

function toCurrency(code: string): Currency {
  return CURRENCIES.some((c) => c.value === code) ? (code as Currency) : "ARS"
}

/**
 * Saldo "según libro" de la cuenta elegida en /banco: lo que el banco debería
 * tener según lo registrado (saldo inicial + movimientos), análogo al saldo
 * esperado de la caja. Lo calcula el servidor; acá sólo se muestra.
 */
export function BankAccountBalanceCard({ account }: { account: BankAccount | null }) {
  if (!account) return null

  const currency = toCurrency(account.currency)
  const pending = account.pendingReconciliationCount

  return (
    <Card>
      <CardHeader className="pb-2">
        <CardTitle className="text-base flex items-center gap-2">
          <Scale className="h-4 w-4 text-muted-foreground" />
          Saldo según libro
        </CardTitle>
      </CardHeader>
      <CardContent className="space-y-1">
        <p
          data-testid="bank-libro-balance"
          className={cn(
            "text-3xl font-bold tabular-nums",
            account.currentBalance < 0 && "text-destructive",
          )}
        >
          {formatMoney(account.currentBalance, currency)}
        </p>
        <p className="text-xs text-muted-foreground">
          Lo que debería tener el banco según lo registrado.
        </p>
        <p className="text-sm text-muted-foreground">
          Saldo inicial: {formatMoney(account.openingBalance, currency)}
        </p>
        {account.lastMovementDate && (
          <p className="text-sm text-muted-foreground">
            Último movimiento: {formatDate(account.lastMovementDate)}
          </p>
        )}
        {pending > 0 && (
          <p className="text-sm text-muted-foreground">
            {pending} {pending === 1 ? "movimiento sin conciliar" : "movimientos sin conciliar"}
          </p>
        )}
      </CardContent>
    </Card>
  )
}
