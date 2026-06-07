"use client"

import { useCallback, useEffect, useRef, useState } from "react"
import { useDebouncedCallback } from "../ui/use-debounce"

type AutosaveStatus = "idle" | "saving" | "saved" | "error"

interface UseAutosaveOptions<T> {
  data: T
  onSave: (data: T) => Promise<void>
  /** Debounce delay before triggering save. Default: 1500ms */
  delay?: number
  /** Only autosave when true (e.g., after first user interaction) */
  enabled?: boolean
}

interface UseAutosaveReturn {
  status: AutosaveStatus
  lastSaved: Date | null
  saveNow: () => Promise<void>
  error: string | null
}

/**
 * Autosaves form data after the user stops typing. Shows saving/saved/error status.
 * Ideal for long forms (import configuration, product descriptions, notes).
 *
 * @example
 * const { status, lastSaved } = useAutosave({
 *   data: formValues,
 *   onSave: async (values) => await updateDraft(values),
 *   enabled: isDirty,
 * })
 *
 * {status === "saving" && <Spinner />}
 * {status === "saved" && <CheckIcon />}
 * {lastSaved && <span>Guardado {formatRelative(lastSaved)}</span>}
 */
export function useAutosave<T>({
  data,
  onSave,
  delay = 1500,
  enabled = true,
}: UseAutosaveOptions<T>): UseAutosaveReturn {
  const [status, setStatus] = useState<AutosaveStatus>("idle")
  const [lastSaved, setLastSaved] = useState<Date | null>(null)
  const [error, setError] = useState<string | null>(null)
  const onSaveRef = useRef(onSave)
  const isFirstRender = useRef(true)

  useEffect(() => {
    onSaveRef.current = onSave
  })

  const doSave = useCallback(async (currentData: T) => {
    setStatus("saving")
    setError(null)
    try {
      await onSaveRef.current(currentData)
      setStatus("saved")
      setLastSaved(new Date())
      // Reset to idle after 2s so the "Saved" indicator fades
      setTimeout(() => setStatus("idle"), 2000)
    } catch (err) {
      setStatus("error")
      setError(err instanceof Error ? err.message : "Error al guardar")
    }
  }, [])

  const debouncedSave = useDebouncedCallback(doSave, delay)

  const saveNow = useCallback(() => doSave(data), [data, doSave])

  useEffect(() => {
    // Skip the first render — we don't want to save before the user types
    if (isFirstRender.current) {
      isFirstRender.current = false
      return
    }
    if (!enabled) return
    debouncedSave(data)
  }, [data, enabled, debouncedSave])

  return { status, lastSaved, saveNow, error }
}
