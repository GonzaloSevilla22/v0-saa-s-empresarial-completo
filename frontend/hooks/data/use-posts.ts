"use client"

import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query"
import { useMemo } from "react"
import { createClient } from "@/lib/supabase/client"
import { queryKeys } from "@/lib/query-keys"
import type { Post, Reply } from "@/lib/types"

// ── Mappers ───────────────────────────────────────────────────────────────────

function mapPost(po: any, userId: string): Post {
  const profile = Array.isArray(po.profiles) ? po.profiles[0] : po.profiles
  const likes   = Array.isArray(po.post_likes) ? po.post_likes : []
  return {
    id:       po.id,
    userId:   po.user_id,
    author:   profile?.name || "Usuario",
    title:    po.title,
    content:  po.content,
    category: po.category     || "General",
    date:     po.created_at?.split("T")[0] || new Date().toISOString().split("T")[0],
    replies:  po.replies_count || 0,
    likes:    po.likes_count   || 0,
    isLiked:  likes.some((l: any) => l.user_id === userId) || false,
  }
}

// ── Hook ─────────────────────────────────────────────────────────────────────

/**
 * Returns posts list + mutations (add, delete, toggleLike, addReply, getReplies).
 * Uses Supabase directly — posts are not migrated to the Python API.
 */
export function usePosts() {
  const queryClient = useQueryClient()
  const supabase    = useMemo(() => createClient(), [])

  const query = useQuery({
    queryKey: queryKeys.posts.all(),
    queryFn: async (): Promise<Post[]> => {
      // getSession() is cache-backed — no network round-trip needed
      const { data: { session } } = await supabase.auth.getSession()
      const userId = session?.user?.id || ""

      const { data, error } = await supabase
        .from("posts")
        .select("*, profiles(name), post_likes(user_id)")
        .order("created_at", { ascending: false })

      if (error) throw error
      return (data ?? []).map((po: any) => mapPost(po, userId))
    },
    staleTime: 60 * 1000,
  })

  const addPostMutation = useMutation({
    mutationFn: async (post: Omit<Post, "id">) => {
      const { data: { user } } = await supabase.auth.getUser()
      if (!user) throw new Error("No autenticado")

      const { data, error } = await supabase.from("posts").insert([{
        user_id:  user.id,
        title:    post.title,
        content:  post.content,
        category: post.category,
      }]).select().single()

      if (error) throw error

      if (data) {
        void supabase.from("analytics_events").insert([{
          user_id:    user.id,
          event_name: "post_created",
          event_data: { post_id: data.id },
        }])
      }

      return data
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.posts.all() })
    },
  })

  const deletePostMutation = useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase.from("posts").delete().eq("id", id)
      if (error) throw error
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.posts.all() })
    },
  })

  const toggleLikeMutation = useMutation({
    mutationFn: async (postId: string) => {
      const { data: { session } } = await supabase.auth.getSession()
      const userId = session?.user?.id
      if (!userId) throw new Error("No autenticado")

      const { data: existing, error: findError } = await supabase
        .from("post_likes")
        .select("id")
        .eq("post_id", postId)
        .eq("user_id", userId)
        .maybeSingle()

      if (findError) throw findError

      if (existing) {
        const { error } = await supabase.from("post_likes").delete().eq("id", existing.id)
        if (error) throw error
      } else {
        const { error } = await supabase.from("post_likes").insert([{ post_id: postId, user_id: userId }])
        if (error) throw error
      }
    },
    onMutate: async (postId: string) => {
      await queryClient.cancelQueries({ queryKey: queryKeys.posts.all() })
      const previous = queryClient.getQueryData<Post[]>(queryKeys.posts.all())

      // Optimistic update — flip the like immediately
      queryClient.setQueryData<Post[]>(queryKeys.posts.all(), old =>
        (old ?? []).map(p => {
          if (p.id !== postId) return p
          const wasLiked = p.isLiked ?? false
          return { ...p, isLiked: !wasLiked, likes: wasLiked ? p.likes - 1 : p.likes + 1 }
        })
      )

      return { previous }
    },
    onError: (_err, _postId, context) => {
      if (context?.previous) {
        queryClient.setQueryData(queryKeys.posts.all(), context.previous)
      }
    },
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.posts.all() })
    },
  })

  async function getReplies(postId: string): Promise<Reply[]> {
    const { data } = await supabase
      .from("replies")
      .select("*, profiles(name)")
      .eq("post_id", postId)
      .order("created_at", { ascending: true })

    if (!data) return []
    return data.map((r: any) => ({
      id:        r.id,
      postId:    r.post_id,
      userId:    r.user_id,
      author:    r.profiles?.name || "Usuario",
      content:   r.content,
      createdAt: r.created_at,
    }))
  }

  async function addReply(postId: string, content: string): Promise<void> {
    const { data: { session } } = await supabase.auth.getSession()
    const userId = session?.user?.id
    if (!userId) return

    const { error } = await supabase.from("replies").insert([{
      post_id: postId,
      user_id: userId,
      content,
    }])

    if (error) throw error
    // replies_count is updated by the DB trigger on_post_reply_change
    // Realtime subscription handles refresh — no manual call needed
  }

  return {
    posts:           query.data ?? [],
    isLoading:       query.isLoading,
    isError:         query.isError,
    error:           query.error,
    addPost:         addPostMutation.mutateAsync,
    deletePost:      deletePostMutation.mutateAsync,
    toggleLike:      toggleLikeMutation.mutateAsync,
    getReplies,
    addReply,
    addPostMutation,
    deletePostMutation,
    toggleLikeMutation,
  }
}
