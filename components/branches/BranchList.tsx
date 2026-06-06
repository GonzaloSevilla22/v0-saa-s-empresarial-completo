"use client"

import { useBranches, useDeactivateBranch } from "@/hooks/data/use-branches"
import { useOrgRole } from "@/hooks/useOrgRole"
import { Button } from "@/components/ui/button"
import { Card, CardContent } from "@/components/ui/card"
import { Badge } from "@/components/ui/badge"
import { MapPin, Trash2, Loader2 } from "lucide-react"
import { toast } from "sonner"
import type { PlanLimits } from "@/lib/types"

interface BranchListProps {
  limits: PlanLimits
}

export function BranchList({ limits }: BranchListProps) {
  const { branches, isLoading } = useBranches()
  const { role } = useOrgRole()
  const { mutateAsync: deactivate, isPending } = useDeactivateBranch()

  const canWrite = role === "owner" || role === "admin"
  const used = branches.length
  const max  = limits.maxBranches

  async function handleDeactivate(id: string, name: string) {
    if (!confirm(`¿Desactivar la sucursal "${name}"? Los registros históricos se conservan.`)) return
    try {
      await deactivate(id)
      toast.success(`Sucursal "${name}" desactivada`)
    } catch (err: unknown) {
      toast.error(err instanceof Error ? err.message : "Error al desactivar")
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
              <Badge variant="outline" className="text-[10px]">Activa</Badge>
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
