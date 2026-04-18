import { createClient } from '@/lib/supabase/client'
import type { Insight } from '@/lib/types'

const supabase = createClient()

export const aiInsightService = {
  /**
   * Generates new insights for the user via Edge Function.
   * New insights are stored in the `ai_insights` table by the function.
   */
  async generateInsights() {
    console.log('[aiInsightService] Request started')
    const { data, error } = await supabase.functions.invoke('ai-insights')
    if (error) {
      console.error('[aiInsightService] SDK error FULL:', error)
      // Read the real body from the edge function response
      let details: string | null = null
      if (error.context?.body) {
        try { details = await error.context.body.text() } catch (_) {}
      }
      console.error('[aiInsightService] Edge body:', details)
      let parsed: any = null
      try { parsed = details ? JSON.parse(details) : null } catch (_) {}
      throw new Error(parsed?.error || details || error.message || 'Error al generar consejos')
    }
    console.log('[aiInsightService] Response received:', JSON.stringify(data).slice(0, 120))
    if (data?.fallback) {
      console.warn('[aiInsightService] Fallback response:', data.message)
      return null
    }
    return data
  },

  /**
   * Retrieves stored insights for the user.
   */
  async getUserInsights(): Promise<Insight[]> {
    const { data, error } = await supabase
      .from('ai_insights')
      .select('*')
      .order('created_at', { ascending: false })

    if (error) throw error

    return data.map((item: any) => ({
      id: item.id,
      type: item.type,
      priority: item.priority as any,
      message: item.message,
      date: item.created_at.split('T')[0]
    }))
  }
}
