"use client"

/**
 * useCashOptin — las tres condiciones del opt-in de caja, en un solo lugar
 * (gastos-forma-pago, D16 / task 8.5).
 *
 * El bloque vivía inline en `components/forms/sale-form.tsx`
 * (`useBranches` + `useCashboxes` + `useCurrentSession` + comparación con el
 * día local argentino). El formulario de gasto es el SEGUNDO consumidor del
 * bloque exacto, así que se extrae en vez de copiarse — Regla de Tres
 * cumplida por duplicación real, no anticipada.
 *
 * Las tres condiciones son las que valida el servidor, copiadas de
 * `rpc_create_sale_operation_v2` y reusadas por `rpc_create_expense`:
 *   1. el `kind` de la forma de pago elegida es `cash`;
 *   2. hay una sesión de caja ABIERTA en la sucursal efectiva de la
 *      operación (sucursal elegida, o la primera activa de la cuenta — el
 *      mismo fallback que `c26_default_branch`);
 *   3. la operación está fechada HOY, en día local argentino.
 *
 * Este hook NO decide nada: la autoridad sigue siendo la RPC, que rechaza
 * con `P0422` si alguna condición no se cumple. Acá sólo se resuelve qué
 * mostrar y qué mandar, para que el usuario no descubra el bloqueo con un
 * error del servidor.
 *
 * El único parámetro que NO es de datos es `document`: el motivo de la
 * condición 3 nombra el documento ("una venta fechada hoy" / "un gasto
 * fechado hoy"), y decirlo en genérico es peor que decirlo bien.
 */

import { useBranches } from "@/hooks/data/use-branches"
import { useCashboxes } from "@/hooks/data/use-cashboxes"
import { useCurrentSession } from "@/hooks/data/use-cash-session"
import { argentinaToday } from "@/lib/date-range"
import type { CashSession, PaymentMethodKind } from "@/lib/types"

export type CashOptinDocument = "venta" | "gasto" | "compra" | "cobro"

/** Condición 3 — el texto nombra el documento; el resto es común.
 * caja-compras-cobranzas: "cobro" nunca lee esta entrada (requiresDate la
 * apaga, D5 — el cobro/pago no tiene fecha propia), pero el Record exige
 * una entrada por cada miembro del union. */
const DATE_REASON: Record<CashOptinDocument, string> = {
  venta: "Sólo se puede registrar en caja una venta fechada hoy.",
  gasto: "Sólo se puede registrar en caja un gasto fechado hoy.",
  compra: "Sólo se puede registrar en caja una compra fechada hoy.",
  cobro: "Sólo se puede registrar en caja un movimiento fechado hoy.",
}
/** Condición 2 — literal heredado de `sale-form.tsx`, sin cambiar una coma. */
const NO_SESSION_REASON =
  "No hay caja abierta en esta sucursal — el efectivo no se registrará en el arqueo."
/** Condición 1 — nueva: el formulario de venta nunca la mostraba porque el
 * bloque entero sólo se renderiza con `kind = cash`. El de gasto sí la
 * necesita (D1: el motivo se muestra, nunca se oculta en silencio). */
const NOT_CASH_REASON =
  "Sólo un pago en efectivo puede registrarse en la caja."

export interface UseCashOptinParams {
  /** `kind` derivado de la forma de pago elegida (null = ninguna). */
  kind: PaymentMethodKind | null | undefined
  /** Sucursal elegida en el formulario (null = usar la default de la cuenta). */
  branchId: string | null | undefined
  /** Fecha del documento, `YYYY-MM-DD`. */
  date: string
  document?: CashOptinDocument
  /**
   * caja-compras-cobranzas (D5): el cobro y el pago de cuenta corriente no
   * tienen fecha propia — se registran en el instante en que ocurren, así
   * que la condición 3 no aplica. `false` desactiva el chequeo de fecha
   * (la condición se trata como cumplida por construcción). Default `true`
   * — venta, gasto y compra siguen exigiendo fecha de hoy.
   */
  requiresDate?: boolean
}

export interface CashOptinState {
  /** Condición 1. */
  isCashSelected: boolean
  /** Condición 3. */
  isDateToday: boolean
  /** Sucursal efectiva de la operación (la elegida, o la default de la cuenta). */
  effectiveBranchId: string | null
  /** Caja resuelta de esa sucursal (la primera), o null. */
  cashboxId: string | null
  /** Sesión abierta de esa caja, o null — condición 2. */
  session: CashSession | null
  /** Las tres condiciones cumplidas. */
  eligible: boolean
  /** Motivo concreto de por qué no es elegible (vacío de sentido si lo es). */
  reason: string
}

export function useCashOptin({
  kind,
  branchId,
  date,
  document = "venta",
  requiresDate = true,
}: UseCashOptinParams): CashOptinState {
  const isCashSelected = kind === "cash"

  const { branches } = useBranches()
  const effectiveBranchId = branchId || branches[0]?.id || null

  // Los dos hooks reciben `null` mientras el kind no es efectivo: sin eso el
  // formulario consultaría cajas y sesiones que no va a usar en cada render.
  const { data: cashboxes } = useCashboxes(isCashSelected ? effectiveBranchId : null)
  const cashboxId = cashboxes?.[0]?.id ?? null
  const { data: currentSession } = useCurrentSession(isCashSelected ? cashboxId : null)

  // caja-compras-cobranzas (D5): con requiresDate=false la condición 3 se
  // trata como cumplida por construcción — el cobro/pago no tiene fecha
  // propia, así que "hoy" no es un chequeo que pueda fallar.
  const isDateToday = !requiresDate || date === argentinaToday()
  const eligible = isCashSelected && !!currentSession && isDateToday

  const reason = !isCashSelected
    ? NOT_CASH_REASON
    : !isDateToday
      ? DATE_REASON[document]
      : NO_SESSION_REASON

  return {
    isCashSelected,
    isDateToday,
    effectiveBranchId,
    cashboxId,
    session: currentSession ?? null,
    eligible,
    reason,
  }
}
