import { createClient } from "@/lib/supabase/client"

export interface Insurance {
  id: string
  title: string
  description: string
  coverage: string
  price: string
  contact_url: string
  is_visible: boolean
  created_at: string
  updated_at: string
}

const supabase = createClient()

export const insuranceService = {
  /**
   * Fetch all visible insurances for the public page
   */
  async getVisibleInsurances() {
    const { data, error } = await supabase
      .from("seguros")
      .select("*")
      .eq("is_visible", true)
      .order("created_at", { ascending: false })

    if (error) throw error
    return data as Insurance[]
  },

  /**
   * Fetch all insurances (for admin use)
   */
  async getAllInsurances() {
    const { data, error } = await supabase
      .from("seguros")
      .select("*")
      .order("created_at", { ascending: false })

    if (error) throw error
    return data as Insurance[]
  },

  /**
   * Fetch a single insurance by ID
   */
  async getInsuranceById(id: string) {
    const { data, error } = await supabase
      .from("seguros")
      .select("*")
      .eq("id", id)
      .single()

    if (error) throw error
    return data as Insurance
  },

  /**
   * Create a new insurance entry
   */
  async createInsurance(data: Partial<Insurance>) {
    const { data: result, error } = await supabase
      .from("seguros")
      .insert([data])
      .select()
      .single()

    if (error) throw error
    return result as Insurance
  },

  /**
   * Update an existing insurance entry
   */
  async updateInsurance(id: string, data: Partial<Insurance>) {
    const { data: result, error } = await supabase
      .from("seguros")
      .update(data)
      .eq("id", id)
      .select()
      .single()

    if (error) throw error
    return result as Insurance
  },

  /**
   * Delete an insurance entry
   */
  async deleteInsurance(id: string) {
    const { error } = await supabase
      .from("seguros")
      .delete()
      .eq("id", id)

    if (error) throw error
  },

  /**
   * Toggle visibility of an insurance
   */
  async toggleInsuranceVisibility(id: string, currentVisibility: boolean) {
    const { error } = await supabase
      .from("seguros")
      .update({ is_visible: !currentVisibility })
      .eq("id", id)

    if (error) throw error
  },

  /**
   * Increment click count for an insurance
   */
  async incrementClicks(id: string) {
    const { error } = await supabase.rpc("increment_seguros_clicks", { row_id: id })
    if (error) {
      // Fallback if RPC doesn't exist yet
      const insurance = await this.getInsuranceById(id)
      await supabase.from("seguros").update({ clicks_count: ((insurance as any)?.clicks_count || 0) + 1 }).eq("id", id)
    }
  },

  /**
   * Fetch admin dashboard metrics for seguros
   */
  async getAdminStats() {
    const { data: all } = await supabase.from("seguros").select("is_visible, clicks_count, created_at")
    
    const stats = {
      total: all?.length || 0,
      visible: all?.filter(i => i.is_visible).length || 0,
      hidden: all?.filter(i => !i.is_visible).length || 0,
      totalClicks: all?.reduce((acc, curr) => acc + (curr.clicks_count || 0), 0) || 0,
      timeSeries: this.processTimeSeries(all || [])
    }
    
    return stats
  },

  processTimeSeries(data: any[]) {
    const months = ["Ene", "Feb", "Mar", "Abr", "May", "Jun", "Jul", "Ago", "Sep", "Oct", "Nov", "Dic"]
    const series = data.reduce((acc: any, curr: any) => {
      const date = new Date(curr.created_at)
      const month = months[date.getMonth()]
      acc[month] = (acc[month] || 0) + 1
      return acc
    }, {})

    return Object.entries(series).map(([name, total]) => ({ name, value: total }))
  }
}
