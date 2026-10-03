/**
 * Traducción de errores de las RPCs de operaciones (venta/compra) a mensajes
 * que le sirvan al usuario.
 *
 * Origen (2026-08-24): el PO no podía vender y el mensaje era
 * `Insufficient stock for product 0dd2e5bb-2b93-4470-b4b6-52f008046112`.
 * Dos problemas: el UUID no le dice nada a nadie, y "no hay stock" es
 * literalmente falso — el producto TENÍA stock, pero en otra sucursal (la
 * venta descuenta de la sucursal de la operación, no del total del catálogo).
 * El mensaje mandaba a revisar el inventario, que era justo donde NO estaba
 * el problema.
 *
 * sucursal-guard-vaciado-auditoria (G3, task 7.4): el aviso ya explicaba que
 * podía haber unidades en otra sucursal, pero dejaba al usuario buscando
 * dónde se transfiere. `humanizeOperationError` pasa a devolver, además del
 * texto, una acción opcional (etiqueta + destino) hacia la transferencia del
 * producto involucrado — CAMBIO DE CONTRATO (string -> objeto). Se migran
 * los dos call sites existentes en el mismo PR (regla del proyecto: al
 * endurecer un contrato, migrar TODOS los callers) — sale-form.tsx era el
 * único consumidor.
 *
 * candidato "POS sin wirear a operation-errors" (origen: sucursal-guard-
 * vaciado-auditoria G3): el POS (/ventas/pos) tenía su propio friendlyError
 * duplicado y jamás mostraba ni el nombre del producto ni la acción de
 * transferir, porque la RPC que respalda el quick-sale (`_c29_confirm_order_
 * core`, vía `rpc_quick_sale`) usa un vocabulario de error DISTINTO al de
 * `rpc_create_sale_operation_v2` (sale-form): `stock_insuficiente para
 * producto <uuid>: disponible X, solicitado Y` en vez de `Insufficient stock
 * for product <uuid>`. Mismo caso, dos redacciones — `STOCK_ERROR` extiende
 * el regex para reconocer ambas en vez de que el POS reinvente su propio
 * mapeo (regla "reutilización antes que repetición").
 */

/** Devuelve el nombre del producto, o undefined si no se lo puede resolver. */
export type ProductNameLookup = (productId: string) => string | undefined

export interface OperationErrorAction {
  label: string
  /** Ruta a la que navegar — /stock con el producto preseleccionado. */
  href: string
}

export interface HumanizedOperationError {
  message: string
  /** Presente sólo cuando el error reconocido tiene una acción que lo destraba. */
  action?: OperationErrorAction
}

const STOCK_ERROR =
  /(?:insufficient_branch_stock|Insufficient stock) for product\s+([0-9a-f-]{36})|stock_insuficiente para producto\s+([0-9a-f-]{36})/i

// qa-integral-modulos G10 (H21a): tres details crudos que el QA vio impresos
// tal cual al usuario — mismo mapa, sin crear otro (regla del proyecto).
const RN_B4_ERROR = /RN-B4: el producto "([^"]+)" tiene stock \(([\d.]+)\)/i
const AMOUNTS_MISMATCH_ERROR =
  /amounts_mismatch(?::\s*Σ líneas \((-?[\d.]+)\) ≠ Σ movimientos \((-?[\d.]+)\))?/
const PERIODO_INVALIDO_ERROR = /periodo_invalido/

// cobranzas-reverso (task 11.4): errores propios de la anulación de un
// cobro/pago. no_open_session_for_reversal (P0426) y payment_not_found
// (P0404) los emiten las RPCs de reverso; journal_entry_original_not_found
// (P0451) sólo puede llegar al usuario si el consumidor contable corre
// SINCRÓNICO con el request (hoy no es el caso — es async por outbox), pero
// se mapea igual por consistencia con el resto del vocabulario de errores
// de la casa y por si un camino futuro lo expone.
const NO_OPEN_SESSION_FOR_REVERSAL_ERROR = /no_open_session_for_reversal/
const PAYMENT_NOT_FOUND_ERROR = /payment_not_found/
const JOURNAL_ENTRY_ORIGINAL_NOT_FOUND_ERROR = /journal_entry_original_not_found/

// operacion-party-guard (fix ad-hoc 2026-09-10): rpc_create_sale_operation_v2,
// _c29_confirm_order_core (formulario y POS) y rpc_atomic_update_sale_operation
// (edición) rechazan con `client_not_found: <uuid>` un client_id que no
// pertenece a la cuenta — mismo literal que ya usaban las RPCs de cuenta
// corriente (P0404). rpc_create_purchase_operation usa el espejo
// `supplier_not_found: <uuid>` (D6 de compras-proveedor-cuenta-corriente,
// 2026-08-23) — ninguno de los dos tenía traducción propia hasta este fix, así
// que el usuario veía el UUID crudo.
const CLIENT_NOT_FOUND_ERROR = /client_not_found/
const SUPPLIER_NOT_FOUND_ERROR = /supplier_not_found/

// ventas-formulario-sucursal (ronda 1 de revisión): desde que el alta del
// formulario entrega la sucursal elegida a la RPC, los rechazos por sucursal
// son alcanzables. El selector (useBranches) lista `is_active = true`, y una
// sucursal CERRADA (rpc_close_branch: status = 'closed', is_active intacto)
// sigue apareciendo ahí. Tres literales vivos:
//   - `branch_closed: …` (P0422) — alta (rpc_create_sale_operation_v2) y
//     borrado/reverso de stock (rpc_apply_product_stock_delta);
//   - `branch_not_found or not active for this account` (P0404) — alta con una
//     sucursal ajena o desactivada (p.ej. el caché del selector quedó viejo);
//   - `branch_invalid: …` (P0422) — edición (rpc_atomic_update_sale_operation)
//     con la sucursal ya cerrada o desactivada.
// `no_branch_found` (POS: la cuenta no tiene NINGUNA sucursal activa) es otra
// cosa y NO lo atrapa BRANCH_NOT_FOUND — sigue en el friendlyError del POS.
// Sin acción (botón): reabrir una sucursal es una decisión de administración,
// no un paso más del alta; el texto nombra la salida.
const BRANCH_CLOSED_ERROR = /branch_closed/
const BRANCH_NOT_FOUND_ERROR = /branch_not_found/
const BRANCH_INVALID_ERROR = /branch_invalid/

// ventas-unidades-conversion (D1/D3): los tres tokens P0400 que emite
// _uom_normalize_quantity, la ÚNICA definición de "cantidad de una línea en la
// unidad en que se lleva el stock del producto", consumida por los cinco
// caminos (formulario, POS, edición de venta, alta y edición de compra). El
// selector ya sólo ofrece unidades compatibles (lib/unit-utils compatibleUnits),
// así que esto lo ve un cliente viejo o una llamada directa — pero el texto
// tiene que explicar la salida igual. El uuid del producto viaja al final del
// mensaje en los tres casos.
const UNIT_TYPE_MISMATCH_ERROR = /unit_type_mismatch:.*?del producto\s+([0-9a-f-]{36})/i
const UNIT_REQUIRES_BASE_UNIT_ERROR = /unit_requires_base_unit:.*?el producto\s+([0-9a-f-]{36})/i
const QUANTITY_BELOW_PRECISION_ERROR = /quantity_below_precision:.*?del producto\s+([0-9a-f-]{36})/i

// venta-editable-sin-cae: los DOS tokens nuevos de P0423. El SQLSTATE es el
// mismo que `invoiced_operation_immutable` (y que los tres guards de dinero),
// así que lo único que distingue la causa —y la acción que le queda al
// usuario— es el token del mensaje. `invoiced_operation_immutable` NO se
// agrega: su RAISE ya es legible tal cual y agregarlo ensancharía el diff sin
// ganancia (mismo criterio con el que hoy tampoco está).
const FISCAL_SENT_ERROR = /fiscal_document_sent_immutable/
const FISCAL_CLAIM_IN_FLIGHT_ERROR = /fiscal_document_claim_in_flight/

// presupuestos-modulo (D10, task 4.7): literales de las RPCs del presupuesto
// (`rpc_create_quote`/`rpc_update_quote`/`rpc_transition_quote`/
// `rpc_delete_quote`) y de la conversión en venta (`rpc_convert_quote_to_sale`,
// que reutiliza además `cash_requires_session` y el vocabulario de stock del
// núcleo de venta). Mismo mapa que venta y compra — no un segundo mapa.
const QUOTE_LOCKED_CONVERTED_ERROR = /quote_locked_converted/
const QUOTE_EXPIRED_ERROR = /quote_expired/
const QUOTE_INVALID_STATE_ERROR = /quote_invalid_state/
const QUOTE_NOT_DELETABLE_ERROR = /quote_not_deletable/
const QUOTE_VALID_UNTIL_IN_PAST_ERROR = /quote_valid_until_in_past/
const QUOTE_VALID_UNTIL_REQUIRED_ERROR = /quote_valid_until_required/
const QUOTE_CHANGED_ERROR = /quote_changed/
// El RAISE lleva el nombre congelado del producto detrás de los dos puntos.
const QUOTE_PRODUCT_UNAVAILABLE_ERROR = /quote_product_unavailable(?::\s*([^\n]+))?/
const QUOTE_CLIENT_UNAVAILABLE_ERROR = /quote_client_unavailable/
const PRODUCT_NOT_FOUND_ERROR = /product_not_found/
const PRODUCT_IS_PARENT_ERROR = /product_is_parent/
// P0403 de la RPC (`insufficient_role`) y el 403 de `require_account_role`
// ("Rol de cuenta insuficiente: se requiere …", sin `code`): un solo texto.
const INSUFFICIENT_ROLE_ERROR = /insufficient_role|Rol de cuenta insuficiente/
const CASH_REQUIRES_SESSION_ERROR = /cash_requires_session/
const IDEMPOTENCY_KEY_CONFLICT_ERROR = /idempotency_key_conflict/
const PAYMENT_METHOD_REQUIRED_ERROR = /payment_method_required/
// presupuestos-modulo (revisión 6.11, B-03): rechazos realistas de la conversión
// que el núcleo de venta y los helpers de banco levantan con el uuid detrás del
// token — el usuario nunca debe ver ni el uno ni el otro.
const CASH_OPTIN_SESSION_ERROR = /cash_optin_requires_open_session/
const PAYMENT_METHOD_INVALID_ERROR = /payment_method_not_found|payment_method_inactive/
const BANK_ACCOUNT_INVALID_ERROR = /bank_account_not_found_or_inactive/
const BANK_PERIOD_RECONCILED_ERROR = /bank_period_reconciled/

// remitos-venta (D11, tarea 4.5): literales de las RPCs del remito
// (`rpc_create_sale_delivery_note`/`rpc_update_delivery_note`/
// `rpc_cancel_delivery_note`) y, en la tanda B, de la conversión y de la vida
// posterior de la venta nacida de un remito. Mismo mapa que venta, compra y
// presupuesto — no un segundo mapa. `stock_insuficiente`, `branch_closed`,
// `idempotency_key_conflict`, `insufficient_role` y `payment_method_required`
// se reutilizan; el contexto `documentLabel: "remito"` ajusta el texto de los
// que hablaban de "la venta".
const DELIVERY_NOTE_NOT_FOUND_ERROR = /delivery_note_not_found/
const DELIVERY_NOTE_CHANGED_ERROR = /delivery_note_changed/
const DELIVERY_NOTE_REVISION_REQUIRED_ERROR = /delivery_note_revision_required/
const DELIVERY_NOTE_INVALID_STATE_ERROR = /delivery_note_invalid_state/
const DELIVERY_NOTE_LOCKED_CONVERTED_ERROR = /delivery_note_locked_converted/
const DELIVERY_NOTE_CLIENT_UNAVAILABLE_ERROR = /delivery_note_client_unavailable/
const DELIVERY_NOTE_CLIENT_REQUIRED_ERROR = /delivery_note_client_required/
const DELIVERY_NOTE_BRANCH_REQUIRED_ERROR = /delivery_note_branch_required/
const DELIVERY_NOTE_BRANCH_INACTIVE_ERROR = /delivery_note_branch_inactive/
const DELIVERY_NOTE_PRODUCT_REQUIRED_ERROR = /delivery_note_product_required/
const DELIVERY_NOTE_ITEMS_REQUIRED_ERROR = /delivery_note_items_required/
const DELIVERY_NOTE_TOO_MANY_ITEMS_ERROR = /delivery_note_too_many_items/
// El RAISE lleva la línea ("(línea 3)") detrás del texto.
const DELIVERY_NOTE_LINE_QUANTITY_ERROR = /delivery_note_line_invalid_quantity(?:.*?\(línea (\d+)\))?/
const DELIVERY_NOTE_LINE_PRICE_ERROR = /delivery_note_line_invalid_price(?:.*?\(línea (\d+)\))?/
const DELIVERY_NOTE_LINE_SUBTOTAL_ERROR = /delivery_note_line_invalid_subtotal(?:.*?\(línea (\d+)\))?/
const DELIVERY_NOTE_ADDRESS_TOO_LONG_ERROR = /delivery_note_address_too_long/
const DELIVERY_NOTE_NOTES_TOO_LONG_ERROR = /delivery_note_notes_too_long/
// `el producto <uuid> fue dado de baja: … lo entregado (3.0000), no aumentarlo (5.0000)`.
const DELIVERY_NOTE_PRODUCT_UNAVAILABLE_ERROR =
  /delivery_note_product_unavailable:\s*el producto\s+([0-9a-f-]{36}).*?\(([\d.]+)\).*?\(([\d.]+)\)/is
const DELIVERY_NOTE_PRODUCT_UNAVAILABLE_BARE_ERROR = /delivery_note_product_unavailable/
const DELIVERY_NOTE_CANCEL_REASON_REQUIRED_ERROR = /delivery_note_cancel_reason_required/
const DELIVERY_NOTE_CANCEL_REASON_TOO_LONG_ERROR = /delivery_note_cancel_reason_too_long/
const DELIVERY_NOTE_SALE_LOCKED_ERROR = /delivery_note_sale_locked/
const DELIVERY_NOTE_ORDER_MISMATCH_ERROR = /delivery_note_order_mismatch/
// 409 que mapea el service de remitos ante un `40P01` (interbloqueo): la
// transacción revirtió entera, así que reintentar con la misma clave es seguro.
const CONCURRENT_UPDATE_RETRY_ERROR = /concurrent_update_retry/

// remitos-compra (D11, tarea 4.5): literales del remito de COMPRA. `stock_consumed`
// lleva producto, stock de la sucursal y cantidad a restar (`de % en la sucursal
// quedan %, el remito necesita restar %`): el nombre puede venir como uuid si la
// línea no tenía snapshot. Los de la conversión y de la vida posterior de la
// compra (`price_required`, `purchase_*`, `items_from_source`) los emite la
// tanda B; el borrado y el puente (`purchase_delete_forbidden`, `source_protected`)
// se suman en la tarea 7.7.
const DELIVERY_NOTE_SUPPLIER_REQUIRED_ERROR = /delivery_note_supplier_required/
const DELIVERY_NOTE_SUPPLIER_UNAVAILABLE_ERROR = /delivery_note_supplier_unavailable/
const DELIVERY_NOTE_SUPPLIER_REFERENCE_TOO_LONG_ERROR = /delivery_note_supplier_reference_too_long/
const DELIVERY_NOTE_STOCK_CONSUMED_ERROR =
  /delivery_note_stock_consumed:\s*de\s+(.+?)\s+en la sucursal quedan\s+(-?[\d.]+),\s*el remito necesita restar\s+(-?[\d.]+)/is
const DELIVERY_NOTE_STOCK_CONSUMED_BARE_ERROR = /delivery_note_stock_consumed/
const DELIVERY_NOTE_PRICE_REQUIRED_ERROR = /delivery_note_price_required/
const DELIVERY_NOTE_PURCHASE_LOCKED_ERROR = /delivery_note_purchase_locked/
const DELIVERY_NOTE_PURCHASE_MISMATCH_ERROR = /delivery_note_purchase_mismatch/
const DELIVERY_NOTE_PURCHASE_DATE_BEFORE_RECEIPT_ERROR = /delivery_note_purchase_date_before_receipt/
const DELIVERY_NOTE_ITEMS_FROM_SOURCE_ERROR = /delivery_note_items_from_source/
const UUID_ONLY = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

/** `3` -> "3", `0.45` -> "0,45": las cantidades del servidor (`trim_scale`) en es-AR. */
const fmtQty = (raw: string) => Number(raw).toLocaleString("es-AR", { maximumFractionDigits: 4 })

const fmtMoney = (n: number) =>
  n.toLocaleString("es-AR", { style: "currency", currency: "ARS" })

/**
 * remitos-venta (D11): el documento sobre el que se operó. Los textos que
 * hablaban de "la venta" (stock insuficiente, cliente inexistente, rol) cambian
 * cuando el documento es un remito. Default `"venta"`: todo caller existente
 * sigue exactamente igual.
 */
export interface OperationErrorContext {
  documentLabel?: "venta" | "remito"
  /**
   * remitos-compra (D11): el SENTIDO del remito. Sólo cambia el texto de los
   * literales que hablaban de venta o de mercadería que sale (`"purchase"`);
   * sin él, o con `"sale"`, el texto no cambia.
   */
  direction?: "sale" | "purchase"
}

/**
 * Convierte el error crudo de una RPC de operación en un mensaje accionable.
 * Si no reconoce el error, devuelve el mensaje original sin acción (nunca lo
 * oculta).
 */
export function humanizeOperationError(
  message: string,
  lookupProductName?: ProductNameLookup,
  branchName?: string | null,
  context?: OperationErrorContext,
): HumanizedOperationError {
  if (!message) return { message: "Error desconocido" }
  const isRemito = context?.documentLabel === "remito"
  const isPurchaseRemito = isRemito && context?.direction === "purchase"

  // presupuestos-modulo: el estado y la edición primero — son los rechazos que
  // el usuario más ve y cada uno nombra qué hacer en vez de repetir el literal.
  if (QUOTE_LOCKED_CONVERTED_ERROR.test(message)) {
    return {
      message:
        "Este presupuesto ya se convirtió en una venta y no se puede modificar. " +
        "Los cambios se hacen sobre la venta; para presupuestar algo parecido, duplicalo.",
    }
  }

  if (QUOTE_EXPIRED_ERROR.test(message)) {
    return {
      message:
        "El presupuesto está vencido y no se puede convertir en venta. " +
        "Editalo para ampliar la validez o duplicalo.",
    }
  }

  if (QUOTE_INVALID_STATE_ERROR.test(message)) {
    return {
      message:
        "El presupuesto ya no está en un estado que permita esta acción (puede que ya se haya convertido en venta o rechazado). " +
        "Actualizá la pantalla para ver cómo quedó.",
    }
  }

  if (QUOTE_NOT_DELETABLE_ERROR.test(message)) {
    return {
      message:
        "Sólo se puede eliminar un borrador que nunca se envió, y este ya salió o cambió de estado. " +
        "Rechazalo si ya no corresponde, o duplicalo para armar uno nuevo.",
    }
  }

  if (QUOTE_VALID_UNTIL_IN_PAST_ERROR.test(message)) {
    return {
      message: "La fecha de validez ya pasó. Elegí hoy o una fecha posterior.",
    }
  }

  if (QUOTE_VALID_UNTIL_REQUIRED_ERROR.test(message)) {
    return {
      message: "Indicá hasta qué fecha es válido el presupuesto.",
    }
  }

  if (QUOTE_CHANGED_ERROR.test(message)) {
    return {
      message: "El presupuesto cambió mientras lo tenías abierto: revisalo y volvé a intentar.",
    }
  }

  const quoteProductMatch = message.match(QUOTE_PRODUCT_UNAVAILABLE_ERROR)
  if (quoteProductMatch) {
    const name = quoteProductMatch[1]?.trim()
    const producto = name ? `«${name}»` : "uno de los productos"
    return {
      message:
        `${name ? `«${name}»` : "Uno de los productos"} ya no está disponible en el catálogo. ` +
        `Editá el presupuesto y quitá o reemplazá ${producto}.`,
    }
  }

  if (QUOTE_CLIENT_UNAVAILABLE_ERROR.test(message)) {
    return {
      message:
        "El cliente del presupuesto fue dado de baja. Editá el presupuesto y elegí un cliente vigente.",
    }
  }

  // remitos-venta: el estado y la edición primero, como en el presupuesto —
  // cada mensaje nombra qué hacer en vez de repetir el literal.
  if (DELIVERY_NOTE_NOT_FOUND_ERROR.test(message)) {
    return {
      message:
        "El remito no existe o es de otra cuenta. Volvé al listado de remitos y elegilo de ahí.",
    }
  }

  if (DELIVERY_NOTE_CHANGED_ERROR.test(message)) {
    return {
      message: "El remito cambió mientras lo tenías abierto: recargalo y volvé a intentar.",
    }
  }

  if (DELIVERY_NOTE_REVISION_REQUIRED_ERROR.test(message)) {
    return {
      message:
        "Falta la versión del remito que estabas viendo. Recargá la pantalla y volvé a intentar: no se guardó nada.",
    }
  }

  if (DELIVERY_NOTE_INVALID_STATE_ERROR.test(message)) {
    return {
      message:
        `El remito ya no está en un estado que permita esta acción (puede que ya se haya convertido en ${isPurchaseRemito ? "compra" : "venta"} o anulado). ` +
        "Actualizá la pantalla para ver cómo quedó.",
    }
  }

  if (DELIVERY_NOTE_LOCKED_CONVERTED_ERROR.test(message)) {
    // El sentido sale del contexto y, sin él, del propio literal del servidor
    // ("el remito ya se convirtió en compra").
    const lockedInPurchase =
      isPurchaseRemito || (context?.direction === undefined && /se convirti[óo] en compra/i.test(message))
    if (lockedInPurchase) {
      return {
        message:
          "Este remito ya se convirtió en una compra y no se puede modificar ni anular. " +
          "Para corregirlo, eliminá la compra: el remito vuelve a quedar pendiente.",
      }
    }
    return {
      message:
        "Este remito ya se convirtió en una venta y no se puede modificar ni anular. " +
        "Para corregirlo, eliminá la venta: el remito vuelve a quedar pendiente.",
    }
  }

  if (DELIVERY_NOTE_SALE_LOCKED_ERROR.test(message)) {
    return {
      message:
        "Esta venta nació de un remito y no se puede editar: el stock ya se descontó con el remito. " +
        "Para corregirla, eliminá la venta, editá el remito y volvé a convertirlo.",
    }
  }

  if (DELIVERY_NOTE_ORDER_MISMATCH_ERROR.test(message)) {
    return {
      message:
        "La venta no coincide con el remito (cambió el cliente, la sucursal o las líneas): no se registró nada. " +
        "Actualizá el remito y volvé a convertirlo.",
    }
  }

  if (DELIVERY_NOTE_CLIENT_UNAVAILABLE_ERROR.test(message)) {
    return {
      message:
        "El cliente del remito fue dado de baja. Editá el remito y elegí un cliente vigente.",
    }
  }

  if (DELIVERY_NOTE_CLIENT_REQUIRED_ERROR.test(message)) {
    return { message: "Elegí el cliente al que le entregás la mercadería." }
  }

  if (DELIVERY_NOTE_BRANCH_REQUIRED_ERROR.test(message)) {
    if (isPurchaseRemito) {
      return { message: "Elegí la sucursal a la que entra la mercadería: ahí se suma el stock." }
    }
    return { message: "Elegí la sucursal de la que sale la mercadería: de ahí se descuenta el stock." }
  }

  if (DELIVERY_NOTE_BRANCH_INACTIVE_ERROR.test(message)) {
    return {
      message:
        "La sucursal del remito está desactivada o cerrada: no se guardó ningún cambio. " +
        `Reactivala desde Sucursales para editar o anular el remito, o para eliminar su ${isPurchaseRemito ? "compra" : "venta"}.`,
    }
  }

  if (DELIVERY_NOTE_PRODUCT_REQUIRED_ERROR.test(message)) {
    return {
      message:
        `Cada línea del remito necesita un producto: el remito documenta mercadería que ${isPurchaseRemito ? "entra al" : "sale del"} depósito, no conceptos sueltos.`,
    }
  }

  if (DELIVERY_NOTE_ITEMS_REQUIRED_ERROR.test(message)) {
    return { message: "El remito necesita al menos un producto. Agregá una línea." }
  }

  if (DELIVERY_NOTE_TOO_MANY_ITEMS_ERROR.test(message)) {
    return {
      message: "Un remito admite hasta 500 líneas. Dividilo en más de un remito.",
    }
  }

  const lineQuantityMatch = message.match(DELIVERY_NOTE_LINE_QUANTITY_ERROR)
  if (lineQuantityMatch) {
    return {
      message: `La cantidad debe ser mayor que 0${lineQuantityMatch[1] ? ` (línea ${lineQuantityMatch[1]})` : ""}. Corregila o quitá la línea.`,
    }
  }

  const linePriceMatch = message.match(DELIVERY_NOTE_LINE_PRICE_ERROR)
  if (linePriceMatch) {
    return {
      message: `El precio no puede ser negativo${linePriceMatch[1] ? ` (línea ${linePriceMatch[1]})` : ""}. Corregilo y volvé a intentar.`,
    }
  }

  const lineSubtotalMatch = message.match(DELIVERY_NOTE_LINE_SUBTOTAL_ERROR)
  if (lineSubtotalMatch) {
    return {
      message: `El subtotal no puede ser negativo${lineSubtotalMatch[1] ? ` (línea ${lineSubtotalMatch[1]})` : ""}. Corregilo y volvé a intentar.`,
    }
  }

  if (DELIVERY_NOTE_ADDRESS_TOO_LONG_ERROR.test(message)) {
    return { message: "El domicilio de entrega admite hasta 500 caracteres. Acortalo y volvé a intentar." }
  }

  if (DELIVERY_NOTE_NOTES_TOO_LONG_ERROR.test(message)) {
    return { message: "Las notas admiten hasta 2.000 caracteres. Acortalas y volvé a intentar." }
  }

  const dnProductMatch = message.match(DELIVERY_NOTE_PRODUCT_UNAVAILABLE_ERROR)
  if (dnProductMatch) {
    const [, productId, rawHeld, rawRequired] = dnProductMatch
    const name = lookupProductName?.(productId)
    const producto = name ? `«${name}»` : "uno de los productos"
    const held = Number(rawHeld) // "3.0000" → 3, sin los 4 decimales internos
    const required = Number(rawRequired)
    return {
      message:
        `${name ? `«${name}»` : "Uno de los productos"} fue dado de baja del catálogo: se puede conservar o reducir lo ${isPurchaseRemito ? "recibido" : "entregado"} (${held.toLocaleString("es-AR")}), ` +
        `pero no aumentarlo (pediste ${required.toLocaleString("es-AR")}). Bajá la cantidad de ${producto} o quitá la línea.`,
    }
  }
  if (DELIVERY_NOTE_PRODUCT_UNAVAILABLE_BARE_ERROR.test(message)) {
    return {
      message:
        `Uno de los productos fue dado de baja del catálogo: se puede conservar o reducir lo ${isPurchaseRemito ? "recibido" : "entregado"}, pero no aumentarlo.`,
    }
  }

  // remitos-compra (D11): proveedor, faltante al restar y conversión en compra.
  if (DELIVERY_NOTE_SUPPLIER_REQUIRED_ERROR.test(message)) {
    return { message: "Elegí el proveedor que te entrega la mercadería." }
  }

  if (DELIVERY_NOTE_SUPPLIER_UNAVAILABLE_ERROR.test(message)) {
    return {
      message: "El proveedor del remito fue dado de baja. Editá el remito y elegí un proveedor vigente.",
    }
  }

  if (DELIVERY_NOTE_SUPPLIER_REFERENCE_TOO_LONG_ERROR.test(message)) {
    return {
      message: "El número del remito del proveedor admite hasta 100 caracteres. Acortalo y volvé a intentar.",
    }
  }

  // El servidor NO atribuye origen a la diferencia (el stock de la sucursal
  // mezcla otras entradas), y este texto tampoco: dice cuánto queda, cuánto hay
  // que restar y las dos salidas (reducir el remito o ajustar el stock).
  const consumedMatch = message.match(DELIVERY_NOTE_STOCK_CONSUMED_ERROR)
  if (consumedMatch) {
    const [, rawName, rawLeft, rawNeeded] = consumedMatch
    const productId = UUID_ONLY.test(rawName.trim()) ? rawName.trim() : null
    const resolvedName = productId ? lookupProductName?.(productId) : rawName.trim()
    const producto = resolvedName ? `«${resolvedName}»` : "uno de los productos"
    return {
      message:
        `No se puede restar ${producto} del stock: en la sucursal quedan ${fmtQty(rawLeft)} y el remito necesita restar ${fmtQty(rawNeeded)}. ` +
        "Editá el remito y reducí lo que sigue en el depósito, o ajustá el stock antes de volver a intentar. No se guardó ningún cambio.",
      action: { label: "Ajustar stock", href: productId ? `/stock?product=${productId}` : "/stock" },
    }
  }
  if (DELIVERY_NOTE_STOCK_CONSUMED_BARE_ERROR.test(message)) {
    return {
      message:
        "La mercadería de este remito ya no está toda en el stock de la sucursal. " +
        "Editá el remito y reducí lo que sigue en el depósito, o ajustá el stock antes de volver a intentar. No se guardó ningún cambio.",
      action: { label: "Ajustar stock", href: "/stock" },
    }
  }

  if (DELIVERY_NOTE_PRICE_REQUIRED_ERROR.test(message)) {
    return {
      message:
        "Cargá el precio de compra de todas las líneas antes de convertir el remito en compra. " +
        "Editá el remito, completá los precios y volvé a convertirlo.",
    }
  }

  if (DELIVERY_NOTE_PURCHASE_DATE_BEFORE_RECEIPT_ERROR.test(message)) {
    return {
      message:
        "La fecha de la compra no puede ser anterior a la recepción del remito. " +
        "Elegí la fecha del remito o una posterior.",
    }
  }

  if (DELIVERY_NOTE_PURCHASE_MISMATCH_ERROR.test(message)) {
    return {
      message:
        "La compra no coincide con el remito (cambió el proveedor, la sucursal o las líneas): no se registró nada. " +
        "Actualizá el remito y volvé a convertirlo.",
    }
  }

  if (DELIVERY_NOTE_ITEMS_FROM_SOURCE_ERROR.test(message)) {
    return {
      message:
        "Las líneas de esta compra salen del remito y no se pueden enviar aparte: no se guardó nada. " +
        "Actualizá la pantalla y volvé a convertir el remito.",
    }
  }

  if (DELIVERY_NOTE_PURCHASE_LOCKED_ERROR.test(message)) {
    return {
      message:
        "Esta compra nació de un remito y no se puede editar: el stock ya se sumó al recibir la mercadería. " +
        "Para corregirla, eliminá la compra, editá el remito y volvé a convertirlo.",
    }
  }

  if (DELIVERY_NOTE_CANCEL_REASON_REQUIRED_ERROR.test(message)) {
    return { message: "Escribí el motivo de la anulación para poder anular el remito." }
  }

  if (DELIVERY_NOTE_CANCEL_REASON_TOO_LONG_ERROR.test(message)) {
    return { message: "El motivo de la anulación admite hasta 500 caracteres. Acortalo y volvé a intentar." }
  }

  if (CONCURRENT_UPDATE_RETRY_ERROR.test(message)) {
    return {
      message:
        "Otra operación tocó los mismos productos al mismo tiempo. Volvé a intentarlo: no se guardó nada.",
    }
  }

  if (PRODUCT_IS_PARENT_ERROR.test(message)) {
    return {
      message:
        "Uno de los productos tiene variantes (talle, color, …) y no se puede cotizar o vender como padre. " +
        "Elegí la variante puntual.",
    }
  }

  if (PRODUCT_NOT_FOUND_ERROR.test(message)) {
    return {
      message:
        "Uno de los productos no existe o no pertenece a esta cuenta. Quitalo o reemplazalo y volvé a intentar.",
    }
  }

  if (INSUFFICIENT_ROLE_ERROR.test(message)) {
    if (isPurchaseRemito) {
      return {
        message:
          "Tu rol no permite esta acción sobre remitos de compra. Recibir y editar: depósito, administrador o dueño; " +
          "anular: administrador o dueño. Pedile al dueño o a un administrador de la cuenta que te asigne el rol.",
      }
    }
    if (isRemito) {
      return {
        message:
          "Tu rol no permite esta acción sobre remitos. Emitir y editar: vendedor, depósito, administrador o dueño; " +
          "anular: administrador o dueño. Pedile al dueño o a un administrador de la cuenta que te asigne el rol.",
      }
    }
    return {
      message:
        "Tu rol no permite realizar esta acción. Pedile al dueño o a un administrador de la cuenta que te asigne el rol de vendedor.",
    }
  }

  if (CASH_REQUIRES_SESSION_ERROR.test(message)) {
    return {
      message:
        "Para cobrar en efectivo hace falta una caja abierta en esta sucursal. " +
        "Abrí la caja o elegí otra forma de pago: no se registró nada.",
      action: { label: "Ir a Caja", href: "/caja" },
    }
  }

  if (IDEMPOTENCY_KEY_CONFLICT_ERROR.test(message)) {
    return {
      message:
        "Esta operación ya se registró con otro documento (la clave de la operación se repitió). " +
        "Cerrá este cuadro y volvé a intentar.",
    }
  }

  if (PAYMENT_METHOD_REQUIRED_ERROR.test(message)) {
    return {
      message: "Elegí la forma de pago para registrar la venta.",
    }
  }

  if (CASH_OPTIN_SESSION_ERROR.test(message)) {
    return {
      message:
        "La caja de esta sucursal ya no está abierta (se cerró mientras confirmabas): no se registró nada. " +
        "Abrí la caja o elegí otra forma de pago.",
      action: { label: "Ir a Caja", href: "/caja" },
    }
  }

  if (PAYMENT_METHOD_INVALID_ERROR.test(message)) {
    return {
      message:
        "La forma de pago elegida no existe, está desactivada o no pertenece a esta cuenta: no se registró nada. " +
        "Elegí otra forma de pago.",
    }
  }

  if (BANK_ACCOUNT_INVALID_ERROR.test(message)) {
    return {
      message:
        "La cuenta bancaria elegida no existe, está inactiva o no pertenece a esta cuenta: no se registró nada. " +
        "Elegí otra cuenta bancaria.",
    }
  }

  if (BANK_PERIOD_RECONCILED_ERROR.test(message)) {
    return {
      message:
        "La fecha de la operación cae en un período bancario ya conciliado y cerrado: no se registró nada. " +
        "Registrá el ajuste como movimiento bancario manual.",
    }
  }

  const stockMatch = message.match(STOCK_ERROR)
  if (stockMatch) {
    const productId = stockMatch[1] ?? stockMatch[2]
    const name = lookupProductName?.(productId)
    const producto = name ? `«${name}»` : "uno de los productos"
    const sucursal = branchName
      ? `la sucursal ${branchName}`
      : isRemito
        ? "la sucursal del remito"
        : "la sucursal de esta operación"
    return {
      message:
        `No hay stock de ${producto} en ${sucursal}. ` +
        `Puede haber unidades en otra sucursal: revisá el stock por sucursal o cambiá la sucursal ${isRemito ? "del remito" : "de la venta"}.`,
      action: {
        label: "Transferir stock",
        href: `/stock?product=${productId}`,
      },
    }
  }

  const rnB4Match = message.match(RN_B4_ERROR)
  if (rnB4Match) {
    const [, name, rawQty] = rnB4Match
    const qty = Number(rawQty) // "6.0000" → 6, sin los 4 decimales internos
    const unidades = qty === 1 ? "1 unidad" : `${qty.toLocaleString("es-AR")} unidades`
    return {
      message:
        `No se puede borrar «${name}» porque todavía tiene stock (${unidades}). ` +
        `Llevá su stock a 0 (vendé, ajustá o transferí las unidades) y volvé a intentarlo.`,
    }
  }

  const mismatchMatch = message.match(AMOUNTS_MISMATCH_ERROR)
  if (mismatchMatch) {
    const [, rawLines, rawMovs] = mismatchMatch
    const detalle =
      rawLines != null && rawMovs != null
        ? `las líneas seleccionadas del extracto suman ${fmtMoney(Number(rawLines))} y los movimientos ${fmtMoney(Number(rawMovs))}`
        : "lo seleccionado del extracto y los movimientos tienen totales distintos"
    return {
      message: `Las sumas no coinciden: ${detalle}. Ajustá la selección hasta que los dos totales sean iguales.`,
    }
  }

  if (PERIODO_INVALIDO_ERROR.test(message)) {
    return {
      message:
        "El período está invertido: la fecha «Desde» tiene que ser anterior o igual a «Hasta».",
    }
  }

  if (NO_OPEN_SESSION_FOR_REVERSAL_ERROR.test(message)) {
    return {
      message:
        "No se puede anular: la caja que registró este movimiento ya está cerrada. Abrí la caja para poder anularlo.",
    }
  }

  if (PAYMENT_NOT_FOUND_ERROR.test(message)) {
    return {
      message:
        "No se pudo anular: el cobro o pago ya no existe (puede que ya se haya anulado antes).",
    }
  }

  if (JOURNAL_ENTRY_ORIGINAL_NOT_FOUND_ERROR.test(message)) {
    return {
      message:
        "La anulación se registró, pero el asiento contable todavía no está listo para revertirse. Se completará solo en unos minutos.",
    }
  }

  // venta-editable-sin-cae: el transitorio va PRIMERO — su texto es el único
  // que invita a reintentar, y confundirlo con el terminal dejaría al usuario
  // esperando algo que no va a pasar.
  if (FISCAL_CLAIM_IN_FLIGHT_ERROR.test(message)) {
    return {
      message:
        "Justo ahora se está emitiendo el comprobante de esta venta. Esperá unos minutos y volvé a intentar: no se guardó ningún cambio.",
    }
  }

  if (FISCAL_SENT_ERROR.test(message)) {
    return {
      message:
        "El comprobante de esta venta ya se envió a ARCA y todavía no hay respuesta. No se puede editar ni borrar hasta que se resuelva — no se guardó ningún cambio.",
    }
  }

  if (CLIENT_NOT_FOUND_ERROR.test(message)) {
    // remitos-venta (D11): en un remito sólo es alcanzable con un cliente dado
    // de baja después de emitir — la salida es elegir uno vigente.
    if (isRemito) return { message: "Cliente dado de baja — elegí uno vigente" }
    return {
      message:
        "El cliente seleccionado no existe o no pertenece a esta cuenta. Elegí un cliente del listado o dejá el campo vacío.",
    }
  }

  if (SUPPLIER_NOT_FOUND_ERROR.test(message)) {
    // remitos-compra (D11): en un remito sólo es alcanzable con un proveedor
    // dado de baja después de recibir — la salida es elegir uno vigente.
    if (isRemito) return { message: "Proveedor dado de baja — elegí uno vigente" }
    return {
      message:
        "El proveedor seleccionado no existe o no pertenece a esta cuenta. Elegí un proveedor del listado o dejá el campo vacío.",
    }
  }

  if (BRANCH_CLOSED_ERROR.test(message)) {
    // remitos-venta (D7): la conversión de un remito se imputa a SU sucursal, que
    // no se elige — "elegí otra sucursal" no tiene salida. Se reactiva la del remito.
    if (isPurchaseRemito) {
      return {
        message:
          "La sucursal del remito está cerrada o desactivada: no se guardó nada. " +
          "Reabrila o reactivala desde Sucursales y volvé a intentar.",
      }
    }
    if (isRemito) {
      return {
        message:
          "La sucursal del remito está cerrada o desactivada: no se registró la venta. " +
          "Reabrila o reactivala desde Sucursales y volvé a intentar.",
      }
    }
    return {
      message:
        "La sucursal está cerrada y no admite operaciones: no se guardó nada. Elegí otra sucursal o reabrila desde Sucursales.",
    }
  }

  if (BRANCH_NOT_FOUND_ERROR.test(message)) {
    return {
      message:
        "La sucursal elegida no existe, está desactivada o no pertenece a esta cuenta: no se guardó nada. Elegí otra sucursal del listado.",
    }
  }

  if (BRANCH_INVALID_ERROR.test(message)) {
    return {
      message:
        "La sucursal de esta operación ya no está operativa (está cerrada o desactivada): no se guardó ningún cambio. Elegí otra sucursal o reabrila desde Sucursales.",
    }
  }

  const unitTypeMatch = message.match(UNIT_TYPE_MISMATCH_ERROR)
  if (unitTypeMatch) {
    const name = lookupProductName?.(unitTypeMatch[1])
    const producto = name ? `«${name}»` : "este producto"
    return {
      message:
        `La unidad elegida no es del mismo tipo que la unidad base de ${producto} ` +
        `(peso, volumen, longitud o unidades no se convierten entre sí). Elegí una unidad compatible: no se guardó nada.`,
    }
  }

  const unitRequiresBaseMatch = message.match(UNIT_REQUIRES_BASE_UNIT_ERROR)
  if (unitRequiresBaseMatch) {
    const productId = unitRequiresBaseMatch[1]
    const name = lookupProductName?.(productId)
    const producto = name ? `«${name}»` : "Este producto"
    return {
      message:
        `${producto} no tiene unidad base, así que sólo se puede cargar en una unidad base (unidad, kilogramo, litro o metro). ` +
        `Para usar gramos, docenas u otra unidad derivada, asignale una unidad base en el catálogo: no se guardó nada.`,
      action: {
        label: "Editar producto",
        href: `/productos?q=${productId}`,
      },
    }
  }

  const belowPrecisionMatch = message.match(QUANTITY_BELOW_PRECISION_ERROR)
  if (belowPrecisionMatch) {
    const name = lookupProductName?.(belowPrecisionMatch[1])
    const producto = name ? `«${name}»` : "este producto"
    return {
      message:
        `La cantidad es demasiado chica para la unidad base de ${producto}: equivale a 0 al redondear a 4 decimales. ` +
        `Cargá una cantidad mayor o usá una unidad más chica.`,
    }
  }

  return { message }
}
