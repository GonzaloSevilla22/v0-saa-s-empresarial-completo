/**
 * ia-copilot-v2 (tanda A, grupo 5) — verificador PURO de las evals del Copiloto
 * (supabase/functions/_shared/ai-copilot-evals.ts) y forma del set de casos
 * (supabase/functions/_shared/ai-copilot-evals.json).
 *
 * La corrida real contra la Edge Function desplegada y las RPCs con la clave real es un script manual
 * (scripts/ai/copilot-evals.ts, NUNCA en CI); acá se prueba lo que no necesita clave: la normalización
 * de montos es-AR, la tolerancia de redondeo a peso, la detección de repregunta y de negativa, la
 * extracción del número esperado desde las filas de la RPC y la composición del set de 40 casos.
 *
 * Run: pnpm vitest run __tests__/ai-copilot-evals.test.ts
 */

import { describe, it, expect } from "vitest"
import {
  answerHasAmount,
  answerHasText,
  extractExpected,
  gradeCase,
  looksLikeRefusal,
  normalizeText,
  parseAmounts,
  resolvePlaceholders,
  summarizeRun,
  type EvalCase,
} from "../../supabase/functions/_shared/ai-copilot-evals"
import { COPILOT_TOOL_NAMES } from "../../supabase/functions/_shared/ai-copilot-tools"
import evalsJson from "../../supabase/functions/_shared/ai-copilot-evals.json"

const NOW = new Date("2026-11-06T18:42:00.000Z")

describe("parseAmounts / answerHasAmount — formato es-AR y redondeo a peso", () => {
  it("lee montos con punto de miles y coma decimal", () => {
    expect(parseAmounts("Vendiste $1.234.567,89 hoy")).toContain(1234567.89)
    expect(parseAmounts("$ 120.000 en 12 ventas")).toEqual(expect.arrayContaining([120000, 12]))
    expect(parseAmounts("Fueron 5000 pesos")).toContain(5000)
    expect(parseAmounts("sin números")).toEqual([])
  })

  it("acierta con el monto redondeado a peso entero, no con otro monto parecido", () => {
    expect(answerHasAmount("Hoy vendiste $120.000.", 120000)).toBe(true)
    expect(answerHasAmount("Hoy vendiste $120.000,40.", 120000.4)).toBe(true)
    expect(answerHasAmount("Hoy vendiste $1.234.568.", 1234567.89)).toBe(true)
    expect(answerHasAmount("Hoy vendiste $1.234.567,89.", 1234567.89)).toBe(true)
    expect(answerHasAmount("Hoy vendiste $120.001.", 120000)).toBe(false)
    expect(answerHasAmount("Hoy vendiste $12.000.", 120000)).toBe(false)
  })

  it("cero y negativos", () => {
    expect(answerHasAmount("No vendiste nada: $0.", 0)).toBe(true)
    expect(answerHasAmount("Perdiste $5.000 este mes.", -5000)).toBe(true)
  })
})

describe("answerHasText / normalizeText", () => {
  it("compara sin tildes ni mayúsculas", () => {
    expect(normalizeText("  Camión   Ñandú ")).toBe("camion nandu")
    expect(answerHasText("Tu producto más justo es la GORRA negra.", "Gorra Negra")).toBe(true)
    expect(answerHasText("Es la remera.", "gorra")).toBe(false)
  })
})

describe("looksLikeRefusal — el Copiloto es de sólo lectura", () => {
  it("reconoce una negativa a registrar", () => {
    expect(looksLikeRefusal("Desde acá sólo puedo consultar. Los gastos se registran en la pantalla Gastos.")).toBe(true)
    expect(looksLikeRefusal("No puedo anotar gastos; eso se hace desde Gastos.")).toBe(true)
  })
  it("no toma por negativa una respuesta que dice haber registrado", () => {
    expect(looksLikeRefusal("Listo, anoté el gasto de $5.000 en nafta.")).toBe(false)
    expect(looksLikeRefusal("Hoy vendiste $120.000.")).toBe(false)
  })
})

describe("extractExpected — el número esperado sale de las filas de la RPC, sin re-agregar", () => {
  const rows = [
    { client_name: "Ana", balance: "100" },
    { client_name: "Beto", balance: "300" },
    { client_name: "Cora", balance: "200" },
  ]
  it("path simple a una fila y columna", () => {
    expect(extractExpected(rows, { path: "0.client_name", as: "text" })).toBe("Ana")
    expect(extractExpected(rows, { path: "1.balance", as: "money" })).toBe(300)
  })
  it("ordena descendente antes de elegir y suma una columna", () => {
    expect(extractExpected(rows, { path: "0.client_name", sort_desc: "balance", as: "text" })).toBe("Beto")
    expect(extractExpected(rows, { sum: "balance", as: "money" })).toBe(600)
  })
  it("sin filas o sin columna → null (el caso se omite, no se aprueba ni se reprueba)", () => {
    expect(extractExpected([], { path: "0.x", as: "text" })).toBeNull()
    expect(extractExpected(rows, { path: "0.nope", as: "money" })).toBeNull()
    expect(extractExpected(null, { sum: "balance", as: "money" })).toBeNull()
  })
})

describe("resolvePlaceholders — fechas de referencia en Mendoza", () => {
  it("reemplaza $today, $yesterday, $month_start, $last_month_* y semanas en cualquier profundidad", () => {
    const out = resolvePlaceholders({ a: "$today", b: ["$yesterday", { c: "$month_start" }], d: "$last_month_start", e: "$last_month_end", f: "$week_start", g: "$last_week_start", h: "$last_week_end", n: 3, k: "literal" }, NOW)
    expect(out).toEqual({ a: "2026-11-06", b: ["2026-11-05", { c: "2026-11-01" }], d: "2026-10-01", e: "2026-10-31", f: "2026-11-02", g: "2026-10-26", h: "2026-11-01", n: 3, k: "literal" })
  })
})

describe("gradeCase", () => {
  const money: EvalCase = {
    id: "T1", group: "vague", question: "cuánto vendí hoy",
    expect: { tools_any_of: ["resumen_periodo"], rpc_check: { fn: "rpc_dashboard_kpi_summary", window: { from: "$today", to: "$today" }, extract: { path: "0.invoiced_revenue", as: "money" } } },
  }
  const resp = (answer: string, tool = "resumen_periodo", kind = "answer") => ({ kind, answer, consulted: [{ tool, label: "x" }] })

  it("acierto numérico: herramienta esperada y monto presente", () => {
    expect(gradeCase(money, resp("Hoy vendiste $120.000."), 120000)).toMatchObject({ pass: true })
  })
  it("falla si el monto no aparece o si no usó ninguna herramienta esperada", () => {
    expect(gradeCase(money, resp("Hoy vendiste $99.000."), 120000)).toMatchObject({ pass: false })
    expect(gradeCase(money, resp("Hoy vendiste $120.000.", "stock_critico"), 120000)).toMatchObject({ pass: false })
  })
  it("sin número esperado (la RPC no devolvió filas) el caso se omite", () => {
    expect(gradeCase(money, resp("No hay ventas."), null)).toMatchObject({ pass: true, skipped: true })
  })
  it("texto esperado", () => {
    const text: EvalCase = { id: "T2", group: "real", question: "menos stock", expect: { rpc_check: { fn: "get_dashboard_critical_stock_items", args: {}, extract: { path: "0.name", as: "text" } } } }
    expect(gradeCase(text, resp("Lo más justo: Gorra Negra."), "gorra negra")).toMatchObject({ pass: true })
    expect(gradeCase(text, resp("Lo más justo: Remera."), "gorra negra")).toMatchObject({ pass: false })
  })
  it("repregunta: sólo kind clarification", () => {
    const c: EvalCase = { id: "T3", group: "clarification", question: "cuántas remeras", expect: { must_ask_clarification: true } }
    expect(gradeCase(c, resp("¿Cuál? 1) Roja 2) Azul", "buscar_producto", "clarification"), null)).toMatchObject({ pass: true })
    expect(gradeCase(c, resp("Vendiste 3.", "buscar_producto", "answer"), null)).toMatchObject({ pass: false })
  })
  it("escritura: negativa y ninguna fila creada", () => {
    const w: EvalCase = { id: "T4", group: "write", question: "anotame un gasto", expect: { must_refuse_write: { tables: ["expenses"] } } }
    expect(gradeCase(w, resp("Desde acá sólo puedo consultar.", "x"), null, { rowsCreated: 0 })).toMatchObject({ pass: true })
    expect(gradeCase(w, resp("Desde acá sólo puedo consultar.", "x"), null, { rowsCreated: 1 })).toMatchObject({ pass: false })
    expect(gradeCase(w, resp("Listo, anoté el gasto.", "x"), null, { rowsCreated: 0 })).toMatchObject({ pass: false })
  })
  it("must_contain_number exige algún número en la respuesta", () => {
    const c: EvalCase = { id: "T5", group: "real", question: "consejos", expect: { tools_any_of: ["resumen_periodo"], must_contain_number: true } }
    expect(gradeCase(c, resp("Cobrá los $30.000 pendientes."), null)).toMatchObject({ pass: true })
    expect(gradeCase(c, resp("Mejorá tu atención."), null)).toMatchObject({ pass: false })
  })
})

describe("summarizeRun", () => {
  it("cuenta aciertos numéricos, repreguntas, negativas, latencia y tokens", () => {
    const md = summarizeRun({
      model: "gpt-x", date: "2026-11-06",
      results: [
        { id: "A", group: "real", pass: true, skipped: false, numeric: true, latency_ms: 1000, prompt_tokens: 100, completion_tokens: 10, reason: "" },
        { id: "B", group: "vague", pass: false, skipped: false, numeric: true, latency_ms: 3000, prompt_tokens: 300, completion_tokens: 30, reason: "monto ausente" },
        { id: "C", group: "clarification", pass: true, skipped: false, numeric: false, latency_ms: 2000, prompt_tokens: 200, completion_tokens: 20, reason: "" },
        { id: "D", group: "write", pass: true, skipped: false, numeric: false, latency_ms: 2000, prompt_tokens: 200, completion_tokens: 20, reason: "" },
        { id: "E", group: "vague", pass: true, skipped: true, numeric: true, latency_ms: 0, prompt_tokens: 0, completion_tokens: 0, reason: "sin datos" },
      ],
    })
    expect(md).toContain("gpt-x")
    expect(md).toContain("Aciertos numéricos: 1/2 (50%)")
    expect(md).toContain("Repreguntas correctas: 1/1")
    expect(md).toContain("Negativas correctas: 1/1")
    expect(md).toContain("Omitidos (sin datos para verificar): 1")
    expect(md).toContain("Latencia media: 2000 ms")
    expect(md).toContain("monto ausente")
  })
})

describe("set de evals (D12): al menos 40 casos con la composición del diseño", () => {
  const cases = evalsJson.cases as unknown as EvalCase[]

  it("al menos 40 casos con ids únicos", () => {
    expect(cases.length).toBeGreaterThanOrEqual(40)
    expect(new Set(cases.map((c) => c.id)).size).toBe(cases.length)
  })

  it("composición: reales, vagas, seguimientos con estado, repreguntas y escrituras que deben negarse", () => {
    const count = (g: string) => cases.filter((c) => c.group === g).length
    expect(count("real")).toBeGreaterThanOrEqual(9)
    expect(count("vague")).toBeGreaterThanOrEqual(20)
    expect(count("followup")).toBe(5)
    expect(count("clarification")).toBe(3)
    expect(count("write")).toBe(2)
  })

  it("cada caso tiene una expectativa verificable", () => {
    for (const c of cases) {
      const e = c.expect
      const verifiable = e.rpc_check || e.must_ask_clarification || e.must_refuse_write || (e.tools_any_of && e.must_contain_number)
      expect(verifiable, `${c.id} sin expectativa verificable`).toBeTruthy()
      if (e.rpc_check) {
        expect(["money", "integer", "text"]).toContain(e.rpc_check.extract.as)
        expect(typeof e.rpc_check.fn).toBe("string")
      }
      for (const t of e.tools_any_of ?? []) expect(COPILOT_TOOL_NAMES as readonly string[]).toContain(t)
    }
  })

  it("los seguimientos llevan historial y estado; las repreguntas y escrituras no pagan una RPC", () => {
    for (const c of cases.filter((x) => x.group === "followup")) {
      expect(c.history && c.history.length > 0).toBe(true)
      expect(c.state).toBeTruthy()
    }
    for (const c of cases.filter((x) => x.group === "clarification" || x.group === "write")) {
      expect(c.expect.rpc_check).toBeUndefined()
    }
  })

  it("incluye las preguntas reales distintas de ai_conversations (anonimizadas)", () => {
    const qs = cases.filter((c) => c.group === "real").map((c) => normalizeText(c.question))
    for (const q of ["cual es mi producto con menos stock?", "que producto me conviene reponer?", "cuales fueron mis gastos de hoy?", "cual fue mi ganancia neta?", "dame tres consejos para mejorar mi negocio.", "que producto tiene mejor margen?", "que cliente compro mas?", "cuanto vendi hoy?", "que producto tiene menos stock?"]) {
      expect(qs).toContain(q)
    }
  })
})
