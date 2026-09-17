import { SupabaseClient } from '@supabase/supabase-js'
import { pricingService } from './pricingService'
// auth-hardening-jwt-cookies (Parte C, D1, task 19.8b): la identidad ya no sale
// del cliente que recibe por parámetro. Ese cliente es el de NAVEGADOR y con
// `accessToken` configurado `supabase.auth` lanza (`index.mjs:389`); el
// parámetro se conserva porque sigue siendo el que lee y escribe los datos.
import { getSessionUser } from '@/lib/auth/access-token-store'

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
    const user = await getSessionUser()
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
    const user = await getSessionUser()
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
