import { createClient } from './supabase/client'

// ─── Existing admin analytics RPCs ───────────────────────────────────────────

export const fetchKpiOverview = async (dateFrom: string, dateTo: string, granularity: 'day' | 'week' = 'day', client?: any) => {
  const supabase = client || createClient()

  const { data, error } = await supabase.rpc('rpc_admin_kpi_overview', {
    date_from: dateFrom,
    date_to: dateTo,
    granularity: granularity
  })

  if (error) {
    throw error
  }

  return data
}

export const fetchRetention = async (dateFrom: string, dateTo: string, cohortGranularity: 'week' | 'month' = 'week', client?: any) => {
  const supabase = client || createClient()

  const { data, error } = await supabase.rpc('rpc_admin_retention_30d', {
    cohort_granularity: cohortGranularity,
    date_from: dateFrom,
    date_to: dateTo
  })

  if (error) {
    throw error
  }

  return data
}

export const fetchWeeklyUsageDistribution = async (dateFrom: string, dateTo: string, client?: any) => {
  const supabase = client || createClient()

  const { data, error } = await supabase.rpc('rpc_admin_weekly_usage_distribution', {
    date_from: dateFrom,
    date_to: dateTo
  })

  if (error) {
    throw error
  }

  return data
}

export const fetchBusinessKpis = async (dateFrom?: string, dateTo?: string, client?: any) => {
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

  return data
}

export const fetchModuleStats = async (moduleType: string, dateFrom: string, dateTo: string, client?: any) => {
  const supabase = client || createClient()

  const { data, error } = await supabase.rpc('rpc_admin_module_stats', {
    p_module_type: moduleType,
    p_date_from: dateFrom,
    p_date_to: dateTo
  })

  if (error) {
    throw error
  }

  return data
}

// ─── New KPI Engine RPCs (secured — guarded by is_admin() server-side) ───────

/** Percentage of users who completed their first operation within the cohort window. */
export const fetchActivationRate = async (dateFrom: string, dateTo: string, client?: any): Promise<number> => {
  const supabase = client || createClient()

  const { data, error } = await supabase.rpc('get_admin_activation_rate', {
    p_date_from: dateFrom,
    p_date_to:   dateTo,
  })

  if (error) throw error
  return Number(data ?? 0)
}

/** Percentage of activated users who also generated at least one AI insight. */
export const fetchUmvRate = async (dateFrom: string, dateTo: string, client?: any): Promise<number> => {
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
  client?:   any,
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
export const fetchCommunityInteractions = async (dateFrom: string, dateTo: string, client?: any): Promise<number> => {
  const supabase = client || createClient()

  const { data, error } = await supabase.rpc('get_admin_community_interactions', {
    p_date_from: dateFrom,
    p_date_to:   dateTo,
  })

  if (error) throw error
  return Number(data ?? 0)
}

/** Breakdown of AI insight types generated within the date range. */
export const fetchInsightsBreakdown = async (
  dateFrom: string,
  dateTo: string,
  client?: any
): Promise<Array<{ insight_type: string; total: number }>> => {
  const supabase = client || createClient()

  const { data, error } = await supabase.rpc('get_admin_insights_breakdown', {
    p_date_from: dateFrom,
    p_date_to:   dateTo,
  })

  if (error) throw error
  return (data ?? []).map((row: any) => ({
    insight_type: String(row.insight_type ?? 'uncategorized'),
    total:        Number(row.total        ?? 0),
  }))
}
