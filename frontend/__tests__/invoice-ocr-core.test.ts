/**
 * auth-hardening-jwt-cookies Parte A (grupo 7, D13) — núcleo puro de la Edge
 * Function invoice-ocr: supabase/functions/_shared/invoice-ocr-core.ts.
 *
 * Por qué el test vive acá y no bajo supabase/functions/: este repo NO tiene
 * arnés de Deno (cero archivos de test bajo supabase/functions/, cero pasos
 * `deno` en .github/workflows/). El molde real es vitest importando un núcleo
 * puro de `_shared/` por ruta relativa — precedente exacto:
 * frontend/__tests__/ai-estadisticas.test.ts → _shared/ai-estadisticas-core.ts.
 *
 * Lo que fija este archivo (D13):
 * - El objeto que se descarga con SERVICE_ROLE sale de la FILA ya autorizada,
 *   nunca del body. Hoy se autoriza `document_id` contra `user_id` y después
 *   se descarga el `storage_path` que mandó el cliente: confused deputy.
 * - El campo del body se sigue ACEPTANDO por compatibilidad (el caller vivo,
 *   frontend/lib/services/invoiceOcrService.ts:117-119, lo sigue mandando)
 *   pero no tiene NINGÚN efecto sobre qué se descarga.
 * - Fail-closed: una fila sin `storage_path` no cae de vuelta al body.
 *
 * Run: pnpm vitest run __tests__/invoice-ocr-core.test.ts
 */

import { describe, it, expect } from "vitest"
import {
  parseInvoiceOcrRequest,
  resolveInvoiceDownload,
  type InvoiceDocumentRow,
} from "../../supabase/functions/_shared/invoice-ocr-core"

const ROW_PATH = "11111111-1111-4111-8111-111111111111/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa.jpg"
const OTHER_PATH = "22222222-2222-4222-8222-222222222222/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb.jpg"

function row(overrides: Partial<InvoiceDocumentRow> = {}): InvoiceDocumentRow {
  return {
    id: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
    mime_type: "image/jpeg",
    status: "pending",
    storage_path: ROW_PATH,
    ...overrides,
  }
}

describe("resolveInvoiceDownload — el objeto a descargar sale de la fila, no del body", () => {
  it("con un storage_path del body DISTINTO del de la fila, descarga el de la FILA", () => {
    const decision = resolveInvoiceDownload(row(), { document_id: "dddddddd-dddd-4ddd-8ddd-dddddddddddd", storage_path: OTHER_PATH })

    expect(decision.ok).toBe(true)
    if (!decision.ok) return
    expect(decision.storagePath).toBe(ROW_PATH)
    expect(decision.storagePath).not.toBe(OTHER_PATH)
  })

  it("el body no puede elegir el objeto: con cuatro bodies hostiles distintos el resultado es siempre el de la fila", () => {
    const hostiles = [
      { storage_path: OTHER_PATH },
      { storage_path: "../otro-tenant/factura.jpg" },
      { storage_path: "" },
      {},
    ]

    for (const body of hostiles) {
      const decision = resolveInvoiceDownload(row(), { document_id: "d", ...body })
      expect(decision.ok).toBe(true)
      if (!decision.ok) continue
      expect(decision.storagePath).toBe(ROW_PATH)
    }
  })

  it("una fila sin storage_path falla cerrada: NO cae de vuelta al valor del body", () => {
    const decision = resolveInvoiceDownload(row({ storage_path: null }), { document_id: "d", storage_path: OTHER_PATH })

    expect(decision).toEqual({ ok: false, status: 404, error: "Documento no encontrado" })
  })

  it("una fila inexistente (el SELECT filtrado por user_id no la trajo) es 404, no una descarga", () => {
    expect(resolveInvoiceDownload(null, { document_id: "d", storage_path: OTHER_PATH })).toEqual({
      ok: false,
      status: 404,
      error: "Documento no encontrado",
    })
  })

  it("un documento ya procesado es 409 y no resuelve ningún objeto", () => {
    const decision = resolveInvoiceDownload(row({ status: "completed" }), { document_id: "d" })

    expect(decision).toEqual({ ok: false, status: 409, error: "Documento ya fue procesado" })
  })

  it("el mime_type viaja desde la fila, con el default histórico cuando la fila no lo trae", () => {
    const conMime = resolveInvoiceDownload(row({ mime_type: "image/png" }), { document_id: "d" })
    const sinMime = resolveInvoiceDownload(row({ mime_type: null }), { document_id: "d" })

    expect(conMime.ok && conMime.mimeType).toBe("image/png")
    expect(sinMime.ok && sinMime.mimeType).toBe("image/jpeg")
  })
})

describe("parseInvoiceOcrRequest — el campo del body se acepta, pero deja de ser la fuente", () => {
  it("sin document_id es 400 con el texto histórico", () => {
    expect(parseInvoiceOcrRequest({ storage_path: ROW_PATH })).toEqual({
      ok: false,
      status: 400,
      error: "Falta document_id",
    })
    expect(parseInvoiceOcrRequest({ document_id: "   " })).toEqual({
      ok: false,
      status: 400,
      error: "Falta document_id",
    })
    expect(parseInvoiceOcrRequest(null)).toEqual({ ok: false, status: 400, error: "Falta document_id" })
  })

  it("el caller vivo (document_id + storage_path) sigue siendo aceptado sin cambios", () => {
    const parsed = parseInvoiceOcrRequest({ document_id: "dddddddd-dddd-4ddd-8ddd-dddddddddddd", storage_path: ROW_PATH })

    expect(parsed).toEqual({ ok: true, documentId: "dddddddd-dddd-4ddd-8ddd-dddddddddddd" })
  })

  it("un caller futuro que ya NO manda storage_path también es aceptado (el campo dejó de ser requerido porque dejó de usarse)", () => {
    expect(parseInvoiceOcrRequest({ document_id: "dddddddd-dddd-4ddd-8ddd-dddddddddddd" })).toEqual({
      ok: true,
      documentId: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
    })
  })

  it("el resultado del parseo no expone ningún storage_path: no hay forma de que el handler lo use por accidente", () => {
    const parsed = parseInvoiceOcrRequest({ document_id: "d", storage_path: OTHER_PATH })

    expect(parsed.ok).toBe(true)
    expect(JSON.stringify(parsed)).not.toContain(OTHER_PATH)
    expect(Object.keys(parsed)).not.toContain("storagePath")
    expect(Object.keys(parsed)).not.toContain("storage_path")
  })
})
