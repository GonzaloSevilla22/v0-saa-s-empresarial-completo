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
  parentId?: string // For variants
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
  /** UUID shared by all items submitted from the same cart operation. */
  operationId?: string
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
  /** UUID shared by all items submitted from the same cart operation. */
  operationId?: string
}

export interface Expense {
  id: string
  date: string
  category: string
  description: string
  amount: number
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

export interface CourseLesson {
  id: string
  moduleId: string
  title: string
  duration: string
  completed: boolean
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
  | "Logística"
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
