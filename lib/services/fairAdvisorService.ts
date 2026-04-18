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
    console.log('[fairAdvisorService] Request started')
    const { data, error } = await supabase.functions.invoke('fair-advisor')
    if (error) {
      console.error('[fairAdvisorService] SDK error FULL:', error)
      let details: string | null = null
      if (error.context?.body) {
        try { details = await error.context.body.text() } catch (_) {}
      }
      console.error('[fairAdvisorService] Edge body:', details)
      let parsed: any = null
      try { parsed = details ? JSON.parse(details) : null } catch (_) {}
      throw new Error(parsed?.error || details || error.message || 'Error al generar recomendación')
    }
    console.log('[fairAdvisorService] Response received:', JSON.stringify(data).slice(0, 120))
    if (data?.processing) {
      console.log('[fairAdvisorService] Heavy payload detected, processing async')
      return null
    }
    if (data?.fallback) {
      console.warn('[fairAdvisorService] Fallback:', data.message)
      return null
    }
    return (data?.data ?? data) as FairRecommendation[]
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
