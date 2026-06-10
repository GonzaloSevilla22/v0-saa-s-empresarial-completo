/**
 * TDD tests para use-posts — schema community (C-23 v20-community-schema-split).
 *
 * Las tablas posts/post_likes/replies viven en el schema `community`:
 * todo acceso debe ir vía supabase.schema("community").from(...).
 * El insert de analytics_events (tabla ERP) debe permanecer en `public`
 * (supabase.from(...) directo, sin .schema()).
 */

import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, waitFor, act } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"
import { usePosts } from "@/hooks/data/use-posts"

// ── Mock del cliente supabase ─────────────────────────────────────────────────

type ChainResult = { data: unknown; error: unknown }

function chainable(result: ChainResult = { data: [], error: null }) {
  const chain: Record<string, unknown> = {}
  for (const m of ["select", "insert", "update", "delete", "eq", "order", "single", "maybeSingle"]) {
    chain[m] = vi.fn(() => chain)
  }
  ;(chain as { then: unknown }).then = (resolve: (v: ChainResult) => unknown) =>
    Promise.resolve(result).then(resolve)
  return chain
}

const POST_ROW = {
  id: "p-1",
  user_id: "u-1",
  title: "Hola comunidad",
  content: "Primer post",
  category: "General",
  created_at: "2026-06-10T00:00:00Z",
  replies_count: 0,
  likes_count: 1,
  profiles: { name: "Ana" },
  post_likes: [{ user_id: "u-1" }],
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

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("usePosts — schema community (C-23)", () => {
  it("lee el feed desde community.posts con embedding de profiles y post_likes", async () => {
    communityResults.posts = { data: [POST_ROW], error: null }

    const { result } = renderHook(() => usePosts(), { wrapper: makeWrapper() })
    await waitFor(() => expect(result.current.isLoading).toBe(false))

    expect(schemaSpy).toHaveBeenCalledWith("community")
    expect(communityFrom).toHaveBeenCalledWith("posts")
    expect(publicFrom).not.toHaveBeenCalledWith("posts")
    expect(result.current.posts[0]).toMatchObject({
      id: "p-1",
      author: "Ana",
      title: "Hola comunidad",
      isLiked: true,
    })
  })

  it("addPost inserta en community.posts y analytics_events permanece en public", async () => {
    communityResults.posts = { data: POST_ROW, error: null }

    const { result } = renderHook(() => usePosts(), { wrapper: makeWrapper() })
    await waitFor(() => expect(result.current.isLoading).toBe(false))

    await act(async () => {
      await result.current.addPost({
        title: "Nuevo", content: "Contenido", category: "General",
        userId: "u-1", author: "Ana", date: "2026-06-10", replies: 0, likes: 0,
      })
    })

    expect(communityFrom).toHaveBeenCalledWith("posts")
    // analytics_events es tabla ERP: va por public, nunca por schema community
    expect(publicFrom).toHaveBeenCalledWith("analytics_events")
    expect(communityFrom).not.toHaveBeenCalledWith("analytics_events")
  })

  it("toggleLike opera sobre community.post_likes", async () => {
    communityResults.posts = { data: [POST_ROW], error: null }
    communityResults.post_likes = { data: null, error: null }

    const { result } = renderHook(() => usePosts(), { wrapper: makeWrapper() })
    await waitFor(() => expect(result.current.isLoading).toBe(false))

    await act(async () => {
      await result.current.toggleLike("p-1")
    })

    expect(communityFrom).toHaveBeenCalledWith("post_likes")
    expect(publicFrom).not.toHaveBeenCalledWith("post_likes")
  })

  it("addReply y getReplies usan community.replies", async () => {
    communityResults.replies = { data: [], error: null }

    const { result } = renderHook(() => usePosts(), { wrapper: makeWrapper() })
    await waitFor(() => expect(result.current.isLoading).toBe(false))

    await act(async () => {
      await result.current.addReply("p-1", "una respuesta")
      await result.current.getReplies("p-1")
    })

    expect(communityFrom).toHaveBeenCalledWith("replies")
    expect(publicFrom).not.toHaveBeenCalledWith("replies")
  })
})
