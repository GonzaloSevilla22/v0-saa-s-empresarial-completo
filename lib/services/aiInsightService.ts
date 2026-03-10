import { createClient } from '@/lib/supabase/client'
import type { Insight } from '@/lib/types'

const supabase = createClient()

export const aiInsightService = {
  /**
   * Generates new insights for the user via Edge Function.
   * New insights are stored in the `ai_insights` table by the function.
   */
  async generateInsights() {
    const { data, error } = await supabase.functions.invoke('ai-insights')
    if (error) throw error
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
