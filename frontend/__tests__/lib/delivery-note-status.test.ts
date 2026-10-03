/**
 * remitos-venta (D3/D11, tarea 4.3) — `lib/delivery-note-status.ts`: rótulos del
 * estado, pestañas del listado con el contrato de URL `?estado=` y la matriz
 * estado × rol de las acciones del detalle. Funciones puras.
 */
import { describe, it, expect } from "vitest"
import {
  DELIVERY_NOTE_ESTADO_TABS,
  DELIVERY_NOTE_STATUS_LABELS,
  canceledReason,
  deliveryNoteHistoryLabel,
  deliveryNoteActions,
  parseDeliveryNoteEstadoParam,
  type DeliveryNoteActionContext,
} from "@/lib/delivery-note-status"
import { DELIVERY_NOTE_STATUSES, type DeliveryNoteHistoryEntry } from "@/lib/delivery-note-types"

const ALL_ROLES: DeliveryNoteActionContext = { canDeliver: true, canSell: true, canVoid: true }
const NO_ROLES: DeliveryNoteActionContext = { canDeliver: false, canSell: false, canVoid: false }

describe("DELIVERY_NOTE_STATUS_LABELS", () => {
  it("tiene un rótulo para cada estado del catálogo", () => {
    for (const status of DELIVERY_NOTE_STATUSES) {
      expect(DELIVERY_NOTE_STATUS_LABELS[status]).toBeTruthy()
    }
  })

  it("nombra el estado como lo ve el usuario: pendiente, convertido en venta, anulado", () => {
    expect(DELIVERY_NOTE_STATUS_LABELS.issued).toBe("Pendiente")
    expect(DELIVERY_NOTE_STATUS_LABELS.converted).toBe("Convertido en venta")
    expect(DELIVERY_NOTE_STATUS_LABELS.canceled).toBe("Anulado")
  })
})

describe("pestañas del listado y contrato ?estado=", () => {
  it("son Todos, Pendientes, Convertidos y Anulados, sin pestañas de sentido (OQ-RV6)", () => {
    expect(DELIVERY_NOTE_ESTADO_TABS.map((t) => t.label)).toEqual(["Todos", "Pendientes", "Convertidos", "Anulados"])
  })

  it("cada pestaña resuelve el filtro de estado del servidor (todos = sin filtro)", () => {
    const byValue = Object.fromEntries(DELIVERY_NOTE_ESTADO_TABS.map((t) => [t.value, t.status]))
    expect(byValue).toEqual({
      todos: undefined,
      pendientes: "issued",
      convertidos: "converted",
      anulados: "canceled",
    })
  })

  it.each([
    ["pendientes", "pendientes"],
    ["convertidos", "convertidos"],
    ["anulados", "anulados"],
    ["todos", "todos"],
  ])("?estado=%s preselecciona la pestaña %s", (raw, expected) => {
    expect(parseDeliveryNoteEstadoParam(raw)).toBe(expected)
  })

  it.each([null, undefined, "", "issued", "PENDIENTES", "cualquiera"])(
    "un valor ausente o desconocido (%j) cae en Todos",
    (raw) => {
      expect(parseDeliveryNoteEstadoParam(raw)).toBe("todos")
    },
  )
})

describe("deliveryNoteActions — matriz estado × rol (D11)", () => {
  describe("issued", () => {
    it("con todos los roles: compartir, editar, anular; la venta NO se muestra en la tanda A", () => {
      const a = deliveryNoteActions("issued", ALL_ROLES)
      expect(a.share).toBe(true)
      expect(a.edit).toBe(true)
      expect(a.cancel).toBe(true)
      expect(a.convert.visible).toBe(false)
      expect(a.viewSale).toBe(false)
    })

    it("editar sigue a CAN_DELIVER_SALE: el rol que sólo anula no edita", () => {
      expect(deliveryNoteActions("issued", { ...NO_ROLES, canVoid: true }).edit).toBe(false)
      expect(deliveryNoteActions("issued", { ...NO_ROLES, canDeliver: true }).edit).toBe(true)
    })

    it("anular sigue a CAN_VOID_DELIVERY_NOTE: el rol stock emite y edita pero no anula", () => {
      const a = deliveryNoteActions("issued", { ...NO_ROLES, canDeliver: true })
      expect(a.edit).toBe(true)
      expect(a.cancel).toBe(false)
    })

    it("compartir es de cualquier miembro, incluso sin ningún rol de remito", () => {
      expect(deliveryNoteActions("issued", NO_ROLES).share).toBe(true)
    })

    it("tanda B: con la conversión habilitada, 'Venta' sigue a CAN_SELL", () => {
      expect(deliveryNoteActions("issued", { ...NO_ROLES, canSell: true, conversionEnabled: true }).convert.visible).toBe(true)
      expect(deliveryNoteActions("issued", { ...NO_ROLES, canSell: false, conversionEnabled: true }).convert.visible).toBe(false)
    })

    it("tanda B: con el cliente dado de baja, 'Venta' queda deshabilitado con el motivo de D11", () => {
      const a = deliveryNoteActions("issued", { ...ALL_ROLES, conversionEnabled: true, clientDeleted: true })
      expect(a.convert.visible).toBe(true)
      expect(a.convert.disabledReason).toBe(
        "El cliente fue dado de baja: editá el remito y elegí uno vigente",
      )
    })

    it("con el cliente vigente 'Venta' no tiene motivo de bloqueo", () => {
      const a = deliveryNoteActions("issued", { ...ALL_ROLES, conversionEnabled: true })
      expect(a.convert.disabledReason).toBeNull()
    })
  })

  describe("converted", () => {
    it("compartir y ver la venta; no se edita ni se anula", () => {
      const a = deliveryNoteActions("converted", ALL_ROLES)
      expect(a.share).toBe(true)
      expect(a.viewSale).toBe(true)
      expect(a.edit).toBe(false)
      expect(a.cancel).toBe(false)
      expect(a.convert.visible).toBe(false)
    })

    it("la leyenda explica cómo corregirlo: eliminar la venta reabre el remito", () => {
      expect(deliveryNoteActions("converted", ALL_ROLES).legend).toBe(
        "Para corregirlo, eliminá la venta: el remito vuelve a quedar pendiente.",
      )
    })

    it("con la venta ya facturada la leyenda pasa a la nota de crédito (D9)", () => {
      expect(deliveryNoteActions("converted", { ...ALL_ROLES, saleInvoiced: true }).legend).toBe(
        "La venta ya está facturada: para devolver mercadería se necesita una nota de crédito.",
      )
    })
  })

  describe("canceled", () => {
    it("sólo se comparte (PDF con sello ANULADO); sin acciones de escritura ni leyenda de venta", () => {
      const a = deliveryNoteActions("canceled", ALL_ROLES)
      expect(a.share).toBe(true)
      expect(a.edit).toBe(false)
      expect(a.cancel).toBe(false)
      expect(a.convert.visible).toBe(false)
      expect(a.viewSale).toBe(false)
      expect(a.legend).toBeNull()
    })
  })

  it("un remito pendiente no lleva leyenda", () => {
    expect(deliveryNoteActions("issued", ALL_ROLES).legend).toBeNull()
  })
})

describe("canceledReason", () => {
  const entry = (overrides: Partial<DeliveryNoteHistoryEntry>): DeliveryNoteHistoryEntry => ({
    from_status: null,
    to_status: "issued",
    performed_by: "u-1",
    occurred_at: "2026-10-02T12:00:00Z",
    reason: null,
    ...overrides,
  })

  it("devuelve el motivo de la transición a anulado", () => {
    expect(
      canceledReason([entry({}), entry({ from_status: "issued", to_status: "canceled", reason: "Cliente devolvió todo" })]),
    ).toBe("Cliente devolvió todo")
  })

  it("sin transición a anulado, o sin motivo, no inventa uno", () => {
    expect(canceledReason([])).toBeNull()
    expect(canceledReason([entry({})])).toBeNull()
    expect(canceledReason([entry({ from_status: "issued", to_status: "canceled", reason: null })])).toBeNull()
    expect(canceledReason([entry({ from_status: "issued", to_status: "canceled", reason: "   " })])).toBeNull()
  })

  it("ignora el motivo de otras transiciones", () => {
    expect(canceledReason([entry({ from_status: "converted", to_status: "issued", reason: "se eliminó la venta" })])).toBeNull()
  })

  it("si hubiera más de una, toma la más reciente", () => {
    expect(
      canceledReason([
        entry({ to_status: "canceled", reason: "vieja", occurred_at: "2026-10-02T10:00:00Z" }),
        entry({ to_status: "canceled", reason: "nueva", occurred_at: "2026-10-02T11:00:00Z" }),
      ]),
    ).toBe("nueva")
  })
})

describe("deliveryNoteHistoryLabel", () => {
  const entry = (from: DeliveryNoteHistoryEntry["from_status"], to: DeliveryNoteHistoryEntry["to_status"]): DeliveryNoteHistoryEntry => ({
    from_status: from,
    to_status: to,
    performed_by: "u-1",
    occurred_at: "2026-10-02T12:00:00Z",
    reason: null,
  })

  it.each([
    [null, "issued", "Emitido"],
    ["issued", "converted", "Convertido en venta"],
    ["issued", "canceled", "Anulado"],
    ["converted", "issued", "Vuelto a pendiente"],
  ] as const)("la transición %s -> %s se lee '%s'", (from, to, label) => {
    expect(deliveryNoteHistoryLabel(entry(from, to))).toBe(label)
  })

  it("una transición no prevista cae al rótulo del estado de destino", () => {
    expect(deliveryNoteHistoryLabel(entry("canceled", "canceled"))).toBe("Anulado")
  })
})
