/**
 * punto-venta-seleccion (D6) — qué punto de venta se ofrece al facturar.
 *
 * Regla ÚNICA (una sola implementación para /ventas, /ventas/ordenes y
 * /admin/pagos), firmada por el PO el 2026-09-26 (OQ-2), considerando sólo
 * puntos de venta ACTIVOS:
 *   1. la última elección de la sesión para esta cuenta, si sigue activa;
 *   2. el predeterminado de la cuenta (`isDefault`);
 *   3. el único activo, si hay uno solo;
 *   4. ninguno (el usuario elige).
 *
 * El servidor (`rpc_emit_pending_cae`) es la fuente de verdad de la emisión;
 * esto sólo decide qué aparece MARCADO en el diálogo. La UI siempre manda el PV
 * elegido de forma explícita (D4).
 *
 * Pura y sin imports de runtime de `python-client` (mismo criterio que
 * `lib/fiscal-comprobante.ts`): testeable sin mockear media app.
 */
import type { PointOfSale } from "@/hooks/data/use-points-of-sale"
import { formatPuntoDeVenta } from "@/lib/fiscal-comprobante"

/** Lo mínimo que la regla necesita de un punto de venta. */
export type PointOfSaleOption = Pick<PointOfSale, "id" | "numero" | "isActive" | "isDefault">

interface PreselectionContext {
  /** Último PV con el que se facturó OK en esta sesión y cuenta (sessionStorage). */
  lastUsedId: string | null
}

/** Sólo los activos, en el orden recibido (la API los ordena por número). */
export function activePointsOfSale<T extends PointOfSaleOption>(pointsOfSale: readonly T[]): T[] {
  return pointsOfSale.filter((pv) => pv.isActive)
}

/** Id del PV a preseleccionar, o `null` si el usuario tiene que elegir. */
export function resolvePreselectedPointOfSale(
  pointsOfSale: readonly PointOfSaleOption[],
  { lastUsedId }: PreselectionContext,
): string | null {
  const active = activePointsOfSale(pointsOfSale)
  if (lastUsedId && active.some((pv) => pv.id === lastUsedId)) return lastUsedId
  const byDefault = active.find((pv) => pv.isDefault)
  if (byDefault) return byDefault.id
  if (active.length === 1) return active[0].id
  return null
}

/** Número de PV con el formato de ARCA (4 dígitos). */
export function formatPointOfSaleNumber(numero: number): string {
  return formatPuntoDeVenta(numero)
}

/** Etiqueta visible de un PV: "PV 0003". */
export function formatPointOfSaleLabel(numero: number): string {
  return `PV ${formatPointOfSaleNumber(numero)}`
}

/**
 * Clave de sessionStorage de la última elección (D8). Por cuenta: un usuario
 * con acceso a dos cuentas no arrastra un id que en la otra no existe (y aun
 * así la regla lo descarta si no está entre los activos).
 */
export function lastPointOfSaleStorageKey(accountId: string): string {
  return `fiscal:last-pv:${accountId}`
}
