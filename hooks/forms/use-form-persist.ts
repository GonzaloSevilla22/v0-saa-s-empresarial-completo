"use client"

import { useCallback, useEffect } from "react"
import { usePersistentState } from "../persistence/use-persistent-state"

interface UseFormPersistOptions {
  /** How long to keep the draft (seconds). Default: 24h */
  ttlSeconds?: number
}

interface PersistedForm<T> {
  data: T
  savedAt: number
}

interface UseFormPersistReturn<T> {
  draft: T | null
  saveDraft: (data: T) => void
  clearDraft: () => void
  hasDraft: boolean
  draftAge: number | null
}

/**
 * Persists form data as a draft in localStorage. Useful for multi-step imports,
 * long product forms, or any form where accidental navigation = data loss.
 *
 * @example
 * const { draft, saveDraft, clearDraft, hasDraft } = useFormPersist<ProductForm>(
 *   "draft:product-new"
 * )
 *
 * // On form change:
 * saveDraft(formValues)
 *
 * // On mount, restore draft if available:
 * useEffect(() => {
 *   if (draft) setFormValues(draft)
 * }, [])
 *
 * // On submit, clear the draft:
 * onSubmit: async (data) => { await save(data); clearDraft() }
 */
export function useFormPersist<T>(
  formId: string,
  options: UseFormPersistOptions = {},
): UseFormPersistReturn<T> {
  const { ttlSeconds = 60 * 60 * 24 } = options
  const storageKey = `draft:${formId}`

  const [persisted, setPersisted, clearPersisted] =
    usePersistentState<PersistedForm<T> | null>(storageKey, null)

  const isExpired =
    persisted !== null &&
    Date.now() - persisted.savedAt > ttlSeconds * 1000

  // Clear expired drafts on mount
  useEffect(() => {
    if (isExpired) clearPersisted()
  }, [isExpired, clearPersisted])

  const saveDraft = useCallback(
    (data: T) => setPersisted({ data, savedAt: Date.now() }),
    [setPersisted],
  )

  const clearDraft = useCallback(() => clearPersisted(), [clearPersisted])

  const draft = persisted !== null && !isExpired ? persisted.data : null
  const draftAge =
    persisted !== null && !isExpired
      ? Math.round((Date.now() - persisted.savedAt) / 1000)
      : null

  return { draft, saveDraft, clearDraft, hasDraft: draft !== null, draftAge }
}
