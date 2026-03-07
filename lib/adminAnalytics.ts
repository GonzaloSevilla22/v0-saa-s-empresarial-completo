import { createClient } from './supabase/client'

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

  const { data, error } = await supabase.rpc('rpc_admin_business_kpis', {
    date_from: dateFrom,
    date_to: dateTo
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
