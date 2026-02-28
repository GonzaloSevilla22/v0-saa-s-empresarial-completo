import { createClient } from './supabase/client'

export const fetchKpiOverview = async (dateFrom: string, dateTo: string, granularity: 'day' | 'week' = 'day') => {
  const supabase = createClient()
  
  const { data, error } = await supabase.rpc('rpc_admin_kpi_overview', {
    date_from: dateFrom,
    date_to: dateTo,
    granularity: granularity
  })

  if (error) {
    console.error('Error fetching KPI overview:', error)
    throw error
  }

  return data
}

export const fetchRetention = async (dateFrom: string, dateTo: string, cohortGranularity: 'week' | 'month' = 'week') => {
  const supabase = createClient()
  
  const { data, error } = await supabase.rpc('rpc_admin_retention_30d', {
    cohort_granularity: cohortGranularity,
    date_from: dateFrom,
    date_to: dateTo
  })

  if (error) {
    console.error('Error fetching retention:', error)
    throw error
  }

  return data
}

export const fetchWeeklyUsageDistribution = async (dateFrom: string, dateTo: string) => {
  const supabase = createClient()
  
  const { data, error } = await supabase.rpc('rpc_admin_weekly_usage_distribution', {
    date_from: dateFrom,
    date_to: dateTo
  })

  if (error) {
    console.error('Error fetching weekly usage distribution:', error)
    throw error
  }

  return data
}
