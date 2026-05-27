"use client"

import { useMutation, useQueryClient } from "@tanstack/react-query"
import { useMemo } from "react"
import { createClient } from "@/lib/supabase/client"
import { queryKeys } from "@/lib/query-keys"
import type { Expense } from "@/lib/types"

// ── Error translation ─────────────────────────────────────────────────────────

function translateError(err: { code?: string; message?: string } | null): string {
  if (!err) return "Error desconocido"
  switch (err.code) {
    case "23503": return "No se puede eliminar: el gasto está siendo referenciado."
    case "42501": return "No tenés permisos para realizar esta acción."
    default:      return err.message || "Ocurrió un error inesperado."
  }
}

// ── Mutations ─────────────────────────────────────────────────────────────────
// NOTE: The DataContext still holds `expenses` state for Dashboard computed values
// (getTodayExpenses, getNetProfit). These mutations invalidate the React Query cache.
// The DataContext stays in sync via Supabase Realtime (rt-expenses channel).

export function useAddExpense() {
  const queryClient = useQueryClient()
  const supabase    = useMemo(() => createClient(), [])

  return useMutation({
    mutationFn: async (expense: Omit<Expense, "id">) => {
      const { data: { user } } = await supabase.auth.getUser()
      if (!user) throw new Error("No autenticado")

      const { error } = await supabase.from("expenses").insert([{
        user_id:     user.id,
        date:        expense.date,
        category:    expense.category,
        description: expense.description,
        amount:      expense.amount,
      }])
      if (error) throw new Error(translateError(error))
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.expenses.all() })
    },
  })
}

export function useUpdateExpense() {
  const queryClient = useQueryClient()
  const supabase    = useMemo(() => createClient(), [])

  return useMutation({
    mutationFn: async (expense: Expense) => {
      const { error } = await supabase.from("expenses").update({
        category:    expense.category,
        description: expense.description,
        amount:      expense.amount,
        date:        expense.date,
      }).eq("id", expense.id)
      if (error) throw new Error(translateError(error))
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.expenses.all() })
    },
  })
}

export function useDeleteExpense() {
  const queryClient = useQueryClient()
  const supabase    = useMemo(() => createClient(), [])

  return useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase.from("expenses").delete().eq("id", id)
      if (error) throw new Error(translateError(error))
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.expenses.all() })
    },
  })
}
