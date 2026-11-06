// Evals del Copiloto — ia-copilot-v2 (tanda A, D12). Se corre A MANO con la clave real; NUNCA en CI.
//
// Por cada caso de supabase/functions/_shared/ai-copilot-evals.json:
//   1. llama a la Edge Function DESPLEGADA (`/functions/v1/ai-copilot`) con el JWT de una cuenta de prueba;
//   2. obtiene el número esperado ejecutando la RPC canónica del caso con el MISMO JWT (jamás re-agregando);
//   3. califica con el verificador puro (montos es-AR, tolerancia de redondeo a peso, repregunta, negativa);
//   4. en los casos de escritura cuenta las filas de las tablas antes y después (no tiene que haber ninguna nueva).
// Escribe openspec/changes/ia-copilot-v2/evals/<fecha>-<modelo>.md con aciertos, repreguntas, negativas,
// latencia media y tokens.
//
// El modelo NO se elige por request (OQ-4: un header que elige modelo sería una puerta de costo): para
// comparar modelos se cambia el secreto COPILOT_AI_MODEL de Supabase entre corridas y se vuelve a correr.
// El modelo que respondió se lee de la fila registrada en ai_conversations (columna `model`).
//
// Variables de entorno (la clave de OpenAI NO se usa acá: la tiene la función desplegada):
//   SUPABASE_URL        https://<ref>.supabase.co
//   SUPABASE_ANON_KEY   clave anónima (publicable) del proyecto
//   EVAL_EMAIL / EVAL_PASSWORD   una cuenta de PRUEBA con datos del mes, plan con cuota suficiente
//                       (40 consultas por corrida: plan avanzado o pro) y las fixtures de las
//                       repreguntas (>= 2 productos que coincidan con «remera», «gorra» y «campera»).
//   EVAL_PACE_SECONDS   (opcional) segundos entre preguntas; por defecto 13 (la ráfaga es de 5 por minuto).
//   EVAL_ONLY           (opcional) ids separados por coma, p. ej. R04,V01.
//
// Uso (desde la raíz del repo):
//   deno run --allow-net --allow-env --allow-write=openspec/changes/ia-copilot-v2/evals scripts/ai/copilot-evals.ts

import evals from "../../supabase/functions/_shared/ai-copilot-evals.json" with { type: "json" }
import {
  extractExpected,
  gradeCase,
  resolvePlaceholders,
  summarizeRun,
  type EvalCase,
  type EvalResponse,
  type RunResult,
} from "../../supabase/functions/_shared/ai-copilot-evals.ts"
import { artDateInfo } from "../../supabase/functions/_shared/ai-copilot-prompt.ts"
import { previousWindow } from "../../supabase/functions/_shared/reporting-canon.ts"

const need = (name: string): string => {
  const v = Deno.env.get(name)
  if (!v) {
    console.error(`Falta la variable de entorno ${name}.`)
    Deno.exit(1)
  }
  return v
}
const baseUrl = need("SUPABASE_URL").replace(/\/+$/, "")
const anonKey = need("SUPABASE_ANON_KEY")
const email = need("EVAL_EMAIL")
const password = need("EVAL_PASSWORD")
const paceMs = Number(Deno.env.get("EVAL_PACE_SECONDS") ?? "13") * 1000
const only = (Deno.env.get("EVAL_ONLY") ?? "").split(",").map((s) => s.trim()).filter(Boolean)

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))

// ─── Sesión de la cuenta de prueba ────────────────────────────────────────────

const loginRes = await fetch(`${baseUrl}/auth/v1/token?grant_type=password`, {
  method: "POST",
  headers: { apikey: anonKey, "Content-Type": "application/json" },
  body: JSON.stringify({ email, password }),
})
if (!loginRes.ok) {
  console.error(`No se pudo iniciar sesión con la cuenta de prueba (HTTP ${loginRes.status}).`)
  Deno.exit(1)
}
const token = ((await loginRes.json()) as { access_token: string }).access_token
const authHeaders = { apikey: anonKey, Authorization: `Bearer ${token}`, "Content-Type": "application/json" }

async function rpc(fn: string, args: Record<string, unknown>): Promise<unknown> {
  const res = await fetch(`${baseUrl}/rest/v1/rpc/${fn}`, { method: "POST", headers: authHeaders, body: JSON.stringify(args) })
  if (!res.ok) throw new Error(`RPC ${fn}: HTTP ${res.status} ${(await res.text()).slice(0, 200)}`)
  return await res.json()
}

async function countRows(table: string): Promise<number> {
  const res = await fetch(`${baseUrl}/rest/v1/${table}?select=id`, { headers: { ...authHeaders, Prefer: "count=exact", Range: "0-0" } })
  const range = res.headers.get("content-range") ?? "*/0"
  return Number(range.split("/")[1] ?? 0)
}

const accountRaw = await rpc("current_account_ids", {})
const accountId = String(Array.isArray(accountRaw) ? accountRaw[0] : accountRaw)

const now = new Date()
const today = artDateInfo(now).today

// $top_product_*: la primera fila del ranking del mes por unidades (misma RPC que usa la pantalla).
const d0 = artDateInfo(now)
const topRows = await rpc("rpc_product_ranking", {
  p_account_id: accountId, p_start: d0.monthStart, p_end: d0.today, p_order_by: "units", p_group_variants: true,
  p_branch_id: null, p_canal: null, p_limit: 1, p_offset: 0,
}) as Array<{ product_id: string; product_name: string }>
const topProduct = topRows[0] ?? null

function substitute<T>(value: T): T {
  const resolved = resolvePlaceholders(value, now)
  const walk = (v: unknown): unknown => {
    if (typeof v === "string") {
      if (v === "$account_id") return accountId
      if (v === "$top_product_id") return topProduct?.product_id ?? "00000000-0000-4000-8000-000000000000"
      if (v === "$top_product_name") return topProduct?.product_name ?? "sin producto"
      return v
    }
    if (Array.isArray(v)) return v.map(walk)
    if (typeof v === "object" && v !== null) return Object.fromEntries(Object.entries(v as Record<string, unknown>).map(([k, x]) => [k, walk(x)]))
    return v
  }
  return walk(resolved) as T
}

// ─── Una corrida por caso ─────────────────────────────────────────────────────

async function expectedFor(c: EvalCase): Promise<number | string | null> {
  const check = c.expect.rpc_check
  if (!check) return null
  const resolved = substitute(check)
  let args: Record<string, unknown>
  if (resolved.window) {
    const from = `${resolved.window.from}T00:00:00.000Z`
    const to = `${resolved.window.to}T23:59:59.999Z`
    const prev = previousWindow(from, to)
    args = { p_from: from, p_to: to, p_prev_from: prev.from, p_prev_to: prev.to, p_branch_id: null }
  } else {
    args = resolved.args ?? {}
  }
  try {
    return extractExpected(await rpc(resolved.fn, args), resolved.extract)
  } catch (err) {
    console.warn(`  (no se pudo calcular el esperado: ${err instanceof Error ? err.message : String(err)})`)
    return null
  }
}

interface AskResult {
  status: number
  json: Record<string, unknown>
}

async function ask(c: EvalCase, threadId: string): Promise<AskResult> {
  const body = { question: c.question, history: c.history ?? [], state: c.state ? substitute(c.state) : null, thread_id: threadId }
  for (let attempt = 0; attempt < 4; attempt++) {
    const res = await fetch(`${baseUrl}/functions/v1/ai-copilot`, { method: "POST", headers: authHeaders, body: JSON.stringify(body) })
    const json = await res.json().catch(() => ({})) as Record<string, unknown>
    if (res.status === 429 && json.error === "rate_limited") {
      const wait = Number(res.headers.get("Retry-After") ?? json.retryAfterSeconds ?? 15) + 1
      console.log(`  ráfaga: espero ${wait} s`)
      await sleep(wait * 1000)
      continue
    }
    return { status: res.status, json }
  }
  return { status: 429, json: { error: "rate_limited" } }
}

const selected = (evals.cases as unknown as EvalCase[]).filter((c) => only.length === 0 || only.includes(c.id))
const results: RunResult[] = []
let modelSeen = "desconocido"

for (const c of selected) {
  console.log(`${c.id} (${c.group}): ${c.question}`)
  const tables = c.expect.must_refuse_write?.tables ?? []
  const before: Record<string, number> = {}
  for (const t of tables) before[t] = await countRows(t)

  const expected = await expectedFor(c)
  const t0 = performance.now()
  const res = await ask(c, crypto.randomUUID())
  const wall = Math.round(performance.now() - t0)

  if (res.status === 429 && res.json.error === "quota_exceeded") {
    console.error("La cuenta de prueba agotó su cuota mensual de IA: se corta la corrida.")
    break
  }

  let rowsCreated = 0
  for (const t of tables) rowsCreated += Math.max(0, (await countRows(t)) - before[t])

  let result: RunResult
  if (res.status !== 200 || res.json.ok !== true) {
    result = { id: c.id, group: c.group, pass: false, skipped: false, numeric: !!c.expect.rpc_check, latency_ms: wall, prompt_tokens: 0, completion_tokens: 0, reason: `HTTP ${res.status} ${String(res.json.error ?? "")}` }
  } else {
    const response: EvalResponse = {
      kind: String(res.json.kind),
      answer: String(res.json.answer ?? ""),
      consulted: Array.isArray(res.json.consulted) ? res.json.consulted as EvalResponse["consulted"] : [],
    }
    const grade = gradeCase(c, response, expected, { rowsCreated })
    let latency = wall
    let promptTokens = 0
    let completionTokens = 0
    const convId = res.json.conversation_id
    if (typeof convId === "string") {
      const r = await fetch(`${baseUrl}/rest/v1/ai_conversations?id=eq.${convId}&select=model,latency_ms,prompt_tokens,completion_tokens`, { headers: authHeaders })
      const rows = await r.json().catch(() => []) as Array<{ model: string | null; latency_ms: number | null; prompt_tokens: number | null; completion_tokens: number | null }>
      if (rows[0]) {
        if (rows[0].model) modelSeen = rows[0].model
        latency = rows[0].latency_ms ?? wall
        promptTokens = rows[0].prompt_tokens ?? 0
        completionTokens = rows[0].completion_tokens ?? 0
      }
    }
    result = { id: c.id, group: c.group, pass: grade.pass, skipped: grade.skipped === true, numeric: grade.numeric, latency_ms: latency, prompt_tokens: promptTokens, completion_tokens: completionTokens, reason: grade.reason }
  }
  console.log(`  -> ${result.skipped ? "OMITIDO" : result.pass ? "OK" : "FALLA"}${result.reason ? ` (${result.reason})` : ""}`)
  results.push(result)
  await sleep(paceMs)
}

const markdown = summarizeRun({ model: modelSeen, date: today, results })
const dir = "openspec/changes/ia-copilot-v2/evals"
await Deno.mkdir(dir, { recursive: true })
const file = `${dir}/${today}-${modelSeen.replace(/[^a-zA-Z0-9._-]/g, "_")}.md`
await Deno.writeTextFile(file, markdown)
console.log(`\n${markdown}\nResumen escrito en ${file}`)
