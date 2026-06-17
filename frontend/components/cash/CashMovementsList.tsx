"use client"

import { ArrowDownCircle, ArrowUpCircle } from "lucide-react"
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table"
import type { CashMovement, CashMovementType } from "@/lib/types"

const MOVEMENT_LABELS: Record<CashMovementType, string> = {
  sale:             "Venta",
  purchase_payment: "Pago a proveedor",
  expense:          "Gasto",
  advance:          "Adelanto / depósito",
  withdrawal:       "Retiro",
}

interface CashMovementsListProps {
  movements: CashMovement[]
  isLoading: boolean
}

export function CashMovementsList({ movements, isLoading }: CashMovementsListProps) {
  if (isLoading) {
    return (
      <p className="text-sm text-muted-foreground py-4 text-center">
        Cargando movimientos…
      </p>
    )
  }

  if (movements.length === 0) {
    return (
      <p className="text-sm text-muted-foreground py-6 text-center">
        Sin movimientos registrados en esta sesión.
      </p>
    )
  }

  return (
    <div className="overflow-x-auto rounded-md border">
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead className="w-8" />
            <TableHead>Tipo</TableHead>
            <TableHead className="text-right">Monto</TableHead>
            <TableHead className="text-right">Saldo tras mov.</TableHead>
            <TableHead>Hora</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {movements.map((m) => {
            const isIncome = m.amount >= 0
            return (
              <TableRow key={m.id}>
                <TableCell className="pr-0">
                  {isIncome ? (
                    <ArrowUpCircle
                      className="h-4 w-4 text-green-500"
                      aria-label="Ingreso"
                    />
                  ) : (
                    <ArrowDownCircle
                      className="h-4 w-4 text-red-500"
                      aria-label="Egreso"
                    />
                  )}
                </TableCell>
                <TableCell className="text-sm">
                  {MOVEMENT_LABELS[m.movementType] ?? m.movementType}
                </TableCell>
                <TableCell
                  className={`text-right font-medium ${
                    isIncome ? "text-green-600 dark:text-green-400" : "text-red-600 dark:text-red-400"
                  }`}
                >
                  {isIncome ? "+" : ""}
                  ${Math.abs(m.amount).toLocaleString("es-AR", { minimumFractionDigits: 2 })}
                </TableCell>
                <TableCell className="text-right text-sm">
                  ${m.balanceAfter.toLocaleString("es-AR", { minimumFractionDigits: 2 })}
                </TableCell>
                <TableCell className="text-xs text-muted-foreground whitespace-nowrap">
                  {new Date(m.createdAt).toLocaleTimeString("es-AR", {
                    hour: "2-digit",
                    minute: "2-digit",
                  })}
                </TableCell>
              </TableRow>
            )
          })}
        </TableBody>
      </Table>
    </div>
  )
}
