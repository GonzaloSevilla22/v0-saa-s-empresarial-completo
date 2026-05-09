"use client"

import { useState, useEffect, useMemo } from "react"
import { createClient } from "@/lib/supabase/client"
import type { UnitOfMeasure } from "@/lib/types"

interface UseUnitsOfMeasureResult {
  units: UnitOfMeasure[]
  loading: boolean
  error: string | null
}

/**
 * Fetches all units of measure visible to the current user:
 *   - System units (is_system = true, available to everyone)
 *   - User's own custom units (user_id = auth.uid())
 *
 * RLS on units_of_measure enforces this automatically.
 * Results are ordered by type then name for a consistent selector list.
 */
export function useUnitsOfMeasure(): UseUnitsOfMeasureResult {
  const [units, setUnits] = useState<UnitOfMeasure[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  // Stable client instance — recreated only on mount (same pattern as data-context)
  const supabase = useMemo(() => createClient(), [])

  useEffect(() => {
    let active = true

    async function fetchUnits() {
      setLoading(true)
      const { data, error: fetchError } = await supabase
        .from("units_of_measure")
        .select("id, name, symbol, type, factor, base_unit_id, is_system")
        .order("type")
        .order("name")

      if (!active) return

      if (fetchError) {
        setError(fetchError.message)
      } else {
        setUnits(
          (data ?? []).map((u) => ({
            id: u.id,
            name: u.name,
            symbol: u.symbol,
            type: u.type as UnitOfMeasure["type"],
            factor: Number(u.factor),
            baseUnitId: u.base_unit_id ?? undefined,
            isSystem: u.is_system,
          })),
        )
        setError(null)
      }
      setLoading(false)
    }

    fetchUnits()
    return () => {
      active = false
    }
  }, [supabase])

  return { units, loading, error }
}
