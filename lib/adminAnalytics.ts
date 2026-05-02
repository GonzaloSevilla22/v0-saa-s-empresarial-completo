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

  const defaultDateFrom = dateFrom || new Date(new Date().setMonth(new Date().getMonth() - 1)).toISOString()
  const defaultDateTo = dateTo || new Date().toISOString()

  // Fetch the base KPI object (old logic)
  const { data: baseData, error: baseError } = await supabase.rpc('rpc_admin_business_kpis', {
    date_from: dateFrom,
    date_to: dateTo
  })

  if (baseError) throw baseError

  // Fetch the new refactored KPIs concurrently
  const [
    activationRes,
    umvRes,
    conversionRes,
    communityRes,
    insightsRes
  ] = await Promise.all([
    supabase.rpc('get_admin_activation_rate', {
      p_date_from: defaultDateFrom,
      p_date_to: defaultDateTo
    }),
    supabase.rpc('get_admin_umv_rate', {
      p_date_from: defaultDateFrom,
      p_date_to: defaultDateTo
    }),
    supabase.rpc('get_admin_paid_conversion_rate'),
    supabase.rpc('get_admin_community_interactions', {
      p_date_from: defaultDateFrom,
      p_date_to: defaultDateTo
    }),
    supabase.rpc('get_admin_insights_breakdown', {
      p_date_from: defaultDateFrom,
      p_date_to: defaultDateTo
    })
  ])

  const kpis = { ...baseData }

  // Overwrite with refactored data
  if (kpis.adoption) {
    kpis.adoption.activation_rate = activationRes.data !== null ? Number(activationRes.data) : kpis.adoption.activation_rate
    // Using UMV rate in adoption metric if needed, else ignore
  }

  if (kpis.freemium) {
    kpis.freemium.conversion_rate = conversionRes.data !== null ? Number(conversionRes.data) : kpis.freemium.conversion_rate
  }

  if (kpis.community) {
    kpis.community.total_activity = communityRes.data !== null ? Number(communityRes.data) : kpis.community.total_activity
  }

  if (kpis.ai && insightsRes.data) {
    const totalInsights = insightsRes.data.reduce((acc: number, row: any) => acc + Number(row.total), 0)
    const alertsTriggered = insightsRes.data.find((r: any) => r.insight_type === 'alert')?.total || 0
    kpis.ai.total_insights = totalInsights
    kpis.ai.alerts_triggered = alertsTriggered
  }

  return kpis
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
