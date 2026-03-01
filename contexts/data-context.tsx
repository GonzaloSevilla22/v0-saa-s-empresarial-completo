"use client"

import React, { createContext, useContext, useState, useCallback, useMemo, useEffect } from "react"
import { createClient } from "@/lib/supabase/client"
import { services } from "@/lib/supabase/services"
import type { Product, Sale, Purchase, Expense, Client, Insight, Post, Course } from "@/lib/types"

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
  addPurchase: (p: Omit<Purchase, "id">) => Promise<void>
  updatePurchase: (p: Purchase) => Promise<void>
  deletePurchase: (id: string) => Promise<void>
  addExpense: (e: Omit<Expense, "id">) => Promise<void>
  updateExpense: (e: Expense) => Promise<void>
  deleteExpense: (id: string) => Promise<void>
  addClient: (c: Omit<Client, "id">) => Promise<void>
  updateClient: (c: Client) => Promise<void>
  deleteClient: (id: string) => Promise<void>
  addInsight: (i: Insight) => void
  addPost: (p: Omit<Post, "id">) => Promise<void>
  // Computed
  getTodaySales: () => number
  getTodayExpenses: () => number
  getNetProfit: () => number
  getLowStockProducts: () => Product[]
  getSalesByDay: (days: number) => { date: string; total: number }[]
  refreshData: () => Promise<void>
}

const DataContext = createContext<DataContextType | null>(null)

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
        { data: coursesData }
      ] = await Promise.all([
        supabase.from('products').select('*').order('created_at', { ascending: false }),
        supabase.from('sales').select('*, product:products(name), client:clients(name)').order('date', { ascending: false }),
        supabase.from('purchases').select('*, product:products(name)').order('date', { ascending: false }),
        supabase.from('expenses').select('*').order('date', { ascending: false }),
        supabase.from('clients').select('*').order('created_at', { ascending: false }),
        supabase.from('insights').select('*').order('created_at', { ascending: false }),
        supabase.from('posts').select('*, user:profiles(name)').order('created_at', { ascending: false }),
        supabase.from('courses').select('*')
      ])

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
        parentId: p.parent_id
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
        currency: s.currency as any
      })))

      if (purchasesData) setPurchases(purchasesData.map(pr => ({
        id: pr.id,
        date: pr.date.split('T')[0],
        productId: pr.product_id,
        productName: pr.product?.name || "Eliminado",
        quantity: pr.quantity,
        unitCost: Number(pr.amount) / pr.quantity,
        total: Number(pr.amount)
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
        priority: "alta",
        message: i.content,
        date: i.created_at.split('T')[0]
      })))

      if (postsData) setPosts(postsData.map(po => ({
        id: po.id,
        author: po.user?.name || "Usuario",
        title: po.title,
        content: po.content,
        category: po.category || "General",
        date: po.created_at.split('T')[0],
        replies: 0,
        likes: po.likes_count || 0
      })))

      if (coursesData) setCourses(coursesData.map(cr => ({
        id: cr.id,
        title: cr.title,
        description: cr.description,
        level: "basico",
        isPro: false,
        modules: [],
        category: "General",
        students: 0,
        rating: 5
      })))

    } catch (err) {
      console.error("Error fetching data:", err)
    } finally {
      setLoading(false)
    }
  }, [supabase])

  useEffect(() => {
    refreshData()

    // Realtime setup
    const channel = supabase
      .channel('schema-db-changes')
      .on('postgres_changes', { event: '*', schema: 'public' }, () => {
        refreshData()
      })
      .subscribe()

    return () => {
      supabase.removeChannel(channel)
    }
  }, [refreshData, supabase])

  // Products
  const addProduct = useCallback(async (p: Omit<Product, "id">) => {
    const { data: { user } } = await supabase.auth.getUser()
    if (!user) return
    await supabase.from('products').insert([{
      user_id: user.id,
      name: p.name,
      category: p.category,
      price: p.price,
      cost: p.cost,
      stock: p.stock,
      min_stock: p.minStock,
      barcode: p.barcode,
      parent_id: p.parentId
    }])
  }, [supabase])

  const updateProduct = useCallback(async (p: Product) => {
    await supabase.from('products').update({
      name: p.name,
      category: p.category,
      price: p.price,
      cost: p.cost,
      stock: p.stock,
      min_stock: p.minStock,
      barcode: p.barcode,
      parent_id: p.parentId
    }).eq('id', p.id)
  }, [supabase])

  const deleteProduct = useCallback(async (id: string) => {
    await supabase.from('products').delete().eq('id', id)
  }, [supabase])

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
    await supabase.from('sales').delete().eq('id', id)
  }, [supabase])

  // Purchases (Using Edge Function for Stock Safety)
  const addPurchase = useCallback(async (p: Omit<Purchase, "id">) => {
    await services.createPurchase(p)
    await refreshData()
  }, [refreshData])

  const updatePurchase = useCallback(async (p: Purchase) => {
    await supabase.from('purchases').update({
      amount: p.total,
      quantity: p.quantity
    }).eq('id', p.id)
  }, [supabase])

  const deletePurchase = useCallback(async (id: string) => {
    await supabase.from('purchases').delete().eq('id', id)
  }, [supabase])

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
    await supabase.from('expenses').delete().eq('id', id)
  }, [supabase])

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
    await supabase.from('clients').delete().eq('id', id)
  }, [supabase])

  // Insights
  const addInsight = useCallback((i: Insight) => {
    setInsights((prev) => [i, ...prev])
  }, [])

  // Posts
  const addPost = useCallback(async (p: Omit<Post, "id">) => {
    const { data: { user } } = await supabase.auth.getUser()
    if (!user) return
    await supabase.from('posts').insert([{
      user_id: user.id,
      title: p.title,
      content: p.content,
      category: p.category
    }])
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
      addSale, updateSale, deleteSale,
      addPurchase, updatePurchase, deletePurchase,
      addExpense, updateExpense, deleteExpense,
      addClient, updateClient, deleteClient,
      addInsight, addPost,
      getTodaySales, getTodayExpenses, getNetProfit, getLowStockProducts, getSalesByDay,
      refreshData
    }),
    [products, sales, purchases, expenses, clients, insights, posts, courses, loading,
      addProduct, updateProduct, deleteProduct,
      addSale, updateSale, deleteSale,
      addPurchase, updatePurchase, deletePurchase,
      addExpense, updateExpense, deleteExpense,
      addClient, updateClient, deleteClient,
      addInsight, addPost,
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
