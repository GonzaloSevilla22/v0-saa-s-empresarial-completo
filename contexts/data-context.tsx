"use client"

import React, { createContext, useContext, useState, useCallback, useMemo, useEffect } from "react"
import { createClient } from "@/lib/supabase/client"
import { services } from "@/lib/supabase/services"
import type { Product, Sale, Purchase, Expense, Client, Insight, Post, Course, Reply } from "@/lib/types"

interface DataContextType {
  products: Product[]
  sales: Sale[]
  purchases: Purchase[]
  expenses: Expense[]
  clients: Client[]
  insights: Insight[]
  posts: Post[]
  courses: Course[]
  loading: boolean
  addProduct: (p: Omit<Product, "id">) => Promise<void>
  updateProduct: (p: Product) => Promise<void>
  deleteProduct: (id: string) => Promise<void>
  addSale: (s: Omit<Sale, "id">) => Promise<void>
  updateSale: (s: Sale) => Promise<void>
  deleteSale: (id: string) => Promise<void>
  /** Deletes ALL sales rows that share the given operation_id (one DB call). */
  deleteSalesByOperation: (operationId: string) => Promise<void>
  addPurchase: (p: Omit<Purchase, "id">) => Promise<void>
  updatePurchase: (p: Purchase) => Promise<void>
  deletePurchase: (id: string) => Promise<void>
  /** Deletes ALL purchases rows that share the given operation_id (one DB call). */
  deletePurchasesByOperation: (operationId: string) => Promise<void>
  addExpense: (e: Omit<Expense, "id">) => Promise<void>
  updateExpense: (e: Expense) => Promise<void>
  deleteExpense: (id: string) => Promise<void>
  addClient: (c: Omit<Client, "id">) => Promise<void>
  updateClient: (c: Client) => Promise<void>
  deleteClient: (id: string) => Promise<void>
  addInsight: (i: Insight) => void
  addPost: (p: Omit<Post, "id">) => Promise<void>
  deletePost: (id: string) => Promise<void>
  toggleLike: (postId: string) => Promise<void>
  addReply: (postId: string, content: string) => Promise<void>
  getReplies: (postId: string) => Promise<Reply[]>
  addCourse: (c: Omit<Course, "id" | "modules">) => Promise<void>
  updateCourse: (c: Omit<Course, "modules">) => Promise<void>
  deleteCourse: (id: string) => Promise<void>
  // Computed
  getTodaySales: () => number
  getTodayExpenses: () => number
  getNetProfit: () => number
  getLowStockProducts: () => Product[]
  getSalesByDay: (days: number) => { date: string; total: number }[]
  refreshData: () => Promise<void>
}

const DataContext = createContext<DataContextType | null>(null)

/** Translates raw Postgres / Supabase error objects into clear Spanish messages. */
function translateDbError(error: { code?: string; message?: string } | null): string {
  if (!error) return "Error desconocido"
  switch (error.code) {
    case "23503": return "No se puede eliminar: el registro está siendo usado en otros datos del sistema."
    case "23505": return "Ya existe un registro con esos datos. Revisá los campos duplicados."
    case "42501": return "No tenés permisos para realizar esta acción."
    case "PGRST116": return "No se encontró el registro."
    default:
      return error.message || "Ocurrió un error inesperado. Intentá nuevamente."
  }
}

export function DataProvider({ children }: { children: React.ReactNode }) {
  const supabase = createClient()
  const [products, setProducts] = useState<Product[]>([])
  const [sales, setSales] = useState<Sale[]>([])
  const [purchases, setPurchases] = useState<Purchase[]>([])
  const [expenses, setExpenses] = useState<Expense[]>([])
  const [clients, setClients] = useState<Client[]>([])
  const [insights, setInsights] = useState<Insight[]>([])
  const [posts, setPosts] = useState<Post[]>([])
  const [courses, setCourses] = useState<Course[]>([])
  const [loading, setLoading] = useState(true)

  const refreshData = useCallback(async () => {
    try {
      const { data: { user } } = await supabase.auth.getUser()
      if (!user) return

      // Fetch all core user-specific data
      const [
        { data: productsData },
        { data: salesData },
        { data: purchasesData },
        { data: expensesData },
        { data: clientsData },
        { data: insightsData },
        { data: postsData },
      ] = await Promise.all([
        supabase.from('products').select('*').order('created_at', { ascending: false }),
        supabase.from('sales').select('*, product:products(name), client:clients(name)').order('date', { ascending: false }),
        supabase.from('purchases').select('*, product:products(name)').order('date', { ascending: false }),
        supabase.from('expenses').select('*').order('date', { ascending: false }),
        supabase.from('clients').select('*').order('created_at', { ascending: false }),
        supabase.from('ai_insights').select('*').order('created_at', { ascending: false }),
        supabase.from('posts').select('*, profiles(name), post_likes(user_id)').order('created_at', { ascending: false }),
      ])

      const { data: coursesData, error: coursesError } = await supabase.from('courses').select('*')
      if (coursesError) {
        console.error("Error fetching courses (might be missing columns):", coursesError)
      }

      if (productsData) setProducts(productsData.map(p => ({
        id: p.id,
        name: p.name,
        category: p.category || "Otros",
        cost: Number(p.cost),
        price: Number(p.price),
        margin: p.price > 0 ? Math.round(((p.price - p.cost) / p.price) * 100) : 0,
        stock: p.stock,
        minStock: p.min_stock || 0,
        barcode: p.barcode,
        parentId: p.parent_id ?? undefined,
        isVariant: p.is_variant ?? false,
      })))

      if (salesData) setSales(salesData.map(s => ({
        id: s.id,
        date: s.date.split('T')[0],
        productId: s.product_id,
        productName: s.product?.name || "Eliminado",
        clientId: s.client_id,
        clientName: s.client?.name || "Consumidor Final",
        quantity: s.quantity,
        unitPrice: Number(s.amount) / s.quantity,
        total: Number(s.amount),
        currency: s.currency as any,
        operationId: s.operation_id ?? undefined,
      })))

      if (purchasesData) setPurchases(purchasesData.map(pr => ({
        id: pr.id,
        date: pr.date.split('T')[0],
        productId: pr.product_id,
        productName: pr.product?.name || "Eliminado",
        quantity: pr.quantity,
        unitCost: Number(pr.amount) / pr.quantity,
        total: Number(pr.amount),
        operationId: pr.operation_id ?? undefined,
      })))

      if (expensesData) setExpenses(expensesData.map(e => ({
        id: e.id,
        date: e.date.split('T')[0],
        category: e.category,
        description: e.description || "",
        amount: Number(e.amount)
      })))

      if (clientsData) setClients(clientsData.map(c => ({
        id: c.id,
        name: c.name,
        email: c.email || "",
        phone: c.phone || "",
        status: c.status || "activo",
        lastPurchase: "-",
        totalSpent: 0,
        category: c.category
      })))

      if (insightsData) setInsights(insightsData.map(i => ({
        id: i.id,
        type: i.type,
        priority: i.priority as any,
        message: i.message,
        date: i.created_at.split('T')[0]
      })))

      // Debugging
      if (postsData && postsData.length > 0) {
        console.log("Community Posts fetched:", postsData.length)
      }

      if (postsData) setPosts(postsData.map(po => {
        // PostgREST returns the joined table under the key matching the table name ('profiles')
        const profile = Array.isArray(po.profiles) ? po.profiles[0] : po.profiles;
        const likes = Array.isArray(po.post_likes) ? po.post_likes : [];

        return {
          id: po.id,
          userId: po.user_id,
          author: profile?.name || "Usuario",
          title: po.title,
          content: po.content,
          category: po.category || "General",
          date: po.created_at?.split('T')[0] || new Date().toISOString().split('T')[0],
          replies: po.replies_count || 0,
          likes: po.likes_count || 0,
          isLiked: likes.some((l: any) => l.user_id === user.id) || false
        }
      }))

      if (coursesData) {
        setCourses(coursesData.map(cr => ({
          id: cr.id,
          title: cr.title,
          description: cr.description,
          level: (cr.level as "basico" | "intermedio" | "avanzado") || "basico",
          isPro: cr.is_pro ?? false,
          modules: [],
          category: cr.category || "General",
          students: cr.students || 0,
          rating: cr.rating ? Number(cr.rating) : 5
        })))
      } else {
        // Fallback or empty if error
        setCourses([])
      }

    } catch (err) {
      console.error("Error fetching data:", err)
    } finally {
      setLoading(false)
    }
  }, [supabase])

  useEffect(() => {
    refreshData()
  }, [refreshData])

  const addProduct = useCallback(async (p: Omit<Product, "id">) => {
    const { data: { user } } = await supabase.auth.getUser()
    if (!user) return
    const { error } = await supabase.from('products').insert([{
      user_id: user.id,
      name: p.name,
      category: p.category,
      price: p.price,
      cost: p.cost,
      stock: p.stock,
      min_stock: p.minStock,
      barcode: p.barcode,
      parent_id: p.parentId ?? null,
      is_variant: p.isVariant,
    }])
    if (error) throw new Error(translateDbError(error))
    await refreshData()
  }, [supabase, refreshData])

  const updateProduct = useCallback(async (p: Product) => {
    const { error } = await supabase.from('products').update({
      name: p.name,
      category: p.category,
      price: p.price,
      cost: p.cost,
      stock: p.stock,
      min_stock: p.minStock,
      barcode: p.barcode,
      parent_id: p.parentId ?? null,
      is_variant: p.isVariant,
    }).eq('id', p.id)
    if (error) throw new Error(translateDbError(error))
    await refreshData()
  }, [supabase, refreshData])

  const deleteProduct = useCallback(async (id: string) => {
    // ── SDK bypass with full FK cleanup ───────────────────────────────────────
    // Confirmed FK chain (from browser console diagnosis):
    //   products → product_variants (ON DELETE CASCADE)
    //            → inventory_movements.variant_id (RESTRICT) ← this was blocking
    console.log('[deleteProduct] Starting delete for id:', id)

    // Step 1 — nullify sales references
    const { error: e1 } = await supabase.from('sales').update({ product_id: null }).eq('product_id', id)
    console.log('[deleteProduct] sales nullify →', e1 ? `WARN: ${e1.message}` : 'OK')

    // Step 2 — nullify purchases references
    const { error: e2 } = await supabase.from('purchases').update({ product_id: null }).eq('product_id', id)
    console.log('[deleteProduct] purchases nullify →', e2 ? `WARN: ${e2.message}` : 'OK')

    // Step 3 — detach variant products (self-referential parent_id)
    // Also reset is_variant so orphaned children become proper standalone products
    const { error: e3 } = await supabase.from('products')
      .update({ parent_id: null, is_variant: false })
      .eq('parent_id', id)
    console.log('[deleteProduct] parent_id nullify →', e3 ? `WARN: ${e3.message}` : 'OK')

    // Step 4 — get this product's variants so we can clean inventory_movements
    const { data: variants, error: e4 } = await supabase
      .from('product_variants')
      .select('id')
      .eq('product_id', id)
    console.log('[deleteProduct] variants found →', variants?.length ?? 0, e4 ? `WARN: ${e4.message}` : '')

    // Step 5 — DELETE inventory_movements for those variants
    //   variant_id is NOT NULL → cannot nullify, must delete the movement rows.
    //   These movements belong to variants of the product being deleted,
    //   so removing them is correct (they're orphaned once variants go away).
    if (variants && variants.length > 0) {
      const variantIds = variants.map((v: { id: string }) => v.id)
      const { error: e5 } = await supabase
        .from('inventory_movements')
        .delete()
        .in('variant_id', variantIds)
      console.log('[deleteProduct] inventory_movements delete →', e5 ? `WARN: ${e5.message}` : 'OK')
    }

    // Step 6 — delete the product (cascade handles product_variants)
    const { error: delErr } = await supabase.from('products').delete().eq('id', id)
    console.log('[deleteProduct] delete →', delErr
      ? `ERROR: code=${delErr.code} msg=${delErr.message} details=${delErr.details}`
      : 'OK — deleted')

    if (delErr) throw new Error(translateDbError(delErr))
    await refreshData()
  }, [supabase, refreshData])

  // Sales (Using Edge Function for Stock Safety and AARRR logging)
  const addSale = useCallback(async (s: Omit<Sale, "id">) => {
    await services.createSale(s)
  }, [])

  const updateSale = useCallback(async (s: Sale) => {
    await supabase.from('sales').update({
      amount: s.total,
      quantity: s.quantity,
      currency: s.currency
    }).eq('id', s.id)
  }, [supabase])

  const deleteSale = useCallback(async (id: string) => {
    const { error } = await supabase.from('sales').delete().eq('id', id)
    if (error) throw new Error(translateDbError(error))
    await refreshData()
  }, [supabase, refreshData])

  const deleteSalesByOperation = useCallback(async (operationId: string) => {
    const { error } = await supabase.from('sales').delete().eq('operation_id', operationId)
    if (error) throw new Error(translateDbError(error))
    await refreshData()
  }, [supabase, refreshData])

  // Purchases (Using Edge Function for Stock Safety)
  const addPurchase = useCallback(async (p: Omit<Purchase, "id">) => {
    await services.createPurchase(p)
    // Note: refreshData is called once by the form after all cart items are processed.
    // The compras page also has a realtime subscription for live updates.
  }, [])

  const updatePurchase = useCallback(async (p: Purchase) => {
    await supabase.from('purchases').update({
      amount: p.total,
      quantity: p.quantity
    }).eq('id', p.id)
  }, [supabase])

  const deletePurchase = useCallback(async (id: string) => {
    const { error } = await supabase.from('purchases').delete().eq('id', id)
    if (error) throw new Error(translateDbError(error))
    await refreshData()
  }, [supabase, refreshData])

  const deletePurchasesByOperation = useCallback(async (operationId: string) => {
    const { error } = await supabase.from('purchases').delete().eq('operation_id', operationId)
    if (error) throw new Error(translateDbError(error))
    await refreshData()
  }, [supabase, refreshData])

  // Expenses
  const addExpense = useCallback(async (e: Omit<Expense, "id">) => {
    await services.createExpense(e)
    await refreshData()
  }, [refreshData])

  const updateExpense = useCallback(async (e: Expense) => {
    await supabase.from('expenses').update({
      category: e.category,
      description: e.description,
      amount: e.amount
    }).eq('id', e.id)
  }, [supabase])

  const deleteExpense = useCallback(async (id: string) => {
    const { error } = await supabase.from('expenses').delete().eq('id', id)
    if (error) throw new Error(translateDbError(error))
    await refreshData()
  }, [supabase, refreshData])

  // Clients
  const addClient = useCallback(async (c: Omit<Client, "id">) => {
    await services.createClient(c)
    await refreshData()
  }, [refreshData])

  const updateClient = useCallback(async (c: Client) => {
    await supabase.from('clients').update({
      name: c.name,
      email: c.email,
      phone: c.phone,
      status: c.status,
      category: c.category
    }).eq('id', c.id)
  }, [supabase])

  const deleteClient = useCallback(async (id: string) => {
    const { error } = await supabase.from('clients').delete().eq('id', id)
    if (error) throw new Error(translateDbError(error))
    await refreshData()
  }, [supabase, refreshData])

  // Insights
  const addInsight = useCallback((i: Insight) => {
    setInsights((prev) => [i, ...prev])
  }, [])

  // Courses
  const addCourse = useCallback(async (c: Omit<Course, "id" | "modules">) => {
    const { error } = await supabase.from('courses').insert([{
      title: c.title,
      description: c.description,
      is_pro: c.isPro,
      level: c.level,
      category: c.category,
      students: c.students,
      rating: c.rating,
      content: ""
    }])
    if (error) {
      console.error("Error adding course:", error)
      throw error
    }
    await refreshData()
  }, [supabase, refreshData])

  const updateCourse = useCallback(async (c: Omit<Course, "modules">) => {
    const { error } = await supabase.from('courses').update({
      title: c.title,
      description: c.description,
      is_pro: c.isPro,
      level: c.level,
      category: c.category,
      students: c.students,
      rating: c.rating
    }).eq('id', c.id)
    if (error) {
      console.error("Error updating course:", error)
      throw error
    }
    await refreshData()
  }, [supabase, refreshData])

  const deleteCourse = useCallback(async (id: string) => {
    const { error } = await supabase.from('courses').delete().eq('id', id)
    if (error) {
      console.error("Error deleting course:", error)
      throw error
    }
    await refreshData()
  }, [supabase, refreshData])

  // Posts
  const addPost = useCallback(async (p: Omit<Post, "id">) => {
    const { data: { user } } = await supabase.auth.getUser()
    if (!user) return
    const { data, error } = await supabase.from('posts').insert([{
      user_id: user.id,
      title: p.title,
      content: p.content,
      category: p.category
    }]).select().single()

    if (error) {
      console.error("Error adding post:", error)
      throw error
    }

    if (data) {
      await supabase.from('analytics_events').insert([{
        user_id: user.id,
        event_name: 'post_created',
        event_data: { post_id: data.id }
      }])
      await refreshData()
    }
  }, [supabase, refreshData])

  const deletePost = useCallback(async (id: string) => {
    const { error } = await supabase.from('posts').delete().eq('id', id)
    if (error) {
      console.error("Error deleting post:", error)
      throw error
    }
    await refreshData()
  }, [supabase, refreshData])

  const toggleLike = useCallback(async (postId: string) => {
    const { data: { user } } = await supabase.auth.getUser()
    if (!user) return

    const { data: existing, error: findError } = await supabase
      .from('post_likes')
      .select('id')
      .eq('post_id', postId)
      .eq('user_id', user.id)
      .maybeSingle()

    if (findError) {
      console.error("Error checking like status:", findError)
      throw findError
    }

    if (existing) {
      const { error: deleteError } = await supabase.from('post_likes').delete().eq('id', existing.id)
      if (deleteError) {
        console.error("Error removing like:", deleteError)
        throw deleteError
      }
    } else {
      const { error: insertError } = await supabase.from('post_likes').insert([{ post_id: postId, user_id: user.id }])
      if (insertError) {
        console.error("Error adding like:", insertError)
        throw insertError
      }
    }
    await refreshData()
  }, [supabase, refreshData])

  const addReply = useCallback(async (postId: string, content: string) => {
    const { data: { user } } = await supabase.auth.getUser()
    if (!user) return

    const { error } = await supabase.from('replies').insert([{
      post_id: postId,
      user_id: user.id,
      content
    }])

    if (error) {
      console.error("Error adding reply:", error)
      throw error
    }
    await refreshData()
  }, [supabase, refreshData])

  const getReplies = useCallback(async (postId: string): Promise<Reply[]> => {
    const { data } = await supabase
      .from('replies')
      .select('*, profiles(name)')
      .eq('post_id', postId)
      .order('created_at', { ascending: true })

    if (!data) return []
    return data.map(r => ({
      id: r.id,
      postId: r.post_id,
      userId: r.user_id,
      author: r.profiles?.name || "Usuario",
      content: r.content,
      createdAt: r.created_at
    }))
  }, [supabase])

  // Computed
  const getTodaySales = useCallback(() => {
    const today = new Date().toISOString().split("T")[0]
    return sales.filter((s) => s.date === today).reduce((acc, s) => acc + s.total, 0)
  }, [sales])

  const getTodayExpenses = useCallback(() => {
    const today = new Date().toISOString().split("T")[0]
    return expenses.filter((e) => e.date === today).reduce((acc, e) => acc + e.amount, 0)
  }, [expenses])

  const getNetProfit = useCallback(() => {
    const totalSales = sales.reduce((acc, s) => acc + s.total, 0)
    const totalCost = purchases.reduce((acc, p) => acc + p.total, 0)
    const totalExpenses = expenses.reduce((acc, e) => acc + e.amount, 0)
    return totalSales - totalCost - totalExpenses
  }, [sales, purchases, expenses])

  const getLowStockProducts = useCallback(() => {
    return products.filter((p) => p.stock <= p.minStock)
  }, [products])

  const getSalesByDay = useCallback(
    (days: number) => {
      const result: { date: string; total: number }[] = []
      for (let i = days - 1; i >= 0; i--) {
        const d = new Date()
        d.setDate(d.getDate() - i)
        const dateStr = d.toISOString().split("T")[0]
        const dayTotal = sales
          .filter((s) => s.date === dateStr)
          .reduce((acc, s) => acc + s.total, 0)
        result.push({ date: dateStr, total: dayTotal })
      }
      return result
    },
    [sales]
  )

  const value = useMemo(
    () => ({
      products, sales, purchases, expenses, clients, insights, posts, courses, loading,
      addProduct, updateProduct, deleteProduct,
      addSale, updateSale, deleteSale, deleteSalesByOperation,
      addPurchase, updatePurchase, deletePurchase, deletePurchasesByOperation,
      addExpense, updateExpense, deleteExpense,
      addClient, updateClient, deleteClient,
      addInsight, addPost, deletePost, toggleLike, addReply, getReplies,
      addCourse, updateCourse, deleteCourse,
      getTodaySales, getTodayExpenses, getNetProfit, getLowStockProducts, getSalesByDay,
      refreshData
    }),
    [products, sales, purchases, expenses, clients, insights, posts, courses, loading,
      addProduct, updateProduct, deleteProduct,
      addSale, updateSale, deleteSale, deleteSalesByOperation,
      addPurchase, updatePurchase, deletePurchase, deletePurchasesByOperation,
      addExpense, updateExpense, deleteExpense,
      addClient, updateClient, deleteClient,
      addInsight, addPost, deletePost, toggleLike, addReply, getReplies,
      addCourse, updateCourse, deleteCourse,
      getTodaySales, getTodayExpenses, getNetProfit, getLowStockProducts, getSalesByDay,
      refreshData]
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
