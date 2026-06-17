/**
 * Centralized query key factory.
 *
 * Rules:
 * - Every key starts with the domain name so prefix invalidation works.
 * - invalidateQueries({ queryKey: queryKeys.courses.all() })
 *   will invalidate ALL courses queries (list, detail, summary, etc.)
 * - Keys are const tuples for type safety.
 */
export const queryKeys = {
  courses: {
    all:    () => ["courses"] as const,
    lists:  () => ["courses", "list"] as const,
    detail: (id: string) => ["courses", "detail", id] as const,
  },
  expenses: {
    all:     () => ["expenses"] as const,
    lists:   () => ["expenses", "list"] as const,
    summary: () => ["expenses", "summary"] as const,
  },
  products: {
    all:    () => ["products"] as const,
    lists:  () => ["products", "list"] as const,
    detail: (id: string) => ["products", "detail", id] as const,
  },
  sales: {
    all:     () => ["sales"] as const,
    lists:   () => ["sales", "list"] as const,
    summary: () => ["sales", "summary"] as const,
  },
  purchases: {
    all:   () => ["purchases"] as const,
    lists: () => ["purchases", "list"] as const,
  },
  clients: {
    all:     () => ["clients"] as const,
    lists:   () => ["clients", "list"] as const,
    metrics: () => ["clients", "metrics"] as const,
  },
  insights: {
    all: () => ["insights"] as const,
  },
  posts: {
    all:    () => ["posts"] as const,
    detail: (id: string) => ["posts", "detail", id] as const,
  },
  branches: {
    all:    () => ["branches"] as const,
    active: () => ["branches", "active"] as const,
  },
  branchStock: {
    all:      () => ["branchStock"] as const,
    byBranch: (branchId: string) => ["branchStock", "branch", branchId] as const,
  },
  organizations: {
    all:    () => ["organizations"] as const,
    detail: (orgId: string) => ["organizations", "detail", orgId] as const,
  },
  stock: {
    all:    () => ["stock"] as const,
    lists:  () => ["stock", "list"] as const,
  },
  // C-27: FiscalProfile + PointsOfSale + FiscalDocuments
  fiscalProfile: {
    all:    () => ["fiscalProfile"] as const,
    detail: () => ["fiscalProfile", "detail"] as const,
  },
  pointsOfSale: {
    all:   () => ["pointsOfSale"] as const,
    lists: () => ["pointsOfSale", "list"] as const,
  },
  fiscalDocuments: {
    all:     () => ["fiscalDocuments"] as const,
    pending: () => ["fiscalDocuments", "pending"] as const,
  },
  // C-28: CashSession / CashMovement
  cashboxes: {
    all:      () => ["cashboxes"] as const,
    byBranch: (branchId: string) => ["cashboxes", "branch", branchId] as const,
  },
  cashSessions: {
    all:           () => ["cashSessions"] as const,
    byCashbox:     (cashboxId: string) => ["cashSessions", "cashbox", cashboxId] as const,
    currentOpen:   (cashboxId: string) => ["cashSessions", "current", cashboxId] as const,
  },
  cashMovements: {
    all:       () => ["cashMovements"] as const,
    bySession: (sessionId: string) => ["cashMovements", "session", sessionId] as const,
  },
  // C-29: Quote / SalesOrder
  quotes: {
    all:    () => ["quotes"] as const,
    lists:  () => ["quotes", "list"] as const,
    detail: (id: string) => ["quotes", "detail", id] as const,
  },
  salesOrders: {
    all:    () => ["salesOrders"] as const,
    lists:  () => ["salesOrders", "list"] as const,
    detail: (id: string) => ["salesOrders", "detail", id] as const,
  },
} as const
