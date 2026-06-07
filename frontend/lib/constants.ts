// ── Legacy plan constants (C-01: @deprecated) ────────────────────────────────
// These constants reflect the old 2-tier free/pro model.
// @deprecated Use PLAN_LIMITS instead. Values now live in the `plan_limits` DB
// table (source of truth). These are kept only to avoid breaking existing
// imports until C-02 removes all references.
export const MAX_PRODUCTS_FREE = 20
export const MAX_CLIENTS_FREE = 100
export const MAX_HISTORY_MONTHS_FREE = 3
export const MAX_INSIGHTS_FREE = 5

// ── 4-tier plan limits (C-01 billing-schema-migration) ───────────────────────
// These values mirror the `plan_limits` seed in 20260605000001_billing_schema.sql.
// They serve as static fallback and compile-time types.
// Runtime: C-02 will fetch live limits from the DB via usePlanLimits().
// If you change a limit, update BOTH this object AND the migration seed.
export const PLAN_LIMITS = {
  gratis: {
    name: "Gratis",
    priceMonthly: 0,
    maxUsers: 1,
    maxProducts: 100,
    maxClients: 50,
    maxSuppliers: 20,
    maxOperationsPerMonth: 100,
    historyDays: 30,
    maxExportsPerMonth: 0,
    maxAiQueriesPerMonth: 5,
    maxAiAdvicePerMonth: 3,
    maxBranches: 1,
    hasProductProfitability: false,
    hasComparativeReports: false,
    hasPriceSuggestion: false,
    hasBranchesModule: false,
    hasMonthlyAnalysis: false,
    internalRoles: "none" as const,
  },
  inicial: {
    name: "Inicial",
    priceMonthly: 24900,
    maxUsers: 2,
    maxProducts: 500,
    maxClients: 250,
    maxSuppliers: 100,
    maxOperationsPerMonth: 500,
    historyDays: 365,
    maxExportsPerMonth: 3,
    maxAiQueriesPerMonth: 30,
    maxAiAdvicePerMonth: 15,
    maxBranches: 1,
    hasProductProfitability: false,
    hasComparativeReports: false,
    hasPriceSuggestion: false,
    hasBranchesModule: false,
    hasMonthlyAnalysis: false,
    internalRoles: "none" as const,
  },
  avanzado: {
    name: "Avanzado",
    priceMonthly: 34900,
    maxUsers: 5,
    maxProducts: 1500,
    maxClients: 1000,
    maxSuppliers: 300,
    maxOperationsPerMonth: 2000,
    historyDays: 730,
    maxExportsPerMonth: 15,
    maxAiQueriesPerMonth: 120,
    maxAiAdvicePerMonth: 60,
    maxBranches: 1,
    hasProductProfitability: true,
    hasComparativeReports: true,
    hasPriceSuggestion: true,
    hasBranchesModule: false,
    hasMonthlyAnalysis: false,
    internalRoles: "basic" as const,
  },
  pro: {
    name: "Pro",
    priceMonthly: 69900,
    maxUsers: 10,
    maxProducts: 5000,
    maxClients: 3000,
    maxSuppliers: 1000,
    maxOperationsPerMonth: 6000,
    historyDays: 1825,
    maxExportsPerMonth: 50,
    maxAiQueriesPerMonth: 300,
    maxAiAdvicePerMonth: 150,
    maxBranches: 3,
    hasProductProfitability: true,
    hasComparativeReports: true,
    hasPriceSuggestion: true,
    hasBranchesModule: true,
    hasMonthlyAnalysis: true,
    internalRoles: "advanced" as const,
  },
} as const satisfies Record<string, {
  name: string
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
  internalRoles: "none" | "basic" | "advanced"
}>

// @deprecated Use PLAN_LIMITS instead. Kept for backwards compatibility.
// The old free/pro model is replaced by the 4-tier PLAN_LIMITS above.
export const PLAN_FEATURES = {
  // @deprecated — use PLAN_LIMITS.gratis
  free: {
    name: "Gratis",
    maxProducts: MAX_PRODUCTS_FREE,
    maxClients: MAX_CLIENTS_FREE,
    maxHistoryMonths: MAX_HISTORY_MONTHS_FREE,
    maxInsights: MAX_INSIGHTS_FREE,
    community: "solo lectura",
    courses: "básicos",
    aiSimulator: "limitado",
  },
  // @deprecated — use PLAN_LIMITS.pro
  pro: {
    name: "Pro",
    maxProducts: Infinity,
    maxClients: Infinity,
    maxHistoryMonths: Infinity,
    maxInsights: Infinity,
    community: "completo",
    courses: "todos",
    aiSimulator: "completo",
  },
} as const

export const EXPENSE_CATEGORIES = [
  "Alquiler",
  "Servicios",
  "Marketing",
  "Logística",
  "Personal",
  "Impuestos",
  "Otros",
] as const

export const PRODUCT_CATEGORIES = [
  "Electrónica",
  "Ropa",
  "Alimentos",
  "Hogar",
  "Salud",
  "Accesorios",
  "Otros",
] as const

export const CLIENT_STATUSES = [
  { value: "activo", label: "Activo" },
  { value: "inactivo", label: "Inactivo" },
  { value: "perdido", label: "Perdido" },
] as const
