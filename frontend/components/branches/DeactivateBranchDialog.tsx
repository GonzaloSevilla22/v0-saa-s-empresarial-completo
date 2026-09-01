"use client"

/**
 * DeactivateBranchDialog — sucursal-guard-vaciado-auditoria (G1/G3, task 6.4,
 * design.md D7).
 *
 * Reemplaza el `confirm()` nativo de BranchList.tsx ("¿Desactivar la sucursal
 * X? Los registros históricos se conservan.") — la frase que en el incidente
 * real del 22-08 fue lo único que la usuaria leyó antes de dejar su negocio
 * invendible dos días. Ahora, ANTES de preguntar, muestra qué hay adentro
 * (reutilizando use-branch-stock.ts, sin consulta nueva — regla del proyecto)
 * y si hay contenido NO ofrece confirmar: ofrece ir a transferir. Mismo
 * patrón de "gate visual" que DeleteOperationDialog.tsx
 * (delete-guard-ledgers).
 *
 * El guard real vive en la base de datos (disparador
 * trg_guard_branch_decommission, P0428) — este diálogo es UX, no seguridad:
 * informa antes de que el backend rechace, no reemplaza el rechazo.
 */

import Link from "next/link"
import { Button } from "@/components/ui/button"
import {
  AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent,
  AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle,
  AlertDialogTrigger,
} from "@/components/ui/alert-dialog"
import { Trash2, ArrowRightLeft } from "lucide-react"
import { useBranchStock } from "@/hooks/data/use-branch-stock"

interface DeactivateBranchDialogProps {
  branchId: string
  branchName: string
  onConfirm: () => void
  isDeactivating: boolean
}

export function DeactivateBranchDialog({
  branchId, branchName, onConfirm, isDeactivating,
}: DeactivateBranchDialogProps) {
  const { branchStock, isLoading } = useBranchStock(branchId)

  const withContent = branchStock.filter((row) => row.quantity !== 0)
  const totalUnits = withContent.reduce((sum, row) => sum + row.quantity, 0)
  const hasContent = withContent.length > 0

  return (
    <AlertDialog>
      <AlertDialogTrigger asChild>
        <Button
          variant="ghost"
          size="icon"
          className="h-11 w-11 md:h-7 md:w-7 text-muted-foreground hover:text-destructive"
          disabled={isDeactivating || isLoading}
          aria-label={`Desactivar ${branchName}`}
        >
          <Trash2 className="h-3.5 w-3.5" />
        </Button>
      </AlertDialogTrigger>
      <AlertDialogContent className="bg-card border-border">
        <AlertDialogHeader>
          <AlertDialogTitle className="text-card-foreground">
            {hasContent ? `"${branchName}" tiene mercadería adentro` : `¿Desactivar "${branchName}"?`}
          </AlertDialogTitle>
          <AlertDialogDescription asChild>
            <div className="space-y-2 text-sm text-muted-foreground">
              {hasContent ? (
                <>
                  <p>
                    Esta sucursal tiene <strong className="text-foreground">{totalUnits}</strong> unidades
                    en <strong className="text-foreground">{withContent.length}</strong> producto
                    {withContent.length !== 1 ? "s" : ""}. No se puede desactivar mientras tenga
                    existencias — el sistema la va a rechazar.
                  </p>
                  <p>Transferí el stock a otra sucursal y volvé a intentarlo.</p>
                </>
              ) : (
                <p>La sucursal está vacía de existencias. Los registros históricos se conservan.</p>
              )}
            </div>
          </AlertDialogDescription>
        </AlertDialogHeader>
        <AlertDialogFooter>
          <AlertDialogCancel className="border-border text-foreground">
            Cancelar
          </AlertDialogCancel>
          {hasContent ? (
            <AlertDialogAction asChild>
              <Link href={`/sucursales/${branchId}/stock`}>
                <ArrowRightLeft className="h-3.5 w-3.5 mr-1.5" />
                Ir a transferir stock
              </Link>
            </AlertDialogAction>
          ) : (
            <AlertDialogAction
              onClick={onConfirm}
              disabled={isDeactivating}
              className="bg-destructive text-destructive-foreground hover:bg-destructive/90"
            >
              {isDeactivating ? "Desactivando…" : "Desactivar"}
            </AlertDialogAction>
          )}
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  )
}
