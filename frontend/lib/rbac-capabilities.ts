/**
 * presupuestos-modulo (D11) — capacidades de rol de TENANT en el frontend.
 *
 * Espejo de `backend/core/rbac.py`: el backend es la fuente de verdad y el
 * frontend sólo decide qué mostrar (ocultar un CTA que igual rechazaría un 403).
 * Cada conjunto está atado por test (`__tests__/lib/rbac-capabilities.test.ts`)
 * al de Python y al catálogo de la máquina de estados
 * (`document_status_transitions.allowed_role`).
 *
 * Se decide sobre el CONJUNTO `roles` de `useOrgRole`, nunca sobre el `role`
 * singular: ese colapsa a `member` a un usuario que sólo es vendedor y le
 * ocultaría el módulo al usuario principal.
 */
import type { OrgRole } from "@/lib/types"

/** Crear, editar, enviar, rechazar, eliminar y convertir un presupuesto. */
export const CAN_QUOTE: readonly OrgRole[] = ["owner", "admin", "seller"]

/**
 * Configurar la cuenta (validez por defecto de los presupuestos, formas de
 * pago…). Espejo de `CAN_CONFIGURE` de `backend/core/rbac.py`; la RPC
 * `rpc_set_default_quote_validity` lo exige con `P0403`.
 */
export const CAN_CONFIGURE: readonly OrgRole[] = ["owner", "admin"]

/**
 * remitos-venta (D13) — emitir y editar un remito de venta. Espejo de
 * `CAN_DELIVER_SALE` de `backend/core/rbac.py` y del `allowed_role` de la
 * transición `NULL -> issued` del catálogo `delivery_note_sale`: el vendedor y
 * el rol de depósito (`stock`) despachan mercadería; el cajero cobra pero no
 * emite remitos.
 */
export const CAN_DELIVER_SALE: readonly OrgRole[] = ["owner", "admin", "seller", "stock"]

/**
 * remitos-venta (D13) — anular un remito (devuelve stock). Espejo de
 * `CAN_VOID_DELIVERY_NOTE` de `backend/core/rbac.py` y de `issued -> canceled`
 * del catálogo. Coincide con `CAN_CONFIGURE`, así que `is_sensitive_capability`
 * la trata como sensible (la autoridad es la base, no el claim): es deliberado
 * para una acción que mueve stock. `stock` y `seller` emiten pero no anulan.
 */
export const CAN_VOID_DELIVERY_NOTE: readonly OrgRole[] = ["owner", "admin"]

/**
 * Vender y cobrar. Espejo de `CAN_SELL` de `backend/core/rbac.py`. El remito lo
 * usa para convertirse en venta (tanda B, OQ-RV2): el cajero cobra cuando el
 * cliente viene a pagar lo que se llevó; el rol `stock` emite pero no cobra.
 */
export const CAN_SELL: readonly OrgRole[] = ["owner", "admin", "seller", "cashier"]

/**
 * remitos-compra (D12) — recibir mercadería con un remito de compra (emitir y
 * editar: suma stock). Espejo de `CAN_RECEIVE_PURCHASE` de `backend/core/rbac.py`
 * y del `allowed_role` de `NULL -> issued` del catálogo `delivery_note_purchase`.
 * Tiene el mismo contenido que el rol de depósito (`stock`) más owner/admin, pero
 * va con nombre propio por acción, igual que `CAN_DELIVER_SALE`: si "depósito" y
 * "recepción" divergen algún día cambia una constante y no todas las pantallas.
 * El vendedor despacha pero NO recibe mercadería.
 */
export const CAN_RECEIVE_PURCHASE: readonly OrgRole[] = ["owner", "admin", "stock"]

/**
 * remitos-compra (D12, OQ-RC6) — convertir un remito de compra en compra (tanda
 * B). Espejo de `CAN_CONVERT_PURCHASE_DELIVERY_NOTE` de `backend/core/rbac.py` y
 * de `issued -> converted` del catálogo. Suma `stock` a `CAN_PURCHASE`: quien
 * recibe la mercadería y tiene la factura en la mano tiene que poder cerrar el
 * ciclo; si sólo pudiera registrar una compra directa, volvería a sumar el stock.
 * Anular sigue siendo `CAN_VOID_DELIVERY_NOTE` (los dos sentidos).
 */
export const CAN_CONVERT_PURCHASE_DELIVERY_NOTE: readonly OrgRole[] = ["owner", "admin", "purchases", "stock"]

/**
 * stock-ledger-solo-rpc (D5, D12) — ajustar el stock A MANO (modal y CSV de
 * /stock, inventario por sucursal, stock inicial del alta de producto). Espejo
 * de `CAN_STOCK` de `backend/core/rbac.py` y del `ARRAY['owner','admin','stock']`
 * de `_stock_assert_can_adjust` (migración 20261074000001): la base lo exige en
 * las tres RPCs de ajuste y el frontend sólo decide qué mostrar. Un test
 * (`__tests__/lib/rbac-capabilities.test.ts`) lee los tres y falla si divergen.
 * Las transferencias entre sucursales NO usan esta capacidad (OQ-3: siguen con
 * `isWriter`).
 */
export const CAN_STOCK: readonly OrgRole[] = ["owner", "admin", "stock"]

/**
 * ¿Alguno de los roles activos del usuario habilita la capacidad?
 *
 * Mientras el conjunto no resolvió (`rolesResolved === false`) responde `true`:
 * fail-OPEN, igual que `isWriter`. Con el conjunto sin resolver `roles` vale
 * `[role]`, que para un vendedor es `["member"]`; decidir sobre eso ocultaría el
 * módulo durante la carga. Es sólo informativo — la barrera real es la RPC
 * (`P0403`) y `require_account_role` del backend.
 */
export function hasCapability(
  roles: readonly OrgRole[],
  capability: readonly OrgRole[],
  rolesResolved: boolean,
): boolean {
  if (!rolesResolved) return true
  return roles.some((role) => capability.includes(role))
}
