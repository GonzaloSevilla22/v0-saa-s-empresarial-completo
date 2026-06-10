/**
 * TDD tests para use-courses-query — schema community (C-23).
 * courses/course_modules/course_lessons/course_enrollments/lesson_progress
 * viven en el schema `community`.
 */

import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, waitFor, act } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"
import { useCoursesQuery, useAddCourse } from "@/hooks/data/use-courses-query"

type ChainResult = { data: unknown; error: unknown }

function chainable(result: ChainResult = { data: [], error: null }) {
  const chain: Record<string, unknown> = {}
  for (const m of ["select", "insert", "update", "upsert", "delete", "eq", "in", "order", "single", "maybeSingle"]) {
    chain[m] = vi.fn(() => chain)
  }
  ;(chain as { then: unknown }).then = (resolve: (v: ChainResult) => unknown) =>
    Promise.resolve(result).then(resolve)
  return chain
}

const COURSE_ROW = {
  id: "c-1",
  title: "Finanzas para emprendedores",
  description: "Curso intro",
  level: "basico",
  is_pro: false,
  category: "Finanzas",
  students: 10,
  rating: 4.5,
  created_at: "2026-06-01T00:00:00Z",
}

const communityResults: Record<string, ChainResult> = {}
const communityFrom = vi.fn((table: string) => chainable(communityResults[table]))
const publicFrom = vi.fn(() => chainable())
const schemaSpy = vi.fn(() => ({ from: communityFrom }))

vi.mock("@/lib/supabase/client", () => ({
  createClient: vi.fn(() => ({
    auth: {
      getSession: vi.fn().mockResolvedValue({ data: { session: { user: { id: "u-1" } } }, error: null }),
      getUser: vi.fn().mockResolvedValue({ data: { user: { id: "u-1" } }, error: null }),
    },
    schema: schemaSpy,
    from: publicFrom,
  })),
}))

function makeWrapper() {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return ({ children }: { children: React.ReactNode }) =>
    React.createElement(QueryClientProvider, { client: queryClient }, children)
}

beforeEach(() => {
  vi.clearAllMocks()
  for (const k of Object.keys(communityResults)) delete communityResults[k]
})

describe("useCoursesQuery — schema community (C-23)", () => {
  it("lista cursos desde community.courses", async () => {
    communityResults.courses = { data: [COURSE_ROW], error: null }

    const { result } = renderHook(() => useCoursesQuery(), { wrapper: makeWrapper() })
    await waitFor(() => expect(result.current.isLoading).toBe(false))

    expect(schemaSpy).toHaveBeenCalledWith("community")
    expect(communityFrom).toHaveBeenCalledWith("courses")
    expect(publicFrom).not.toHaveBeenCalledWith("courses")
    expect(result.current.data?.[0]).toMatchObject({ id: "c-1", title: "Finanzas para emprendedores" })
  })

  it("useAddCourse inserta en community.courses", async () => {
    communityResults.courses = { data: null, error: null }

    const { result } = renderHook(() => useAddCourse(), { wrapper: makeWrapper() })

    await act(async () => {
      await result.current.mutateAsync({
        title: "Nuevo curso", description: "desc", level: "basico",
        isPro: false, category: "General", students: 0, rating: 5,
      })
    })

    expect(communityFrom).toHaveBeenCalledWith("courses")
    expect(publicFrom).not.toHaveBeenCalledWith("courses")
  })
})
