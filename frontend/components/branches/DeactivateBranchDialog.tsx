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
 * El diálogo lo consulta y, si hay, en lugar de "Desactivar" ofrece ir a verlos con
 * el contrato de query params de `/remitos`. Mientras no sabe si hay, el
 * disparador queda deshabilitado; si la consulta falla, no bloquea (la base igual
 * rechaza con el motivo traducido en `use-branches.ts`).
 *
 * remitos-compra (D11, task 5.8): `/remitos` tiene pestañas por sentido, así que el
 * diálogo consulta el total de CADA sentido (`GET /delivery-notes?direction=…
 * &status=issued&branch_id=…`) y muestra un párrafo y un enlace por sentido con
 * pendientes (`&sentido=venta` / `&sentido=compra`). El texto de cada uno sale de
 * `DELIVERY_NOTE_TEXTS[direction].pendingBranchNotes`: el remito de venta RETIENE
 * mercadería de la sucursal; el de compra le APORTÓ stock.
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
import { DELIVERY_NOTE_TEXTS } from "@/lib/delivery-note-status"
import type { DeliveryNoteDirection } from "@/lib/delivery-note-types"

/** Los sentidos del remito, con el valor de `?sentido=` que abre su pestaña en /remitos. */
const NOTE_SENTIDOS: ReadonlyArray<{ direction: DeliveryNoteDirection; sentido: "venta" | "compra" }> = [
  { direction: "sale", sentido: "venta" },
  { direction: "purchase", sentido: "compra" },
]

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
  // Una consulta por sentido: los dos retienen o aportaron stock de la sucursal y
  // `/remitos` los separa en pestañas. `pageSize: 1`: sólo importa cuántos hay,
  // `total` viene en el sobre.
  const { data: pendingSale, isLoading: saleLoading } = useDeliveryNotes({
    direction: "sale",
    status: "issued",
    branchId,
    pageSize: 1,
  })
  const { data: pendingPurchase, isLoading: purchaseLoading } = useDeliveryNotes({
    direction: "purchase",
    status: "issued",
    branchId,
    pageSize: 1,
  })
  const isLoading = stockLoading || saleLoading || purchaseLoading

  const withContent = branchStock.filter((row) => row.quantity !== 0)
  const totalUnits = withContent.reduce((sum, row) => sum + row.quantity, 0)
  const hasStock = withContent.length > 0
  const pendingBySentido = NOTE_SENTIDOS.map((entry) => ({
    ...entry,
    count: (entry.direction === "sale" ? pendingSale?.total : pendingPurchase?.total) ?? 0,
  })).filter((entry) => entry.count > 0)
  const hasPendingNotes = pendingBySentido.length > 0
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
              {pendingBySentido.map(({ direction, count }) => {
                const text = DELIVERY_NOTE_TEXTS[direction].pendingBranchNotes(count)
                return (
                  <div key={direction} className="space-y-2">
                    <p>
                      Tiene <strong className="text-foreground">{count}</strong> {text.noun} {text.tail}
                    </p>
                    <p>{text.advice}</p>
                  </div>
                )
              })}
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
          {pendingBySentido.map(({ direction, sentido, count }) => (
            <AlertDialogAction asChild key={direction}>
              <Link href={`/remitos?estado=pendientes&sucursal=${encodeURIComponent(branchId)}&sentido=${sentido}`}>
                <PackageCheck className="h-3.5 w-3.5 mr-1.5" />
                {DELIVERY_NOTE_TEXTS[direction].pendingBranchNotes(count).linkLabel}
              </Link>
            </AlertDialogAction>
          ))}
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
