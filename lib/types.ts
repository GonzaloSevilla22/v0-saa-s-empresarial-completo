export type Plan = "free" | "pro"
export type UserRole = "user" | "admin"

export interface User {
  id: string
  name: string
  email: string
  plan: Plan
  role: UserRole
  avatar?: string
}

// --- Multi-tenant ERP Types ---

export interface Company {
  id: string
  name: string
  created_at: string
}

export interface CompanyUser {
  id: string
  company_id: string
  user_id: string
  role: "admin" | "user" | "owner"
}

export interface Warehouse {
  id: string
  company_id: string
  name: string
  location?: string
  created_at: string
}

export interface ProductVariant {
  id: string
  product_id: string
  sku: string
  barcode?: string
  price: number
  cost: number
  created_at: string
  product?: Product
}

export interface InventoryStock {
  id: string
  variant_id: string
  warehouse_id: string
  quantity: number
  updated_at: string
}

export interface SaleItem {
  id: string
  sale_id: string
  variant_id: string
  quantity: number
  price: number
  subtotal: number
}

export interface PurchaseItem {
  id: string
  purchase_id: string
  variant_id: string
  quantity: number
  price: number
  subtotal: number
}

// --- Legacy & UI Types (Refactored or Adatped) ---

export interface Product {
  id: string
  name: string
  category: string
  cost: number
  price: number
  margin: number
  stock: number
  minStock: number
  barcode?: string
  parentId?: string
  company_id?: string
}

export interface Sale {
  id: string
  date: string
  productId: string
  productName: string
  clientId: string
  clientName: string
  quantity: number
  unitPrice: number
  total: number
  currency: "ARS" | "USD" | "EUR" | "BRL"
}

export interface Purchase {
  id: string
  date: string
  productId: string
  productName: string
  quantity: number
  unitCost: number
  total: number
  description?: string
}

export interface Expense {
  id: string
  date: string
  category: string
  description: string
  amount: number
  company_id?: string
}

export type ClientStatus = "activo" | "inactivo" | "perdido"

export interface Client {
  id: string
  name: string
  email: string
  phone: string
  status: ClientStatus
  lastPurchase: string
  totalSpent: number
  category?: string
  company_id?: string
}

export type InsightPriority = "alta" | "media" | "baja"

export interface Insight {
  id: string
  type: string
  priority: InsightPriority
  message: string
  date: string
}

export interface Post {
  id: string
  userId: string
  author: string
  authorAvatar?: string
  title: string
  content: string
  category: string
  date: string
  replies: number
  likes: number
  isLiked?: boolean
}

export interface Reply {
  id: string
  postId: string
  userId: string
  author: string
  content: string
  createdAt: string
}

export interface CourseModule {
  id: string
  title: string
  duration: string
  completed: boolean
}

export interface Course {
  id: string
  title: string
  description: string
  level: "basico" | "intermedio" | "avanzado"
  isPro: boolean
  modules: CourseModule[]
  category: string
  students: number
  rating: number
}

export type ExpenseCategory =
  | "Alquiler"
  | "Servicios"
  | "Marketing"
  | "Logistica"
  | "Personal"
  | "Impuestos"
  | "Otros"

export type ProductCategory =
  | "Electrónica"
  | "Ropa"
  | "Alimentos"
  | "Hogar"
  | "Salud"
  | "Accesorios"
  | "Otros"
