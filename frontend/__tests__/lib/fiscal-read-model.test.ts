/**
 * factura-fiscal-imprimible (D10, tasks 6.1/6.3) — un solo mapeo del estado
 * fiscal que devuelven `/sales` y `/sales-orders` (mismos nombres de campos),
 * con el CAE, su vencimiento y el tipo de comprobante.
 */
import { describe, it, expect } from "vitest"

import { mapFiscalState } from "@/lib/fiscal-comprobante"

const autorizado = {
  fiscal_document_id: "fd-1",
  fiscal_document_status: "authorized",
  fiscal_punto_de_venta: 3,
  fiscal_number: 501,
  fiscal_cae: "71234567890123",
  fiscal_cae_due_date: "2026-10-05",
  fiscal_comprobante_type: "factura_c",
  fiscal_frozen: false,
}

describe("mapFiscalState", () => {
  it("mapea el comprobante autorizado con su CAE", () => {
    expect(mapFiscalState(autorizado)).toEqual({
      documentId: "fd-1",
      status: "authorized",
      label: "0003-00000501",
      submittedToArca: false,
      frozen: false,
      voidable: false,
      cae: "71234567890123",
      caeDueDate: "2026-10-05",
      comprobanteType: "factura_c",
    })
  })

  it("sin comprobante devuelve null", () => {
    expect(mapFiscalState({ fiscal_document_id: null })).toBeNull()
    expect(mapFiscalState({})).toBeNull()
  })

  it("un estado desconocido cae en pending_cae (no ofrece acciones)", () => {
    expect(mapFiscalState({ ...autorizado, fiscal_document_status: "raro" })?.status).toBe("pending_cae")
  })

  it("un pendiente no trae CAE", () => {
    const state = mapFiscalState({
      fiscal_document_id: "fd-2",
      fiscal_document_status: "pending_cae",
      fiscal_punto_de_venta: 3,
      fiscal_number: 502,
      fiscal_submitted_to_arca: true,
      fiscal_pending_voidable: false,
    })
    expect(state).toMatchObject({ status: "pending_cae", submittedToArca: true, cae: null, caeDueDate: null })
  })

  it("una fecha con hora se recorta al día", () => {
    expect(mapFiscalState({ ...autorizado, fiscal_cae_due_date: "2026-10-05T00:00:00" })?.caeDueDate).toBe(
      "2026-10-05",
    )
  })
})
