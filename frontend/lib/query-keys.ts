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
    all:      () => ["clients"] as const,
    lists:    () => ["clients", "list"] as const,
    metrics:  () => ["clients", "metrics"] as const,
    // clientes-frecuentes-historial: bajo el mismo prefijo "clients" —
    // invalidateQueries({queryKey: clients.all()}) invalida esto también.
    activity:  () => ["clients", "activity"] as const,
    purchases: (clientId: string) => ["clients", "purchases", clientId] as const,
  },
  // compras-proveedor-cuenta-corriente (D10): calco de clients.all/lists —
  // el proveedor como maestro operable.
  suppliers: {
    all:   () => ["suppliers"] as const,
    lists: () => ["suppliers", "list"] as const,
  },
  insights: {
    all: () => ["insights"] as const,
  },
  posts: {
    all:    () => ["posts"] as const,
    detail: (id: string) => ["posts", "detail", id] as const,
  },
  branches: {
    all:      () => ["branches"] as const,
    active:   () => ["branches", "active"] as const,
    inactive: () => ["branches", "inactive"] as const,
  },
  branchStock: {
    all:      () => ["branchStock"] as const,
    byBranch: (branchId: string) => ["branchStock", "branch", branchId] as const,
    byProduct: (productId: string) => ["branchStock", "product", productId] as const,
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
    // banco-caja-historial-ajustes (D2): el historial por caja no pasa por
    // TanStack Query (LedgerMovementsPanel administra su propio estado
    // imperativo, ver hooks/data/use-cash-movements.ts:
    // fetchCashMovementsByCashboxPage) — sin key acá por diseño.
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
  // C-30: CustomerAccount / SupplierAccount
  customerAccounts: {
    all:       () => ["customerAccounts"] as const,
    byClient:  (clientId: string) => ["customerAccounts", "client", clientId] as const,
    movements: (accountId: string) => ["customerAccounts", "movements", accountId] as const,
  },
  // cobranzas-panel: read-model agregado de deudores. Prefijo propio para
  // que invalidateQueries({queryKey: receivables.all()}) alcance lista,
  // resumen y KPI del Tablero de una sola vez (D8).
  receivables: {
    all: () => ["receivables"] as const,
    list: (accountId: string, page: number, size: number, sort: string, sortDir: string) =>
      ["receivables", "list", accountId, page, size, sort, sortDir] as const,
    summary: (accountId: string) => ["receivables", "summary", accountId] as const,
  },
  supplierAccounts: {
    all:         () => ["supplierAccounts"] as const,
    bySupplier:  (supplierId: string) => ["supplierAccounts", "supplier", supplierId] as const,
    movements:   (accountId: string) => ["supplierAccounts", "movements", accountId] as const,
  },
  // cost-center-dimension (V2.5 Finanzas)
  costCenters: {
    all:    () => ["costCenters"] as const,
    lists:  () => ["costCenters", "list"] as const,
    active: () => ["costCenters", "active"] as const,
  },
  // metodos-pago-operaciones
  paymentMethods: {
    all:    () => ["paymentMethods"] as const,
    lists:  () => ["paymentMethods", "list"] as const,
    active: () => ["paymentMethods", "active"] as const,
    report: (accountId: string | null, start: string, end: string) =>
      ["paymentMethods", "report", accountId, start, end] as const,
  },
  // bank-payment-routing C2 (V2.5 BankReconciliation)
  bankAccounts: {
    all:    () => ["bankAccounts"] as const,
    active: () => ["bankAccounts", "active"] as const,
  },
  // banco-caja-historial-ajustes (D3): el historial de la cuenta bancaria no
  // pasa por TanStack Query — mismo criterio que cashMovements arriba (ver
  // hooks/data/use-bank-movements.ts: fetchBankMovementsPage).
  // bank-reconciliation C3 (V2.5 BankReconciliation)
  bankReconciliation: {
    all:         () => ["bankReconciliation"] as const,
    imports:     (bankAccountId: string) => ["bankReconciliation", "imports", bankAccountId] as const,
    importLines: (importId: string) => ["bankReconciliation", "importLines", importId] as const,
    sessions:    (bankAccountId: string) => ["bankReconciliation", "sessions", bankAccountId] as const,
    session:     (sessionId: string) => ["bankReconciliation", "session", sessionId] as const,
    pending:     (sessionId: string) => ["bankReconciliation", "pending", sessionId] as const,
    suggestions: (sessionId: string) => ["bankReconciliation", "suggestions", sessionId] as const,
  },
  // v3-notifications-realtime (Modelo V3 §3)
  notifications: {
    all:    () => ["notifications"] as const,
    byAccount: (accountId: string) => ["notifications", "account", accountId] as const,
  },
  // mp-real-subscriptions follow-up (task 8.8): cola admin de suscripciones
  // ambiguas + selector de cuenta destino
  ambiguousSubscriptions: {
    all: () => ["ambiguousSubscriptions"] as const,
  },
  accountSearch: {
    all:   () => ["accountSearch"] as const,
    query: (q: string) => ["accountSearch", q] as const,
  },
} as const
