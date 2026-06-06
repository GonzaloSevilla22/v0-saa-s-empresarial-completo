import type { Currency } from "@/lib/format"
export type { Currency }

// ── Billing & plan types (C-01 billing-schema-migration) ─────────────────────

/** 4-tier commercial plan. Source of truth: accounts.billing_plan (C-05). */
export type Plan = "gratis" | "inicial" | "avanzado" | "pro"

/** Subscription lifecycle state. Source of truth: accounts.billing_status (C-05). */
export type BillingStatus = "active" | "trialing" | "expired" | "cancelled"

// ── Multi-tenant account types (C-05 multi-user-tenant-architecture) ─────────

/**
 * A billing/tenant account.
 * One account can have multiple members. Each user belongs to exactly one
 * account after the C-05 backfill (N:N schema, 1:1 in practice for MVP).
 * Source of truth: accounts table.
 */
export interface Account {
  id: string
  billingPlan: Plan
  billingStatus: BillingStatus
  /** Which plan is being trialed. null if no active trial. */
  trialPlan: Plan | null
  trialStartedAt: string | null
  trialExpiresAt: string | null
  ownerUserId: string
  createdAt: string
}

/**
 * Membership of a user in an account.
 * Source of truth: account_members table.
 */
/** Role of a user within an account. 'admin' requires plan 'pro'. */
export type OrgRole = "owner" | "admin" | "member"

export interface AccountMember {
  id: string
  accountId: string
  userId: string
  role: OrgRole
  createdAt: string
}

/**
 * Mirror of the `plan_limits` DB table.
 * Used for static fallback / typing. Runtime values come from the DB (C-02).
 */
export interface PlanLimits {
  plan: Plan
  priceMonthly: number
  maxUsers: number
  maxProducts: number
  maxClients: number
  maxSuppliers: number
  maxOperationsPerMonth: number
  historyDays: number
  maxExportsPerMonth: number
  maxAiQueriesPerMonth: number
  maxAiAdvicePerMonth: number
  maxBranches: number
  hasProductProfitability: boolean
  hasComparativeReports: boolean
  hasPriceSuggestion: boolean
  hasBranchesModule: boolean
  hasMonthlyAnalysis: boolean
  /** Role management level available to this plan. */
  internalRoles: "none" | "basic" | "advanced"
}

export type UserRole = "user" | "admin"

export interface User {
  // ── Auth identity (from auth.users) ───────────────────────────────────────
  id: string
  email: string
  // ── Tenant account (C-05) — source of truth for billing & scoping ─────────
  /** UUID of the user's active account. Resolved from account_members at login. */
  accountId: string
  /** Role of this user within the active account. */
  accountRole: OrgRole
  // ── Billing (C-01/C-05) — now stored on accounts, mirrored here ───────────
  billingPlan: Plan
  billingStatus: BillingStatus
  /** Which plan is being trialed (e.g. 'avanzado'). NULL if no active trial. */
  trialPlan?: Plan
  /** ISO timestamp when the trial expires. Undefined for beta/active users. */
  trialExpiresAt?: string
  /**
   * Computed plan used for all gating decisions (C-02/C-05). Derived from the
   * account's billingPlan with an override to trialPlan while a trial is active.
   * NOT persisted in DB. Source of truth for access checks.
   */
  effectivePlan: Plan
  /** AI query counter (resets monthly via C-04). */
  aiQueriesUsed: number
  /** AI advice counter (resets monthly via C-04). */
  aiAdviceUsed: number
  // ── System-managed (read-only for the user) ───────────────────────────────
  // @deprecated Use `billingPlan` instead. Legacy column kept for compatibility
  // until all references are migrated. Will be removed in a future change.
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

// ── Product profitability (C-11 ai-insights-rentabilidad-producto) ────────────

export interface ProductProfitability {
  product_id:       string
  product_name:     string
  total_revenue:    number
  total_cost:       number
  gross_margin:     number
  gross_margin_pct: number
  units_sold:       number
  last_sale_date:   string | null
}

export interface ProfitabilityInsight {
  id:         string
  message:    string
  created_at: string
}

// ── Period comparison (C-12 ai-comparative-reports) ───────────────────────────

export interface PeriodComparison {
  period_a_revenue:     number
  period_a_expenses:    number
  period_a_purchases:   number
  period_a_operations:  number
  period_b_revenue:     number
  period_b_expenses:    number
  period_b_purchases:   number
  period_b_operations:  number
  revenue_delta_pct:    number | null
  expenses_delta_pct:   number | null
  purchases_delta_pct:  number | null
  operations_delta_pct: number | null
}

export interface ComparativeInsight {
  id:         string
  message:    string
  created_at: string
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
  productName?:   string   // denormalised column (migration 000005); falls back to JOIN
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
  /** UUID shared by all movements created by the same logical operation (item 8). */
  operationGroupId?: string
  /** Global sequential counter for fiscal compliance and gap detection (item 9). */
  movementNumber?:   number
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
