"use client"

/**
 * TransferStockAction — sucursal-guard-vaciado-auditoria (G3, tasks 7.1-7.3,
 * design.md D7).
 *
 * La transferencia de stock entre sucursales ya existía y funcionaba (518
 * unidades transferidas a mano el 24-08 lo probaron), pero sólo se llegaba a
 * ella recorriendo Sucursales → una sucursal → Stock → la fila del producto.
 * El PO, que conoce el sistema, creyó que la función no existía; la usuaria
 * del incidente muy probablemente por lo mismo. Este componente la ofrece
 * directo desde el módulo de Stock principal, por fila del listado.
 *
 * Muestra el desglose por sucursal (useProductBranchBreakdown, ledger
 * canónico) para elegir el ORIGEN, y abre TransferStockModal REUTILIZADO TAL
 * CUAL — cero diálogo nuevo, cero lógica de validación duplicada.
 */

import { useState } from "react"
import { Button } from "@/components/ui/button"
import {
  Dialog, DialogContent, DialogHeader, DialogTitle,
} from "@/components/ui/dialog"
import { ArrowRightLeft, Loader2 } from "lucide-react"
import { useProductBranchBreakdown } from "@/hooks/data/use-branch-stock"
import { TransferStockModal } from "@/components/branches/TransferStockModal"

interface TransferStockActionProps {
  productId:   string
  productName: string
  /**
   * Abre el diálogo ya montado — usado desde /stock cuando llega
   * ?product=<id> del camino directo del aviso de error de venta (task 7.5),
   * sin necesidad de que el usuario encuentre y clickee el botón de la fila.
   */
  defaultOpen?: boolean
  /** Trigger opcional propio — si se omite, se renderiza el botón por defecto. */
  hideTrigger?: boolean
}

export function TransferStockAction({
  productId, productName, defaultOpen = false, hideTrigger = false,
}: TransferStockActionProps) {
  const [open, setOpen] = useState(defaultOpen)
  const [origin, setOrigin] = useState<{ branchId: string; quantity: number } | null>(null)
  const { breakdown, isLoading } = useProductBranchBreakdown(open ? productId : null)

  const withStock = breakdown.filter((row) => row.quantity > 0)

  if (origin) {
    return (
      <TransferStockModal
        productId={productId}
        productName={productName}
        currentBranchId={origin.branchId}
        currentQuantity={origin.quantity}
        onClose={() => { setOrigin(null); setOpen(false) }}
      />
    )
  }

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      {!hideTrigger && (
        <Button
          type="button"
          variant="ghost"
          size="sm"
          className="h-7 px-2 text-xs opacity-0 group-hover:opacity-100 transition-opacity"
          onClick={(e) => { e.stopPropagation(); setOpen(true) }}
          aria-label={`Transferir stock de ${productName}`}
          title="Transferir stock entre sucursales"
        >
          <ArrowRightLeft className="h-3.5 w-3.5" />
        </Button>
      )}
      <DialogContent className="sm:max-w-md" onClick={(e) => e.stopPropagation()}>
        <DialogHeader>
          <DialogTitle>Transferir stock — {productName}</DialogTitle>
        </DialogHeader>

        {isLoading ? (
          <div className="flex items-center justify-center py-8">
            <Loader2 className="h-5 w-5 animate-spin text-muted-foreground" />
          </div>
        ) : withStock.length === 0 ? (
          <p className="text-sm text-muted-foreground py-4 text-center">
            Este producto no tiene existencias en ninguna sucursal.
          </p>
        ) : (
          <div className="space-y-2">
            <p className="text-xs text-muted-foreground">Elegí la sucursal de origen:</p>
            {withStock.map((row) => (
              <button
                key={row.branchId}
                type="button"
                className="w-full flex items-center justify-between rounded-md border border-border px-3 py-2 text-sm hover:bg-accent transition-colors"
                onClick={() => setOrigin({ branchId: row.branchId, quantity: row.quantity })}
              >
                <span>{row.branchName}</span>
                <span className="tabular-nums text-muted-foreground">{row.quantity} unidades</span>
              </button>
            ))}
          </div>
        )}
      </DialogContent>
    </Dialog>
  )
}
