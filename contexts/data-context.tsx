"use client"

import React, {
  createContext, useContext, useState,
  useCallback, useMemo, useEffect,
} from "react"
import { createClient } from "@/lib/supabase/client"
import { services } from "@/lib/supabase/services"
import type { Product, Sale, Purchase, Expense, Client, Insight, Post, Course, Reply } from "@/lib/types"

// ── Context interface ──────────────────────────────────────────────────────────

interface DataContextType {
  products:  Product[]
  sales:     Sale[]
  purchases: Purchase[]
  expenses:  Expense[]
  clients:   Client[]
  insights:  Insight[]
  posts:     Post[]
  courses:   Course[]
  loading:   boolean
  addProduct:    (p: Omit<Product, "id">) => Promise<void>
  updateProduct: (p: Product) => Promise<void>
  deleteProduct: (id: string) => Promise<void>
  addSale:    (s: Omit<Sale, "id">) => Promise<void>
  updateSale: (s: Sale) => Promise<void>
  deleteSale: (id: string) => Promise<void>
  /** Deletes ALL sales rows that share the given operation_id (one DB call). */
  deleteSalesByOperation: (operationId: string) => Promise<void>
  addPurchase:    (p: Omit<Purchase, "id">) => Promise<void>
  updatePurchase: (p: Purchase) => Promise<void>
  deletePurchase: (id: string) => Promise<void>
  /** Deletes ALL purchases rows that share the given operation_id (one DB call). */
  deletePurchasesByOperation: (operationId: string) => Promise<void>
  addExpense:    (e: Omit<Expense, "id">) => Promise<void>
  updateExpense: (e: Expense) => Promise<void>
  deleteExpense: (id: string) => Promise<void>
  addClient:    (c: Omit<Client, "id">) => Promise<void>
  updateClient: (c: Client) => Promise<void>
  deleteClient: (id: string) => Promise<void>
  addInsight: (i: Insight) => void
  addPost:    (p: Omit<Post, "id">) => Promise<void>
  deletePost: (id: string) => Promise<void>
  toggleLike: (postId: string) => Promise<void>
  addReply:   (postId: string, content: string) => Promise<void>
  getReplies: (postId: string) => Promise<Reply[]>
  addCourse:    (c: Omit<Course, "id" | "modules">) => Promise<void>
  updateCourse: (c: Omit<Course, "modules">) => Promise<void>
  deleteCourse: (id: string) => Promise<void>
  // Computed
  getTodaySales:       () => number
  getTodayExpenses:    () => number
  getNetProfit:        () => number
  getLowStockProducts: () => Product[]
  getSalesByDay:       (days: number) => { date: string; total: number }[]
  /** Full re-fetch of all data slices. Use sparingly — prefer domain-specific fns internally. */
  refreshData: () => Promise<void>
}

const DataContext = createContext<DataContextType | null>(null)

// ── Pure mapping helpers (outside component — never recreated) ─────────────────

function mapProduct(p: any): Product {
  return {
    id:               p.id,
    name:             p.name,
    category:         p.category || "Otros",
    cost:             Number(p.cost),
    price:            Number(p.price),
    margin:           p.price > 0 ? Math.round(((p.price - p.cost) / p.price) * 100) : 0,
    stock:            p.stock,
    minStock:         p.min_stock || 0,
    barcode:          p.barcode,
    parentId:         p.parent_id  ?? undefined,
    isVariant:        p.is_variant ?? false,
    baseUnitId:       p.base_unit_id   ?? undefined,
    stockControlType: p.stock_control_type ?? 'tracked',
  }
}

function mapSale(s: any): Sale {
  // DB schema: `amount` = unit price per item; `total` = amount × quantity (computed by RPC).
  // Do NOT divide amount by quantity — amount already IS the unit price.
  return {
    id:          s.id,
    date:        s.date.split("T")[0],
    productId:   s.product_id,
    productName: s.product?.name || "Eliminado",
    clientId:    s.client_id,
    clientName:  s.client?.name || "Consumidor Final",
    quantity:    s.quantity,
    unitPrice:   Number(s.amount),
    total:       Number(s.total ?? s.amount),
    currency:    s.currency as any,
    operationId: s.operation_id ?? undefined,
  }
}

function mapPurchase(pr: any): Purchase {
  // DB schema: `amount` = unit cost per item; `total` = amount × quantity (computed by RPC).
  // Do NOT divide amount by quantity — amount already IS the unit cost per item.
  return {
    id:          pr.id,
    date:        pr.date.split("T")[0],
    productId:   pr.product_id,
    productName: pr.product?.name || "Eliminado",
    quantity:    pr.quantity,
    unitCost:    Number(pr.amount),
    total:       Number(pr.total ?? pr.amount),
    operationId: pr.operation_id ?? undefined,
  }
}

function mapExpense(e: any): Expense {
  return {
    id:          e.id,
    date:        e.date.split("T")[0],
    category:    e.category,
    description: e.description || "",
    amount:      Number(e.amount),
  }
}

function mapClient(c: any): Client {
  // NOTE: `lastPurchase` and `totalSpent` are intentionally left at sentinel
  // values here. The DataProvider derives them via `clientsWithMetrics` useMemo
  // by aggregating the already-loaded `sales` state. This avoids an extra DB
  // join and stays reactive to realtime sale events automatically.
  return {
    id:           c.id,
    name:         c.name,
    email:        c.email        || "",
    phone:        c.phone        || "",
    status:       c.status       || "activo",
    lastPurchase: "-",
    totalSpent:   0,
    category:     c.category,
  }
}

function mapInsight(i: any): Insight {
  return {
    id:       i.id,
    type:     i.type,
    priority: i.priority as any,
    message:  i.message,
    date:     i.created_at.split("T")[0],
  }
}

function mapPost(po: any, userId: string): Post {
  const profile = Array.isArray(po.profiles) ? po.profiles[0] : po.profiles
  const likes   = Array.isArray(po.post_likes) ? po.post_likes : []
  return {
    id:          po.id,
    userId:      po.user_id,
    author:      profile?.name || "Usuario",
    title:       po.title,
    content:     po.content,
    category:    po.category     || "General",
    date:        po.created_at?.split("T")[0] || new Date().toISOString().split("T")[0],
    replies:     po.replies_count || 0,
    likes:       po.likes_count   || 0,
    isLiked:     likes.some((l: any) => l.user_id === userId) || false,
  }
}

function mapCourse(cr: any): Course {
  return {
    id:          cr.id,
    title:       cr.title,
    description: cr.description,
    level:       (cr.level as "basico" | "intermedio" | "avanzado") || "basico",
    isPro:       cr.is_pro ?? false,
    modules:     [],
    category:    cr.category || "General",
    students:    cr.students  || 0,
    rating:      cr.rating ? Number(cr.rating) : 5,
  }
}

/** Translates raw Postgres / Supabase error objects into clear Spanish messages. */
function translateDbError(error: { code?: string; message?: string } | null): string {
  if (!error) return "Error desconocido"
  switch (error.code) {
    case "23503": return "No se puede eliminar: el registro está siendo usado en otros datos del sistema."
    case "23505": return "Ya existe un registro con esos datos. Revisá los campos duplicados."
    case "42501": return "No tenés permisos para realizar esta acción."
    case "PGRST116": return "No se encontró el registro."
    default:      return error.message || "Ocurrió un error inesperado. Intentá nuevamente."
  }
}

// ── Provider ──────────────────────────────────────────────────────────────────

export function DataProvider({ children }: { children: React.ReactNode }) {
  // ── CRITICAL FIX: supabase memoized — stable reference across renders.
  // Previously created fresh on every render, causing all useCallbacks that
  // depend on it (refreshData, every mutation) to also change on every render,
  // which triggered an infinite re-render + re-subscription loop.
  const supabase = useMemo(() => createClient(), [])

  const [products,  setProducts]  = useState<Product[]>([])
  const [sales,     setSales]     = useState<Sale[]>([])
  const [purchases, setPurchases] = useState<Purchase[]>([])
  const [expenses,  setExpenses]  = useState<Expense[]>([])
  const [clients,   setClients]   = useState<Client[]>([])
  const [insights,  setInsights]  = useState<Insight[]>([])
  const [posts,     setPosts]     = useState<Post[]>([])
  const [courses,   setCourses]   = useState<Course[]>([])
  const [loading,   setLoading]   = useState(true)

  // ── Domain-specific refresh functions ─────────────────────────────────────
  // Internal — not exposed via context. Each fetches exactly one table.
  // Stable references (only depend on memoized supabase).

  const refreshProducts = useCallback(async () => {
    const { data } = await supabase
      .from("products")
      .select("*")
      .order("created_at", { ascending: false })
    if (data) setProducts(data.map(mapProduct))
  }, [supabase])

  const refreshSales = useCallback(async () => {
    const { data } = await supabase
      .from("sales")
      .select("*, product:products(name), client:clients(name)")
      .order("date", { ascending: false })
    if (data) setSales(data.map(mapSale))
  }, [supabase])

  const refreshPurchases = useCallback(async () => {
    const { data } = await supabase
      .from("purchases")
      .select("*, product:products(name)")
      .order("date", { ascending: false })
    if (data) setPurchases(data.map(mapPurchase))
  }, [supabase])

  const refreshExpenses = useCallback(async () => {
    const { data } = await supabase
      .from("expenses")
      .select("*")
      .order("date", { ascending: false })
    if (data) setExpenses(data.map(mapExpense))
  }, [supabase])

  const refreshClients = useCallback(async () => {
    const { data } = await supabase
      .from("clients")
      .select("*")
      .order("created_at", { ascending: false })
    if (data) setClients(data.map(mapClient))
  }, [supabase])

  const refreshInsights = useCallback(async () => {
    const { data } = await supabase
      .from("ai_insights")
      .select("*")
      .order("created_at", { ascending: false })
    if (data) setInsights(data.map(mapInsight))
  }, [supabase])

  const refreshPosts = useCallback(async () => {
    // getSession() is cache-backed — no network round-trip needed
    const { data: { session } } = await supabase.auth.getSession()
    const userId = session?.user?.id || ""
    const { data } = await supabase
      .from("posts")
      .select("*, profiles(name), post_likes(user_id)")
      .order("created_at", { ascending: false })
    if (data) setPosts(data.map(po => mapPost(po, userId)))
  }, [supabase])

  const refreshCourses = useCallback(async () => {
    const { data, error } = await supabase.from("courses").select("*")
    if (error) {
      console.error("Error fetching courses:", error)
      setCourses([])
    } else if (data) {
      setCourses(data.map(mapCourse))
    }
  }, [supabase])

  // ── Full refresh — used for initial load and post-AI-generation ────────────
  // Now uses all domain-specific functions in parallel (including courses).

  const refreshData = useCallback(async () => {
    try {
      const { data: { user } } = await supabase.auth.getUser()
      if (!user) return

      await Promise.all([
        refreshProducts(),
        refreshSales(),
        refreshPurchases(),
        refreshExpenses(),
        refreshClients(),
        refreshInsights(),
        refreshPosts(),
        refreshCourses(),   // ← was sequential before (after the Promise.all), now parallel
      ])
    } catch (err) {
      console.error("Error fetching data:", err)
    } finally {
      setLoading(false)
    }
  }, [
    supabase,
    refreshProducts, refreshSales, refreshPurchases, refreshExpenses,
    refreshClients,  refreshInsights, refreshPosts,   refreshCourses,
  ])

  // ── Initial load ───────────────────────────────────────────────────────────
  // With stable refreshData (depends only on stable supabase + stable domain fns),
  // this effect runs exactly once on mount. No render loop.

  useEffect(() => {
    refreshData()
  }, [refreshData])

  // ── Realtime subscriptions (centralised here, not in individual pages) ─────
  // Moved here from each module page to:
  //   1. Prevent duplicate subscriptions when multiple pages subscribe to the same table.
  //   2. Ensure subscriptions are stable — they only tear down on DataProvider unmount,
  //      not on every page navigation.
  //   3. Each callback calls only the relevant single-table refresh (not a full re-fetch).

  useEffect(() => {
    const productsCh = supabase
      .channel("rt-products")
      .on("postgres_changes", { event: "*", schema: "public", table: "products" },
        () => refreshProducts())
      .subscribe()

    const salesCh = supabase
      .channel("rt-sales")
      .on("postgres_changes", { event: "*", schema: "public", table: "sales" },
        () => refreshSales())
      .subscribe()

    const purchasesCh = supabase
      .channel("rt-purchases")
      .on("postgres_changes", { event: "*", schema: "public", table: "purchases" },
        () => refreshPurchases())
      .subscribe()

    const expensesCh = supabase
      .channel("rt-expenses")
      .on("postgres_changes", { event: "*", schema: "public", table: "expenses" },
        () => refreshExpenses())
      .subscribe()

    const clientsCh = supabase
      .channel("rt-clients")
      .on("postgres_changes", { event: "*", schema: "public", table: "clients" },
        () => refreshClients())
      .subscribe()

    const postsCh = supabase
      .channel("rt-posts")
      .on("postgres_changes", { event: "*", schema: "public", table: "posts" },
        () => refreshPosts())
      .subscribe()

    return () => {
      supabase.removeChannel(productsCh)
      supabase.removeChannel(salesCh)
      supabase.removeChannel(purchasesCh)
      supabase.removeChannel(expensesCh)
      supabase.removeChannel(clientsCh)
      supabase.removeChannel(postsCh)
    }
  }, [supabase, refreshProducts, refreshSales, refreshPurchases, refreshExpenses, refreshClients, refreshPosts])

  // ── Products ───────────────────────────────────────────────────────────────

  const addProduct = useCallback(async (p: Omit<Product, "id">) => {
    const { data: { user } } = await supabase.auth.getUser()
    if (!user) return
    const { error } = await supabase.from("products").insert([{
      user_id:            user.id,
      name:               p.name,
      category:           p.category,
      price:              p.price,
      cost:               p.cost,
      stock:              p.stock,
      min_stock:          p.minStock,
      barcode:            p.barcode,
      parent_id:          p.parentId          ?? null,
      is_variant:         p.isVariant,
      base_unit_id:       p.baseUnitId        ?? null,
      stock_control_type: p.stockControlType  ?? 'tracked',
    }])
    if (error) throw new Error(translateDbError(error))
    await refreshProducts()
  }, [supabase, refreshProducts])

  const updateProduct = useCallback(async (p: Product) => {
    const { error } = await supabase.from("products").update({
      name:               p.name,
      category:           p.category,
      price:              p.price,
      cost:               p.cost,
      stock:              p.stock,
      min_stock:          p.minStock,
      barcode:            p.barcode,
      parent_id:          p.parentId          ?? null,
      is_variant:         p.isVariant,
      base_unit_id:       p.baseUnitId        ?? null,
      stock_control_type: p.stockControlType  ?? 'tracked',
    }).eq("id", p.id)
    if (error) throw new Error(translateDbError(error))
    await refreshProducts()
  }, [supabase, refreshProducts])

  const deleteProduct = useCallback(async (id: string) => {
    // Delegates entirely to the atomic RPC which handles in a single transaction:
    //   1. Ownership check via auth.uid() (no p_user_id injection possible)
    //   2. Nullify sales.product_id for historical records (shows "Eliminado" in UI)
    //   3. Nullify purchases.product_id for historical records
    //   4. Nullify products.parent_id for variant children (they become standalone)
    //   5. DELETE the product row
    const { error } = await supabase.rpc('rpc_safe_delete_product', { p_product_id: id })
    if (error) throw new Error(translateDbError(error))

    // Refresh products + related tables that had FK references nullified
    await Promise.all([refreshProducts(), refreshSales(), refreshPurchases()])
  }, [supabase, refreshProducts, refreshSales, refreshPurchases])

  // ── Sales ──────────────────────────────────────────────────────────────────

  const addSale = useCallback(async (s: Omit<Sale, "id">) => {
    await services.createSale(s)
    // Immediate refresh after Edge Function completes (don't wait for realtime)
    await refreshSales()
  }, [refreshSales])

  const updateSale = useCallback(async (s: Sale) => {
    // amount = unit price per item; total = unit price × quantity
    const { error } = await supabase.from("sales").update({
      amount:   s.unitPrice,
      total:    s.unitPrice * s.quantity,
      quantity: s.quantity,
      currency: s.currency,
    }).eq("id", s.id)
    if (error) throw new Error(translateDbError(error))
    await refreshSales()
  }, [supabase, refreshSales])

  const deleteSale = useCallback(async (id: string) => {
    const { error } = await supabase.from("sales").delete().eq("id", id)
    if (error) throw new Error(translateDbError(error))
    await refreshSales()
  }, [supabase, refreshSales])

  const deleteSalesByOperation = useCallback(async (operationId: string) => {
    const { error } = await supabase.from("sales").delete().eq("operation_id", operationId)
    if (error) throw new Error(translateDbError(error))
    await refreshSales()
  }, [supabase, refreshSales])

  // ── Purchases ──────────────────────────────────────────────────────────────

  const addPurchase = useCallback(async (p: Omit<Purchase, "id">) => {
    await services.createPurchase(p)
    // Immediate refresh after Edge Function completes
    await refreshPurchases()
  }, [refreshPurchases])

  const updatePurchase = useCallback(async (p: Purchase) => {
    // amount = unit cost per item; total = unit cost × quantity
    const { error } = await supabase.from("purchases").update({
      amount:   p.unitCost,
      total:    p.unitCost * p.quantity,
      quantity: p.quantity,
    }).eq("id", p.id)
    if (error) throw new Error(translateDbError(error))
    await refreshPurchases()
  }, [supabase, refreshPurchases])

  const deletePurchase = useCallback(async (id: string) => {
    const { error } = await supabase.from("purchases").delete().eq("id", id)
    if (error) throw new Error(translateDbError(error))
    await refreshPurchases()
  }, [supabase, refreshPurchases])

  const deletePurchasesByOperation = useCallback(async (operationId: string) => {
    const { error } = await supabase.from("purchases").delete().eq("operation_id", operationId)
    if (error) throw new Error(translateDbError(error))
    await refreshPurchases()
  }, [supabase, refreshPurchases])

  // ── Expenses ───────────────────────────────────────────────────────────────

  const addExpense = useCallback(async (e: Omit<Expense, "id">) => {
    await services.createExpense(e)
    await refreshExpenses()
  }, [refreshExpenses])

  const updateExpense = useCallback(async (e: Expense) => {
    const { error } = await supabase.from("expenses").update({
      category:    e.category,
      description: e.description,
      amount:      e.amount,
    }).eq("id", e.id)
    if (error) throw new Error(translateDbError(error))
    await refreshExpenses()
  }, [supabase, refreshExpenses])

  const deleteExpense = useCallback(async (id: string) => {
    const { error } = await supabase.from("expenses").delete().eq("id", id)
    if (error) throw new Error(translateDbError(error))
    await refreshExpenses()
  }, [supabase, refreshExpenses])

  // ── Clients ────────────────────────────────────────────────────────────────

  const addClient = useCallback(async (c: Omit<Client, "id">) => {
    await services.createClient(c)
    await refreshClients()
  }, [refreshClients])

  const updateClient = useCallback(async (c: Client) => {
    const { error } = await supabase.from("clients").update({
      name:     c.name,
      email:    c.email,
      phone:    c.phone,
      status:   c.status,
      category: c.category,
    }).eq("id", c.id)
    if (error) throw new Error(translateDbError(error))
    await refreshClients()
  }, [supabase, refreshClients])

  const deleteClient = useCallback(async (id: string) => {
    const { error } = await supabase.from("clients").delete().eq("id", id)
    if (error) throw new Error(translateDbError(error))
    await refreshClients()
  }, [supabase, refreshClients])

  // ── Insights ───────────────────────────────────────────────────────────────

  const addInsight = useCallback((i: Insight) => {
    setInsights(prev => [i, ...prev])
  }, [])

  // ── Posts ──────────────────────────────────────────────────────────────────

  const addPost = useCallback(async (p: Omit<Post, "id">) => {
    const { data: { user } } = await supabase.auth.getUser()
    if (!user) return
    const { data, error } = await supabase.from("posts").insert([{
      user_id:  user.id,
      title:    p.title,
      content:  p.content,
      category: p.category,
    }]).select().single()

    if (error) {
      console.error("Error adding post:", error)
      throw error
    }

    if (data) {
      // Fire analytics in background — don't block post creation.
      // `void` discards the PromiseLike (Supabase returns PromiseLike, not Promise,
      // so .catch() is unavailable — void is the correct fire-and-forget pattern).
      void supabase.from("analytics_events").insert([{
        user_id:    user.id,
        event_name: "post_created",
        event_data: { post_id: data.id },
      }])
    }

    await refreshPosts()
  }, [supabase, refreshPosts])

  const deletePost = useCallback(async (id: string) => {
    const { error } = await supabase.from("posts").delete().eq("id", id)
    if (error) {
      console.error("Error deleting post:", error)
      throw error
    }
    await refreshPosts()
  }, [supabase, refreshPosts])

  const toggleLike = useCallback(async (postId: string) => {
    const { data: { session } } = await supabase.auth.getSession()
    const userId = session?.user?.id
    if (!userId) return

    // Optimistic update — flip the like immediately so the UI feels instant
    setPosts(prev => prev.map(p => {
      if (p.id !== postId) return p
      const wasLiked = p.isLiked ?? false
      return { ...p, isLiked: !wasLiked, likes: wasLiked ? p.likes - 1 : p.likes + 1 }
    }))

    try {
      const { data: existing, error: findError } = await supabase
        .from("post_likes")
        .select("id")
        .eq("post_id", postId)
        .eq("user_id", userId)
        .maybeSingle()

      if (findError) throw findError

      if (existing) {
        const { error: deleteError } = await supabase.from("post_likes").delete().eq("id", existing.id)
        if (deleteError) throw deleteError
      } else {
        const { error: insertError } = await supabase.from("post_likes").insert([{ post_id: postId, user_id: userId }])
        if (insertError) throw insertError
      }
      // No re-fetch needed — optimistic update is already correct
    } catch (err) {
      // Revert optimistic update on any error
      setPosts(prev => prev.map(p => {
        if (p.id !== postId) return p
        const isNowLiked = p.isLiked ?? false
        return { ...p, isLiked: !isNowLiked, likes: isNowLiked ? p.likes - 1 : p.likes + 1 }
      }))
      throw err
    }
  }, [supabase])

  const addReply = useCallback(async (postId: string, content: string) => {
    const { data: { session } } = await supabase.auth.getSession()
    const userId = session?.user?.id
    if (!userId) return

    const { error } = await supabase.from("replies").insert([{
      post_id: postId,
      user_id: userId,
      content,
    }])

    if (error) {
      console.error("Error adding reply:", error)
      throw error
    }

    // Update replies_count in posts state without re-fetching all 8 tables
    setPosts(prev => prev.map(p =>
      p.id === postId ? { ...p, replies: p.replies + 1 } : p,
    ))
  }, [supabase])

  const getReplies = useCallback(async (postId: string): Promise<Reply[]> => {
    const { data } = await supabase
      .from("replies")
      .select("*, profiles(name)")
      .eq("post_id", postId)
      .order("created_at", { ascending: true })

    if (!data) return []
    return data.map(r => ({
      id:        r.id,
      postId:    r.post_id,
      userId:    r.user_id,
      author:    r.profiles?.name || "Usuario",
      content:   r.content,
      createdAt: r.created_at,
    }))
  }, [supabase])

  // ── Courses ────────────────────────────────────────────────────────────────

  const addCourse = useCallback(async (c: Omit<Course, "id" | "modules">) => {
    const { error } = await supabase.from("courses").insert([{
      title:       c.title,
      description: c.description,
      is_pro:      c.isPro,
      level:       c.level,
      category:    c.category,
      students:    c.students,
      rating:      c.rating,
      content:     "",
    }])
    if (error) {
      console.error("Error adding course:", error)
      throw error
    }
    await refreshCourses()
  }, [supabase, refreshCourses])

  const updateCourse = useCallback(async (c: Omit<Course, "modules">) => {
    const { error } = await supabase.from("courses").update({
      title:       c.title,
      description: c.description,
      is_pro:      c.isPro,
      level:       c.level,
      category:    c.category,
      students:    c.students,
      rating:      c.rating,
    }).eq("id", c.id)
    if (error) {
      console.error("Error updating course:", error)
      throw error
    }
    await refreshCourses()
  }, [supabase, refreshCourses])

  const deleteCourse = useCallback(async (id: string) => {
    const { error } = await supabase.from("courses").delete().eq("id", id)
    if (error) {
      console.error("Error deleting course:", error)
      throw error
    }
    await refreshCourses()
  }, [supabase, refreshCourses])

  // ── Computed ───────────────────────────────────────────────────────────────

  const getTodaySales = useCallback(() => {
    const today = new Date().toISOString().split("T")[0]
    return sales.filter(s => s.date === today).reduce((acc, s) => acc + s.total, 0)
  }, [sales])

  const getTodayExpenses = useCallback(() => {
    const today = new Date().toISOString().split("T")[0]
    return expenses.filter(e => e.date === today).reduce((acc, e) => acc + e.amount, 0)
  }, [expenses])

  const getNetProfit = useCallback(() => {
    const totalSales     = sales.reduce((acc, s) => acc + s.total, 0)
    const totalCost      = purchases.reduce((acc, p) => acc + p.total, 0)
    const totalExpenses  = expenses.reduce((acc, e) => acc + e.amount, 0)
    return totalSales - totalCost - totalExpenses
  }, [sales, purchases, expenses])

  const getLowStockProducts = useCallback(() => {
    return products.filter(p => p.stock <= p.minStock)
  }, [products])

  const getSalesByDay = useCallback((days: number) => {
    const result: { date: string; total: number }[] = []
    for (let i = days - 1; i >= 0; i--) {
      const d = new Date()
      d.setDate(d.getDate() - i)
      const dateStr  = d.toISOString().split("T")[0]
      const dayTotal = sales.filter(s => s.date === dateStr).reduce((acc, s) => acc + s.total, 0)
      result.push({ date: dateStr, total: dayTotal })
    }
    return result
  }, [sales])

  // ── Client metrics — derived from sales (no extra DB call) ──────────────────
  // Computes `lastPurchase` (latest sale date) and `totalSpent` (sum of sale
  // totals) per client by joining the already-loaded `sales` state.
  //
  // Why here, not in mapClient?
  //   mapClient receives only the raw clients row — it has no access to sales.
  //   The clients DB table stores no aggregated metrics (no last_purchase /
  //   total_spent columns), so they must be derived in-memory.
  //
  // Reactivity: whenever `sales` changes (new sale, delete, realtime event),
  //   this memo recomputes and the context consumers re-render automatically —
  //   no additional subscription or refresh call needed.
  //
  // Performance: O(n_sales + m_clients). For typical ERP datasets (< 50 k rows)
  //   this is negligible. Replace with a server-side aggregation view if the
  //   sales table grows beyond ~100 k rows per tenant.

  const clientsWithMetrics = useMemo<Client[]>(() => {
    // Build a per-client metrics map in a single pass over sales.
    const metricsMap = new Map<string, { lastDate: string; totalSpent: number }>()

    for (const sale of sales) {
      // Skip sales with no associated client ("Consumidor Final").
      // sale.clientId maps to sales.client_id which is nullable in the DB.
      if (!sale.clientId) continue

      const existing = metricsMap.get(sale.clientId)
      if (!existing) {
        metricsMap.set(sale.clientId, {
          lastDate:   sale.date,
          totalSpent: sale.total,
        })
      } else {
        metricsMap.set(sale.clientId, {
          // ISO dates (YYYY-MM-DD) sort correctly with string comparison.
          lastDate:   sale.date > existing.lastDate ? sale.date : existing.lastDate,
          totalSpent: existing.totalSpent + sale.total,
        })
      }
    }

    return clients.map(client => {
      const m = metricsMap.get(client.id)
      return {
        ...client,
        lastPurchase: m?.lastDate   ?? "-",
        totalSpent:   m?.totalSpent ?? 0,
      }
    })
  }, [clients, sales])

  // ── Context value (memoized to prevent unnecessary re-renders) ─────────────

  const value = useMemo(
    () => ({
      products, sales, purchases, expenses,
      // Expose enriched clients (with computed lastPurchase + totalSpent).
      clients: clientsWithMetrics,
      insights, posts, courses, loading,
      addProduct, updateProduct, deleteProduct,
      addSale, updateSale, deleteSale, deleteSalesByOperation,
      addPurchase, updatePurchase, deletePurchase, deletePurchasesByOperation,
      addExpense, updateExpense, deleteExpense,
      addClient, updateClient, deleteClient,
      addInsight, addPost, deletePost, toggleLike, addReply, getReplies,
      addCourse, updateCourse, deleteCourse,
      getTodaySales, getTodayExpenses, getNetProfit, getLowStockProducts, getSalesByDay,
      refreshData,
    }),
    [
      products, sales, purchases, expenses,
      clientsWithMetrics,  // replaces raw `clients` — already encapsulates both clients + sales
      insights, posts, courses, loading,
      addProduct, updateProduct, deleteProduct,
      addSale, updateSale, deleteSale, deleteSalesByOperation,
      addPurchase, updatePurchase, deletePurchase, deletePurchasesByOperation,
      addExpense, updateExpense, deleteExpense,
      addClient, updateClient, deleteClient,
      addInsight, addPost, deletePost, toggleLike, addReply, getReplies,
      addCourse, updateCourse, deleteCourse,
      getTodaySales, getTodayExpenses, getNetProfit, getLowStockProducts, getSalesByDay,
      refreshData,
    ],
  )

  return <DataContext.Provider value={value}>{children}</DataContext.Provider>
}

export function useData() {
  const context = useContext(DataContext)
  if (!context) {
    throw new Error("useData must be used within a DataProvider")
  }
  return context
}
