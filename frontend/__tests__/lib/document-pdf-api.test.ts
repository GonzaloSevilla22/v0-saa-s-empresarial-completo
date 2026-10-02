/**
 * presupuestos-modulo (D9, task 4.1) — `fetchDocumentPdf`: el fetch binario con
 * sesión y manejo de 401 / RFC 7807, extraído de `lib/api/fiscal-invoice.ts` a
 * la capa canónica para que el presupuesto (y luego los remitos) lo reutilicen.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"

const { redirectedMock } = vi.hoisted(() => ({ redirectedMock: vi.fn() }))

vi.mock("@/lib/api/auth-headers", () => ({
  getAuthHeaders: vi.fn(async (extra?: Record<string, string>) => ({
    ...(extra ?? {}),
    Authorization: "Bearer tok-1",
  })),
  tokenFromHeaders: (h: Record<string, string>) => h.Authorization?.slice(7) ?? null,
  redirectedOnUnauthorized: redirectedMock,
}))

import { DocumentPdfError, fetchDocumentPdf } from "@/lib/api/document-pdf"

function problem(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/problem+json" },
  })
}

describe("fetchDocumentPdf", () => {
  const fetchMock = vi.fn()

  beforeEach(() => {
    vi.stubEnv("NEXT_PUBLIC_BACKEND_URL", "http://api.test")
    vi.stubGlobal("fetch", fetchMock)
    fetchMock.mockReset()
    redirectedMock.mockReset()
    redirectedMock.mockResolvedValue(false)
  })
  afterEach(() => {
    vi.unstubAllEnvs()
    vi.unstubAllGlobals()
  })

  it("200 -> el Blob del PDF, pedido con la sesión y los parámetros en orden", async () => {
    fetchMock.mockResolvedValue(new Response("%PDF-1.4", {
      status: 200, headers: { "Content-Type": "application/pdf" },
    }))

    const blob = await fetchDocumentPdf("/quotes/q-1/pdf", { disposition: "attachment" })

    expect(fetchMock).toHaveBeenCalledWith(
      "http://api.test/quotes/q-1/pdf?disposition=attachment",
      { method: "GET", headers: { Authorization: "Bearer tok-1" } },
    )
    expect(Object.prototype.toString.call(blob)).toBe("[object Blob]")
    expect(await (blob as Blob).text()).toBe("%PDF-1.4")
  })

  it("sin parámetros no agrega '?' a la URL", async () => {
    fetchMock.mockResolvedValue(new Response("%PDF", { status: 200 }))
    await fetchDocumentPdf("/quotes/q-1/pdf")
    expect(fetchMock.mock.calls[0][0]).toBe("http://api.test/quotes/q-1/pdf")
  })

  it("401 que ya navegó al login -> null, sin error", async () => {
    redirectedMock.mockResolvedValue(true)
    fetchMock.mockResolvedValue(new Response("", { status: 401 }))
    await expect(fetchDocumentPdf("/quotes/q-1/pdf")).resolves.toBeNull()
  })

  it("RFC 7807 -> DocumentPdfError con el code estable y el detalle", async () => {
    fetchMock.mockResolvedValue(problem(404, { code: "quote_not_found", detail: "Presupuesto no encontrado." }))
    const err = await fetchDocumentPdf("/quotes/q-1/pdf").catch((e: unknown) => e)
    expect(err).toBeInstanceOf(DocumentPdfError)
    const e = err as DocumentPdfError
    expect(e.code).toBe("quote_not_found")
    expect(e.message).toBe("Presupuesto no encontrado.")
    expect(e.status).toBe(404)
  })

  it("otro RFC 7807 distinto conserva su propio code (no queda fijo)", async () => {
    fetchMock.mockResolvedValue(problem(422, { code: "validation_error", detail: "disposition inválido" }))
    const e = (await fetchDocumentPdf("/quotes/q-1/pdf").catch((x: unknown) => x)) as DocumentPdfError
    expect(e.code).toBe("validation_error")
    expect(e.message).toBe("disposition inválido")
  })

  it("respuesta sin cuerpo problem -> code http_<status> y mensaje genérico", async () => {
    fetchMock.mockResolvedValue(new Response("boom", { status: 502 }))
    const e = (await fetchDocumentPdf("/quotes/q-1/pdf").catch((x: unknown) => x)) as DocumentPdfError
    expect(e).toBeInstanceOf(DocumentPdfError)
    expect(e.code).toBe("http_502")
    expect(e.message).toBe("No se pudo obtener el documento. Probá de nuevo.")
  })

  it("expone el cuerpo problem crudo para que el dominio lo interprete (p. ej. 'missing')", async () => {
    fetchMock.mockResolvedValue(problem(409, { code: "issuer_data_incomplete", missing: ["cuit"] }))
    const e = (await fetchDocumentPdf("/fiscal/documents/x/pdf").catch((x: unknown) => x)) as DocumentPdfError
    expect(e.problem).toEqual({ code: "issuer_data_incomplete", missing: ["cuit"] })
  })
})
