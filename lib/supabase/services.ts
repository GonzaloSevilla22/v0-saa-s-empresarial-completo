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
  async createSale(sale: {
    company_id: string
    warehouse_id: string
    client_id: string
    items: { variant_id: string; quantity: number; price: number }[]
    currency: string
  }) {
    const { data, error } = await supabase.rpc('rpc_atomic_create_sale', {
      p_company_id: sale.company_id,
      p_warehouse_id: sale.warehouse_id,
      p_client_id: sale.client_id,
      p_items: sale.items,
      p_currency: sale.currency
    })

    if (error) throw error
    return data
  },

  // Purchases
  async createPurchase(purchase: {
    company_id: string
    warehouse_id: string
    items: { variant_id: string; quantity: number; price: number }[]
    description?: string
  }) {
    const { data, error } = await supabase.rpc('rpc_atomic_create_purchase', {
      p_company_id: purchase.company_id,
      p_warehouse_id: purchase.warehouse_id,
      p_items: purchase.items,
      p_description: purchase.description
    })

    if (error) throw error
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
      company_id: client.company_id,
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
  async createExpense(expense: any, companyId: string) {
    const { data: { user } } = await supabase.auth.getUser()
    if (!user) throw new Error("Not authenticated")
    const { data, error } = await supabase.from('expenses').insert([{ 
      ...expense, 
      user_id: user.id,
      company_id: companyId 
    }]).select().single()
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
