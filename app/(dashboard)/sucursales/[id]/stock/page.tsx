"use client"

import { use } from "react"
import Link from "next/link"
import { usePlanLimits } from "@/hooks/auth/use-plan-limits"
import { useBranches } from "@/hooks/data/use-branches"
import { BranchStockTable } from "@/components/branches/BranchStockTable"
import { useOrgRole } from "@/hooks/useOrgRole"
import { Button } from "@/components/ui/button"
import { Crown, Package, ArrowLeft, ArrowLeftRight } from "lucide-react"
import { useState } from "react"
import { TransferStockModal } from "@/components/branches/TransferStockModal"

function PlanGateFallback() {
  return (
    <div className="flex flex-col items-center justify-center gap-6 py-24 text-center">
      <div className="flex h-16 w-16 items-center justify-center rounded-full bg-yellow-500/10">
        <Crown className="h-8 w-8 text-yellow-500" />
      </div>
      <div>
        <h2 className="text-xl font-bold text-foreground">Inventario por Sucursal</h2>
        <p className="mt-2 text-sm text-muted-foreground max-w-sm">
          Gestioná el stock de cada punto de venta. Disponible exclusivamente en el plan{" "}
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

interface PageProps {
  params: Promise<{ id: string }>
}

export default function BranchStockPage({ params }: PageProps) {
  const { id: branchId } = use(params)
  const { limits, isLoading: limitsLoading } = usePlanLimits()
  const { branches, isLoading: branchesLoading } = useBranches()
  const { isWriter } = useOrgRole()

  const branch = branches.find((b) => b.id === branchId)
  const branchName = branch?.name ?? "Sucursal"

  if (limitsLoading || branchesLoading) return null

  if (!limits?.hasBranchesModule) {
    return <PlanGateFallback />
  }

  return (
    <div className="max-w-4xl mx-auto space-y-6 p-6">
      {/* Header */}
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-3">
          <Button variant="ghost" size="icon" asChild className="h-8 w-8">
            <Link href="/sucursales" aria-label="Volver a sucursales">
              <ArrowLeft className="h-4 w-4" />
            </Link>
          </Button>
          <div className="flex h-10 w-10 items-center justify-center rounded-lg bg-primary/10">
            <Package className="h-5 w-5 text-primary" />
          </div>
          <div>
            <h1 className="text-xl font-bold">Inventario — {branchName}</h1>
            <p className="text-sm text-muted-foreground">
              Stock de productos en esta sucursal
            </p>
          </div>
        </div>
      </div>

      {/* Stock table */}
      <BranchStockTable branchId={branchId} />
    </div>
  )
}
