"use client"

/**
 * useEditPlanFlow — «guardar → pedir el plan al servidor → confirmar → ejecutar» de una edición que puede tocar dinero
 * (edicion-operaciones-con-dinero, tanda C, D13/D17). Lo comparten los tres formularios de edición (venta, compra y gasto).
 *
 * El formulario sólo decide SI hace falta pedir el plan (`needsPlan`: la operación ya tiene dinero registrado o la forma de
 * pago elegida puede escribirlo). El que decide si el usuario tiene que confirmar es el plan que devuelve el SERVIDOR
 * (`planNeedsConfirmation`): sin cambios en ningún libro se guarda directo, y con cambios o con un bloqueo se abre el
 * diálogo. La edición real vuelve a evaluar todo en la misma transacción, así que si algo cambió entre la vista previa y el
 * guardado manda el servidor (su respuesta trae el plan que ejecutó).
 */

import { useCallback, useRef, useState } from "react"
import { planNeedsConfirmation, type EditPreview } from "@/lib/money-plan"

interface UseEditPlanFlowOptions {
  /** ¿Hay que pedir la vista previa antes de guardar? */
  needsPlan: boolean
  /** Pide el plan al servidor (la misma RPC en seco). */
  preview: () => Promise<EditPreview>
  /** Ejecuta la edición real; maneja sus propios errores (toast). */
  execute: () => Promise<void>
  /** La vista previa falló: nada se guardó. */
  onPreviewError: (error: unknown) => void
}

export interface EditPlanFlow {
  /** Dispara el flujo desde el submit. */
  requestSave: () => Promise<void>
  /** Confirmación del diálogo. */
  confirm: () => Promise<void>
  dialogOpen: boolean
  setDialogOpen: (open: boolean) => void
  /** El plan que mostró el servidor (null mientras no hay uno). */
  preview: EditPreview | null
  /** Se está calculando el plan. */
  previewing: boolean
  /** Se está ejecutando la edición confirmada. */
  executing: boolean
}

export function useEditPlanFlow({ needsPlan, preview, execute, onPreviewError }: UseEditPlanFlowOptions): EditPlanFlow {
  const [dialogOpen, setDialogOpenState] = useState(false)
  const [plan, setPlan] = useState<EditPreview | null>(null)
  const [previewing, setPreviewing] = useState(false)
  const [executing, setExecuting] = useState(false)
  // Cierra la ventana de doble clic antes de que el estado re-renderice el botón.
  const busyRef = useRef(false)

  const setDialogOpen = useCallback((open: boolean) => {
    setDialogOpenState(open)
    if (!open) setPlan(null)
  }, [])

  const requestSave = useCallback(async () => {
    if (busyRef.current) return
    if (!needsPlan) {
      await execute()
      return
    }
    busyRef.current = true
    setPreviewing(true)
    let result: EditPreview | null = null
    try {
      result = await preview()
    } catch (error) {
      onPreviewError(error)
      return
    } finally {
      setPreviewing(false)
      busyRef.current = false
    }
    if (planNeedsConfirmation(result)) {
      setPlan(result)
      setDialogOpenState(true)
      return
    }
    await execute()
  }, [needsPlan, preview, execute, onPreviewError])

  const confirm = useCallback(async () => {
    // Un bloqueo no se ejecuta: el servidor lo rechazaría igual.
    if (!plan || plan.plan.blocks.length > 0 || busyRef.current) return
    busyRef.current = true
    setExecuting(true)
    try {
      await execute()
    } finally {
      setExecuting(false)
      busyRef.current = false
      setDialogOpenState(false)
      setPlan(null)
    }
  }, [plan, execute])

  return { requestSave, confirm, dialogOpen, setDialogOpen, preview: plan, previewing, executing }
}
