"use client"

/**
 * estadisticas-ventas E3 (grupo 10): hooks del análisis con IA del módulo de
 * estadísticas — Edge Function `ai-estadisticas` (molde de ai-rentabilidad,
 * DEC-15: la IA vive en Edge Functions, no en Python).
 *
 * - `analyzeStatistics`: la llamada en sí (fetch), separada del hook para
 *   testearla sin React. Manda el período y la sucursal de la pantalla; la
 *   Edge Function lee los read-models canónicos del módulo con el JWT del
 *   usuario y NUNCA re-agrega ventas.
 * - `useAnalyzeStatistics`: mutación; al éxito invalida el último insight y
 *   el contador de uso (`aiUsage`). En fallback / cuota agotada no invalida
 *   nada: no se generó insight ni se consumió cuota (spec sales-statistics,
 *   "Análisis IA del módulo").
 * - `useLastStatisticsInsight`: el último insight persistido con el tipo
 *   propio del módulo (STATISTICS_INSIGHT_TYPE), como /rentabilidad hace con
 *   `margen`.
 */

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { createClient } from "@/lib/supabase/client"
import { useAuth } from "@/contexts/auth-context"
import { queryKeys } from "@/lib/query-keys"
import { STATISTICS_INSIGHT_TYPE } from "@/lib/sales-statistics"

export interface StatisticsInsight {
  id: string
  message: string
  createdAt: string
}

export interface AnalyzeStatisticsInput {
  /** "YYYY-MM-DD" (fecha de negocio). */
  start: string
  end: string
  branchId: string | null
}

export type AnalyzeStatisticsResult =
  | { status: "ok"; insight: string; recommendations: string[] }
  | { status: "fallback"; message: string }
  | { status: "quota_exceeded" }
  | { status: "error"; message: string }

const FALLBACK_MESSAGE = "El análisis no estuvo disponible. Intentá de nuevo."

/** POST a ai-estadisticas. Traduce la respuesta a un resultado cerrado para
 *  que la superficie no interprete JSON crudo. */
export async function analyzeStatistics(
  input: AnalyzeStatisticsInput,
  accessToken: string,
): Promise<AnalyzeStatisticsResult> {
  const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL
  if (!supabaseUrl) return { status: "error", message: "missing_supabase_url" }

  const res = await fetch(`${supabaseUrl}/functions/v1/ai-estadisticas`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${accessToken}`,
    },
    body: JSON.stringify({ start: input.start, end: input.end, branch_id: input.branchId }),
  })

  const parsed: unknown = await res.json().catch(() => ({}))
  const body = (parsed && typeof parsed === "object" ? parsed : {}) as Record<string, unknown>

  if (res.status === 429) return { status: "quota_exceeded" }
  if (!res.ok) {
    return { status: "error", message: typeof body.error === "string" ? body.error : `Error ${res.status}` }
  }
  if (body.fallback === true) {
    return { status: "fallback", message: typeof body.message === "string" ? body.message : FALLBACK_MESSAGE }
  }
  const data = (body.data && typeof body.data === "object" ? body.data : {}) as Record<string, unknown>
  const insight = typeof data.insight === "string" ? data.insight : ""
  const recommendations = Array.isArray(data.recommendations)
    ? data.recommendations.filter((r): r is string => typeof r === "string")
    : []
  return { status: "ok", insight, recommendations }
}

export function useLastStatisticsInsight() {
  const { user } = useAuth()
  const supabase = createClient()

  return useQuery<StatisticsInsight | null>({
    queryKey: queryKeys.salesStatistics.aiInsight(user?.id ?? null),
    queryFn: async (): Promise<StatisticsInsight | null> => {
      const { data, error } = await supabase
        .from("insights")
        .select("id, message, created_at")
        .eq("type", STATISTICS_INSIGHT_TYPE)
        .order("created_at", { ascending: false })
        .limit(1)
        .maybeSingle()
      if (error) throw error
      const row = data as { id: string; message: string; created_at: string } | null
      return row ? { id: row.id, message: row.message, createdAt: row.created_at } : null
    },
    staleTime: 30_000,
    enabled: !!user,
  })
}

export function useAnalyzeStatistics() {
  const { user } = useAuth()
  const supabase = createClient()
  const queryClient = useQueryClient()

  return useMutation<AnalyzeStatisticsResult, Error, AnalyzeStatisticsInput>({
    mutationFn: async (input) => {
      const { data: session } = await supabase.auth.getSession()
      const token = session?.session?.access_token
      if (!token) return { status: "error", message: "Sin sesión activa" }
      return analyzeStatistics(input, token)
    },
    onSuccess: async (result) => {
      // Sólo un insight generado cambia lo persistido y el contador de uso.
      if (result.status !== "ok") return
      await Promise.all([
        queryClient.invalidateQueries({ queryKey: queryKeys.salesStatistics.aiInsight(user?.id ?? null) }),
        queryClient.invalidateQueries({ queryKey: ["aiUsage", user?.id] }),
      ])
    },
  })
}
