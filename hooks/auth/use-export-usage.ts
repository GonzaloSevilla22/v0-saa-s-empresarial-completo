"use client"

import { useQuery } from "@tanstack/react-query"
import { createClient } from "@/lib/supabase/client"
import { useAuth } from "@/contexts/auth-context"
import { usePlanLimits } from "./use-plan-limits"
import type { ExportType } from "@/lib/types"

type ExportDenyReason = "plan_gratis" | "quota_exceeded" | null

export interface ExportUsage {
  exportsUsed: number
  exportsRemaining: number
  exportsLimit: number
  isLoading: boolean
  canExport: () => { allowed: boolean; reason: ExportDenyReason }
}

export interface ExportResult {
  ok: boolean
  signedUrl?: string
  expiresAt?: string
  exportsUsed?: number
  error?: string
}

export function useExportUsage(): ExportUsage {
  const { user } = useAuth()
  const { limits } = usePlanLimits()
  const supabase = createClient()

  const query = useQuery({
    queryKey: ["exportUsage", user?.id] as const,
    queryFn: async () => {
      const { data, error } = await supabase
        .from("profiles")
        .select("exports_used")
        .eq("id", user!.id)
        .single()

      if (error || !data) return { exports_used: 0 }
      return data
    },
    staleTime: 30_000, // 30s — counters change on each export
    enabled:   !!user,
  })

  const exportsUsed  = query.data?.exports_used ?? 0
  const exportsLimit = limits?.maxExportsPerMonth ?? 0

  function canExport(): { allowed: boolean; reason: ExportDenyReason } {
    if (exportsLimit === 0) return { allowed: false, reason: "plan_gratis" }
    if (exportsUsed >= exportsLimit) return { allowed: false, reason: "quota_exceeded" }
    return { allowed: true, reason: null }
  }

  return {
    exportsUsed,
    exportsRemaining: Math.max(0, exportsLimit - exportsUsed),
    exportsLimit,
    isLoading: query.isLoading,
    canExport,
  }
}

/** Calls the generate-export Edge Function and triggers a browser download. */
export async function triggerExport(
  exportType: ExportType,
  accessToken: string,
): Promise<ExportResult> {
  const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL
  if (!supabaseUrl) return { ok: false, error: "missing_supabase_url" }

  const res = await fetch(`${supabaseUrl}/functions/v1/generate-export`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${accessToken}`,
    },
    body: JSON.stringify({ export_type: exportType }),
  })

  const json = await res.json()
  return json as ExportResult
}
