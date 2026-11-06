"use client"

/**
 * ia-copilot-v2 (tanda B, D11/D13) — hooks del Copiloto v2 sobre la Edge Function `ai-copilot`.
 *
 * - `askCopilot`: la llamada en sí (fetch), separada del hook para testearla sin React. El Bearer lo
 *   arma `getAuthHeaders()` (nunca `supabase.auth.*`). Traduce cada forma CERRADA de respuesta de la
 *   función (D2) a un resultado tipado: la pantalla nunca interpreta JSON crudo ni muestra texto del
 *   proveedor.
 * - `useAskCopilot`: mutación; sólo `answer`/`clarification` invalidan el contador de uso y el
 *   historial (el resto no dejó fila válida ni cambió lo que la pantalla muestra).
 * - `useCopilotHistory`: los últimos 50 turnos propios (D9) con su valoración.
 * - `useSetAiFeedback`: `rpc_set_ai_feedback` (D13), optimista con rollback.
 */

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { createClient } from "@/lib/supabase/client"
import { useAuth } from "@/contexts/auth-context"
import { queryKeys } from "@/lib/query-keys"
import { getAuthHeaders } from "@/lib/api/auth-headers"

// ─── Tipos (contrato D2) ──────────────────────────────────────────────────────

export interface CopilotState {
  period: { start: string; end: string } | null
  product: { id: string; name: string } | null
  client: { id: string; name: string } | null
}

export const EMPTY_COPILOT_STATE: CopilotState = { period: null, product: null, client: null }

export interface CopilotConsulted {
  tool: string
  label: string
}

/** Mensaje del historial visible que viaja al servidor (memoria corta, D6). */
export interface CopilotHistoryMessage {
  role: "user" | "assistant"
  content: string
  /** Rótulos de lo que se consultó para ese mensaje; entran al prompt como «(consulté: …)». */
  consulted?: string[]
}

export interface CopilotAskInput {
  question: string
  history: CopilotHistoryMessage[]
  state: CopilotState
  threadId: string | null
}

export type CopilotAskResult =
  | { status: "answer" | "clarification"; answer: string; conversationId: string | null; consulted: CopilotConsulted[]; state: CopilotState }
  | { status: "fallback"; conversationId: string | null }
  | { status: "invalid"; message: string }
  | { status: "unauthorized" }
  | { status: "no_account" }
  | { status: "quota_exceeded"; resetAt: string | null; used: number | null; limit: number | null }
  | { status: "rate_limited"; retryAfterSeconds: number }
  | { status: "unavailable" }
  | { status: "offline" }
  | { status: "error"; message: string }

export type CopilotRating = "useful" | "not_useful"

export interface CopilotHistoryTurn {
  id: string
  question: string
  answer: string
  createdAt: string
  outcome: string | null
  rating: CopilotRating | null
}

/** Espera por defecto cuando la ráfaga llega sin dato de reintento. */
const DEFAULT_RETRY_SECONDS = 30
export const COPILOT_HISTORY_LIMIT = 50

// ─── Parseo defensivo ─────────────────────────────────────────────────────────

type UnknownRecord = Record<string, unknown>

const isRecord = (v: unknown): v is UnknownRecord => typeof v === "object" && v !== null && !Array.isArray(v)
const asString = (v: unknown): string | null => (typeof v === "string" && v.length > 0 ? v : null)
const asNumber = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? v : null)

function parseRef(raw: unknown): { id: string; name: string } | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id)
  const name = asString(raw.name)
  return id && name ? { id, name } : null
}

function parseState(raw: unknown): CopilotState {
  if (!isRecord(raw)) return EMPTY_COPILOT_STATE
  const p = raw.period
  const start = isRecord(p) ? asString(p.start) : null
  const end = isRecord(p) ? asString(p.end) : null
  return {
    period: start && end ? { start, end } : null,
    product: parseRef(raw.product),
    client: parseRef(raw.client),
  }
}

function parseConsulted(raw: unknown): CopilotConsulted[] {
  if (!Array.isArray(raw)) return []
  return raw.flatMap((item): CopilotConsulted[] => {
    if (!isRecord(item)) return []
    const tool = asString(item.tool)
    const label = asString(item.label)
    return tool && label ? [{ tool, label }] : []
  })
}

function retryAfter(body: UnknownRecord, header: string | null): number {
  const fromBody = asNumber(body.retryAfterSeconds)
  if (fromBody !== null && fromBody >= 1) return Math.ceil(fromBody)
  const fromHeader = header === null ? null : Number(header)
  if (fromHeader !== null && Number.isFinite(fromHeader) && fromHeader >= 1) return Math.ceil(fromHeader)
  return DEFAULT_RETRY_SECONDS
}

// ─── Llamada ──────────────────────────────────────────────────────────────────

/** POST a ai-copilot. Traduce la respuesta a un resultado cerrado (D2). */
export async function askCopilot(input: CopilotAskInput): Promise<CopilotAskResult> {
  const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL
  if (!supabaseUrl) return { status: "error", message: "missing_supabase_url" }

  const headers = await getAuthHeaders({ "Content-Type": "application/json" })
  // Sin encabezado de autorización no hay a quién atribuir la consulta: no se gasta la llamada.
  if (!headers.Authorization) return { status: "error", message: "Sin sesión activa" }

  let res: Response
  try {
    res = await fetch(`${supabaseUrl}/functions/v1/ai-copilot`, {
      method: "POST",
      headers,
      body: JSON.stringify({
        question: input.question,
        history: input.history,
        state: input.state,
        ...(input.threadId ? { thread_id: input.threadId } : {}),
      }),
    })
  } catch {
    return { status: "offline" }
  }

  const parsed: unknown = await res.json().catch(() => ({}))
  const body: UnknownRecord = isRecord(parsed) ? parsed : {}

  switch (res.status) {
    case 400:
      return { status: "invalid", message: asString(body.message) ?? "La consulta no es válida." }
    case 401:
      return { status: "unauthorized" }
    case 403:
      return { status: "no_account" }
    case 429:
      if (body.error === "rate_limited") {
        return { status: "rate_limited", retryAfterSeconds: retryAfter(body, res.headers.get("Retry-After")) }
      }
      return { status: "quota_exceeded", resetAt: asString(body.resetAt), used: asNumber(body.used), limit: asNumber(body.limit) }
    case 502:
    case 503:
      return { status: "unavailable" }
  }

  if (!res.ok) return { status: "error", message: `Error ${res.status}` }

  const conversationId = asString(body.conversation_id)
  if (body.kind === "fallback") return { status: "fallback", conversationId }
  const answer = asString(body.answer)
  if ((body.kind === "answer" || body.kind === "clarification") && answer) {
    return {
      status: body.kind,
      answer,
      conversationId,
      consulted: parseConsulted(body.consulted),
      state: parseState(body.state),
    }
  }
  return { status: "error", message: "Respuesta inesperada" }
}

// ─── Hooks ────────────────────────────────────────────────────────────────────

export function useAskCopilot() {
  const { user } = useAuth()
  const queryClient = useQueryClient()

  return useMutation<CopilotAskResult, Error, CopilotAskInput>({
    mutationFn: (input) => askCopilot(input),
    onSuccess: async (result) => {
      // Sólo una respuesta o repregunta dejó fila y gastó una consulta del cupo.
      if (result.status !== "answer" && result.status !== "clarification") return
      await Promise.all([
        queryClient.invalidateQueries({ queryKey: ["aiUsage", user?.id] }),
        queryClient.invalidateQueries({ queryKey: queryKeys.copilot.history(user?.accountId ?? null) }),
      ])
    },
  })
}

interface ConversationRow {
  id: string
  question: string
  answer: string
  created_at: string
  outcome: string | null
}

interface FeedbackRow {
  subject_id: string
  rating: CopilotRating
}

export function useCopilotHistory() {
  const { user } = useAuth()
  const supabase = createClient()

  return useQuery<CopilotHistoryTurn[]>({
    queryKey: queryKeys.copilot.history(user?.accountId ?? null),
    queryFn: async (): Promise<CopilotHistoryTurn[]> => {
      // Los últimos turnos propios (la RLS ya acota a la cuenta); nunca `select('*')` sin límite.
      const { data, error } = await supabase
        .from("ai_conversations")
        .select("id, question, answer, created_at, outcome")
        .eq("user_id", user!.id)
        .order("created_at", { ascending: false })
        .limit(COPILOT_HISTORY_LIMIT)
      if (error) throw error
      const rows = (data ?? []) as ConversationRow[]
      if (rows.length === 0) return []

      // La valoración es un extra: si su lectura falla, el historial se muestra igual sin ella.
      const feedback = await supabase
        .from("ai_feedback")
        .select("subject_id, rating")
        .eq("subject_type", "copilot_answer")
        .in("subject_id", rows.map((r) => r.id))
      const ratings = new Map<string, CopilotRating>(
        feedback.error ? [] : ((feedback.data ?? []) as FeedbackRow[]).map((f) => [f.subject_id, f.rating]),
      )

      return rows
        .map((r): CopilotHistoryTurn => ({
          id: r.id,
          question: r.question,
          answer: r.answer,
          createdAt: r.created_at,
          outcome: r.outcome ?? null,
          rating: ratings.get(r.id) ?? null,
        }))
        .reverse()
    },
    staleTime: 30_000,
    enabled: !!user,
  })
}

export interface SetAiFeedbackInput {
  conversationId: string
  /** `null` borra la valoración (toggle). */
  rating: CopilotRating | null
}

export function useSetAiFeedback() {
  const { user } = useAuth()
  const supabase = createClient()
  const queryClient = useQueryClient()
  const historyKey = queryKeys.copilot.history(user?.accountId ?? null)

  return useMutation<unknown, Error, SetAiFeedbackInput, { previous: CopilotHistoryTurn[] | undefined }>({
    mutationFn: async ({ conversationId, rating }) => {
      const { data, error } = await supabase.rpc("rpc_set_ai_feedback", {
        p_subject_type: "copilot_answer",
        p_subject_id: conversationId,
        p_rating: rating,
      })
      if (error) throw new Error(error.message)
      return data
    },
    onMutate: async ({ conversationId, rating }) => {
      await queryClient.cancelQueries({ queryKey: historyKey })
      const previous = queryClient.getQueryData<CopilotHistoryTurn[]>(historyKey)
      if (previous) {
        queryClient.setQueryData<CopilotHistoryTurn[]>(
          historyKey,
          previous.map((t) => (t.id === conversationId ? { ...t, rating } : t)),
        )
      }
      return { previous }
    },
    onError: (_err, _vars, context) => {
      if (context?.previous) queryClient.setQueryData(historyKey, context.previous)
    },
  })
}
