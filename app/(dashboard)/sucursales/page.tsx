"use client"

import { usePlanLimits } from "@/hooks/auth/use-plan-limits"
import { useBranches } from "@/hooks/data/use-branches"
import { BranchList } from "@/components/branches/BranchList"
import { BranchForm } from "@/components/branches/BranchForm"
import { Crown, MapPin } from "lucide-react"
import { Button } from "@/components/ui/button"
import Link from "next/link"

function PlanGateFallback() {
  return (
    <div className="flex flex-col items-center justify-center gap-6 py-24 text-center">
      <div className="flex h-16 w-16 items-center justify-center rounded-full bg-yellow-500/10">
        <Crown className="h-8 w-8 text-yellow-500" />
      </div>
      <div>
        <h2 className="text-xl font-bold text-foreground">Módulo de Sucursales</h2>
        <p className="mt-2 text-sm text-muted-foreground max-w-sm">
          Gestioná múltiples puntos de venta. Disponible exclusivamente en el plan{" "}
          <span className="font-semibold text-foreground">PRO</span>.
        </p>
      </div>
      <Button asChild className="bg-yellow-500 hover:bg-yellow-400 text-black font-semibold">
        <Link href="/configuracion">
          <Crown className="mr-2 h-4 w-4" />
          Ver planes PRO
        </Link>
      </Button>
    </div>
  )
}

export default function SucursalesPage() {
  const { limits, isLoading } = usePlanLimits()

  if (isLoading) return null

  if (!limits?.hasBranchesModule) {
    return <PlanGateFallback />
  }

  const atLimit = (limits.maxBranches ?? 0) === 0

  return (
    <div className="max-w-2xl mx-auto space-y-6 p-6">
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-3">
          <div className="flex h-10 w-10 items-center justify-center rounded-lg bg-primary/10">
            <MapPin className="h-5 w-5 text-primary" />
          </div>
          <div>
            <h1 className="text-xl font-bold">Sucursales</h1>
            <p className="text-sm text-muted-foreground">Puntos de venta de tu negocio</p>
          </div>
        </div>
        <BranchForm disabled={atLimit} />
      </div>

      <BranchList limits={limits} />
    </div>
  )
}
