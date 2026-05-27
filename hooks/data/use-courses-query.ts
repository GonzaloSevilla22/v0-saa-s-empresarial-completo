"use client"

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useMemo } from "react"
import { createClient } from "@/lib/supabase/client"
import { queryKeys } from "@/lib/query-keys"
import type { Course } from "@/lib/types"

// ── Mapper (same logic as DataContext.mapCourse, kept co-located) ─────────────

function mapCourse(raw: Record<string, unknown>): Course {
  return {
    id:          raw.id as string,
    title:       raw.title as string,
    description: raw.description as string,
    level:       ((raw.level as string) || "basico") as Course["level"],
    isPro:       (raw.is_pro as boolean) ?? false,
    modules:     [],
    category:    (raw.category as string) || "General",
    students:    (raw.students as number) || 0,
    rating:      raw.rating != null ? Number(raw.rating) : 5,
  }
}

function translateError(err: { code?: string; message?: string } | null): string {
  if (!err) return "Error desconocido"
  switch (err.code) {
    case "23505": return "Ya existe un curso con ese título."
    case "42501": return "No tenés permisos para realizar esta acción."
    default:      return err.message || "Ocurrió un error inesperado."
  }
}

// ── Query ─────────────────────────────────────────────────────────────────────

async function fetchCourses(): Promise<Course[]> {
  const supabase = createClient()
  const { data, error } = await supabase
    .from("courses")
    .select("*")
    .order("created_at", { ascending: false })
  if (error) throw new Error(translateError(error))
  return (data ?? []).map(mapCourse)
}

export function useCoursesQuery() {
  return useQuery({
    queryKey: queryKeys.courses.lists(),
    queryFn:  fetchCourses,
  })
}

// ── Mutations ─────────────────────────────────────────────────────────────────

type CourseInput = Omit<Course, "id" | "modules">

export function useAddCourse() {
  const queryClient = useQueryClient()
  const supabase    = useMemo(() => createClient(), [])

  return useMutation({
    mutationFn: async (input: CourseInput) => {
      const { error } = await supabase.from("courses").insert([{
        title:       input.title,
        description: input.description,
        is_pro:      input.isPro,
        level:       input.level,
        category:    input.category,
        students:    input.students,
        rating:      input.rating,
        content:     "",
      }])
      if (error) throw new Error(translateError(error))
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.courses.all() })
    },
  })
}

export function useUpdateCourse() {
  const queryClient = useQueryClient()
  const supabase    = useMemo(() => createClient(), [])

  return useMutation({
    mutationFn: async (input: Omit<Course, "modules">) => {
      const { error } = await supabase.from("courses").update({
        title:       input.title,
        description: input.description,
        is_pro:      input.isPro,
        level:       input.level,
        category:    input.category,
        students:    input.students,
        rating:      input.rating,
      }).eq("id", input.id)
      if (error) throw new Error(translateError(error))
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.courses.all() })
    },
  })
}

export function useDeleteCourse() {
  const queryClient = useQueryClient()
  const supabase    = useMemo(() => createClient(), [])

  return useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase.from("courses").delete().eq("id", id)
      if (error) throw new Error(translateError(error))
    },
    onMutate: async (id) => {
      // Optimistic: remove from list immediately
      await queryClient.cancelQueries({ queryKey: queryKeys.courses.all() })
      const previous = queryClient.getQueryData<Course[]>(queryKeys.courses.lists())
      queryClient.setQueryData<Course[]>(
        queryKeys.courses.lists(),
        (old) => (old ?? []).filter((c) => c.id !== id),
      )
      return { previous }
    },
    onError: (_err, _id, context) => {
      // Rollback optimistic update
      if (context?.previous) {
        queryClient.setQueryData(queryKeys.courses.lists(), context.previous)
      }
    },
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.courses.all() })
    },
  })
}
