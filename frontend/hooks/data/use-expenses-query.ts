"use client"

import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query"
import { pythonClient } from "@/lib/api/python-client"
import { queryKeys } from "@/lib/query-keys"
import type { Expense } from "@/lib/types"

// ── Types for API responses ───────────────────────────────────────────────────

interface ExpenseApiRow {
  id: string
  account_id: string
  user_id?: string
  category: string
  amount: string | number
  description: string | null
  date: string
  created_at: string
  // cost-center-dimension: optional analytic dimension
  cost_center_id?: string | null
}

function mapExpense(e: ExpenseApiRow): Expense {
  return {
    id:            e.id,
    date:          typeof e.date === "string" ? e.date.split("T")[0] : String(e.date),
    category:      e.category,
    description:   e.description || "",
    amount:        Number(e.amount),
    costCenterId:  e.cost_center_id ?? null,
  }
}

// ── Unified hook ─────────────────────────────────────────────────────────────

/**
 * Returns expenses list + mutations (add, update, delete) via Python API.
 */
export function useExpenses() {
  const queryClient = useQueryClient()

  const query = useQuery({
    queryKey: queryKeys.expenses.lists(),
    queryFn: async (): Promise<Expense[]> => {
      const data = await pythonClient.get<ExpenseApiRow[]>("/expenses")
      return data.map(mapExpense)
    },
    staleTime: 60 * 1000, // 1 min
  })

  const addExpenseMutation = useMutation({
    mutationFn: async (expense: Omit<Expense, "id">) => {
      return pythonClient.post<ExpenseApiRow>("/expenses", {
        category:        expense.category,
        description:     expense.description ?? null,
        amount:          expense.amount,
        date:            expense.date,
        // cost-center-dimension: optional analytic dimension
        cost_center_id:  expense.costCenterId ?? null,
      })
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.expenses.all() })
    },
  })

  const updateExpenseMutation = useMutation({
    mutationFn: async (expense: Expense) => {
      return pythonClient.put<ExpenseApiRow>(`/expenses/${expense.id}`, {
        category:    expense.category,
        description: expense.description ?? null,
        amount:      expense.amount,
        date:        expense.date,
      })
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.expenses.all() })
    },
  })

  const deleteExpenseMutation = useMutation({
    mutationFn: async (id: string) => {
      return pythonClient.delete<void>(`/expenses/${id}`)
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.expenses.all() })
    },
  })

  return {
    expenses:      query.data ?? [],
    isLoading:     query.isLoading,
    isError:       query.isError,
    error:         query.error,
    addExpense:    addExpenseMutation.mutateAsync,
    updateExpense: updateExpenseMutation.mutateAsync,
    deleteExpense: deleteExpenseMutation.mutateAsync,
    // Individual mutation states for UI feedback
    addExpenseMutation,
    updateExpenseMutation,
    deleteExpenseMutation,
  }
}

// ── Legacy individual exports (kept for backward compatibility) ───────────────

/** @deprecated Use `useExpenses()` instead */
export function useAddExpense() {
  const { addExpenseMutation } = useExpenses()
  return addExpenseMutation
}

/** @deprecated Use `useExpenses()` instead */
export function useUpdateExpense() {
  const { updateExpenseMutation } = useExpenses()
  return updateExpenseMutation
}

/** @deprecated Use `useExpenses()` instead */
export function useDeleteExpense() {
  const { deleteExpenseMutation } = useExpenses()
  return deleteExpenseMutation
}
