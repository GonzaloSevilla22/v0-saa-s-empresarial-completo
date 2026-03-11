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
  }
}
