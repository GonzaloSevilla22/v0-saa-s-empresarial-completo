import { SupabaseClient } from '@supabase/supabase-js'
import { pricingService } from './pricingService'

export const aiCopilotService = {
  /**
   * Detects if a question is about pricing and extracts cost if present.
   */
  analyzePricingInQuestion(question: string) {
    const q = question.toLowerCase()
    const pricingKeywords = ['precio', 'costo', 'costó', 'margen', 'ganancia', 'vender', 'cobra']
    const isPricingQuery = pricingKeywords.some(key => q.includes(key))

    if (!isPricingQuery) return null

    // Simple regex to extract a number that looks like a cost
    // Example: "me costó 8000" -> 8000
    const costMatch = q.match(/(?:costó|costo|costa|de|es)\s*(?:\$)?\s*(\d+(?:\.\d+)?)/i)
    const cost = costMatch ? Number(costMatch[1]) : null

    if (cost) {
      return {
        cost,
        suggestions: pricingService.suggestPriceRange(cost)
      }
    }

    return { isPricingQuery: true }
  },

  /**
   * Retrieves conversation history for the user.
   */
  async getConversationHistory(supabase: SupabaseClient) {
    const { data: { user } } = await supabase.auth.getUser()
    if (!user) throw new Error("Unauthorized")

    const { data, error } = await supabase
      .from('ai_conversations')
      .select('*')
      .eq('user_id', user.id)
      .order('created_at', { ascending: true })

    if (error) throw error
    return data
  },

  /**
   * Stores a new conversation in the database.
   */
  async saveConversation(supabase: SupabaseClient, question: string, answer: string) {
    const { data: { user } } = await supabase.auth.getUser()
    if (!user) throw new Error("Unauthorized")

    const { data, error } = await supabase
      .from('ai_conversations')
      .insert([{ user_id: user.id, question, answer }])
      .select()
      .single()

    if (error) throw error
    return data
  }
}
