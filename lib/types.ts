import type { Currency } from "@/lib/format"
export type { Currency }
export type Plan = "free" | "pro"
export type UserRole = "user" | "admin"

export interface User {
  // ── Auth identity (from auth.users) ───────────────────────────────────────
  id: string
  email: string
  // ── System-managed (read-only for the user) ───────────────────────────────
  plan: Plan
  role: UserRole
  // ── Personal profile (editable) ───────────────────────────────────────────
  name: string
  lastName?: string
  avatar?: string          // URL from storage bucket
  businessName?: string
  phone?: string
  bio?: string
  // ── System preferences (editable) ─────────────────────────────────────────
  currency: string         // 'ARS' | 'USD' | 'EUR' | 'BRL' | 'CLP'
  timezone: string         // IANA timezone, e.g. 'America/Argentina/Buenos_Aires'
  dateFormat: string       // 'DD/MM/YYYY' | 'MM/DD/YYYY' | 'YYYY-MM-DD'
  language: string         // 'es' (others prepared for future)
}

export type StockControlType = 'tracked' | 'untracked' | 'variant_only'

export interface ProductAttribute {
  id:         string
  productId:  string
  key:        string    // e.g. "color", "talle"
  value:      string    // e.g. "Rojo", "XL"
  sortOrder:  number
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
  /** Human-readable SKU — unique per user. Used as stable key for CSV upserts. */
  sku?: string
  /** FK to products.id — set when this product is a variant of a parent */
  parentId?: string
  /**
   * true  → SKU variant (always paired with parentId)
   * false → root product: either a parent catalogue entry or a standalone product
   */
  isVariant: boolean
  /** Dynamic attributes loaded on demand (color, talle, etc.) */
  attributes?: ProductAttribute[]
  // ── Etapa 5+ ──────────────────────────────────────────────────────────────
  /** FK to units_of_measure.id — the unit this product's stock is measured in. */
  baseUnitId?: string
  /**
   * 'tracked'      → physical stock counted and decremented on each sale
   * 'untracked'    → service/digital, stock never changes
   * 'variant_only' → parent catalogue entry, stock lives in variant children
   */
  stockControlType?: StockControlType
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
  currency: Currency
  /** UUID of the unit of measure used for this sale (Etapa 3+). */
  unitId?: string
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
  /** UUID of the unit of measure used for this purchase (Etapa 3+). */
  unitId?: string
  /** UUID shared by all items submitted from the same cart operation. */
  operationId?: string
}

export interface UnitOfMeasure {
  id: string
  name: string
  symbol: string
  type: 'unit' | 'weight' | 'volume' | 'length' | 'custom'
  /** Conversion factor relative to the base unit of this type. */
  factor: number
  baseUnitId?: string
  isSystem: boolean
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

// ── Inventory Movements ───────────────────────────────────────────────────────

export type MovementType =
  | 'purchase'
  | 'sale'
  | 'adjustment'
  | 'return'
  | 'initial'
  | 'sale_return'
  | 'purchase_return'
  | 'physical_count'
  | 'loss'
  | 'damage'
  | 'expiry'
  | 'transfer_in'
  | 'transfer_out'

export interface StockMovement {
  id:             string
  userId:         string
  productId:      string
  productName?:   string   // joined from products.name
  type:           MovementType
  quantityDelta:  number
  quantityBefore?: number
  quantityAfter?:  number
  reason?:        string
  notes?:         string
  referenceId?:   string
  referenceType?: string
  performedBy?:   string
  metadata?:      Record<string, unknown>
  createdAt:      string
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
