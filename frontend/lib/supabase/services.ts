import { createClient } from './client'
import type { Insight } from '@/lib/types'

const supabase = createClient()

export const getProfile = async (id: string, client?: any) => {
  const supabaseClient = client || supabase
  const { data, error } = await supabaseClient.from('profiles').select('*').eq('id', id).single()
  if (error) return null
  return data
}

export const services = {
  getProfile,
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

    // analytics-events-revival: la telemetría (operation_created /
    // first_operation) ya no se emite desde la aplicación. El choke point
    // único es el trigger AFTER INSERT de DB
    // (analytics_emit_operation_event(), 20260914000001), que cubre esta
    // ruta y todas las demás sin duplicar lógica ni arriesgar doble conteo.
    return data
  }
}
