import { createClient } from './client'
import type { Sale, Purchase, Insight } from '@/lib/types'

const supabase = createClient()

export const services = {
  // Sales
  async createSale(sale: Omit<Sale, 'id'>) {
    const { data, error } = await supabase.functions.invoke('create-sale', {
      body: sale,
    })
    if (error) throw error
    return data
  },

  // Purchases
  async createPurchase(purchase: Omit<Purchase, 'id'>) {
    const { data, error } = await supabase.functions.invoke('create-purchase', {
      body: purchase,
    })
    if (error) throw error
    return data
  },

  // AI Insights
  async getAIInsights() {
    const { data, error } = await supabase.functions.invoke('ai-insights')
    if (error) throw error
    return data
  },

  // AI Resumen (Financial Summary)
  async getAISummary(period: 'daily' | 'weekly' | 'monthly' = 'daily') {
    const { data, error } = await supabase.functions.invoke('ai-resumen', {
      body: { period },
    })
    if (error) throw error
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
