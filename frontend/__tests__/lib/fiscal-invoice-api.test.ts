/**
 * factura-fiscal-imprimible (D10, task 7.3) — `fetchFiscalInvoicePdf`.
 *
 * - Pide `GET /fiscal/documents/{id}/pdf` con los encabezados de
 *   `getAuthHeaders` (nunca leyendo cookies) y devuelve el blob.
 * - Un 401 que ya navegó al login corta (devuelve null, sin error visible).
 * - Los 409/404 RFC 7807 se traducen a `FiscalInvoiceError` con su `code`
 *   estable y un mensaje en castellano; `issuer_data_incomplete` nombra lo que
 *   falta (mismas etiquetas que la configuración fiscal).
 */
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import { Blob as NodeBlob } from "node:buffer"

const { redirectedMock } = vi.hoisted(() => ({ redirectedMock: vi.fn() }))

vi.mock("@/lib/api/auth-headers", () => ({
  getAuthHeaders: vi.fn(async (extra?: Record<string, string>) => ({
    ...(extra ?? {}),
    Authorization: "Bearer tok-1",
  })),
  tokenFromHeaders: (h: Record<string, string>) => h.Authorization?.slice(7) ?? null,
  redirectedOnUnauthorized: redirectedMock,
}))

import { FiscalInvoiceError, fetchFiscalInvoicePdf } from "@/lib/api/fiscal-invoice"

/**
 * El blob que devuelve `Response.blob()` puede venir de OTRO realm que el
 * `Blob` global de jsdom (en CI, Node 20: el `Response` es el de undici y el
 * `Blob` global es el de jsdom), así que `toBeInstanceOf(Blob)` falla sin que
 * el helper esté roto. Se asserta por forma: la etiqueta `[object Blob]`, el
 * tipo `application/pdf`, el tamaño y el contenido.
 */
async function expectPdfBlob(blob: unknown, content: string): Promise<void> {
  expect(Object.prototype.toString.call(blob)).toBe("[object Blob]")
  const b = blob as Blob
  expect(b.type).toBe("application/pdf")
  expect(b.size).toBe(content.length)
  expect(await b.text()).toBe(content)
}

function problem(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/problem+json" },
  })
}

describe("fetchFiscalInvoicePdf", () => {
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

  it("pide el PDF con la sesión y devuelve el blob", async () => {
    fetchMock.mockResolvedValue(new Response("%PDF-1.4", {
      status: 200, headers: { "Content-Type": "application/pdf" },
    }))

    const blob = await fetchFiscalInvoicePdf("fd-1")

    expect(fetchMock).toHaveBeenCalledWith(
      "http://api.test/fiscal/documents/fd-1/pdf?disposition=inline&copia=original",
      { method: "GET", headers: { Authorization: "Bearer tok-1" } },
    )
    await expectPdfBlob(blob, "%PDF-1.4")
  })

  it("acepta el blob aunque venga de otro realm (el Blob de Node, como en CI)", async () => {
    fetchMock.mockResolvedValue({
      ok: true,
      status: 200,
      blob: async () => new NodeBlob(["%PDF-1.4"], { type: "application/pdf" }),
    })

    const blob = await fetchFiscalInvoicePdf("fd-1")

    await expectPdfBlob(blob, "%PDF-1.4")
  })

  it("la aserción de forma distingue un cuerpo que NO es PDF", async () => {
    const html = new NodeBlob(["<html>"], { type: "text/html" })
    await expect(expectPdfBlob(html, "<html>")).rejects.toThrow()
    await expect(expectPdfBlob("%PDF-1.4", "%PDF-1.4")).rejects.toThrow()
  })

  it("descarga del duplicado", async () => {
    fetchMock.mockResolvedValue(new Response("%PDF", { status: 200 }))

    await fetchFiscalInvoicePdf("fd-1", { disposition: "attachment", copy: "duplicado" })

    expect(fetchMock.mock.calls[0][0]).toBe(
      "http://api.test/fiscal/documents/fd-1/pdf?disposition=attachment&copia=duplicado",
    )
  })

  it("un 401 que ya navegó al login corta sin error", async () => {
    fetchMock.mockResolvedValue(new Response(null, { status: 401 }))
    redirectedMock.mockResolvedValue(true)

    await expect(fetchFiscalInvoicePdf("fd-1")).resolves.toBeNull()
    expect(redirectedMock).toHaveBeenCalledWith(expect.any(Response), "tok-1")
  })

  it("emisor incompleto: error tipado que nombra lo que falta", async () => {
    fetchMock.mockResolvedValue(problem(409, {
      code: "issuer_data_incomplete",
      detail: "Faltan datos del emisor…",
      missing: ["domicilio_comercial", "inicio_actividades"],
    }))

    const err = await fetchFiscalInvoicePdf("fd-1").catch((e: unknown) => e)

    expect(err).toBeInstanceOf(FiscalInvoiceError)
    const e = err as FiscalInvoiceError
    expect(e.code).toBe("issuer_data_incomplete")
    expect(e.missing).toEqual(["domicilio_comercial", "inicio_actividades"])
    expect(e.message).toBe(
      "Para imprimir la factura falta completar el domicilio comercial y la fecha de inicio de actividades.",
    )
  })

  it("sin fecha confirmada: mensaje de ARCA", async () => {
    fetchMock.mockResolvedValue(problem(409, { code: "invoice_date_unknown", detail: "x" }))

    const err = (await fetchFiscalInvoicePdf("fd-1").catch((e: unknown) => e)) as FiscalInvoiceError

    expect(err.code).toBe("invoice_date_unknown")
    expect(err.message).toMatch(/confirmando con ARCA la fecha/)
  })

  it("otro 409 usa el detail del servidor", async () => {
    fetchMock.mockResolvedValue(problem(409, {
      code: "invoice_lines_mismatch", detail: "El detalle no coincide con ARCA.",
    }))

    const err = (await fetchFiscalInvoicePdf("fd-1").catch((e: unknown) => e)) as FiscalInvoiceError

    expect(err.code).toBe("invoice_lines_mismatch")
    expect(err.message).toBe("El detalle no coincide con ARCA.")
  })

  it("404 o un cuerpo ilegible: error genérico con código", async () => {
    fetchMock.mockResolvedValue(new Response("<html>", { status: 404 }))

    const err = (await fetchFiscalInvoicePdf("fd-1").catch((e: unknown) => e)) as FiscalInvoiceError

    expect(err).toBeInstanceOf(FiscalInvoiceError)
    expect(err.code).toBe("http_404")
    expect(err.message).toMatch(/no se pudo obtener la factura/i)
  })
})
