"use client"

/**
 * ia-copilot-v2 (tanda B, task 8.3) — pasada visual de /copiloto-ia.
 *
 * Monta la pantalla REAL (`app/(dashboard)/copiloto-ia/page.tsx`) sin sesión ni backend. Lo que se
 * simula son los bordes, con las MISMAS claves que usan los hooks reales:
 *
 *  - cuota: se siembra `["aiUsage", undefined]` y `["planLimits", "gratis"]` (como el arnés de OCR);
 *  - historial: se siembra `queryKeys.copilot.history(null)` (sin usuario el hook no consulta, pero la
 *    caché sembrada se lee igual);
 *  - sesión: `window.fetch` intercepta `/api/auth/token` (el Bearer que arma `getAuthHeaders()`);
 *  - la Edge Function: `window.fetch` intercepta `/functions/v1/ai-copilot` y el RPC de valoración.
 *
 * `?state=` decide qué responde la función:
 *
 *   vacio      → sin llamadas; chat vacío con las 6 sugerencias (y el historial sembrado si `historial=1`)
 *   respuesta  → 200 `answer` con «Miré: …» y conversation_id (para valorar)
 *   repregunta → 200 `clarification`
 *   cuota      → cupo agotado (30 de 30), sin llamadas
 *   rafaga     → 429 `rate_limited` (retryAfterSeconds = 40)
 *   error      → 502 `ai_unavailable`
 *   espera     → la función nunca responde (se ve «Pensando…» y los pasos)
 *
 * `?theme=light|dark` escribe la clase `dark` en `<html>` igual que next-themes.
 */

import { useEffect, useState } from "react"
import { useQueryClient } from "@tanstack/react-query"
import CopilotoPage from "@/app/(dashboard)/copiloto-ia/page"
import { queryKeys } from "@/lib/query-keys"
import { resolveAccessToken } from "@/lib/auth/access-token-store"
import type { CopilotHistoryTurn } from "@/hooks/data/use-copilot"
import type { PlanLimits } from "@/lib/types"

type HarnessState = "vacio" | "respuesta" | "repregunta" | "cuota" | "rafaga" | "error" | "espera"

function limitsFor(queries: number): PlanLimits {
  return {
    plan: "gratis",
    priceMonthly: 0,
    maxUsers: 1,
    maxProducts: 100,
    maxClients: 50,
    maxSuppliers: 20,
    maxOperationsPerMonth: 100,
    historyDays: 30,
    maxExportsPerMonth: 0,
    maxAiQueriesPerMonth: queries,
    maxAiAdvicePerMonth: 3,
    maxAiOcrPerMonth: 5,
    maxBranches: 1,
    hasProductProfitability: false,
    hasComparativeReports: false,
    hasPriceSuggestion: false,
    hasBranchesModule: false,
    hasMonthlyAnalysis: false,
    internalRoles: "none",
  }
}

const SAVED_TURNS: CopilotHistoryTurn[] = [
  {
    id: "turn-1",
    question: "¿Qué producto es el que más vendo?",
    answer: "El producto que más vendiste en octubre fue la Remera básica: 48 unidades, $412.800.",
    createdAt: "2026-11-05T12:00:00Z",
    outcome: "answer",
    rating: "useful",
  },
  {
    id: "turn-2",
    question: "¿A quién le tengo que cobrar?",
    answer: "Tenés 3 clientes con saldo pendiente por un total de $186.500. El más grande es Panadería Don Luis: $98.000.",
    createdAt: "2026-11-06T09:30:00Z",
    outcome: "answer",
    rating: null,
  },
]

function json(status: number, body: unknown, headers: Record<string, string> = {}) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", ...headers } })
}

function installFetchIntercept(state: HarnessState) {
  const original = window.fetch.bind(window)
  window.fetch = async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url

    // Sesión simulada: lo que lee `getAuthHeaders()` para armar el Bearer.
    if (url.includes("/api/auth/token")) {
      return json(200, { access_token: "harness-token", expires_at: Math.floor(Date.now() / 1000) + 3600, user: null })
    }
    // Valoración (RPC de PostgREST).
    if (url.includes("/rest/v1/rpc/rpc_set_ai_feedback")) {
      return json(200, { subject_type: "copilot_answer", subject_id: "live-1", rating: "useful" })
    }
    // La Edge Function.
    if (url.includes("/functions/v1/ai-copilot")) {
      switch (state) {
        case "respuesta":
          return json(200, {
            ok: true,
            kind: "answer",
            answer:
              "Hoy vendiste $128.400 en 14 operaciones. Es un 18 % más que el mismo día de la semana pasada ($108.800).\n\nEl producto que más se movió fue la Remera básica (9 unidades).",
            conversation_id: "live-1",
            consulted: [
              { tool: "resumen_periodo", label: "ventas de hoy" },
              { tool: "ranking_productos", label: "productos más vendidos de hoy" },
            ],
            state: { period: { start: "2026-11-06", end: "2026-11-06" }, product: null, client: null },
          })
        case "repregunta":
          return json(200, {
            ok: true,
            kind: "clarification",
            answer: "Tengo dos productos que se llaman parecido: «Remera básica» y «Remera básica oversize». ¿De cuál querés saber el stock?",
            conversation_id: "live-2",
            consulted: [{ tool: "buscar_producto", label: "productos que se parecen a «remera»" }],
            state: { period: null, product: null, client: null },
          })
        case "rafaga":
          return json(429, { ok: false, error: "rate_limited", retryAfterSeconds: 40 }, { "Retry-After": "40" })
        case "error":
          return json(502, { ok: false, error: "ai_unavailable" })
        case "espera":
          return new Promise<Response>(() => {})
        default:
          return json(200, { ok: false })
      }
    }
    return original(input, init)
  }
  return () => {
    window.fetch = original
  }
}

export function CopilotoChatHarness() {
  const queryClient = useQueryClient()
  const [ready, setReady] = useState(false)

  useEffect(() => {
    const params = new URLSearchParams(window.location.search)
    const state = (params.get("state") as HarnessState | null) ?? "vacio"
    const uninstall = installFetchIntercept(state)
    document.documentElement.classList.toggle("dark", params.get("theme") === "dark")

    queryClient.setQueryData(["planLimits", "gratis"], limitsFor(30))
    queryClient.setQueryData(["aiUsage", undefined], {
      ai_queries_used: state === "cuota" ? 30 : 22,
      ai_advice_used: 0,
      ai_ocr_used: 0,
      usage_reset_at: null,
    })
    queryClient.setQueryData(queryKeys.copilot.history(null), params.get("historial") === "1" ? SAVED_TURNS : [])
    // El proveedor de sesión ya pudo haber cacheado «sin sesión» antes de instalar el intercept:
    // se fuerza la lectura contra el token simulado para que `getAuthHeaders()` arme el Bearer.
    void resolveAccessToken({ force: true }).finally(() => setReady(true))
    return uninstall
  }, [queryClient])

  return <main className="p-3 sm:p-6">{ready && <CopilotoPage />}</main>
}
