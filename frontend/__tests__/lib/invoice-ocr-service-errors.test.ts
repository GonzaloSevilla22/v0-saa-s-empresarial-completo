/**
 * v31-ia-ratelimit-budget (D8, tasks 4.5/4.6): la respuesta de `functions.invoke` se mapea a un
 * `InvoiceOcrError` tipado. En supabase-js el `context` de FunctionsHttpError ES la Response
 * (functions-js 2.104: `new FunctionsHttpError(response)`); el código viejo leía
 * `context.response`, que no existe, así que el cuerpo del error nunca se leía. Se aceptan las
 * dos formas, sin `as any`.
 */
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { describe, it, expect, vi } from "vitest"

vi.mock("@/lib/supabase/client", () => ({ createClient: () => ({}) }))
vi.mock("@/lib/auth/access-token-store", () => ({ getSessionUser: vi.fn() }))

import { toInvoiceOcrError } from "@/lib/services/invoiceOcrService"
import { InvoiceOcrError } from "@/lib/invoice-types"

function httpError(status: number, body: unknown, shape: "response" | "legacy" = "response") {
  const text = typeof body === "string" ? body : JSON.stringify(body)
  const response = new Response(text, { status })
  const err = new Error("Edge Function returned a non-2xx status code") as Error & { context?: unknown }
  err.context = shape === "response" ? response : { response }
  return err
}

describe("toInvoiceOcrError", () => {
  it("429 quota_exceeded -> code, resetAt, used y limit", async () => {
    const e = await toInvoiceOcrError(
      httpError(429, { ok: false, error: "quota_exceeded", resetAt: "2026-12-01T00:00:00+00:00", used: 5, limit: 5 }),
    )
    expect(e).toBeInstanceOf(InvoiceOcrError)
    expect(e.code).toBe("quota_exceeded")
    expect(e.resetAt).toBe("2026-12-01T00:00:00+00:00")
    expect(e.used).toBe(5)
    expect(e.limit).toBe(5)
  })

  it("429 rate_limited -> retryAfterSeconds", async () => {
    const e = await toInvoiceOcrError(httpError(429, { ok: false, error: "rate_limited", retryAfterSeconds: 40 }))
    expect(e.code).toBe("rate_limited")
    expect(e.retryAfterSeconds).toBe(40)
  })

  it("413 -> image_too_large con el mensaje del servidor", async () => {
    const e = await toInvoiceOcrError(httpError(413, { ok: false, error: "La imagen supera 6 MB. Sacá la foto de nuevo o recortala." }))
    expect(e.code).toBe("image_too_large")
    expect(e.message).toMatch(/6 MB/)
  })

  it("503 quota_unavailable -> quota_unavailable", async () => {
    const e = await toInvoiceOcrError(httpError(503, { ok: false, error: "quota_unavailable" }))
    expect(e.code).toBe("quota_unavailable")
  })

  it("cualquier otro status -> other con el mensaje del body", async () => {
    const e = await toInvoiceOcrError(httpError(502, { ok: false, error: "OpenAI error 401" }))
    expect(e.code).toBe("other")
    expect(e.message).toBe("OpenAI error 401")
  })

  it("un 429 con un error desconocido NO se confunde con la cuota: other", async () => {
    const e = await toInvoiceOcrError(httpError(429, { ok: false, error: "Rate limit de OpenAI" }))
    expect(e.code).toBe("other")
    expect(e.message).toBe("Rate limit de OpenAI")
  })

  it("body que no es JSON -> other con el texto", async () => {
    const e = await toInvoiceOcrError(httpError(500, "Internal Server Error"))
    expect(e.code).toBe("other")
    expect(e.message).toBe("Internal Server Error")
  })

  it("acepta también la forma legada context.response", async () => {
    const e = await toInvoiceOcrError(httpError(429, { ok: false, error: "rate_limited", retryAfterSeconds: 12 }, "legacy"))
    expect(e.code).toBe("rate_limited")
    expect(e.retryAfterSeconds).toBe(12)
  })

  it("sin respuesta HTTP (falla de red) -> other con el mensaje del Error", async () => {
    const e = await toInvoiceOcrError(new Error("Failed to send a request to the Edge Function"))
    expect(e.code).toBe("other")
    expect(e.message).toBe("Failed to send a request to the Edge Function")
  })

  it("algo que ni siquiera es un Error -> other con el mensaje genérico", async () => {
    const e = await toInvoiceOcrError(undefined)
    expect(e.code).toBe("other")
    expect(e.message).toBe("Error en el procesamiento IA")
  })
})

describe("el servicio no usa `as any` para leer el error de la función", () => {
  it("no queda (fnErr as any) en invoiceOcrService.ts", () => {
    const src = readFileSync(join(process.cwd(), "lib/services/invoiceOcrService.ts"), "utf8")
    expect(src).not.toMatch(/fnErr as any/)
    expect(src).not.toMatch(/\bas any\b/)
  })
})

describe("InvoiceOcrError.userMessage — mensaje propio en español por código", () => {
  it("rate_limited con segundos: «Esperá 40 segundos y volvé a intentar»", () => {
    expect(new InvoiceOcrError("rate_limited", "x", { retryAfterSeconds: 40 }).userMessage).toBe("Esperá 40 segundos y volvé a intentar")
  })

  it("rate_limited con 1 segundo va en singular y sin dato cae a un texto genérico", () => {
    expect(new InvoiceOcrError("rate_limited", "x", { retryAfterSeconds: 1 }).userMessage).toBe("Esperá 1 segundo y volvé a intentar")
    expect(new InvoiceOcrError("rate_limited", "x").userMessage).toBe("Esperá unos segundos y volvé a intentar")
  })

  it("image_too_large, quota_exceeded y quota_unavailable tienen su texto", () => {
    expect(new InvoiceOcrError("image_too_large", "x").userMessage).toBe("La imagen supera 6 MB. Sacá la foto de nuevo o recortala.")
    expect(new InvoiceOcrError("quota_exceeded", "x").userMessage).toBe("Usaste todas las lecturas de factura de tu plan este mes.")
    expect(new InvoiceOcrError("quota_unavailable", "x").userMessage).toBe("No pudimos verificar tu cupo, intentá en un rato.")
  })

  it("other devuelve el mensaje del servidor", () => {
    expect(new InvoiceOcrError("other", "OpenAI error 401").userMessage).toBe("OpenAI error 401")
  })
})
