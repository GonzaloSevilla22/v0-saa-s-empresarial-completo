/**
 * remitos-compra (D11, tarea 4.6) — `lib/delivery-note-status.ts` por SENTIDO:
 * rótulos del estado (`DELIVERY_NOTE_STATUS_LABELS[direction]`), pestañas
 * De venta / De compra con su contrato `?sentido=`, `deliveryNoteListHref`, la
 * matriz estado × rol × sentido del detalle (incluido el motivo de "Compra"
 * deshabilitada por precio faltante o proveedor dado de baja) y la tabla de
 * textos por sentido. Funciones puras. Los casos de venta siguen en
 * `delivery-note-status.test.ts`, sin tocarlos más que por el índice del rótulo.
 */
import { describe, it, expect } from "vitest"
import {
  DELIVERY_NOTE_SENTIDO_TABS,
  DELIVERY_NOTE_STATUS_LABELS,
  DELIVERY_NOTE_TEXTS,
  MISSING_PRICE_CONVERT_REASON,
  SUPPLIER_DELETED_CONVERT_REASON,
  deliveryNoteActions,
  deliveryNoteHistoryLabel,
  deliveryNoteListHref,
  directionFromSentido,
  parseDeliveryNoteSentidoParam,
  type DeliveryNoteActionContext,
} from "@/lib/delivery-note-status"
import { DELIVERY_NOTE_STATUSES, type DeliveryNoteHistoryEntry } from "@/lib/delivery-note-types"

const PURCHASE_ALL: DeliveryNoteActionContext = { direction: "purchase", canDeliver: true, canSell: true, canVoid: true }
const PURCHASE_NONE: DeliveryNoteActionContext = { direction: "purchase", canDeliver: false, canSell: false, canVoid: false }

describe("DELIVERY_NOTE_STATUS_LABELS[direction]", () => {
  it("cada sentido tiene un rótulo para cada estado del catálogo", () => {
    for (const direction of ["sale", "purchase"] as const) {
      for (const status of DELIVERY_NOTE_STATUSES) {
        expect(DELIVERY_NOTE_STATUS_LABELS[direction][status]).toBeTruthy()
      }
    }
  })

  it("compra: pendiente, convertido en compra, anulado", () => {
    expect(DELIVERY_NOTE_STATUS_LABELS.purchase).toEqual({
      issued: "Pendiente",
      converted: "Convertido en compra",
      canceled: "Anulado",
    })
  })

  it("venta no cambia: pendiente, convertido en venta, anulado", () => {
    expect(DELIVERY_NOTE_STATUS_LABELS.sale).toEqual({
      issued: "Pendiente",
      converted: "Convertido en venta",
      canceled: "Anulado",
    })
  })
})

describe("pestañas De venta / De compra y contrato ?sentido=", () => {
  it("son De venta y De compra, en ese orden", () => {
    expect(DELIVERY_NOTE_SENTIDO_TABS.map((t) => t.label)).toEqual(["De venta", "De compra"])
  })

  it("cada pestaña resuelve el sentido que el servidor entiende", () => {
    expect(Object.fromEntries(DELIVERY_NOTE_SENTIDO_TABS.map((t) => [t.value, t.direction]))).toEqual({
      venta: "sale",
      compra: "purchase",
    })
  })

  it.each([
    ["compra", "compra"],
    ["venta", "venta"],
  ])("?sentido=%s preselecciona la pestaña %s", (raw, expected) => {
    expect(parseDeliveryNoteSentidoParam(raw)).toBe(expected)
  })

  it.each([null, undefined, "", "purchase", "COMPRA", "cualquiera"])(
    "un valor ausente o desconocido (%j) cae en De venta (el default firmado)",
    (raw) => {
      expect(parseDeliveryNoteSentidoParam(raw)).toBe("venta")
    },
  )

  it("directionFromSentido: compra -> purchase, venta -> sale", () => {
    expect(directionFromSentido("compra")).toBe("purchase")
    expect(directionFromSentido("venta")).toBe("sale")
  })
})

describe("deliveryNoteListHref — el regreso al listado del sentido correcto", () => {
  it("compra vuelve a la pestaña De compra: /remitos?sentido=compra", () => {
    expect(deliveryNoteListHref("purchase")).toBe("/remitos?sentido=compra")
  })

  it("venta vuelve a /remitos (el default abre De venta)", () => {
    expect(deliveryNoteListHref("sale")).toBe("/remitos")
  })

  it("la ida y la vuelta coinciden: el href de compra se lee como compra", () => {
    const sentido = new URL(deliveryNoteListHref("purchase"), "http://x").searchParams.get("sentido")
    expect(directionFromSentido(parseDeliveryNoteSentidoParam(sentido))).toBe("purchase")
  })
})

describe("deliveryNoteActions — remito de compra (matriz estado × rol)", () => {
  describe("issued", () => {
    it("recibe/edita sólo con canDeliver (CAN_RECEIVE_PURCHASE) y anula sólo con canVoid", () => {
      expect(deliveryNoteActions("issued", { ...PURCHASE_NONE, canDeliver: true }).edit).toBe(true)
      expect(deliveryNoteActions("issued", { ...PURCHASE_NONE, canVoid: true }).edit).toBe(false)
      expect(deliveryNoteActions("issued", { ...PURCHASE_NONE, canVoid: true }).cancel).toBe(true)
      expect(deliveryNoteActions("issued", { ...PURCHASE_NONE, canDeliver: true }).cancel).toBe(false)
    })

    it("compartir lo ve cualquier miembro", () => {
      expect(deliveryNoteActions("issued", PURCHASE_NONE).share).toBe(true)
    })

    it("en la tanda A 'Compra' no se muestra (conversionEnabled apagado), aunque haya permiso", () => {
      expect(deliveryNoteActions("issued", PURCHASE_ALL).convert.visible).toBe(false)
    })

    it("con la conversión habilitada, 'Compra' se muestra sólo con canSell (CAN_CONVERT_PURCHASE_DELIVERY_NOTE)", () => {
      expect(deliveryNoteActions("issued", { ...PURCHASE_ALL, conversionEnabled: true }).convert.visible).toBe(true)
      expect(deliveryNoteActions("issued", { ...PURCHASE_ALL, canSell: false, conversionEnabled: true }).convert.visible).toBe(false)
    })

    it("lista para convertir: sin motivo de deshabilitado", () => {
      const a = deliveryNoteActions("issued", { ...PURCHASE_ALL, conversionEnabled: true, missingPriceCount: 0 })
      expect(a.convert).toEqual({ visible: true, disabledReason: null })
    })

    it("con una línea sin precio, 'Compra' queda deshabilitada y dice cuántas faltan (singular)", () => {
      const a = deliveryNoteActions("issued", { ...PURCHASE_ALL, conversionEnabled: true, missingPriceCount: 1 })
      expect(a.convert.visible).toBe(true)
      expect(a.convert.disabledReason).toBe(MISSING_PRICE_CONVERT_REASON(1))
      expect(a.convert.disabledReason).toMatch(/1 línea/)
      expect(a.convert.disabledReason).toMatch(/editá el remito/i)
    })

    it("con varias líneas sin precio, el motivo va en plural", () => {
      const a = deliveryNoteActions("issued", { ...PURCHASE_ALL, conversionEnabled: true, missingPriceCount: 3 })
      expect(a.convert.disabledReason).toMatch(/3 líneas/)
    })

    it("con el proveedor dado de baja, 'Compra' queda deshabilitada con ese motivo", () => {
      const a = deliveryNoteActions("issued", { ...PURCHASE_ALL, conversionEnabled: true, supplierDeleted: true })
      expect(a.convert.disabledReason).toBe(SUPPLIER_DELETED_CONVERT_REASON)
      expect(a.convert.disabledReason).toMatch(/proveedor/i)
    })

    it("el proveedor dado de baja manda sobre el precio faltante (no se arregla cargando precios)", () => {
      const a = deliveryNoteActions("issued", {
        ...PURCHASE_ALL,
        conversionEnabled: true,
        supplierDeleted: true,
        missingPriceCount: 2,
      })
      expect(a.convert.disabledReason).toBe(SUPPLIER_DELETED_CONVERT_REASON)
    })

    it("sin permiso de conversión no hay botón y por lo tanto tampoco motivo", () => {
      const a = deliveryNoteActions("issued", {
        ...PURCHASE_ALL,
        canSell: false,
        conversionEnabled: true,
        missingPriceCount: 2,
      })
      expect(a.convert).toEqual({ visible: false, disabledReason: null })
    })

    it("no hay 'Ver compra' ni leyenda en un remito pendiente", () => {
      const a = deliveryNoteActions("issued", PURCHASE_ALL)
      expect(a.viewPurchase).toBe(false)
      expect(a.viewSale).toBe(false)
      expect(a.legend).toBeNull()
    })
  })

  describe("converted", () => {
    it("compartir y 'Ver compra' (no 'Ver venta'), sin editar ni anular", () => {
      const a = deliveryNoteActions("converted", PURCHASE_ALL)
      expect(a).toMatchObject({ share: true, edit: false, cancel: false, viewPurchase: true, viewSale: false })
      expect(a.convert.visible).toBe(false)
    })

    it("la leyenda manda a eliminar la compra, no la venta", () => {
      expect(deliveryNoteActions("converted", PURCHASE_ALL).legend).toBe(
        "Para corregirlo, eliminá la compra: el remito vuelve a quedar pendiente.",
      )
    })

    it("la leyenda de venta facturada no aplica a una compra", () => {
      expect(deliveryNoteActions("converted", { ...PURCHASE_ALL, saleInvoiced: true }).legend).toMatch(/eliminá la compra/)
    })

    it("un remito de venta convertido sigue con 'Ver venta' y sin 'Ver compra'", () => {
      const a = deliveryNoteActions("converted", { canDeliver: true, canSell: true, canVoid: true })
      expect(a.viewSale).toBe(true)
      expect(a.viewPurchase).toBe(false)
    })
  })

  describe("canceled", () => {
    it("sólo compartir (PDF con sello ANULADO)", () => {
      expect(deliveryNoteActions("canceled", PURCHASE_ALL)).toEqual({
        share: true,
        edit: false,
        convert: { visible: false, disabledReason: null },
        cancel: false,
        viewSale: false,
        viewPurchase: false,
        legend: null,
      })
    })
  })

  it("en venta el proveedor y los precios faltantes no cambian nada (retrocompatible)", () => {
    const a = deliveryNoteActions("issued", {
      canDeliver: true,
      canSell: true,
      canVoid: true,
      conversionEnabled: true,
      supplierDeleted: true,
      missingPriceCount: 4,
    })
    expect(a.convert).toEqual({ visible: true, disabledReason: null })
  })
})

describe("deliveryNoteHistoryLabel — por sentido", () => {
  const entry = (
    from: DeliveryNoteHistoryEntry["from_status"],
    to: DeliveryNoteHistoryEntry["to_status"],
  ): DeliveryNoteHistoryEntry => ({
    from_status: from,
    to_status: to,
    performed_by: "u-1",
    occurred_at: "2026-10-03T12:00:00Z",
    reason: null,
  })

  it.each([
    [null, "issued", "Recibido"],
    ["issued", "converted", "Convertido en compra"],
    ["issued", "canceled", "Anulado"],
    ["converted", "issued", "Vuelto a pendiente"],
  ] as const)("compra: la transición %s -> %s se lee '%s'", (from, to, label) => {
    expect(deliveryNoteHistoryLabel(entry(from, to), "purchase")).toBe(label)
  })

  it("venta (explícita o por defecto) conserva 'Emitido' y 'Convertido en venta'", () => {
    expect(deliveryNoteHistoryLabel(entry(null, "issued"), "sale")).toBe("Emitido")
    expect(deliveryNoteHistoryLabel(entry(null, "issued"))).toBe("Emitido")
    expect(deliveryNoteHistoryLabel(entry("issued", "converted"))).toBe("Convertido en venta")
  })
})

describe("DELIVERY_NOTE_TEXTS — la tabla de textos por sentido (D11)", () => {
  it("rótulo de la sucursal en el detalle: 'Sale de:' / 'Ingresa a:'", () => {
    expect(DELIVERY_NOTE_TEXTS.sale.branchLabel).toBe("Sale de:")
    expect(DELIVERY_NOTE_TEXTS.purchase.branchLabel).toBe("Ingresa a:")
  })

  it("aviso de anulado: 'el stock volvió a …' / 'el stock salió de …'", () => {
    expect(DELIVERY_NOTE_TEXTS.sale.canceledNotice("Centro")).toBe("Remito anulado: el stock volvió a Centro.")
    expect(DELIVERY_NOTE_TEXTS.purchase.canceledNotice("Centro")).toBe("Remito anulado: el stock salió de Centro.")
  })

  it("aviso de convertido: venta (stock ya descontado) / compra (stock ya sumado)", () => {
    expect(DELIVERY_NOTE_TEXTS.sale.convertedNotice).toBe(
      "Este remito se convirtió en una venta. El stock ya se había descontado al emitirlo.",
    )
    expect(DELIVERY_NOTE_TEXTS.purchase.convertedNotice).toBe(
      "Este remito se convirtió en una compra; el stock ya se había sumado al recibirlo.",
    )
  })

  it("toast de anulación", () => {
    expect(DELIVERY_NOTE_TEXTS.sale.cancelToast("R-00000012", "Centro")).toBe(
      "Remito R-00000012 anulado: el stock volvió a Centro",
    )
    expect(DELIVERY_NOTE_TEXTS.purchase.cancelToast("RC-00000012", "Centro")).toBe(
      "Remito RC-00000012 anulado: el stock salió de Centro",
    )
  })

  it("placeholder del motivo de anulación", () => {
    expect(DELIVERY_NOTE_TEXTS.sale.cancelReasonPlaceholder).toBe("Ej: el cliente devolvió la mercadería")
    expect(DELIVERY_NOTE_TEXTS.purchase.cancelReasonPlaceholder).toBe("Ej.: el proveedor se llevó la mercadería")
  })

  it("rótulos de las acciones de conversión: Venta / Compra y Ver venta / Ver compra", () => {
    expect(DELIVERY_NOTE_TEXTS.sale.convertLabel).toBe("Venta")
    expect(DELIVERY_NOTE_TEXTS.purchase.convertLabel).toBe("Compra")
    expect(DELIVERY_NOTE_TEXTS.sale.viewOperationLabel).toBe("Ver venta")
    expect(DELIVERY_NOTE_TEXTS.purchase.viewOperationLabel).toBe("Ver compra")
  })

  describe("DeactivateBranchDialog: remitos pendientes que ...", () => {
    it("venta, singular y plural: 'retiene(n) mercadería de esta sucursal'", () => {
      const one = DELIVERY_NOTE_TEXTS.sale.pendingBranchNotes(1)
      expect(one.noun).toBe("remito pendiente que retiene")
      expect(one.tail).toMatch(/^mercadería de esta sucursal/)
      expect(DELIVERY_NOTE_TEXTS.sale.pendingBranchNotes(3).noun).toBe("remitos pendientes que retienen")
      expect(one.advice).toBe("Convertilos en venta o anulalos (un administrador o el dueño) y volvé a intentarlo.")
      expect(one.linkLabel).toBe("Ver remitos pendientes")
    })

    it("compra, singular y plural: 'aportó/aportaron stock a esta sucursal'", () => {
      const one = DELIVERY_NOTE_TEXTS.purchase.pendingBranchNotes(1)
      expect(one.noun).toBe("remito de compra pendiente que aportó")
      expect(one.tail).toMatch(/^stock a esta sucursal/)
      expect(DELIVERY_NOTE_TEXTS.purchase.pendingBranchNotes(2).noun).toBe("remitos de compra pendientes que aportaron")
      expect(one.advice).toBe("Convertilos en compra o anulalos (un administrador o el dueño) y volvé a intentarlo.")
      expect(one.linkLabel).toBe("Ver remitos de compra pendientes")
    })

    it("los dos sentidos avisan que no se puede desactivar mientras haya alguno", () => {
      for (const direction of ["sale", "purchase"] as const) {
        expect(DELIVERY_NOTE_TEXTS[direction].pendingBranchNotes(2).tail).toMatch(/No se puede desactivar mientras haya alguno\.$/)
      }
    })
  })
})
