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
    const { data, error } = await supabase.functions.invoke('create-sale', {
      body: {
        client_id: sale.clientId,
        product_id: sale.productId,
        amount: sale.unitPrice,
        quantity: sale.quantity,
        currency: sale.currency,
        operation_id: sale.operationId ?? null,
      },
    })

    if (error) {
      let detailedMsg = "Error en la venta"

      try {
        const context = (error as any).context
        if (context && context.response) {
          const bodyText = await context.response.text()
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
        if (error instanceof Error) detailedMsg = error.message
      }

      throw new Error(detailedMsg)
    }
    return data
  },

  // Purchases
  async createPurchase(purchase: Omit<Purchase, 'id'>) {
    const { data, error } = await supabase.functions.invoke('create-purchase', {
      body: {
        product_id: purchase.productId,
        amount: purchase.unitCost,
        quantity: purchase.quantity,
        description: purchase.description,
        operation_id: purchase.operationId ?? null,
      }
    })

    if (error) {
      let detailedMsg = "Error en la compra"

      try {
        const context = (error as any).context
        if (context && context.response) {
          const bodyText = await context.response.text()
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
        if (error instanceof Error) detailedMsg = error.message
      }

      throw new Error(detailedMsg)
    }

    return data
  },

  // AI Insights - MOVED TO aiInsightService.ts
  
  // AI Resumen (Financial Summary)
  async getAISummary(period: 'daily' | 'weekly' | 'monthly' = 'daily') {
    const { data, error } = await supabase.functions.invoke('ai-resumen', {
      body: { period },
    })
    if (error) {
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
    const { data, error } = await supabase.from('clients').insert([{
      user_id: user.id,
      name: client.name,
      email: client.email,
      phone: client.phone,
      status: client.status || 'activo',
      category: client.category
    }]).select().single()
    if (error) throw error
    return data
  },

  // Expenses
  async createExpense(expense: any) {
    const { data: { user } } = await supabase.auth.getUser()
    if (!user) throw new Error("Not authenticated")
    const { data, error } = await supabase.from('expenses').insert([{ ...expense, user_id: user.id }]).select().single()
    if (error) throw error

    // Log analytics operation
    await supabase.from('analytics_events').insert([{
      user_id: user.id,
      event_name: 'operation_created',
      event_data: { type: 'expense', expense_id: data.id }
    }])

    // Check if it's the first operation
    const { data: firstOp } = await supabase.from('analytics_events')
      .select('id').eq('user_id', user.id).eq('event_name', 'first_operation').limit(1)

    if (!firstOp || firstOp.length === 0) {
      await supabase.from('analytics_events').insert([{
        user_id: user.id,
        event_name: 'first_operation',
        event_data: { type: 'expense', expense_id: data.id }
      }])
    }

    return data
  }
}
