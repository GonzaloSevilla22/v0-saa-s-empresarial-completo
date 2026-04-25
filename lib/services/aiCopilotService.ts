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
   * Fetches relevant business data to provide rich context for the AI.
   *
   * Fixes vs. original:
   *  - Products are ordered by price DESC (revenue proxy) not stock ASC (was backwards)
   *  - Top products are ranked by sales VOLUME from recent sales, not by arbitrary slice
   *  - Purchases (compras) are now included in context
   *  - Actual revenue totals are computed, not just row counts
   *  - Expense breakdown by category is included
   */
  async getBusinessDataContext(supabase: SupabaseClient) {
    const thirtyDaysAgo = new Date()
    thirtyDaysAgo.setDate(thirtyDaysAgo.getDate() - 30)
    const thirtyDaysAgoStr = thirtyDaysAgo.toISOString().split('T')[0]

    const [
      { data: products },
      { data: recentSales },
      { data: recentExpenses },
      { data: recentPurchases },
    ] = await Promise.all([
      supabase
        .from('products')
        .select('id, name, price, cost, stock, min_stock')
        .order('price', { ascending: false }),    // High-value products first
      supabase
        .from('sales')
        .select('amount, quantity, date, product_id, products(name)')
        .gte('date', thirtyDaysAgoStr)
        .order('date', { ascending: false })
        .limit(100),                               // 30-day window, not just last 20
      supabase
        .from('expenses')
        .select('amount, category, date')
        .gte('date', thirtyDaysAgoStr)
        .order('date', { ascending: false }),
      supabase
        .from('purchases')
        .select('amount, quantity, date, product_id, products(name)')
        .gte('date', thirtyDaysAgoStr)
        .order('date', { ascending: false })
        .limit(50),
    ])

    // ── Top products by sales volume in the period ───────────────────────────
    const salesByProduct = new Map<string, { name: string; units: number; revenue: number }>()
    for (const s of recentSales ?? []) {
      const pid = s.product_id
      const name = (s.products as any)?.name ?? 'Desconocido'
      const existing = salesByProduct.get(pid) ?? { name, units: 0, revenue: 0 }
      salesByProduct.set(pid, {
        name,
        units: existing.units + Number(s.quantity),
        revenue: existing.revenue + Number(s.amount),
      })
    }
    const topProducts = [...salesByProduct.values()]
      .sort((a, b) => b.revenue - a.revenue)
      .slice(0, 5)

    // ── Revenue & expense totals ─────────────────────────────────────────────
    const totalRevenue = (recentSales ?? []).reduce((s, r) => s + Number(r.amount), 0)
    const totalExpenses = (recentExpenses ?? []).reduce((s, r) => s + Number(r.amount), 0)
    const totalPurchases = (recentPurchases ?? []).reduce((s, r) => s + Number(r.amount), 0)
    const netProfit = totalRevenue - totalExpenses

    // ── Expense breakdown by category ────────────────────────────────────────
    const expenseByCategory = new Map<string, number>()
    for (const e of recentExpenses ?? []) {
      const cat = e.category ?? 'Sin categoría'
      expenseByCategory.set(cat, (expenseByCategory.get(cat) ?? 0) + Number(e.amount))
    }
    const topExpenseCategories = [...expenseByCategory.entries()]
      .sort((a, b) => b[1] - a[1])
      .slice(0, 4)
      .map(([cat, amt]) => `${cat}: $${amt.toLocaleString()}`)

    // ── Stock alerts ─────────────────────────────────────────────────────────
    const lowStockProducts = (products ?? [])
      .filter(p => Number(p.stock) <= Number(p.min_stock ?? 5))
      .slice(0, 5)
      .map(p => `${p.name} (${p.stock} uds)`)

    // ── High-margin products (potential upsell) ──────────────────────────────
    const highMarginProducts = (products ?? [])
      .map(p => ({
        name: p.name,
        price: p.price,
        margin: p.price > 0 ? ((p.price - p.cost) / p.price) * 100 : 0,
      }))
      .filter(p => p.margin >= 50)
      .slice(0, 3)
      .map(p => `${p.name} (${p.margin.toFixed(0)}% margen)`)

    return {
      period: 'últimos 30 días',
      totalRevenue,
      totalExpenses,
      totalPurchases,
      netProfit,
      topProducts,
      topExpenseCategories,
      lowStockProducts,
      highMarginProducts,
      totalProductCount: (products ?? []).length,
    }
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
