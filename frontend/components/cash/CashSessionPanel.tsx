"use client"

import { Wallet, Clock, TrendingUp, AlertCircle } from "lucide-react"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Badge } from "@/components/ui/badge"
import type { CashSession } from "@/lib/types"

interface CashSessionPanelProps {
  session: CashSession | null
  isLoading: boolean
  /** Live running balance derived from movements (opening + Σ amount) */
  runningBalance?: number
}

export function CashSessionPanel({
  session,
  isLoading,
  runningBalance,
}: CashSessionPanelProps) {
  if (isLoading) {
    return (
      <Card>
        <CardContent className="py-8 text-center text-sm text-muted-foreground">
          Cargando estado de la caja…
        </CardContent>
      </Card>
    )
  }

  if (!session) {
    return (
      <Card className="border-dashed">
        <CardContent className="py-8 text-center">
          <Wallet className="mx-auto h-10 w-10 text-muted-foreground mb-3" />
          <p className="text-sm text-muted-foreground">
            No hay ninguna sesión de caja abierta.
          </p>
          <p className="text-xs text-muted-foreground mt-1">
            Ingresá el saldo inicial para comenzar.
          </p>
        </CardContent>
      </Card>
    )
  }

  const balance = runningBalance ?? session.openingBalance

  return (
    <Card>
      <CardHeader className="pb-3">
        <div className="flex items-center justify-between">
          <CardTitle className="text-base font-semibold">
            Estado de la caja
          </CardTitle>
          <Badge
            variant={session.status === "open" ? "default" : "secondary"}
            className={
              session.status === "open"
                ? "bg-green-500/15 text-green-700 dark:text-green-400 border-green-500/30"
                : ""
            }
          >
            {session.status === "open" ? "Abierta" : "Cerrada"}
          </Badge>
        </div>
      </CardHeader>
      <CardContent className="grid grid-cols-2 gap-4">
        <div>
          <p className="text-xs text-muted-foreground mb-0.5">Saldo inicial</p>
          <p className="text-lg font-semibold">
            $ {session.openingBalance.toLocaleString("es-AR", { minimumFractionDigits: 2 })}
          </p>
        </div>
        <div>
          <p className="text-xs text-muted-foreground mb-0.5">Saldo actual (esperado)</p>
          <p className="text-lg font-bold text-primary">
            $ {balance.toLocaleString("es-AR", { minimumFractionDigits: 2 })}
          </p>
        </div>
        {session.openedAt && (
          <div className="col-span-2 flex items-center gap-1.5 text-xs text-muted-foreground">
            <Clock className="h-3.5 w-3.5" />
            <span>
              Apertura:{" "}
              {new Date(session.openedAt).toLocaleString("es-AR", {
                dateStyle: "short",
                timeStyle: "short",
              })}
            </span>
          </div>
        )}
        {session.status === "closed" && session.difference != null && (
          <div
            className={`col-span-2 flex items-center gap-1.5 rounded-md px-3 py-2 text-sm ${
              session.difference === 0
                ? "bg-green-500/10 text-green-700 dark:text-green-400"
                : "bg-yellow-500/10 text-yellow-700 dark:text-yellow-400"
            }`}
          >
            {session.difference === 0 ? (
              <TrendingUp className="h-4 w-4" />
            ) : (
              <AlertCircle className="h-4 w-4" />
            )}
            <span>
              Diferencia:{" "}
              <strong>
                {session.difference >= 0 ? "+" : ""}
                ${session.difference.toLocaleString("es-AR", { minimumFractionDigits: 2 })}
              </strong>{" "}
              {session.difference === 0 ? "(sin diferencia)" : "(faltante/sobrante)"}
            </span>
          </div>
        )}
      </CardContent>
    </Card>
  )
}
