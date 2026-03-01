import { createClient } from './client'
import type { Sale, Purchase, Insight } from '@/lib/types'

const supabase = createClient()

export const getProfile = async (id: string, client?: any) => {
  const supabaseClient = client || supabase
  const { data, error } = await supabaseClient.from('profiles').select('*').eq('id', id).single()
  if (error) return null
  return data
}

export const services = {
  getProfile,
  // Sales
  async createSale(sale: Omit<Sale, 'id'>) {
    console.log("--- DEBUG: Invoking create-sale ---")
    const { data, error } = await supabase.functions.invoke('create-sale', {
      body: {
        client_id: sale.clientId,
        product_id: sale.productId,
        amount: sale.unitPrice,
        quantity: sale.quantity,
        currency: sale.currency
      },
    })

    if (error) {
      console.error("--- EDGE FUNCTION ERROR (create-sale) ---")
      try {
        console.error("Full Error:", JSON.stringify(error, Object.getOwnPropertyNames(error), 2))
      } catch (e) {
        console.error("Full Error Object (fallback):", error)
      }

      let detailedMsg = "Error en la venta"

      try {
        const context = (error as any).context
        if (context && context.response) {
          const bodyText = await context.response.text()
          console.log("DEBUG: Raw Response Body:", bodyText)
          try {
            const parsed = JSON.parse(bodyText)
            detailedMsg = parsed.error || bodyText
          } catch (e) {
            detailedMsg = bodyText
          }
        } else if (error instanceof Error) {
          detailedMsg = error.message
        }
      } catch (e) {
        console.warn("Could not parse detailed error body:", e)
        if (error instanceof Error) detailedMsg = error.message
      }

      console.log("FINAL ERROR MSG TO USER:", detailedMsg)
      throw new Error(detailedMsg)
    }
    return data
  },

  // Purchases
  async createPurchase(purchase: Omit<Purchase, 'id'>) {
    console.log("--- DEBUG: Invoking create-purchase ---")
    const { data, error } = await supabase.functions.invoke('create-purchase', {
      body: {
        product_id: purchase.productId,
        amount: purchase.unitCost,
        quantity: purchase.quantity,
        description: purchase.description
      }
    })

    if (error) {
      console.error("--- EDGE FUNCTION ERROR (create-purchase) ---")
      try {
        console.error("Full Error:", JSON.stringify(error, Object.getOwnPropertyNames(error), 2))
      } catch (e) {
        console.error("Full Error Object (fallback):", error)
      }

      let detailedMsg = "Error en la compra"

      try {
        const context = (error as any).context
        if (context && context.response) {
          const bodyText = await context.response.text()
          console.log("DEBUG: Raw Response Body:", bodyText)
          try {
            const parsed = JSON.parse(bodyText)
            detailedMsg = parsed.error || bodyText
          } catch (e) {
            detailedMsg = bodyText
          }
        } else if (error instanceof Error) {
          detailedMsg = error.message
        }
      } catch (e) {
        console.warn("Could not parse detailed error body:", e)
        if (error instanceof Error) detailedMsg = error.message
      }

      console.log("FINAL ERROR MSG TO USER:", detailedMsg)
      throw new Error(detailedMsg)
    }

    return data
  },

  // AI Insights
  async getAIInsights() {
    const { data, error } = await supabase.functions.invoke('ai-insights')
    if (error) {
      console.error("AI Insights Error:", error)
      return [] // Return empty instead of crashing for non-critical fallback
    }
    return data
  },

  // AI Resumen (Financial Summary)
  async getAISummary(period: 'daily' | 'weekly' | 'monthly' = 'daily') {
    const { data, error } = await supabase.functions.invoke('ai-resumen', {
      body: { period },
    })
    if (error) {
      console.error("AI Summary Error:", error)
      return { content: "Resumen no disponible. Verificá tu conexión." }
    }
    return data
  },

  // AI Prediccion (Sales Prediction)
  async getAIPrediction(daysAhead: number = 7) {
    const { data, error } = await supabase.functions.invoke('ai-prediccion', {
      body: { days_ahead: daysAhead },
    })
    if (error) throw error
    return data
  },

  // AI Simulador (Pricing/Scenario Simulation)
  async runAISimulation(scenario: string) {
    const { data, error } = await supabase.functions.invoke('ai-simulador', {
      body: { scenario },
    })
    if (error) throw error
    return data
  },

  // Clients
  async createClient(client: any) {
    const { data: { user } } = await supabase.auth.getUser()
    if (!user) throw new Error("Not authenticated")
    const { data, error } = await supabase.from('clients').insert([{ ...client, user_id: user.id }]).select().single()
    if (error) throw error
    return data
  },

  // Expenses
  async createExpense(expense: any) {
    const { data: { user } } = await supabase.auth.getUser()
    if (!user) throw new Error("Not authenticated")
    const { data, error } = await supabase.from('expenses').insert([{ ...expense, user_id: user.id }]).select().single()
    if (error) throw error
    return data
  }
}
