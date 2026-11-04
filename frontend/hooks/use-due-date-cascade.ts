"use client"

/**
 * useDueDateCascade — el vencimiento de una deuda de cuenta corriente, PRE-CARGADO
 * por la cascada del plazo y editable (cobranzas-vencimientos D3/D11; extraído de
 * `sale-form.tsx` por remitos-compra tanda B, D11, para que lo use también el
 * diálogo que convierte un remito de compra sin copiar la cascada).
 *
 * La cascada: plazo de la CONTRAPARTE (cliente o proveedor) → plazo por defecto de
 * la cuenta (`useCollectionSettings`) → sin plazo (el cargo nace sin vencimiento;
 * nunca significa cero: un plazo de 0 días es un plazo y vence el mismo día).
 *
 * Reglas:
 *  - Mientras el usuario NO tocó el campo, sigue a la cascada: cambiar la fecha de
 *    la operación o el plazo recalcula el vencimiento.
 *  - Una vez tocado (`setDueDate`, también para vaciarlo), el valor elegido no se
 *    pisa nunca más.
 *  - Sólo viaja al servidor lo TOCADO (`valueForServer`): sin tocar va `null` y la
 *    cascada AUTORITATIVA se resuelve en `_pay_register_party_charge`, nunca acá.
 *    Esto es sólo la vista previa de lo que el servidor va a resolver.
 */

import { useCallback, useEffect, useState } from "react"
import { useCollectionSettings } from "@/hooks/data/use-collection-settings"
import { addDaysToIsoDate } from "@/lib/receivables-aging"

/** De dónde sale el plazo que resolvió la cascada. */
export type DueDateTermsSource = "entity" | "account" | null

export interface UseDueDateCascadeParams {
  /** Fecha de la operación (AAAA-MM-DD): el plazo se cuenta desde ahí. */
  date: string
  /** Plazo de la contraparte (cliente o proveedor); null/undefined = no tiene. */
  entityTermsDays: number | null | undefined
}

export interface DueDateCascadeState {
  /** El valor del campo: el de la cascada hasta que se toca, después el elegido. */
  dueDate: string
  /** El usuario modificó el campo (también al vaciarlo). */
  touched: boolean
  /** Edita el campo y lo marca como tocado. */
  setDueDate: (value: string) => void
  /** El plazo que resolvió la cascada, en días; null si no hay ninguno. */
  effectiveTermsDays: number | null
  termsSource: DueDateTermsSource
  /** Lo que se manda al servidor: el vencimiento sólo si fue tocado y no está vacío; si no, null. */
  valueForServer: string | null
}

export function useDueDateCascade({ date, entityTermsDays }: UseDueDateCascadeParams): DueDateCascadeState {
  const { data: collectionSettings } = useCollectionSettings()
  const [dueDate, setDueDateState] = useState("")
  const [touched, setTouched] = useState(false)

  const accountTermsDays = collectionSettings?.defaultPaymentTermsDays ?? null
  const effectiveTermsDays = entityTermsDays ?? accountTermsDays
  const termsSource: DueDateTermsSource =
    entityTermsDays != null ? "entity" : accountTermsDays !== null ? "account" : null
  const resolvedDueDate =
    effectiveTermsDays !== null && date ? addDaysToIsoDate(date, effectiveTermsDays) : ""

  useEffect(() => {
    if (!touched) setDueDateState(resolvedDueDate)
  }, [resolvedDueDate, touched])

  const setDueDate = useCallback((value: string) => {
    setDueDateState(value)
    setTouched(true)
  }, [])

  return {
    dueDate,
    touched,
    setDueDate,
    effectiveTermsDays,
    termsSource,
    valueForServer: touched && dueDate ? dueDate : null,
  }
}
