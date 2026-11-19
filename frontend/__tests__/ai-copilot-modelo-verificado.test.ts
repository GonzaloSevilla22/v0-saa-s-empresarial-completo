/**
 * Task 0 de ia-copilot-v2, corrida por el PO con la clave real (2026-11-06,
 * `scripts/ai/verify-copilot-models.ts`): `gpt-6.1-terra` y `gpt-6-luna` existen pero
 * rechazan las herramientas en /v1/chat/completions («Function tools with
 * reasoning_effort are not supported for gpt-6.1-terra in /v1/chat/completions»),
 * aun sin mandar `reasoning_effort`. Con herramientas sirven `gpt-5-mini`,
 * `gpt-4.1-mini` y `gpt-4o-mini`. Antes de este fix el default era terra y ese 400
 * no disparaba el salto de modelo: toda pregunta con datos caía al mensaje de
 * «No pude responder ahora».
 */
import { describe, it, expect, vi } from "vitest"
import {
  COPILOT_ALLOWED_MODELS,
  COPILOT_DEFAULT_MODEL,
  COPILOT_FALLBACK_ORDER,
  COPILOT_MODEL_PARAMS,
  createModelFailover,
  isUnknownModelError,
} from "../../supabase/functions/_shared/ai-copilot-core"

const TOOLS_UNSUPPORTED =
  "Function tools with reasoning_effort are not supported for gpt-6.1-terra in /v1/chat/completions. To use them, call the Responses API."

describe("modelo verificado con la clave real (task 0, 2026-11-06)", () => {
  it("el default es gpt-5-mini y la familia 6 queda fuera de la allow-list hasta migrar al endpoint que la soporta", () => {
    expect(COPILOT_DEFAULT_MODEL).toBe("gpt-5-mini")
    expect(COPILOT_FALLBACK_ORDER).toEqual(["gpt-5-mini", "gpt-4.1-mini", "gpt-4o-mini"])
    expect([...COPILOT_ALLOWED_MODELS].sort()).toEqual([...COPILOT_FALLBACK_ORDER].sort())
    for (const m of COPILOT_ALLOWED_MODELS) expect(COPILOT_MODEL_PARAMS[m]).toBeDefined()
  })

  it("un 400 «herramientas no soportadas para este modelo» cuenta como modelo inutilizable (salta), no como parámetro a corregir", () => {
    expect(isUnknownModelError(400, TOOLS_UNSUPPORTED)).toBe(true)
    expect(isUnknownModelError(400, "Unsupported value: 'temperature' does not support 0.2 with this model.")).toBe(false)
  })

  it("el failover salta al siguiente modelo ante ese 400 y se queda en el que funcionó", async () => {
    const send = vi.fn(async (model: string) =>
      model === "gpt-6.1-terra"
        ? { kind: "http_error" as const, status: 400, message: TOOLS_UNSUPPORTED }
        : { kind: "ok" as const, message: { role: "assistant" as const, content: "ok" }, usage: { prompt_tokens: 1, completion_tokens: 1 } },
    )
    const log = vi.fn()
    const call = createModelFailover({ candidates: ["gpt-6.1-terra", "gpt-5-mini"], send, log })
    const req = { messages: [{ role: "user" as const, content: "hola" }], tools: [], jsonSchema: false, timeoutMs: 1000 }
    const first = await call(req)
    expect(first.kind).toBe("ok")
    expect((first as { model?: string }).model).toBe("gpt-5-mini")
    await call(req)
    expect(send.mock.calls.map((c) => c[0])).toEqual(["gpt-6.1-terra", "gpt-5-mini", "gpt-5-mini"])
  })
})
