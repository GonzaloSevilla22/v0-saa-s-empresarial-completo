"use client"

/**
 * useTeamMembers — miembros de una cuenta con su rol y su nombre de perfil.
 *
 * El email NO sale de acá: `public.profiles` no tiene esa columna (vive en
 * auth.users) y pedirla hacía que PostgREST respondiera 400 en cada carga, con
 * lo que TODOS los perfiles caían a null en silencio (tablero-menu-pulido P4).
 *
 * Y el nombre que devuelve es, para un miembro común, sólo el PROPIO: la RLS de
 * `profiles` deja leer la fila de `auth.uid()` (y todas, sólo al admin de
 * PLATAFORMA), así que el perfil de un compañero vuelve null. Nombre y email de
 * todos los miembros los da el directorio de `useMembers` (GET /members ->
 * rpc_list_account_members, SECURITY DEFINER), con `resolveMemberName`.
 *
 * Extraído de TeamSection.tsx (C-05 Bloque G) a la capa canónica cuando
 * sucursal-guard-vaciado-auditoria (G2) necesitó el MISMO dato para resolver
 * "creada por X" / "desactivada por X" en BranchList.tsx; desde
 * tablero-menu-pulido BranchList resuelve la autoría con el directorio de
 * /members y este hook queda para la lista del Equipo (TeamSection.tsx).
 */

import { useQuery } from "@tanstack/react-query"
import { createClient } from "@/lib/supabase/client"

export interface TeamMemberRow {
  id: string
  user_id: string
  role: "owner" | "admin" | "member"
  created_at: string
  profiles: {
    name: string | null
  } | null
}

export function useTeamMembers(accountId: string | null | undefined) {
  const supabase = createClient()
  return useQuery({
    queryKey: ["teamMembers", accountId] as const,
    queryFn: async (): Promise<TeamMemberRow[]> => {
      if (!accountId) return []
      // qa-integral-modulos (G8/D6): SIN el embed profiles(name, email) — no
      // existe FK account_members→profiles y PostgREST responde 400 PGRST200,
      // así que la lectura entera fallaba (Equipo "0 / 10 usuarios"). Patrón
      // que ya funciona en /organizacion/invitar: account_members plano; los
      // perfiles van en una segunda query + join en cliente (NO se crea la FK).
      const { data, error } = await supabase
        .from("account_members")
        .select("id, user_id, role, created_at")
        .eq("account_id", accountId)
        .order("created_at", { ascending: true })

      if (error) throw error
      const members = (data ?? []) as Omit<TeamMemberRow, "profiles">[]
      if (members.length === 0) return []

      // Segunda query: perfiles visibles según RLS (hoy: el propio + admins).
      // Si falla, degradamos a miembros sin perfil — la lista no se rompe.
      const userIds = [...new Set(members.map((m) => m.user_id))]
      const { data: profileRows, error: profilesError } = await supabase
        .from("profiles")
        .select("id, name")
        .in("id", userIds)

      const profilesById = new Map<string, TeamMemberRow["profiles"]>()
      if (!profilesError) {
        for (const p of (profileRows ?? []) as { id: string; name: string | null }[]) {
          profilesById.set(p.id, { name: p.name })
        }
      }

      return members.map((m) => ({
        ...m,
        profiles: profilesById.get(m.user_id) ?? null,
      }))
    },
    enabled: !!accountId,
    staleTime: 60_000, // 1 minute
  })
}
