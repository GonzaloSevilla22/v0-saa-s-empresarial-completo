"use client"

import { useMemo } from "react"
import { useQuery } from "@tanstack/react-query"
import { createClient } from "@/lib/supabase/client"
import { useAuth } from "@/contexts/auth-context"
import { queryKeys } from "@/lib/query-keys"
import { argentinaToday, utcDayRange } from "@/lib/date-range"
import {
  AiSummaryEmptyError,
  AiSummaryTimeoutError,
  parseAiSummaryResponse,
} from "@/lib/ai-summary"

/**
 * Tope de espera de TODA la operación. La función corta a OpenAI a los 25 s;
 * 30 s cubre además la resolución del token y la lectura de la respuesta.
 */
export const AI_SUMMARY_TIMEOUT_MS = 30_000

type SupabaseClient = ReturnType<typeof createClient>

/**
 * Invoca `ai-resumen` para el día de hoy con un tope de espera sobre toda la
 * operación: `Promise.race` contra un temporizador (un `AbortSignal` solo
 * cortaría la petición, no la espera del token) más el `signal` para liberar
 * la conexión. Nunca usa el `signal` de React Query: si lo consumiera, un
 * desmontaje cancelaría la llamada en vuelo y un remontaje perdería su
 * resultado.
 */
export async function fetchAiDailySummary(
  supabase: SupabaseClient,
  timeoutMs: number = AI_SUMMARY_TIMEOUT_MS,
): Promise<string> {
  const controller = new AbortController()
  let timer: ReturnType<typeof setTimeout> | undefined

  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => {
      controller.abort()
      reject(new AiSummaryTimeoutError())
    }, timeoutMs)
  })

  const call = (async (): Promise<string> => {
    // Rango UTC explícito: la Edge Function corre en UTC y no puede inferir el
    // «hoy» del usuario (las filas se guardan a medianoche UTC).
    const { from: dateFrom, to: dateTo } = utcDayRange()
    const { data, error } = await supabase.functions.invoke("ai-resumen", {
      body: { period: "daily", dateFrom, dateTo },
      signal: controller.signal,
    })
    if (error) throw error
    const text = parseAiSummaryResponse(data)
    if (!text) throw new AiSummaryEmptyError()
    return text
  })()
  // Si el tope gana la carrera, un rechazo posterior de `call` (por el abort)
  // no debe quedar como promesa sin manejar.
  call.catch(() => undefined)

  try {
    return await Promise.race([call, timeout])
  } finally {
    clearTimeout(timer)
  }
}

/**
 * tablero-explicable (D7): Resumen IA del día como consulta por cuenta y día
 * argentino. `staleTime: Infinity` y sin refetch automático: volver al Tablero
 * en la misma sesión NO vuelve a llamar a OpenAI (antes cada montaje gastaba
 * una consulta de la cuota mensual). «Regenerar» es `refetch()`. Como vive
 * fuera de la tarjeta, un remontaje con la llamada en vuelo recibe su resultado.
 */
export function useAiDailySummary() {
  const { user } = useAuth()
  const accountId = user?.accountId ?? null
  const supabase = useMemo(() => createClient(), [])

  return useQuery<string>({
    queryKey: queryKeys.aiSummary.daily(accountId, argentinaToday()),
    queryFn: () => fetchAiDailySummary(supabase),
    enabled: !!accountId,
    staleTime: Infinity,
    refetchOnWindowFocus: false,
    refetchOnMount: false,
    refetchOnReconnect: false,
    retry: false,
  })
}
