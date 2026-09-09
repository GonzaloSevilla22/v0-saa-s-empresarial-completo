"use client"

/**
 * ProductBranchBreakdown — sucursal-guard-vaciado-auditoria (OQ-5).
 *
 * El listado de /stock mostraba solo el agregado del catálogo
 * (`SUM(branch_stock.quantity)`), lo mismo que hacía invisible el incidente
 * del 22-08 (una sucursal se vació sin que nadie viera qué se estaba
 * perdiendo). Este componente es el contenido de la fila expandible: lee del
 * mismo hook canónico que ya usa TransferStockAction
 * (`useProductBranchBreakdown` → `branch_stock`, sin recalcular nada) y
 * reutiliza `StockSemaphore` para el estado — mismo predicado de umbral
 * (`min_stock <= 0` = "sin mínimo", nunca "Crítico") que la columna "Estado"
 * de la tabla principal.
 *
 * Se monta perezosamente: el padre (DataTable, vía `renderExpanded`) sólo la
 * renderiza mientras la fila está expandida, así que el hook no dispara su
 * query hasta que el usuario abre el desglose.
 */

import { useProductBranchBreakdown } from "@/hooks/data/use-branch-stock"
import { StockSemaphore } from "@/components/stock/stock-semaphore"
import { Skeleton } from "@/components/ui/skeleton"
import {
  Table, TableBody, TableCell, TableHead, TableHeader, TableRow,
} from "@/components/ui/table"

interface ProductBranchBreakdownProps {
  productId: string
}

export function ProductBranchBreakdown({ productId }: ProductBranchBreakdownProps) {
  const { breakdown, isLoading } = useProductBranchBreakdown(productId)

  if (isLoading) {
    return (
      <div className="flex flex-col gap-2 py-1" aria-label="Cargando desglose por sucursal">
        <Skeleton className="h-4 w-full" />
        <Skeleton className="h-4 w-full" />
      </div>
    )
  }

  if (breakdown.length === 0) {
    return (
      <p className="text-sm text-muted-foreground py-2">
        Sin existencias en ninguna sucursal.
      </p>
    )
  }

  return (
    <Table>
      <TableHeader>
        <TableRow className="border-border hover:bg-transparent">
          <TableHead className="text-muted-foreground text-xs font-medium uppercase tracking-wider">
            Sucursal
          </TableHead>
          <TableHead className="text-muted-foreground text-xs font-medium uppercase tracking-wider text-right">
            Cantidad
          </TableHead>
          <TableHead className="text-muted-foreground text-xs font-medium uppercase tracking-wider text-right">
            Mínimo
          </TableHead>
          <TableHead className="text-muted-foreground text-xs font-medium uppercase tracking-wider">
            Estado
          </TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {breakdown.map((row) => (
          <TableRow key={row.branchId} className="border-border hover:bg-transparent">
            <TableCell className="text-sm text-card-foreground">{row.branchName}</TableCell>
            <TableCell className="text-sm text-card-foreground text-right tabular-nums">
              {row.quantity}
            </TableCell>
            <TableCell className="text-sm text-muted-foreground text-right tabular-nums">
              {row.minStock}
            </TableCell>
            <TableCell>
              <StockSemaphore stock={row.quantity} minStock={row.minStock} size="sm" />
            </TableCell>
          </TableRow>
        ))}
      </TableBody>
    </Table>
  )
}
