import type { Currency } from "@/lib/format"
export type { Currency }

// ── Billing & plan types (C-01 billing-schema-migration) ─────────────────────

/** 4-tier commercial plan. Source of truth: accounts.billing_plan (C-05). */
export type Plan = "gratis" | "inicial" | "avanzado" | "pro"

/** Subscription lifecycle state. Source of truth: accounts.billing_status (C-05). */
export type BillingStatus = "active" | "trialing" | "expired" | "cancelled" | "cancelling"

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
  /**
   * billing-pro-trial (D4): exención de cortesía explícita y auditable.
   * Cuando es true, get_effective_plan()/getEffectivePlan() resuelven 'pro'
   * sin importar billing_plan/trial_plan. Source of truth: accounts.billing_exempt.
   */
  billingExempt: boolean
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
 * A physical location / point of sale within an account.
 * Exclusive to plan 'pro'. Source of truth: branches table (C-07).
 */
export interface Branch {
  id: string
  accountId: string
  name: string
  address: string | null
  isActive: boolean
  createdAt: string
  /** C-26: estado operacional (independiente del soft-delete isActive) */
  status: "active" | "closed"
  openedAt: string | null
  closedAt: string | null
  /**
   * sucursal-guard-vaciado-auditoria (G2, D6): autoría de alta y de baja.
   * NULL en sucursales preexistentes (sin backfill) y en las altas de camino
   * de sistema — se muestra como "no registrado" en la interfaz.
   */
  createdBy: string | null
  deactivatedAt: string | null
  deactivatedBy: string | null
}

/**
 * C-26: stock transfer between branches as a first-class entity.
 * Source of truth: stock_transfers table; served by GET /branches/{id}/transfers.
 */
export interface StockTransfer {
  id: string
  productId: string
  productName: string
  fromBranchId: string
  fromBranchName: string
  toBranchId: string
  toBranchName: string
  quantity: number
  status: string
  createdAt: string
}

/**
 * Per-branch stock ledger entry. Tracks quantity of a product in a branch.
 * Rows are created lazily on first movement (UPSERT pattern).
 * Source of truth: branch_stock table (C-08).
 */
export interface BranchStock {
  id: string
  accountId: string
  productId: string
  branchId: string
  quantity: number
  minStock: number
}

/**
 * BranchStock enriched with product info from a JOIN.
 * Used by BranchStockTable to display product details alongside stock levels.
 */
export interface BranchStockWithProduct extends BranchStock {
  productName: string
  productSku: string | null
}

/** Return type of rpc_transfer_stock */
export interface TransferStockResult {
  from_branch_id: string
  to_branch_id: string
  product_id: string
  quantity_transferred: number
}

/** Return type of rpc_adjust_branch_stock */
export interface AdjustBranchStockResult {
  product_id: string
  branch_id: string
  old_quantity: number
  new_quantity: number
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
  /** Annual price in ARS (monthly * 10 = 2 free months). C-10. */
  priceArsAnnual?: number
}

// ── C-28: CashSession / CashMovement ──────────────────────────────────────

/** Cash movement types (C-28). Distinct from stock MovementType (inventory).
 * sale_reversal: contra-movimiento de delete-guard-ledgers (2026-08-22).
 * adjustment: ajuste manual con motivo obligatorio, banco-caja-historial-ajustes. */
export type CashMovementType =
  | "sale"
  | "purchase_payment"
  | "expense"
  | "advance"
  | "withdrawal"
  | "sale_reversal"
  // gastos-forma-pago (D9): contra-partida automática del egreso por gasto,
  // espejo de `sale_reversal` en FAMILIA (Reversas) y opuesto en SIGNO
  // (repone plata, así que es ingreso en backend/schemas/cash.py).
  | "expense_reversal"
  // caja-compras-cobranzas (D1): tres tipos nuevos. purchase_payment_reversal
  // es la contra-partida automática del borrado de una compra en efectivo
  // (familia Reversas, ingreso por signo — repone plata). payment_received/
  // payment_made son el cobro/pago de cuenta corriente en efectivo.
  | "purchase_payment_reversal"
  | "payment_received"
  | "payment_made"
  // cobranzas-reverso (D10): anulación de un cobro/pago de cuenta corriente.
  // Familia "Reversas" (igual que las otras tres), pero SIGNO OPUESTO entre
  // sí: anular un cobro saca plata del cajón (egreso), anular un pago la
  // repone (ingreso) — ver backend/schemas/cash.py _INCOME_TYPES/_EXPENSE_TYPES.
  | "payment_received_reversal"
  | "payment_made_reversal"
  | "adjustment"

/**
 * A physical cash register assigned to a branch.
 * Source of truth: cashboxes table (C-28).
 */
export interface Cashbox {
  id: string
  branchId: string
  name: string
  currency: string
  createdAt: string
}

/**
 * An operating session of a cashbox (open → closed lifecycle).
 * Source of truth: cash_sessions table (C-28).
 */
export interface CashSession {
  id: string
  cashboxId: string
  status: "open" | "closed"
  openingBalance: number
  closingBalance: number | null
  countedBalance: number | null
  expectedBalance: number | null
  difference: number | null
  openedBy: string
  closedBy: string | null
  openedAt: string
  closedAt: string | null
  /** banco-caja-historial-ajustes (D5): snapshot al cierre; calculado al
   * vuelo para sesiones abiertas. */
  adjustmentsTotal: number
}

/**
 * A single cash movement entry (append-only ledger).
 * Source of truth: cash_movements table (C-28).
 */
export interface CashMovement {
  id: string
  sessionId: string
  amount: number
  movementType: CashMovementType
  referenceId: string | null
  balanceAfter: number
  createdBy: string
  createdAt: string
  /** banco-caja-historial-ajustes: motivo — obligatorio solo para 'adjustment'. */
  description: string | null
}

/** Fila del historial por caja (D2) — CashMovement + contexto de sesión. */
export interface CashMovementHistoryRow extends CashMovement {
  sessionOpenedAt: string
  sessionStatus: "open" | "closed"
}

/** Tipos de bank_movements (V2.5 C1 + banco-caja-historial-ajustes). */
export type BankMovementType =
  | "transfer_in"
  | "transfer_out"
  | "card_settlement"
  | "fee"
  | "tax_debit"
  | "interest"
  | "manual_adjustment"

export type ReconciliationStatus = "unreconciled" | "matched"

/** Fila del historial de una cuenta bancaria (D3). */
export interface BankMovementRow {
  id: string
  bankAccountId: string
  amount: number
  balanceAfter: number
  movementType: BankMovementType
  valueDate: string | null
  description: string | null
  createdAt: string
  reconciliationStatus: ReconciliationStatus
}

/** Envelope estándar de paginación (v3-api-standards §2), espejo del backend. */
export interface Page<T> {
  items: T[]
  total: number
  page: number
  pages: number
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
  /** billing-pro-trial (D4): exención de cortesía de la cuenta. */
  billingExempt?: boolean
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
  locality?: string
  province?: string
  bio?: string
  // ── Consentimiento legal (change register-name-terms-captcha) ─────────────
  /** Versión de Términos aceptada en el alta (constante TERMS_VERSION). */
  termsVersion?: string
  /** ISO timestamp de la aceptación de Términos. */
  termsAcceptedAt?: string
  /** Opt-in explícito a comunicaciones por email (default false en DB). */
  emailNotificationsOptIn?: boolean
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
  /** Espejo TEXT del nombre de la categoría (mantenido por trigger) — para mostrar/buscar. */
  category: string
  /**
   * productos-categorias-sku (D1): FK a product_categories — la fuente de
   * verdad de la imputación. `null` = sin categoría (legacy no resuelto).
   */
  categoryId?: string | null
  cost: number
  price: number
  margin: number
  stock: number
  minStock: number
  barcode?: string
  /** SKU opcional — único por CUENTA (case-insensitive, filas vivas). Clave de upsert del importador. */
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
  /**
   * metodos-pago-operaciones: forma de pago de la operación (imputación
   * explícita o, para ventas del POS, derivada de lectura desde la orden —
   * D7). null = "Sin especificar".
   */
  paymentMethodId?: string | null
  paymentMethodName?: string | null
  paymentMethodKind?: PaymentMethodKind | null
  /** edicion-preserva-contexto: sucursal de la operación (editable, tri-estado). */
  branchId?: string | null
  /** edicion-preserva-contexto: canal de venta de la operación (editable, tri-estado). */
  canal?: string | null
  /** edicion-preserva-contexto (F2): true si tiene comprobante fiscal pending_cae/authorized — inmutable. */
  isInvoiced?: boolean
  /** pagos-cableados-restantes (D6): true si tiene cargo de cuenta corriente o movimiento de caja posteado — inmutable. */
  isPaymentLocked?: boolean
  /** delete-guard-ledgers: mismos tres EXISTS de isPaymentLocked, separados
   * para que el diálogo de borrado enumere específicamente qué libro
   * compensaría (cta-cte / caja / banco). */
  hasAccountCharge?: boolean
  hasCashMovement?: boolean
  hasBankMovement?: boolean
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
  /** cost-center-dimension: optional analytic dimension (V2.5). */
  costCenterId?: string | null
  /** cost-center-surface: name resolved by the listing query, for the badge. */
  costCenterName?: string | null
  /** metodos-pago-operaciones: forma de pago de la operación. null = "Sin especificar". */
  paymentMethodId?: string | null
  paymentMethodName?: string | null
  paymentMethodKind?: PaymentMethodKind | null
  /** edicion-preserva-contexto: sucursal de la operación (editable, tri-estado). */
  branchId?: string | null
  /** pagos-cableados-restantes (D6): true si tiene cargo de cuenta corriente posteado — inmutable. */
  isPaymentLocked?: boolean
  /** delete-guard-ledgers: mismos EXISTS de isPaymentLocked, separados. */
  hasAccountCharge?: boolean
  hasBankMovement?: boolean
  /** caja-compras-cobranzas (D9): mismos dos derivados que Expense — hay
   * movimiento de caja de esta compra, y si además no hay sesión abierta en
   * esa caja el borrado quedaría bloqueado (P0426). */
  hasCashMovement?: boolean
  isDeleteBlocked?: boolean
  /** compras-proveedor-cuenta-corriente (D4): proveedor imputado a la
   * operación (editable, tri-estado — D7). null = "Sin proveedor". */
  supplierId?: string | null
  /** compras-proveedor-cuenta-corriente (task 9.2): nombre resuelto por el
   * listado (LEFT JOIN suppliers), para el badge. */
  supplierName?: string | null
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
  branchId?: string | null
  /** cost-center-dimension: optional analytic dimension (V2.5). */
  costCenterId?: string | null
  // ── gastos-forma-pago ─────────────────────────────────────────────────────
  /** Forma de pago imputada del catálogo. null = "Sin especificar" (D7). */
  paymentMethodId?: string | null
  /** Nombre resuelto por el BACKEND (LEFT JOIN al catálogo), no por un Map en cliente. */
  paymentMethodName?: string | null
  paymentMethodKind?: PaymentMethodKind | null
  /** D11: hay movimiento de caja o bancario del gasto → la edición es P0423. */
  isPaymentLocked?: boolean
  /** D18: separados para que el diálogo de borrado enumere qué libro compensa. */
  hasCashMovement?: boolean
  hasBankMovement?: boolean
  /** D8: hay movimiento de caja y NO hay sesión abierta en esa caja → el borrado sería P0426. */
  isDeleteBlocked?: boolean
}

// ── cost-center-dimension (V2.5 Finanzas) ────────────────────────────────────

/**
 * A cost center catalog entry (account-scoped, flat catalog, no hierarchies).
 * Source of truth: cost_centers table (cost-center-dimension).
 * RLS: SELECT = any account member; INSERT/UPDATE = owner/admin only.
 */
export interface CostCenter {
  id: string
  accountId: string
  name: string
  code: string | null
  isActive: boolean
  createdAt: string
}

/**
 * A row of the cost center report (cost-center-surface).
 * Source of truth: rpc_cost_center_report(p_account_id, p_start, p_end).
 *
 * `id === null` is the "Sin centro de costo" row: the costs of the period that
 * were never imputed. It is part of the contract, not a UI detail — excluding
 * it would show a total below the real cost of the period.
 */
export interface CostCenterReportRow {
  id: string | null
  name: string
  code: string | null
  isActive: boolean
  totalExpenses: number
  totalPurchases: number
  totalCost: number
  operationCount: number
}

/**
 * Vocabulario cerrado de `kind` (metodos-pago-operaciones D2). Superset de
 * sales_orders.payment_method y de la taxonomía de cobro/pago — este change
 * no modifica ninguna de las dos.
 */
export type PaymentMethodKind = "cash" | "transfer" | "card" | "check" | "wallet" | "credit" | "other"

/**
 * pos-banco-movimientos (D2): subconjunto bancario del vocabulario — espejo
 * de `BANK_KINDS` en `backend/services/payment_methods.py` y del `IN
 * ('transfer','card','check','wallet')` de `_pay_register_operation_bank_
 * movement`. Fuente canónica única para toda superficie que necesite decidir
 * si un `kind` puede tener/mostrar un destino bancario (POS, formularios,
 * PaymentMethodManager) — no reimplementar este chequeo en cada componente.
 */
export const BANK_PAYMENT_KINDS: readonly PaymentMethodKind[] = ["transfer", "card", "check", "wallet"]

export function isBankPaymentKind(kind: PaymentMethodKind | null | undefined): boolean {
  return kind != null && BANK_PAYMENT_KINDS.includes(kind)
}

/**
 * Cuenta bancaria que debe viajar en el payload de una operación.
 *
 * Bug prod 2026-08-24: `BankAccountDestinationSelect` deja de renderizarse
 * cuando el kind no es bancario, pero el `useState` del formulario CONSERVA la
 * cuenta elegida antes del cambio. Al pasar de "Transferencia" a "Cuenta
 * corriente" el alta viajaba con `bank_account_id` + `kind='credit'` y el
 * servidor la rechazaba con `bank_account_requires_bank_kind`. El payload
 * deriva de acá en vez del estado crudo (el POS ya lo resolvía limpiando el
 * override en `selectPaymentMethod`; los formularios no).
 */
export function bankAccountForKind(
  kind: PaymentMethodKind | null | undefined,
  bankAccountId: string | null | undefined,
): string | null {
  return isBankPaymentKind(kind) ? (bankAccountId ?? null) : null
}

/**
 * A payment method catalog entry (account-scoped, flat catalog, no
 * hierarchies). Source of truth: payment_methods table
 * (metodos-pago-operaciones). Espejo de CostCenter + kind + sort_order.
 * RLS: SELECT = any account member; INSERT/UPDATE = owner/admin only.
 */
// ── productos-categorias-sku: catálogo de categorías de producto por cuenta ──

/**
 * Categoría de producto del catálogo de la cuenta (product_categories).
 * Espejo de PaymentMethod SIN `kind`: una categoría es puro rótulo del
 * usuario. `isActive=false` = baja lógica reversible (sigue visible en los
 * productos que la usan, no se ofrece para altas nuevas).
 */
export interface ProductCategory {
  id: string
  accountId: string
  name: string
  isActive: boolean
  sortOrder: number
  createdAt: string
}

export interface PaymentMethod {
  id: string
  accountId: string
  name: string
  kind: PaymentMethodKind
  isActive: boolean
  sortOrder: number
  createdAt: string
  /**
   * pos-banco-movimientos (D7): destino bancario por defecto — null = "no
   * registra movimiento bancario" (estado inicial de todo método sembrado).
   */
  bankAccountId: string | null
}

/**
 * A row of the payment method distribution report (metodos-pago-operaciones).
 * Source of truth: GET /reports/payment-methods (rpc_payment_method_report).
 *
 * `id === null` is the "Sin especificar" row: operations that were never
 * imputed. Part of the contract — excluding it would understate the total.
 */
export interface PaymentMethodReportRow {
  id: string | null
  name: string
  kind: PaymentMethodKind | null
  isActive: boolean
  totalSold: number
  totalPurchased: number
  /** gastos-forma-pago (D14): gastos del período imputados a esta forma de pago. */
  totalSpent: number
  operationCount: number
}

export type ClientStatus = "activo" | "inactivo" | "perdido"

export type IvaCondition =
  | "responsable_inscripto"
  | "monotributista"
  | "exento"
  | "consumidor_final"

export interface Client {
  id: string
  name: string
  email: string
  phone: string
  /** @deprecated legacy manual field — deudas-menores-agosto (G2): sin
   * superficie de lectura ni edición en la UI. El único estado de cliente
   * visible es el calculado (ClientActivityStatus, ver client-activity).
   * La columna sigue existiendo en la DB sin cambios; sólo se quitó la
   * superficie. Opcional porque algunas rutas aún leen el registro crudo. */
  status?: ClientStatus
  lastPurchase: string
  totalSpent: number
  category?: string
  /** cobranzas-vencimientos (D2): plazo de pago propio en días. undefined =
   * no informado (una edición lo PRESERVA); null = sin plazo propio (hereda
   * el default de la cuenta); número = plazo pactado. Nunca significa 0. */
  paymentTermsDays?: number | null
  taxId?: string
  ivaCondition?: IvaCondition
  legalName?: string
}

// ── compras-proveedor-cuenta-corriente (D2/D10): el proveedor como maestro
// operable — espejo exacto de Client en identidad fiscal (RN-96, FiscalIdentity
// es un VO compartido). Sin lastPurchase/totalSpent/category: no hay read-model
// de actividad de compras por proveedor todavía (design.md OQ-6).
export interface Supplier {
  id: string
  name: string
  email?: string
  phone?: string
  taxId?: string
  ivaCondition?: IvaCondition
  legalName?: string
  /** cobranzas-vencimientos (D2): espejo de Client.paymentTermsDays. */
  paymentTermsDays?: number | null
}

// ── Direcciones operativas del cliente (v3-catalog-masters, V3 §7.3) ─────────
// Distinta de la dirección FISCAL (vive en FiscalIdentity, inmutable por
// snapshot). Sin UI en este change — solo el contrato de tipos para la API
// (GET/POST/PUT/DELETE /clients/{clientId}/addresses + set-primary).
export interface ClientAddress {
  id: string
  accountId: string
  clientId: string
  alias: string | null
  street: string | null
  city: string | null
  province: string | null
  postalCode: string | null
  notes: string | null
  isPrimary: boolean
  createdAt: string
  updatedAt: string | null
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

// productos-categorias-sku: el alias `ProductCategory` (unión de 7 literales,
// sin consumidores) se retiró — la categoría es una fila del catálogo por
// cuenta (interface ProductCategory, más arriba), no un vocabulario fijo.

// ── Export module types (C-14 export-module) ──────────────────────────────────

// estadisticas-ventas E3 (task 8.2): `product_ranking_csv` es el 6º tipo —
// el ranking de productos vendidos, exportado desde el read-model canónico
// con los mismos parámetros que la pantalla. La lista canónica vive en
// supabase/functions/_shared/export-ranking.ts (EXPORT_TYPES); esta unión es
// su espejo TypeScript del lado del cliente.
export type ExportType =
  | "sales_csv"
  | "purchases_csv"
  | "expenses_csv"
  | "stock_csv"
  | "full_report_xlsx"
  | "product_ranking_csv"

export type ExportStatus = "generated" | "expired" | "error"

export interface ExportLog {
  id: string
  userId: string
  orgId: string | null
  exportType: ExportType
  filePath: string
  signedUrl: string | null
  signedUrlExpiresAt: string | null
  status: ExportStatus
  createdAt: string
}

// ── Document status history (v3-document-status-history — Modelo V3 §2) ──────

export type DocumentTypeSlug =
  | "quote"
  | "sales_order"
  | "fiscal_document"
  | "cash_session"
  | "reconciliation_session"
  | "stock_transfer"

export interface DocumentStatusHistoryEntry {
  id: string
  accountId: string
  documentType: DocumentTypeSlug
  documentId: string
  /** NULL = entrada de creación del documento (RN-A2) */
  fromStatus: string | null
  toStatus: string
  /** uuid del actor; 00000000-0000-0000-0000-000000000000 = sistema (relay CAE) */
  performedBy: string
  reason: string | null
  occurredAt: string
}

// ── In-app notifications (v3-notifications-realtime — Modelo V3 §3) ──────────

/**
 * Tipo semántico del aviso. Coincide 1:1 con el event_type del outbox que lo
 * origina (Consumer 4 / _notification_from_event).
 */
export type NotificationType =
  | "CashSessionClosed"
  | "StockBelowMinimum"
  | "FiscalDocumentRejected"
  | "QuoteAccepted"
  | "TransferDispatched"
  | "PlanLimitExceeded"
  // mp-real-subscriptions (D11): aviso de cobro de suscripción rechazado
  // (PR3) y de vencimiento próximo de plan pago sin cobro confirmado (PR4).
  | "SubscriptionPaymentFailed"
  | "SubscriptionExpiringSoon"
  // cobranzas-vencimientos (D8): resumen diario de deuda vencida, por lado.
  | "ReceivablesOverdueDigest"
  | "PayablesOverdueDigest"

export type NotificationSeverity = "info" | "warning" | "urgent"

/**
 * Read model efímero de la campana de notificaciones. Escrito solo por el
 * relay (Consumer 4, SECURITY DEFINER) — el cliente nunca inserta filas.
 * Source of truth: notifications table (RLS por audiencia).
 */
export interface Notification {
  id: string
  accountId: string
  branchId: string | null
  type: NotificationType
  severity: NotificationSeverity
  /** Payload crudo del evento de dominio que originó el aviso. */
  payload: Record<string, unknown>
  read: boolean
  createdAt: string
  readAt: string | null
}

// ── cobranzas-panel: read-model agregado de cuentas por cobrar ───────────────

/**
 * Fila del panel de deudores (/cobranzas). Las antigüedades son `null`
 * cuando no existe ningún movimiento del tipo (OQ-4: deuda nacida de un
 * adjustment) — la superficie muestra "—", nunca 0.
 */
export interface ReceivableRow {
  clientId: string
  clientName: string
  /** Teléfono del deudor — para el recordatorio de WhatsApp (D12). */
  clientPhone: string | null
  balance: number
  daysSinceLastCharge: number | null
  daysSinceLastPayment: number | null
  /** Fecha ISO (día calendario argentino) del último cobro, o null. */
  lastPaymentDate: string | null
  // cobranzas-vencimientos: los cinco tramos (suman balance — invariante de
  // cierre del RPC) + agregados de vencimiento.
  overdueTotal: number
  amountCurrent: number
  amountOverdue1_30: number
  amountOverdue31_60: number
  amountOverdue60Plus: number
  amountNoDueDate: number
  /** Vencimiento más antiguo abierto (ISO), o null si no hay vencidos. */
  oldestDueDate: string | null
  /** Días de atraso del cargo abierto más vencido, o null. */
  daysOverdueMax: number | null
}

/** Resumen agregado (D2): total por cobrar + vencido + cantidad de deudores. */
export interface ReceivablesSummary {
  totalReceivable: number
  overdueTotal: number
  debtorCount: number
}

/** cobranzas-vencimientos: fila del read-model de cuentas por pagar —
 * espejo exacto de ReceivableRow sobre rpc_payables_report. */
export interface PayableRow {
  supplierId: string
  supplierName: string
  balance: number
  daysSinceLastCharge: number | null
  daysSinceLastPayment: number | null
  lastPaymentDate: string | null
  overdueTotal: number
  amountCurrent: number
  amountOverdue1_30: number
  amountOverdue31_60: number
  amountOverdue60Plus: number
  amountNoDueDate: number
  oldestDueDate: string | null
  daysOverdueMax: number | null
}

/** cobranzas-vencimientos: total por pagar + vencido + acreedores. */
export interface PayablesSummary {
  totalPayable: number
  overdueTotal: number
  creditorCount: number
}
