import { createClient } from '@/lib/supabase/client'

const supabase = createClient()

export interface FairRecommendation {
  product: string
  reason: string
  recommendedUnits: number
  suggestedPrice: number
}

export const fairAdvisorService = {
  /**
   * Generates a new fair recommendation using the Edge Function.
   */
  async generateFairRecommendation() {
    const { data, error } = await supabase.functions.invoke('fair-advisor')
    if (error) throw error
    return data
  },

  /**
   * Retrieves the most recent fair recommendation from the database.
   */
  async getLastRecommendation() {
    const { data: { user } } = await supabase.auth.getUser()
    if (!user) throw new Error("Not authenticated")

    const { data, error } = await supabase
      .from('fair_recommendations')
      .select('*')
      .eq('user_id', user.id)
      .order('created_at', { ascending: false })
      .limit(1)
      .single()

    if (error && error.code !== 'PGRST116') throw error
    
    return data ? (data.recommendation as FairRecommendation[]) : null
  }
}
