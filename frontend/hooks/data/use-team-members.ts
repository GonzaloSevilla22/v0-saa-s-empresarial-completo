"use client"

/**
 * useTeamMembers — miembros de una cuenta con su rol y perfil (name/email).
 *
 * Extraído de TeamSection.tsx (C-05 Bloque G) a la capa canónica cuando
 * sucursal-guard-vaciado-auditoria (G2) necesitó el MISMO dato para resolver
 * "creada por X" / "desactivada por X" en BranchList.tsx — regla del
 * proyecto: reutilización antes que repetición, lo reusable nace en
 * hooks/data/. TeamSection.tsx pasa a importarlo de acá; su lógica no
 * cambia una línea.
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
    email: string | null
  } | null
}

export function useTeamMembers(accountId: string | null | undefined) {
  const supabase = createClient()
  return useQuery({
    queryKey: ["teamMembers", accountId] as const,
    queryFn: async (): Promise<TeamMemberRow[]> => {
      if (!accountId) return []
      const { data, error } = await supabase
        .from("account_members")
        .select("id, user_id, role, created_at, profiles(name, email)")
        .eq("account_id", accountId)
        .order("created_at", { ascending: true })

      if (error) throw error
      // Supabase infers the profiles join as an array type; cast via unknown
      // to obtain the single-row object shape (1:1 join on user_id).
      return (data ?? []) as unknown as TeamMemberRow[]
    },
    enabled: !!accountId,
    staleTime: 60_000, // 1 minute
  })
}

/**
 * Resuelve el nombre visible de un miembro a partir de su user_id, con
 * fallback a email y luego a "no registrado" — usado por BranchList.tsx
 * (G2, OQ-4: autoría visible para todos los miembros de la cuenta).
 */
export function resolveMemberName(
  members: TeamMemberRow[],
  userId: string | null | undefined,
): string {
  if (!userId) return "no registrado"
  const member = members.find((m) => m.user_id === userId)
  return member?.profiles?.name ?? member?.profiles?.email ?? "no registrado"
}
