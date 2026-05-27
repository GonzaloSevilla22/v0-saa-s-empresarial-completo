"use client"

import { usePersistentState } from "./use-persistent-state"

/**
 * sessionStorage-backed state. Cleared when the tab closes.
 * Use for wizard step progress, unsaved form data (short-lived).
 *
 * @example
 * const [step, setStep] = useSessionStorage("import:step", 1)
 */
export function useSessionStorage<T>(
  key: string,
  initialValue: T,
): [T, (value: T | ((prev: T) => T)) => void, () => void] {
  return usePersistentState(key, initialValue, { backend: "sessionStorage" })
}
