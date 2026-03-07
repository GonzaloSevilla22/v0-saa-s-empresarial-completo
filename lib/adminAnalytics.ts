import { createClient } from "@/lib/supabase/client"

export async function fetchKpiOverview(
  dateFrom: string,
  dateTo: string,
  granularity: "day" | "week" = "day"
) {
  const supabase = createClient()
  const { data, error } = await supabase.rpc("rpc_admin_kpi_overview", {
    date_from: dateFrom,
    date_to: dateTo,
    granularity,
  })

  if (error) {
    console.error("Error fetching KPI overview:", error)
    throw error
  }
  return data
}

export async function fetchRetention(dateFrom: string, dateTo: string) {
  const supabase = createClient()
  const { data, error } = await supabase.rpc("rpc_admin_retention_30d", {
    cohort_granularity: "week",
    date_from: dateFrom,
    date_to: dateTo,
  })

  if (error) {
    console.error("Error fetching retention:", error)
    throw error
  }
  // The RPC returns { cohort_start, cohort_size, retained_30d, retention_rate }
  return data
}

export async function fetchWeeklyUsageDistribution(dateFrom: string, dateTo: string) {
  const supabase = createClient()
  const { data, error } = await supabase.rpc("rpc_admin_weekly_usage_distribution", {
    date_from: dateFrom,
    date_to: dateTo,
  })

  if (error) {
    console.error("Error fetching weekly usage distribution:", error)
    throw error
  }
  // Returns { week_start, active_days, users_count }
  return data
}
