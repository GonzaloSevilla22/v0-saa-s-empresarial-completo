"use client"

import React, { createContext, useContext, useState, useCallback, useMemo } from "react"
import type { Product, Sale, Purchase, Expense, Client, Insight, Post, Course } from "@/lib/types"
import {
  mockProducts, mockSales, mockPurchases, mockExpenses,
  mockClients, mockInsights, mockPosts, mockCourses,
} from "@/lib/mock-data"

interface DataContextType {
  products: Product[]
  sales: Sale[]
  purchases: Purchase[]
  expenses: Expense[]
  clients: Client[]
  insights: Insight[]
  posts: Post[]
  courses: Course[]
  addProduct: (p: Omit<Product, "id">) => void
  updateProduct: (p: Product) => void
  deleteProduct: (id: string) => void
  addSale: (s: Omit<Sale, "id">) => void
  updateSale: (s: Sale) => void
  deleteSale: (id: string) => void
  addPurchase: (p: Omit<Purchase, "id">) => void
  updatePurchase: (p: Purchase) => void
  deletePurchase: (id: string) => void
  addExpense: (e: Omit<Expense, "id">) => void
  updateExpense: (e: Expense) => void
  deleteExpense: (id: string) => void
  addClient: (c: Omit<Client, "id">) => void
  updateClient: (c: Client) => void
  deleteClient: (id: string) => void
  addInsight: (i: Insight) => void
  addPost: (p: Omit<Post, "id">) => void
  // Computed
  getTodaySales: () => number
  getTodayExpenses: () => number
  getNetProfit: () => number
  getLowStockProducts: () => Product[]
  getSalesByDay: (days: number) => { date: string; total: number }[]
}

const DataContext = createContext<DataContextType | null>(null)

const today = new Date().toISOString().split("T")[0]

function genId(prefix: string) {
  return `${prefix}${Date.now()}${Math.random().toString(36).slice(2, 6)}`
}

export function DataProvider({ children }: { children: React.ReactNode }) {
  const [products, setProducts] = useState<Product[]>(mockProducts)
  const [sales, setSales] = useState<Sale[]>(mockSales)
  const [purchases, setPurchases] = useState<Purchase[]>(mockPurchases)
  const [expenses, setExpenses] = useState<Expense[]>(mockExpenses)
  const [clients, setClients] = useState<Client[]>(mockClients)
  const [insights, setInsights] = useState<Insight[]>(mockInsights)
  const [posts, setPosts] = useState<Post[]>(mockPosts)
  const courses = mockCourses

  // Products
  const addProduct = useCallback((p: Omit<Product, "id">) => {
    setProducts((prev) => [{ ...p, id: genId("p") }, ...prev])
  }, [])
  const updateProduct = useCallback((p: Product) => {
    setProducts((prev) => prev.map((x) => (x.id === p.id ? p : x)))
  }, [])
  const deleteProduct = useCallback((id: string) => {
    setProducts((prev) => prev.filter((x) => x.id !== id))
  }, [])

  // Sales
  const addSale = useCallback((s: Omit<Sale, "id">) => {
    setSales((prev) => [{ ...s, id: genId("s") }, ...prev])
    // Reduce stock
    setProducts((prev) =>
      prev.map((p) => (p.id === s.productId ? { ...p, stock: Math.max(0, p.stock - s.quantity) } : p))
    )
  }, [])
  const updateSale = useCallback((s: Sale) => {
    setSales((prev) => prev.map((x) => (x.id === s.id ? s : x)))
  }, [])
  const deleteSale = useCallback((id: string) => {
    setSales((prev) => prev.filter((x) => x.id !== id))
  }, [])

  // Purchases
  const addPurchase = useCallback((p: Omit<Purchase, "id">) => {
    setPurchases((prev) => [{ ...p, id: genId("pr") }, ...prev])
    // Increase stock
    setProducts((prev) =>
      prev.map((prod) => (prod.id === p.productId ? { ...prod, stock: prod.stock + p.quantity } : prod))
    )
  }, [])
  const updatePurchase = useCallback((p: Purchase) => {
    setPurchases((prev) => prev.map((x) => (x.id === p.id ? p : x)))
  }, [])
  const deletePurchase = useCallback((id: string) => {
    setPurchases((prev) => prev.filter((x) => x.id !== id))
  }, [])

  // Expenses
  const addExpense = useCallback((e: Omit<Expense, "id">) => {
    setExpenses((prev) => [{ ...e, id: genId("e") }, ...prev])
  }, [])
  const updateExpense = useCallback((e: Expense) => {
    setExpenses((prev) => prev.map((x) => (x.id === e.id ? e : x)))
  }, [])
  const deleteExpense = useCallback((id: string) => {
    setExpenses((prev) => prev.filter((x) => x.id !== id))
  }, [])

  // Clients
  const addClient = useCallback((c: Omit<Client, "id">) => {
    setClients((prev) => [{ ...c, id: genId("c") }, ...prev])
  }, [])
  const updateClient = useCallback((c: Client) => {
    setClients((prev) => prev.map((x) => (x.id === c.id ? c : x)))
  }, [])
  const deleteClient = useCallback((id: string) => {
    setClients((prev) => prev.filter((x) => x.id !== id))
  }, [])

  // Insights
  const addInsight = useCallback((i: Insight) => {
    setInsights((prev) => [i, ...prev])
  }, [])

  // Posts
  const addPost = useCallback((p: Omit<Post, "id">) => {
    setPosts((prev) => [{ ...p, id: genId("po") }, ...prev])
  }, [])

  // Computed
  const getTodaySales = useCallback(() => {
    return sales.filter((s) => s.date === today).reduce((acc, s) => acc + s.total, 0)
  }, [sales])

  const getTodayExpenses = useCallback(() => {
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
      products, sales, purchases, expenses, clients, insights, posts, courses,
      addProduct, updateProduct, deleteProduct,
      addSale, updateSale, deleteSale,
      addPurchase, updatePurchase, deletePurchase,
      addExpense, updateExpense, deleteExpense,
      addClient, updateClient, deleteClient,
      addInsight, addPost,
      getTodaySales, getTodayExpenses, getNetProfit, getLowStockProducts, getSalesByDay,
    }),
    [products, sales, purchases, expenses, clients, insights, posts, courses,
      addProduct, updateProduct, deleteProduct,
      addSale, updateSale, deleteSale,
      addPurchase, updatePurchase, deletePurchase,
      addExpense, updateExpense, deleteExpense,
      addClient, updateClient, deleteClient,
      addInsight, addPost,
      getTodaySales, getTodayExpenses, getNetProfit, getLowStockProducts, getSalesByDay]
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
