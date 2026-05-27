"use client"

import { useCallback, useState } from "react"

interface ConfirmOptions {
  title?: string
  description?: string
  confirmLabel?: string
  cancelLabel?: string
  variant?: "destructive" | "default"
}

interface ConfirmState extends ConfirmOptions {
  isOpen: boolean
  onConfirm: (() => void) | null
  onCancel: (() => void) | null
}

interface UseConfirmDialogReturn {
  dialogProps: ConfirmState
  confirm: (options?: ConfirmOptions) => Promise<boolean>
  close: () => void
}

const DEFAULT_STATE: ConfirmState = {
  isOpen: false,
  title: "¿Estás seguro?",
  description: "Esta acción no se puede deshacer.",
  confirmLabel: "Confirmar",
  cancelLabel: "Cancelar",
  variant: "default",
  onConfirm: null,
  onCancel: null,
}

/**
 * Replaces window.confirm() with a proper dialog. Returns a promise that
 * resolves to true (confirmed) or false (cancelled).
 *
 * Pair with a <ConfirmDialog> component that reads `dialogProps`.
 *
 * @example
 * const { confirm, dialogProps } = useConfirmDialog()
 *
 * const handleDelete = async () => {
 *   const ok = await confirm({
 *     title: "Eliminar producto",
 *     description: `¿Eliminar "${product.name}"? Esta acción es irreversible.`,
 *     confirmLabel: "Eliminar",
 *     variant: "destructive",
 *   })
 *   if (ok) await deleteProduct(product.id)
 * }
 *
 * // In JSX:
 * <ConfirmDialog {...dialogProps} />
 */
export function useConfirmDialog(): UseConfirmDialogReturn {
  const [state, setState] = useState<ConfirmState>(DEFAULT_STATE)

  const confirm = useCallback(
    (options: ConfirmOptions = {}): Promise<boolean> => {
      return new Promise((resolve) => {
        setState({
          ...DEFAULT_STATE,
          ...options,
          isOpen: true,
          onConfirm: () => {
            setState((prev) => ({ ...prev, isOpen: false }))
            resolve(true)
          },
          onCancel: () => {
            setState((prev) => ({ ...prev, isOpen: false }))
            resolve(false)
          },
        })
      })
    },
    [],
  )

  const close = useCallback(() => {
    state.onCancel?.()
  }, [state])

  return { dialogProps: state, confirm, close }
}
