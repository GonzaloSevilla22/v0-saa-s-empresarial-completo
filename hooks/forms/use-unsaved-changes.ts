"use client"

import { useCallback, useEffect, useRef } from "react"
import { useRouter } from "next/navigation"

interface UseUnsavedChangesOptions {
  message?: string
  /** Only block navigation when true */
  when: boolean
}

/**
 * Blocks the browser's back button and tab close when `when` is true.
 * Shows a confirm dialog before navigating away.
 *
 * Limitations: Next.js App Router doesn't expose a beforeRouteChange API,
 * so only browser-level navigation (tab close, reload, address bar) is blocked.
 * For in-app navigation, use the `confirmNavigation` return value.
 *
 * @example
 * const { confirmNavigation } = useUnsavedChanges({
 *   when: isDirty,
 *   message: "¿Salir sin guardar los cambios?",
 * })
 *
 * // In a custom back button:
 * <Button onClick={() => confirmNavigation(() => router.back())}>Volver</Button>
 */
export function useUnsavedChanges({
  message = "Tenés cambios sin guardar. ¿Querés salir igualmente?",
  when,
}: UseUnsavedChangesOptions) {
  const whenRef = useRef(when)
  const router = useRouter()

  useEffect(() => {
    whenRef.current = when
  })

  // Block browser tab close / reload
  useEffect(() => {
    if (!when) return

    const handleBeforeUnload = (e: BeforeUnloadEvent) => {
      e.preventDefault()
      e.returnValue = message
      return message
    }

    window.addEventListener("beforeunload", handleBeforeUnload)
    return () => window.removeEventListener("beforeunload", handleBeforeUnload)
  }, [when, message])

  // Utility for guarded in-app navigation
  const confirmNavigation = useCallback(
    (navigate: () => void) => {
      if (!whenRef.current) {
        navigate()
        return
      }
      if (window.confirm(message)) {
        navigate()
      }
    },
    [message],
  )

  const guardedPush = useCallback(
    (href: string) => confirmNavigation(() => router.push(href)),
    [confirmNavigation, router],
  )

  const guardedBack = useCallback(
    () => confirmNavigation(() => router.back()),
    [confirmNavigation, router],
  )

  return { confirmNavigation, guardedPush, guardedBack }
}
