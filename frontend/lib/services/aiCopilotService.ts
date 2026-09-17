import { SupabaseClient } from '@supabase/supabase-js'
import { pricingService } from './pricingService'

/**
 * auth-hardening-jwt-cookies (Parte C, D1) — de dónde sale la identidad acá.
 *
 * Con `accessToken` configurado, `supabase.auth` del cliente de **navegador**
 * lanza (`supabase-js/index.mjs:389`), así que estos métodos no pueden pedirle la
 * identidad al cliente que reciben. Tampoco pueden tomarla del store del token: la
 * revisión adversarial de la Parte C encontró que `saveConversation` corre dentro
 * de `POST /api/ai/copilot` —un Route Handler, sin `window`— donde el store
 * devuelve `null` siempre y **ninguna** conversación volvía a persistirse.
 *
 * Los dos métodos tienen callers de los dos lados (el handler de servidor y la
 * pantalla `/copiloto-ia`), y el único dato que funciona en ambos es el que el
 * caller ya tiene autenticado: el servidor por `supabase.auth.getUser()` con el
 * cliente de servidor, la pantalla por `useAuth()`. Por eso `userId` es parámetro.
 */
function requireUserId(userId: string): string {
  if (!userId) throw new Error('Unauthorized')
  return userId
}

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
  async getConversationHistory(supabase: SupabaseClient, userId: string) {
    const { data, error } = await supabase
      .from('ai_conversations')
      .select('*')
      .eq('user_id', requireUserId(userId))
      .order('created_at', { ascending: true })

    if (error) throw error
    return data
  },

  /**
   * Stores a new conversation in the database.
   */
  async saveConversation(
    supabase: SupabaseClient,
    userId: string,
    question: string,
    answer: string,
  ) {
    const { data, error } = await supabase
      .from('ai_conversations')
      .insert([{ user_id: requireUserId(userId), question, answer }])
      .select()
      .single()

    if (error) throw error
    return data
  }
}
