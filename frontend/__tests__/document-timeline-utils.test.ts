/**
 * v3-document-status-history — utils puras del DocumentTimeline (task 6.2).
 * TDD: estas funciones concentran la lógica presentacional testeable del
 * Server Component (labels es-AR, actor "Sistema" para el relay, orden).
 */
import { describe, expect, it } from "vitest"

import {
  SYSTEM_ACTOR_UUID,
  describeTransition,
  formatTimelineActor,
  getStatusLabel,
  sortTimelineEntries,
} from "@/lib/document-timeline-utils"
import type { DocumentStatusHistoryEntry } from "@/lib/types"

function entry(overrides: Partial<DocumentStatusHistoryEntry>): DocumentStatusHistoryEntry {
  return {
    id: "e1",
    accountId: "acc-1",
    documentType: "sales_order",
    documentId: "doc-1",
    fromStatus: "draft",
    toStatus: "confirmed",
    performedBy: "9f8b1c2d-0000-4000-8000-123456789abc",
    reason: null,
    occurredAt: "2026-07-03T12:00:00Z",
    ...overrides,
  }
}

describe("formatTimelineActor", () => {
  it("muestra 'Sistema' para el uuid cero (relay CAE)", () => {
    expect(formatTimelineActor(SYSTEM_ACTOR_UUID)).toBe("Sistema")
  })

  it("abrevia el uuid de un usuario real", () => {
    expect(formatTimelineActor("9f8b1c2d-0000-4000-8000-123456789abc")).toBe("9f8b1c2d…")
  })
})

describe("getStatusLabel", () => {
  it("traduce estados conocidos por tipo de documento", () => {
    expect(getStatusLabel("sales_order", "confirmed")).toBe("Confirmada")
    expect(getStatusLabel("fiscal_document", "pending_cae")).toBe("CAE pendiente")
    expect(getStatusLabel("cash_session", "open")).toBe("Abierta")
  })

  it("devuelve el estado crudo cuando no hay label", () => {
    expect(getStatusLabel("quote", "estado_desconocido")).toBe("estado_desconocido")
  })
})

describe("describeTransition", () => {
  it("describe la creación (from_status NULL — RN-A2)", () => {
    const created = entry({ fromStatus: null, toStatus: "draft", documentType: "quote" })
    expect(describeTransition(created)).toBe("Creado como Borrador")
  })

  it("describe una transición entre estados", () => {
    expect(describeTransition(entry({}))).toBe("Borrador → Confirmada")
  })
})

describe("sortTimelineEntries", () => {
  it("ordena ascendente por occurredAt sin mutar el input", () => {
    const a = entry({ id: "a", occurredAt: "2026-07-03T10:00:00Z" })
    const b = entry({ id: "b", occurredAt: "2026-07-01T10:00:00Z" })
    const c = entry({ id: "c", occurredAt: "2026-07-02T10:00:00Z" })
    const input = [a, b, c]

    const sorted = sortTimelineEntries(input)

    expect(sorted.map((e) => e.id)).toEqual(["b", "c", "a"])
    expect(input.map((e) => e.id)).toEqual(["a", "b", "c"])
  })

  it("preserva el orden de empates (estable)", () => {
    const a = entry({ id: "a", occurredAt: "2026-07-01T10:00:00Z" })
    const b = entry({ id: "b", occurredAt: "2026-07-01T10:00:00Z" })
    expect(sortTimelineEntries([a, b]).map((e) => e.id)).toEqual(["a", "b"])
  })
})
