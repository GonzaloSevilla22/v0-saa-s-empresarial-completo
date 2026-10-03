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
 *
 * remitos-venta (D10/D11, task 5.10): un remito pendiente retiene stock de la
 * sucursal (de venta o de compra) y es el cuarto contenido que bloquea la baja.
 * El diálogo lo consulta (`GET /delivery-notes?status=issued&branch_id=…`, sin
 * filtro de sentido) y, si hay, en lugar de "Desactivar" ofrece "Ver remitos
 * pendientes" con el contrato de query params de `/remitos`. Mientras no sabe si
 * hay, el disparador queda deshabilitado; si la consulta falla, no bloquea (la
 * base igual rechaza con el motivo traducido en `use-branches.ts`).
 */

import Link from "next/link"
import { Button } from "@/components/ui/button"
import {
  AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent,
  AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle,
  AlertDialogTrigger,
} from "@/components/ui/alert-dialog"
import { Trash2, ArrowRightLeft, PackageCheck } from "lucide-react"
import { useBranchStock } from "@/hooks/data/use-branch-stock"
import { useDeliveryNotes } from "@/hooks/data/use-delivery-notes"

interface DeactivateBranchDialogProps {
  branchId: string
  branchName: string
  onConfirm: () => void
  isDeactivating: boolean
}

export function DeactivateBranchDialog({
  branchId, branchName, onConfirm, isDeactivating,
}: DeactivateBranchDialogProps) {
  const { branchStock, isLoading: stockLoading } = useBranchStock(branchId)
  // Sin `direction`: el remito de compra también retiene stock de la sucursal.
  // `pageSize: 1`: sólo importa cuántos hay, `total` viene en el sobre.
  const { data: pendingNotes, isLoading: notesLoading } = useDeliveryNotes({
    status: "issued",
    branchId,
    pageSize: 1,
  })
  const isLoading = stockLoading || notesLoading

  const withContent = branchStock.filter((row) => row.quantity !== 0)
  const totalUnits = withContent.reduce((sum, row) => sum + row.quantity, 0)
  const hasStock = withContent.length > 0
  const pendingCount = pendingNotes?.total ?? 0
  const hasPendingNotes = pendingCount > 0
  const hasContent = hasStock || hasPendingNotes

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
            {hasStock
              ? `"${branchName}" tiene mercadería adentro`
              : hasPendingNotes
                ? `"${branchName}" tiene remitos pendientes`
                : `¿Desactivar "${branchName}"?`}
          </AlertDialogTitle>
          <AlertDialogDescription asChild>
            <div className="space-y-2 text-sm text-muted-foreground">
              {hasStock && (
                <>
                  <p>
                    Esta sucursal tiene <strong className="text-foreground">{totalUnits}</strong> unidades
                    en <strong className="text-foreground">{withContent.length}</strong> producto
                    {withContent.length !== 1 ? "s" : ""}. No se puede desactivar mientras tenga
                    existencias — el sistema la va a rechazar.
                  </p>
                  <p>Transferí el stock a otra sucursal y volvé a intentarlo.</p>
                </>
              )}
              {hasPendingNotes && (
                <>
                  <p>
                    Tiene <strong className="text-foreground">{pendingCount}</strong>{" "}
                    {pendingCount === 1 ? "remito pendiente que retiene" : "remitos pendientes que retienen"}{" "}
                    mercadería de esta sucursal. No se puede desactivar mientras haya alguno.
                  </p>
                  <p>Convertilos en venta o anulalos y volvé a intentarlo.</p>
                </>
              )}
              {!hasContent && <p>La sucursal está vacía de existencias. Los registros históricos se conservan.</p>}
            </div>
          </AlertDialogDescription>
        </AlertDialogHeader>
        <AlertDialogFooter>
          <AlertDialogCancel className="border-border text-foreground">
            Cancelar
          </AlertDialogCancel>
          {hasStock && (
            <AlertDialogAction asChild>
              <Link href={`/sucursales/${branchId}/stock`}>
                <ArrowRightLeft className="h-3.5 w-3.5 mr-1.5" />
                Ir a transferir stock
              </Link>
            </AlertDialogAction>
          )}
          {hasPendingNotes && (
            <AlertDialogAction asChild>
              <Link href={`/remitos?estado=pendientes&sucursal=${encodeURIComponent(branchId)}`}>
                <PackageCheck className="h-3.5 w-3.5 mr-1.5" />
                Ver remitos pendientes
              </Link>
            </AlertDialogAction>
          )}
          {!hasContent && (
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
