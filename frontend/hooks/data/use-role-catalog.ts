"use client"

/**
 * useRoleCatalog — catálogo GLOBAL y cerrado de roles de membresía
 * (account_role_catalog, v3-rbac-multirole Parte A/C).
 *
 * Lectura DIRECTA vía supabase-js: la tabla tiene RLS `SELECT` abierto a
 * cualquier `authenticated` (D1 — "el catálogo SHALL ser legible por
 * cualquier miembro autenticado"), así que no hace falta un endpoint FastAPI
 * dedicado. Reutilizada por /organizacion/roles y /organizacion/invitar —
 * regla del proyecto: las etiquetas y descripciones salen del catálogo, NUNCA
 * de un objeto hardcodeado en la pantalla (antes: `ROLE_LABELS` en
 * page.tsx).
 */

import { useQuery } from "@tanstack/react-query"
import { createClient } from "@/lib/supabase/client"
import type { OrgRole } from "@/lib/types"

export interface RoleCatalogEntry {
  code: OrgRole
  label: string
  description: string
  sort_order: number
  is_writer: boolean
}

export function useRoleCatalog() {
  const supabase = createClient()
  return useQuery({
    queryKey: ["roleCatalog"] as const,
    queryFn: async (): Promise<RoleCatalogEntry[]> => {
      const { data, error } = await supabase
        .from("account_role_catalog")
        .select("code, label, description, sort_order, is_writer")
        .order("sort_order", { ascending: true })

      if (error) throw error
      return (data ?? []) as RoleCatalogEntry[]
    },
    // Catálogo cerrado y global (D1) — prácticamente estático, no hace
    // falta refrescarlo seguido.
    staleTime: 60 * 60 * 1000,
  })
}

/** Resuelve la etiqueta de un código de rol contra el catálogo ya cargado,
 * con fallback al código crudo si el catálogo todavía no resolvió. */
export function resolveRoleLabel(catalog: RoleCatalogEntry[] | undefined, code: string): string {
  return catalog?.find((entry) => entry.code === code)?.label ?? code
}
