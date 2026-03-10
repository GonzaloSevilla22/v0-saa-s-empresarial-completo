import { createClient } from '@/lib/supabase/server'
import { cookies } from 'next/headers'

export const aiCopilotService = {
  /**
   * Fetches relevant business data to provide context for the AI.
   */
  async getBusinessDataContext() {
    const cookieStore = cookies()
    const supabase = createClient(cookieStore)
    
    const [
      { data: products },
      { data: sales },
      { data: expenses },
      { data: inventory },
    ] = await Promise.all([
      supabase.from('products').select('name, price, cost, stock').order('stock', { ascending: true }),
      supabase.from('sales').select('amount, quantity, created_at, products(name)').order('created_at', { ascending: false }).limit(20),
      supabase.from('expenses').select('amount, category, date').order('date', { ascending: false }).limit(10),
      supabase.from('products').select('name, stock').lt('stock', 5),
    ])

    // Calculate some basic metrics
    const topProducts = products?.slice(0, 5).map(p => ({
      name: p.name,
      margin: p.price - p.cost,
      stock: p.stock
    })) || []

    const totalSales = sales?.reduce((acc, s) => acc + Number(s.amount), 0) || 0
    const recentLowStock = inventory?.map(i => i.name) || []

    return {
      topProducts,
      totalSalesRecent: totalSales,
      recentLowStock,
      recentExpenses: expenses || []
    }
  },

  /**
   * Retrieves conversation history for the user.
   */
  async getConversationHistory() {
    const cookieStore = cookies()
    const supabase = createClient(cookieStore)
    
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
  async saveConversation(question: string, answer: string) {
    const cookieStore = cookies()
    const supabase = createClient(cookieStore)
    
    const { data: { user } } = await supabase.auth.getUser()
    if (!user) throw new Error("Unauthorized")

    const { data, error } = await supabase
      .from('ai_conversations')
      .insert([
        { user_id: user.id, question, answer }
      ])
      .select()
      .single()

    if (error) throw error
    return data
  }
}
