import { createClient } from './supabase/client'
import type { SupabaseClient } from '@supabase/supabase-js'

type AnyClient = SupabaseClient<any, any, any>

// ─── Tipos del payload de cada RPC (D10: sin `any`) ──────────────────────────

/** Ventana de observación de la telemetría de operación (D3). */
export interface AdminKpiDataCoverage {
  last_operation_created_at: string | null
  last_first_operation_at: string | null
  /** Antigüedad en días del último `operation_created`; `null` si nunca hubo uno. */
  operation_events_stale_days: number | null
}

/** `summary` de `rpc_admin_kpi_overview` — KPI de cabecera, ya resueltos en SQL (D1). */
export interface AdminKpiSummary {
  total_activations_in_range: number
  total_umv_in_range: number
  umv_rate: number
  community_active_users: number
  total_insights_in_range: number
  avg_active_days_per_user_week: number
  data_coverage: AdminKpiDataCoverage
}

export interface AdminKpiTimeSeriesPoint {
  period: string
  activations: number
  umv_achieved: number
}

export interface AdminInsightsBreakdownEntry {
  period: string
  insight_type: string | null
  count: number
}

export interface AdminCommunityEngagementEntry {
  period: string
  event_name: string
  count: number
  active_users: number
}

/** Payload completo de `rpc_admin_kpi_overview`. */
export interface AdminKpiOverview {
  time_series: AdminKpiTimeSeriesPoint[]
  insights_breakdown: AdminInsightsBreakdownEntry[]
  community_engagement: AdminCommunityEngagementEntry[]
  summary: AdminKpiSummary
}

/** Fila de `rpc_admin_retention_30d` — la RPC declara su propia ventana (D4). */
export interface AdminRetentionCohort {
  cohort_start: string
  cohort_size: number
  retained_30d: number
  retention_rate: number
  observation_window_days: number
  is_mature: boolean
}

export interface AdminWeeklyUsageBucket {
  week_start: string
  active_days: number
  users_count: number
}

/**
 * Bloque `freemium` de `rpc_admin_business_kpis` (OQ-4, design.md D6, M2
 * admin-kpi-refresh): plan efectivo (`get_effective_plan`) × tarifa de lista
 * (`plan_limits.price_monthly`), con el importe real de una suscripción MP
 * viva cuando existe. Trials y exentas quedan fuera de `mrr_ars` — el trial
 * vigente se valoriza aparte en `trial_pipeline_mrr_ars`. Reemplaza los
 * campos legacy `pro_users`/`conversion_rate`/`mrr` (leían `profiles.plan`,
 * columna que no escribe el motor de billing). Moneda: ARS.
 */
export interface AdminFreemiumMetrics {
  paying_accounts: number
  trial_accounts: number
  exempt_accounts: number
  free_accounts: number
  mrr_ars: number
  trial_pipeline_mrr_ars: number
}

/** Payload de `rpc_admin_business_kpis`. */
export interface AdminBusinessKpis {
  adoption: { total_users: number; mau: number; activation_rate: number }
  freemium: AdminFreemiumMetrics
  community: { total_activity: number; active_pools: number }
  ai: { total_insights: number; alerts_triggered: number }
}

// ─── Existing admin analytics RPCs ───────────────────────────────────────────

export const fetchKpiOverview = async (
  dateFrom: string,
  dateTo: string,
  granularity: 'day' | 'week' = 'day',
  client?: AnyClient,
): Promise<AdminKpiOverview> => {
  const supabase = client || createClient()

  const { data, error } = await supabase.rpc('rpc_admin_kpi_overview', {
    date_from: dateFrom,
    date_to: dateTo,
    granularity: granularity
  })

  if (error) {
    throw error
  }

  return data as AdminKpiOverview
}

export const fetchRetention = async (
  dateFrom: string,
  dateTo: string,
  cohortGranularity: 'week' | 'month' = 'week',
  client?: AnyClient,
): Promise<AdminRetentionCohort[]> => {
  const supabase = client || createClient()

  const { data, error } = await supabase.rpc('rpc_admin_retention_30d', {
    cohort_granularity: cohortGranularity,
    date_from: dateFrom,
    date_to: dateTo
  })

  if (error) {
    throw error
  }

  return (data ?? []) as AdminRetentionCohort[]
}

export const fetchWeeklyUsageDistribution = async (
  dateFrom: string,
  dateTo: string,
  client?: AnyClient,
): Promise<AdminWeeklyUsageBucket[]> => {
  const supabase = client || createClient()

  const { data, error } = await supabase.rpc('rpc_admin_weekly_usage_distribution', {
    date_from: dateFrom,
    date_to: dateTo
  })

  if (error) {
    throw error
  }

  return (data ?? []) as AdminWeeklyUsageBucket[]
}

export const fetchBusinessKpis = async (
  dateFrom?: string,
  dateTo?: string,
  client?: AnyClient,
): Promise<AdminBusinessKpis> => {
  const supabase = client || createClient()

  // Default to the last 30 days when no range is provided
  const defaultDateTo   = new Date().toISOString()
  const defaultDateFrom = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000).toISOString()

  const { data, error } = await supabase.rpc('rpc_admin_business_kpis', {
    date_from: dateFrom ?? defaultDateFrom,
    date_to:   dateTo   ?? defaultDateTo,
  })

  if (error) {
    throw error
  }

  return data as AdminBusinessKpis
}

export const fetchModuleStats = async (
  moduleType: string,
  dateFrom: string,
  dateTo: string,
  client?: AnyClient,
): Promise<{ summary: Record<string, unknown>; time_series: unknown[] }> => {
  const supabase = client || createClient()

  const { data, error } = await supabase.rpc('rpc_admin_module_stats', {
    p_module_type: moduleType,
    p_date_from: dateFrom,
    p_date_to: dateTo
  })

  if (error) {
    throw error
  }

  return data as { summary: Record<string, unknown>; time_series: unknown[] }
}

// ─── New KPI Engine RPCs (secured — guarded by is_admin() server-side) ───────

/** Percentage of users who completed their first operation within the cohort window. */
export const fetchActivationRate = async (dateFrom: string, dateTo: string, client?: AnyClient): Promise<number> => {
  const supabase = client || createClient()

  const { data, error } = await supabase.rpc('get_admin_activation_rate', {
    p_date_from: dateFrom,
    p_date_to:   dateTo,
  })

  if (error) throw error
  return Number(data ?? 0)
}

/** Percentage of activated users who also generated at least one AI insight. */
export const fetchUmvRate = async (dateFrom: string, dateTo: string, client?: AnyClient): Promise<number> => {
  const supabase = client || createClient()

  const { data, error } = await supabase.rpc('get_admin_umv_rate', {
    p_date_from: dateFrom,
    p_date_to:   dateTo,
  })

  if (error) throw error
  return Number(data ?? 0)
}

/**
 * Paid (pro) conversion rate as a percentage.
 *
 * When `dateFrom`/`dateTo` are provided the rate is scoped to profiles
 * registered within that cohort window (consistent with other period KPIs).
 * When omitted the all-time snapshot is returned (original behaviour).
 */
export const fetchPaidConversionRate = async (
  dateFrom?: string,
  dateTo?:   string,
  client?:   AnyClient,
): Promise<number> => {
  const supabase = client || createClient()

  const params = dateFrom && dateTo
    ? { p_date_from: dateFrom, p_date_to: dateTo }
    : {}

  const { data, error } = await supabase.rpc('get_admin_paid_conversion_rate', params)

  if (error) throw error
  return Number(data ?? 0)
}

/** Total community interactions (posts + replies) within the date range. */
export const fetchCommunityInteractions = async (dateFrom: string, dateTo: string, client?: AnyClient): Promise<number> => {
  const supabase = client || createClient()

  const { data, error } = await supabase.rpc('get_admin_community_interactions', {
    p_date_from: dateFrom,
    p_date_to:   dateTo,
  })

  if (error) throw error
  return Number(data ?? 0)
}

interface InsightsBreakdownRow {
  insight_type: string | null
  total: number | string | null
}

/** Breakdown of AI insight types generated within the date range. */
export const fetchInsightsBreakdown = async (
  dateFrom: string,
  dateTo: string,
  client?: AnyClient
): Promise<Array<{ insight_type: string; total: number }>> => {
  const supabase = client || createClient()

  const { data, error } = await supabase.rpc('get_admin_insights_breakdown', {
    p_date_from: dateFrom,
    p_date_to:   dateTo,
  })

  if (error) throw error
  return ((data ?? []) as InsightsBreakdownRow[]).map((row) => ({
    insight_type: String(row.insight_type ?? 'uncategorized'),
    total:        Number(row.total        ?? 0),
  }))
}

// ─── View-model puro (D1/D10): sin agregación de cliente, sólo lectura ──────
// directa de lo que la RPC ya resolvió. Testeado en
// frontend/__tests__/adminAnalytics.test.ts sin montar ninguna página ni
// mockear Supabase.

/** KPI de cabecera, leídos tal cual de `summary` — cero reduce/suma del cliente. */
export interface AdminKpiHeaderMetrics {
  umvRate: number
  totalActivations: number
  totalUmv: number
  communityActiveUsers: number
  totalInsights: number
  avgActiveDaysPerUserWeek: number
}

/**
 * Lee los KPI de cabecera directamente de `overview.summary` (D1: toda
 * agregación vive en la RPC). Reemplaza los `reduce`/`Math.round` que hacía
 * el panel sobre `time_series`/`insights_breakdown`/`community_engagement`.
 */
export function mapKpiHeaderMetrics(overview: AdminKpiOverview): AdminKpiHeaderMetrics {
  const s = overview.summary
  return {
    umvRate: s.umv_rate,
    totalActivations: s.total_activations_in_range,
    totalUmv: s.total_umv_in_range,
    communityActiveUsers: s.community_active_users,
    totalInsights: s.total_insights_in_range,
    avgActiveDaysPerUserWeek: s.avg_active_days_per_user_week,
  }
}

/**
 * La cohorte de retención madura más reciente, o `null` si ninguna cohorte
 * maduró todavía (D4). El panel filtra por `is_mature` — nunca vuelve a
 * hacer aritmética de fechas contra `cohort_start`.
 */
export function selectLatestMatureCohort(
  cohorts: AdminRetentionCohort[],
): AdminRetentionCohort | null {
  const mature = cohorts.filter((c) => c.is_mature)
  if (mature.length === 0) return null

  return mature.reduce((latest, cohort) =>
    new Date(cohort.cohort_start).getTime() > new Date(latest.cohort_start).getTime()
      ? cohort
      : latest
  )
}

/** Umbral (días) sobre el que la telemetría de operación se considera estancada (D3). */
export const DATA_COVERAGE_STALE_THRESHOLD_DAYS = 7

/**
 * Si el panel debe mostrar el aviso de cobertura de datos: la telemetría de
 * `operation_created` está más estancada que el umbral configurado. Sin
 * ningún evento de operación jamás (`operation_events_stale_days === null`)
 * no dispara este aviso — es un caso distinto (cero datos, no datos viejos).
 */
export function shouldShowDataCoverageWarning(
  coverage: AdminKpiDataCoverage,
  thresholdDays: number = DATA_COVERAGE_STALE_THRESHOLD_DAYS,
): boolean {
  return (
    coverage.operation_events_stale_days != null &&
    coverage.operation_events_stale_days > thresholdDays
  )
}
