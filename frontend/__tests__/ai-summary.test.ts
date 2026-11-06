/**
 * tablero-explicable (D7, tasks 4.1/4.3): lectura de la respuesta de
 * `ai-resumen` y mensajes de error legibles del Resumen IA del día.
 */
import { describe, it, expect } from "vitest"
import {
  AiSummaryEmptyError,
  AiSummaryTimeoutError,
  aiSummaryErrorMessage,
  parseAiSummaryResponse,
} from "@/lib/ai-summary"

describe("parseAiSummaryResponse", () => {
  it("lee el texto de la fila de insights (columna `message`)", () => {
    expect(parseAiSummaryResponse({ ok: true, data: { id: "i-1", message: "Hoy vendiste $200." } })).toBe(
      "Hoy vendiste $200.",
    )
  })

  it("lee el texto crudo cuando la función degrada a string", () => {
    expect(parseAiSummaryResponse({ ok: true, data: "Buen día: ventas estables." })).toBe(
      "Buen día: ventas estables.",
    )
  })

  it("acepta `content` como respaldo (tabla legacy)", () => {
    expect(parseAiSummaryResponse({ ok: true, data: { content: "Legacy" } })).toBe("Legacy")
  })

  it("prefiere `message` sobre `content` cuando vienen los dos", () => {
    expect(parseAiSummaryResponse({ data: { message: "nuevo", content: "viejo" } })).toBe("nuevo")
  })

  it("una respuesta sin texto devuelve null (nunca un resumen inventado)", () => {
    expect(parseAiSummaryResponse(null)).toBeNull()
    expect(parseAiSummaryResponse(undefined)).toBeNull()
    expect(parseAiSummaryResponse({ ok: true })).toBeNull()
    expect(parseAiSummaryResponse({ ok: true, data: {} })).toBeNull()
    expect(parseAiSummaryResponse({ ok: true, data: "   " })).toBeNull()
    expect(parseAiSummaryResponse({ ok: true, data: { message: 42 } })).toBeNull()
  })
})

describe("aiSummaryErrorMessage", () => {
  it("429: dice que se alcanzó el límite mensual de IA y cuándo se reinicia", () => {
    const msg = aiSummaryErrorMessage({ name: "FunctionsHttpError", context: { status: 429 } })
    expect(msg).toBe("Llegaste al límite mensual de consultas de IA de tu plan. Se reinicia el 1.º de cada mes.")
  })

  it("401: sesión vencida", () => {
    expect(aiSummaryErrorMessage({ context: { status: 401 } })).toBe("Tu sesión venció. Volvé a ingresar.")
  })

  it("tope de espera vencido", () => {
    expect(aiSummaryErrorMessage(new AiSummaryTimeoutError())).toBe("La IA tardó demasiado. Probá con Regenerar.")
  })

  it("respuesta sin texto", () => {
    expect(aiSummaryErrorMessage(new AiSummaryEmptyError())).toBe(
      "La IA no devolvió un resumen. Probá con Regenerar.",
    )
  })

  it("cualquier otra falla (502, red, desconocida) cae al mensaje genérico", () => {
    const generic = "No pudimos generar el resumen. Probá con Regenerar en unos minutos."
    expect(aiSummaryErrorMessage({ context: { status: 502 } })).toBe(generic)
    expect(aiSummaryErrorMessage(new Error("network"))).toBe(generic)
    expect(aiSummaryErrorMessage("raro")).toBe(generic)
    expect(aiSummaryErrorMessage(null)).toBe(generic)
  })
})
