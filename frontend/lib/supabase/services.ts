import { createClient } from './client'
import type { Insight } from '@/lib/types'
// auth-hardening-jwt-cookies (Parte C, D1, task 19.8b): la identidad ya no sale
// de `supabase.auth.getUser()` — con `accessToken` configurado ese acceso LANZA
// (`supabase-js/index.mjs:389`). Viene del `user` que acompaña al token, así que
// no cuesta una llamada extra.
import { getSessionUser } from '@/lib/auth/access-token-store'

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
    const user = await getSessionUser()
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
    const user = await getSessionUser()
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
