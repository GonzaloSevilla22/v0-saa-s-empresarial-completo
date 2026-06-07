"use client"

import { useState } from "react"
import { useBranchStock } from "@/hooks/data/use-branch-stock"
import { useOrgRole } from "@/hooks/useOrgRole"
import { AdjustStockModal } from "@/components/branches/AdjustStockModal"
import { TransferStockModal } from "@/components/branches/TransferStockModal"
import { Button } from "@/components/ui/button"
import { Badge } from "@/components/ui/badge"
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table"
import { Loader2, Package, SlidersHorizontal, ArrowLeftRight } from "lucide-react"
import type { BranchStockWithProduct } from "@/lib/types"

interface BranchStockTableProps {
  branchId: string
}

type ActiveModal =
  | { type: "adjust"; item: BranchStockWithProduct }
  | { type: "transfer"; item: BranchStockWithProduct }
  | null

export function BranchStockTable({ branchId }: BranchStockTableProps) {
  const { branchStock, isLoading } = useBranchStock(branchId)
  const { isWriter } = useOrgRole()
  const [activeModal, setActiveModal] = useState<ActiveModal>(null)

  if (isLoading) {
    return (
      <div className="flex items-center justify-center py-16 text-muted-foreground">
        <Loader2 className="h-5 w-5 animate-spin mr-2" />
        Cargando inventario…
      </div>
    )
  }

  if (branchStock.length === 0) {
    return (
      <div className="flex flex-col items-center justify-center gap-3 py-16 text-center text-muted-foreground">
        <Package className="h-10 w-10 opacity-30" />
        <p className="text-sm">
          No hay productos con stock en esta sucursal.
        </p>
        <p className="text-xs opacity-70">
          Registrá una compra o ajustá el inventario para agregar stock.
        </p>
      </div>
    )
  }

  return (
    <>
      <div className="rounded-md border">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Producto</TableHead>
              <TableHead className="text-right">Stock actual</TableHead>
              <TableHead className="text-right">Stock mínimo</TableHead>
              {isWriter && <TableHead className="text-right">Acciones</TableHead>}
            </TableRow>
          </TableHeader>
          <TableBody>
            {branchStock.map((item) => {
              const isBelowMin = item.minStock > 0 && item.quantity <= item.minStock
              return (
                <TableRow key={item.id}>
                  <TableCell>
                    <div className="flex flex-col">
                      <span className="text-sm font-medium">{item.productName}</span>
                      {item.productSku && (
                        <span className="text-xs text-muted-foreground">SKU: {item.productSku}</span>
                      )}
                    </div>
                  </TableCell>
                  <TableCell className="text-right">
                    <div className="flex items-center justify-end gap-2">
                      <span className={isBelowMin ? "text-destructive font-semibold" : ""}>
                        {item.quantity}
                      </span>
                      {isBelowMin && (
                        <Badge variant="destructive" className="text-[10px]">
                          Stock bajo
                        </Badge>
                      )}
                    </div>
                  </TableCell>
                  <TableCell className="text-right text-muted-foreground">
                    {item.minStock > 0 ? item.minStock : "—"}
                  </TableCell>
                  {isWriter && (
                    <TableCell className="text-right">
                      <div className="flex items-center justify-end gap-1.5">
                        <Button
                          variant="ghost"
                          size="sm"
                          className="h-7 px-2 text-xs"
                          onClick={() => setActiveModal({ type: "adjust", item })}
                          aria-label={`Ajustar stock de ${item.productName}`}
                        >
                          <SlidersHorizontal className="h-3.5 w-3.5 mr-1" />
                          Ajustar
                        </Button>
                        <Button
                          variant="ghost"
                          size="sm"
                          className="h-7 px-2 text-xs"
                          onClick={() => setActiveModal({ type: "transfer", item })}
                          aria-label={`Transferir stock de ${item.productName}`}
                        >
                          <ArrowLeftRight className="h-3.5 w-3.5 mr-1" />
                          Transferir
                        </Button>
                      </div>
                    </TableCell>
                  )}
                </TableRow>
              )
            })}
          </TableBody>
        </Table>
      </div>

      {activeModal?.type === "adjust" && (
        <AdjustStockModal
          productId={activeModal.item.productId}
          branchId={activeModal.item.branchId}
          currentQuantity={activeModal.item.quantity}
          productName={activeModal.item.productName}
          onClose={() => setActiveModal(null)}
        />
      )}

      {activeModal?.type === "transfer" && (
        <TransferStockModal
          productId={activeModal.item.productId}
          currentBranchId={activeModal.item.branchId}
          currentQuantity={activeModal.item.quantity}
          productName={activeModal.item.productName}
          onClose={() => setActiveModal(null)}
        />
      )}
    </>
  )
}
