"use client"

import Link from "next/link"
import { useBranches, useCloseBranch, useDeactivateBranch, useOpenBranch } from "@/hooks/data/use-branches"
import { useOrgRole } from "@/hooks/useOrgRole"
import { Button } from "@/components/ui/button"
import { Card, CardContent } from "@/components/ui/card"
import { Badge } from "@/components/ui/badge"
import { MapPin, Trash2, Loader2, Package, DoorOpen, DoorClosed } from "lucide-react"
import { toast } from "sonner"
import type { PlanLimits } from "@/lib/types"

interface BranchListProps {
  limits: PlanLimits
}

export function BranchList({ limits }: BranchListProps) {
  const { branches, isLoading } = useBranches()
  const { role } = useOrgRole()
  const { mutateAsync: deactivate, isPending } = useDeactivateBranch()
  const { mutateAsync: openBranch,  isPending: isOpening } = useOpenBranch()
  const { mutateAsync: closeBranch, isPending: isClosing } = useCloseBranch()

  const canWrite = role === "owner" || role === "admin"
  const used = branches.length
  const max  = limits.maxBranches
  const lifecyclePending = isOpening || isClosing

  async function handleDeactivate(id: string, name: string) {
    if (!confirm(`¿Desactivar la sucursal "${name}"? Los registros históricos se conservan.`)) return
    try {
      await deactivate(id)
      toast.success(`Sucursal "${name}" desactivada`)
    } catch (err: unknown) {
      toast.error(err instanceof Error ? err.message : "Error al desactivar")
    }
  }

  async function handleLifecycle(id: string, name: string, status: "active" | "closed") {
    if (status === "active") {
      if (!confirm(`¿Cerrar la sucursal "${name}"? No se podrá operar en ella hasta reabrirla. Si tiene stock, transferilo primero.`)) return
      try {
        await closeBranch(id)
        toast.success(`Sucursal "${name}" cerrada`)
      } catch (err: unknown) {
        toast.error(err instanceof Error ? err.message : "Error al cerrar la sucursal")
      }
    } else {
      try {
        await openBranch(id)
        toast.success(`Sucursal "${name}" reabierta`)
      } catch (err: unknown) {
        toast.error(err instanceof Error ? err.message : "Error al abrir la sucursal")
      }
    }
  }

  if (isLoading) {
    return (
      <div className="flex items-center justify-center py-12 text-muted-foreground">
        <Loader2 className="h-5 w-5 animate-spin mr-2" />
        Cargando sucursales…
      </div>
    )
  }

  if (branches.length === 0) {
    return (
      <div className="flex flex-col items-center justify-center gap-3 py-16 text-center text-muted-foreground">
        <MapPin className="h-10 w-10 opacity-30" />
        <p className="text-sm">Todavía no tenés sucursales.</p>
      </div>
    )
  }

  return (
    <div className="space-y-3">
      <p className="text-xs text-muted-foreground">
        {used} de {max} sucursal{max !== 1 ? "es" : ""} utilizadas
      </p>
      {branches.map((branch) => (
        <Card key={branch.id} className="border border-border">
          <CardContent className="flex items-start justify-between gap-3 p-4">
            <div className="flex items-start gap-3">
              <MapPin className="h-4 w-4 mt-0.5 text-muted-foreground shrink-0" />
              <div>
                <p className="text-sm font-medium">{branch.name}</p>
                {branch.address && (
                  <p className="text-xs text-muted-foreground mt-0.5">{branch.address}</p>
                )}
              </div>
            </div>
            <div className="flex items-center gap-2 shrink-0">
              {branch.status === "closed" ? (
                <Badge variant="outline" className="text-[10px] border-amber-500/50 text-amber-600">Cerrada</Badge>
              ) : (
                <Badge variant="outline" className="text-[10px]">Activa</Badge>
              )}
              <Button
                variant="ghost"
                size="sm"
                className="h-7 px-2 text-xs text-muted-foreground hover:text-foreground"
                asChild
              >
                <Link href={`/sucursales/${branch.id}/stock`} aria-label={`Ver stock de ${branch.name}`}>
                  <Package className="h-3.5 w-3.5 mr-1" />
                  Ver stock
                </Link>
              </Button>
              {canWrite && (
                <Button
                  variant="ghost"
                  size="sm"
                  className="h-7 px-2 text-xs text-muted-foreground hover:text-foreground"
                  disabled={lifecyclePending}
                  onClick={() => handleLifecycle(branch.id, branch.name, branch.status)}
                  aria-label={branch.status === "active" ? `Cerrar ${branch.name}` : `Reabrir ${branch.name}`}
                >
                  {branch.status === "active" ? (
                    <><DoorClosed className="h-3.5 w-3.5 mr-1" />Cerrar</>
                  ) : (
                    <><DoorOpen className="h-3.5 w-3.5 mr-1" />Reabrir</>
                  )}
                </Button>
              )}
              {canWrite && (
                <Button
                  variant="ghost"
                  size="icon"
                  className="h-7 w-7 text-muted-foreground hover:text-destructive"
                  disabled={isPending}
                  onClick={() => handleDeactivate(branch.id, branch.name)}
                  aria-label="Desactivar sucursal"
                >
                  <Trash2 className="h-3.5 w-3.5" />
                </Button>
              )}
            </div>
          </CardContent>
        </Card>
      ))}
    </div>
  )
}
