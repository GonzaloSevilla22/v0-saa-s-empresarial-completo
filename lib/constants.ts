export const MAX_PRODUCTS_FREE = 20
export const MAX_CLIENTS_FREE = 100
export const MAX_HISTORY_MONTHS_FREE = 3
export const MAX_INSIGHTS_FREE = 5

export const EXPENSE_CATEGORIES = [
  "Alquiler",
  "Servicios",
  "Marketing",
  "Logistica",
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

export const PLAN_FEATURES = {
  free: {
    name: "Gratis",
    maxProducts: MAX_PRODUCTS_FREE,
    maxClients: MAX_CLIENTS_FREE,
    maxHistoryMonths: MAX_HISTORY_MONTHS_FREE,
    maxInsights: MAX_INSIGHTS_FREE,
    community: "solo lectura",
    courses: "basicos",
    aiSimulator: "limitado",
  },
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
