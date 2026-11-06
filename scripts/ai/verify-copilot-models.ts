// Task 0 de ia-copilot-v2 — verifica con la clave real qué modelos de OpenAI existen y qué aceptan.
//
// Qué hace (sólo lectura y llamadas mínimas de ~50 tokens por modelo):
//   1. GET /v1/models → cuáles de la allow-list del Copiloto existen para esta clave.
//   2. Por cada modelo existente:
//        - qué parámetro de tope de salida acepta (max_completion_tokens o max_tokens);
//        - si acepta `temperature`;
//        - si acepta `tools` (function calling con schema estricto);
//        - si acepta `response_format: json_schema` estricto.
//   3. Imprime una tabla y un bloque JSON para pegar en design.md («Notas de la tanda A», task 0) y
//      para corregir COPILOT_MODEL_PARAMS en supabase/functions/_shared/ai-copilot-core.ts si hace falta.
//
// La clave sale SÓLO de la variable de entorno OPENAI_API_KEY y nunca se imprime ni se escribe.
//
// Uso (una línea, desde la raíz del repo; en PowerShell: $env:OPENAI_API_KEY="sk-..."; deno run ...):
//   OPENAI_API_KEY=sk-... deno run --allow-net=api.openai.com --allow-env=OPENAI_API_KEY scripts/ai/verify-copilot-models.ts

import { COPILOT_ALLOWED_MODELS } from "../../supabase/functions/_shared/ai-copilot-core.ts"

const apiKey = Deno.env.get("OPENAI_API_KEY")
if (!apiKey) {
  console.error("Falta OPENAI_API_KEY en el entorno (no se lee ningún archivo .env).")
  Deno.exit(1)
}

interface Probe {
  ok: boolean
  status: number
  message: string
  ms: number
  body?: Record<string, unknown>
}

async function post(body: Record<string, unknown>): Promise<Probe> {
  const t0 = performance.now()
  try {
    const res = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: { "Authorization": `Bearer ${apiKey}`, "Content-Type": "application/json" },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(40_000),
    })
    const raw = await res.text()
    let message = ""
    let parsed: Record<string, unknown> | undefined
    try {
      parsed = JSON.parse(raw) as Record<string, unknown>
      message = (parsed.error as { message?: string } | undefined)?.message ?? ""
    } catch { message = raw.slice(0, 200) }
    return { ok: res.ok, status: res.status, message, ms: Math.round(performance.now() - t0), body: parsed }
  } catch (err) {
    return { ok: false, status: 0, message: err instanceof Error ? err.message : String(err), ms: Math.round(performance.now() - t0) }
  }
}

const listRes = await fetch("https://api.openai.com/v1/models", { headers: { "Authorization": `Bearer ${apiKey}` } })
if (!listRes.ok) {
  console.error(`GET /v1/models falló con HTTP ${listRes.status}. ¿La clave es válida?`)
  Deno.exit(1)
}
const available = new Set(((await listRes.json()) as { data: Array<{ id: string }> }).data.map((m) => m.id))

const TOY_TOOL = {
  type: "function",
  function: {
    name: "suma",
    description: "Suma dos enteros.",
    strict: true,
    parameters: { type: "object", properties: { a: { type: "integer" }, b: { type: "integer" } }, required: ["a", "b"], additionalProperties: false },
  },
}
const TOY_SCHEMA = {
  type: "json_schema",
  json_schema: {
    name: "toy",
    strict: true,
    schema: { type: "object", properties: { answer: { type: "string" } }, required: ["answer"], additionalProperties: false },
  },
}
const PING = [{ role: "user", content: "Respondé sólo con la palabra OK." }]

interface Row {
  model: string
  exists: boolean
  output_param: string | null
  temperature: boolean | null
  tools: boolean | null
  json_schema: boolean | null
  ms: number | null
  notes: string[]
}

const rows: Row[] = []
for (const model of COPILOT_ALLOWED_MODELS) {
  const row: Row = { model, exists: available.has(model), output_param: null, temperature: null, tools: null, json_schema: null, ms: null, notes: [] }
  rows.push(row)
  if (!row.exists) continue

  // Tope de salida: se prueba primero max_completion_tokens (modelos nuevos); si no, max_tokens.
  let outParam: "max_completion_tokens" | "max_tokens" | null = null
  for (const p of ["max_completion_tokens", "max_tokens"] as const) {
    const r = await post({ model, messages: PING, [p]: 200 })
    row.ms = r.ms
    if (r.ok) { outParam = p; break }
    row.notes.push(`${p}: HTTP ${r.status} ${r.message.slice(0, 100)}`)
  }
  row.output_param = outParam
  if (!outParam) continue

  const temp = await post({ model, messages: PING, [outParam]: 200, temperature: 0.2 })
  row.temperature = temp.ok
  if (!temp.ok) row.notes.push(`temperature: HTTP ${temp.status} ${temp.message.slice(0, 100)}`)

  const tools = await post({
    model,
    messages: [{ role: "user", content: "¿Cuánto es 2 + 3? Usá la herramienta suma." }],
    tools: [TOY_TOOL], tool_choice: "auto", parallel_tool_calls: true, [outParam]: 400,
  })
  const choice = (tools.body?.choices as Array<{ message?: { tool_calls?: unknown[] } }> | undefined)?.[0]
  row.tools = tools.ok && Array.isArray(choice?.message?.tool_calls) && choice.message.tool_calls.length > 0
  if (!tools.ok) row.notes.push(`tools: HTTP ${tools.status} ${tools.message.slice(0, 100)}`)
  else if (!row.tools) row.notes.push("tools: aceptó el parámetro pero no llamó a la herramienta")

  const schema = await post({ model, messages: PING, response_format: TOY_SCHEMA, [outParam]: 400 })
  let schemaOk = false
  if (schema.ok) {
    const content = (schema.body?.choices as Array<{ message?: { content?: string } }> | undefined)?.[0]?.message?.content ?? ""
    try { schemaOk = typeof (JSON.parse(content) as { answer?: unknown }).answer === "string" } catch { schemaOk = false }
  } else {
    row.notes.push(`json_schema: HTTP ${schema.status} ${schema.message.slice(0, 100)}`)
  }
  row.json_schema = schemaOk
}

const mark = (v: boolean | string | null): string => (v === null ? "—" : v === true ? "sí" : v === false ? "NO" : v)
console.log("\n| modelo | existe | tope de salida | temperature | tools | json_schema | ms |")
console.log("|---|---|---|---|---|---|---|")
for (const r of rows) console.log(`| ${r.model} | ${mark(r.exists)} | ${mark(r.output_param)} | ${mark(r.temperature)} | ${mark(r.tools)} | ${mark(r.json_schema)} | ${r.ms ?? "—"} |`)
const unusable = rows.filter((r) => r.exists && (r.tools !== true || r.output_param === null)).map((r) => r.model)
console.log("\nNotas:")
for (const r of rows) for (const n of r.notes) console.log(`- ${r.model}: ${n}`)
if (unusable.length > 0) console.log(`\nSin soporte de herramientas (sacar de la allow-list o no usar): ${unusable.join(", ")}`)
console.log("\nJSON para design.md:")
console.log(JSON.stringify(rows, null, 2))
