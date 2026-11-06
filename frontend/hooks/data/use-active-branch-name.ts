"use client"

import { useBranches } from "@/hooks/data/use-branches"

/**
 * tablero-explicable (D4): nombre de la sucursal activa del Tablero
 * (`?branch=`), para el contexto de «de dónde sale». Reutiliza la lista que ya
 * trae `useBranches` (la misma que alimenta el `BranchFilter`): sin consulta
 * nueva. `null` = todas las sucursales. Si la lista todavía no cargó, devuelve
 * un rótulo genérico en vez de afirmar «Todas» con una sucursal elegida.
 */
export function useActiveBranchName(branchId: string | null): string | null {
  const { branches } = useBranches()
  if (!branchId) return null
  return branches.find((b) => b.id === branchId)?.name ?? "Sucursal seleccionada"
}
