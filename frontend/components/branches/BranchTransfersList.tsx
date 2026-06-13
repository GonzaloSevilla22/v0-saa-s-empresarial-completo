"use client"

import { useBranchTransfers } from "@/hooks/data/use-branch-transfers"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { ArrowDownLeft, ArrowUpRight, ArrowLeftRight, Loader2 } from "lucide-react"

interface BranchTransfersListProps {
  branchId: string
}

/**
 * C-26: historial de transferencias de la sucursal (entrantes y salientes).
 */
export function BranchTransfersList({ branchId }: BranchTransfersListProps) {
  const { transfers, isLoading } = useBranchTransfers(branchId)

  return (
    <Card className="border border-border">
      <CardHeader className="pb-2">
        <CardTitle className="flex items-center gap-2 text-sm font-semibold">
          <ArrowLeftRight className="h-4 w-4 text-muted-foreground" />
          Transferencias
        </CardTitle>
      </CardHeader>
      <CardContent>
        {isLoading ? (
          <div className="flex items-center justify-center py-6 text-muted-foreground">
            <Loader2 className="h-4 w-4 animate-spin mr-2" />
            Cargando transferencias…
          </div>
        ) : transfers.length === 0 ? (
          <p className="py-4 text-center text-xs text-muted-foreground">
            Sin transferencias registradas para esta sucursal.
          </p>
        ) : (
          <ul className="divide-y divide-border">
            {transfers.map((t) => {
              const isOutgoing = t.fromBranchId === branchId
              return (
                <li key={t.id} className="flex items-center justify-between gap-3 py-2.5">
                  <div className="flex items-center gap-2.5 min-w-0">
                    {isOutgoing ? (
                      <ArrowUpRight className="h-4 w-4 shrink-0 text-amber-500" aria-label="Salida" />
                    ) : (
                      <ArrowDownLeft className="h-4 w-4 shrink-0 text-emerald-500" aria-label="Entrada" />
                    )}
                    <div className="min-w-0">
                      <p className="truncate text-sm font-medium">{t.productName}</p>
                      <p className="text-xs text-muted-foreground">
                        {isOutgoing ? `Hacia ${t.toBranchName}` : `Desde ${t.fromBranchName}`}
                      </p>
                    </div>
                  </div>
                  <div className="shrink-0 text-right">
                    <p className="text-sm font-medium">
                      {isOutgoing ? "−" : "+"}
                      {t.quantity}
                    </p>
                    <p className="text-xs text-muted-foreground">
                      {new Date(t.createdAt).toLocaleDateString("es-AR")}
                    </p>
                  </div>
                </li>
              )
            })}
          </ul>
        )}
      </CardContent>
    </Card>
  )
}
