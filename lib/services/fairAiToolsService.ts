import { createClient } from "@/lib/supabase/client"

export interface FairAiTool {
  id: string
  name: string
  category: string
  description: string
  link: string
  status: 'active' | 'inactive'
  clicks_count: number
  created_at: string
  updated_at: string
}

const supabase = createClient()

export const fairAiToolsService = {
  async getAllTools() {
    const { data, error } = await supabase
      .from("fair_ai_tools")
      .select("*")
      .order("created_at", { ascending: false })

    if (error) throw error
    return data as FairAiTool[]
  },

  async createTool(data: Partial<FairAiTool>) {
    const { data: result, error } = await supabase
      .from("fair_ai_tools")
      .insert([data])
      .select()
      .single()

    if (error) throw error
    return result as FairAiTool
  },

  async updateTool(id: string, data: Partial<FairAiTool>) {
    const { data: result, error } = await supabase
      .from("fair_ai_tools")
      .update(data)
      .eq("id", id)
      .select()
      .single()

    if (error) throw error
    return result as FairAiTool
  },

  async deleteTool(id: string) {
    const { error } = await supabase
      .from("fair_ai_tools")
      .delete()
      .eq("id", id)

    if (error) throw error
  },

  async incrementClicks(id: string) {
    const { data } = await supabase.from("fair_ai_tools").select("clicks_count").eq("id", id).single()
    await supabase.from("fair_ai_tools").update({ clicks_count: (data?.clicks_count || 0) + 1 }).eq("id", id)
  },

  async getAdminStats() {
    const { data: all } = await supabase.from("fair_ai_tools").select("*")
    
    const stats = {
      total: all?.length || 0,
      active: all?.filter(i => i.status === 'active').length || 0,
      totalClicks: all?.reduce((acc, curr) => acc + (curr.clicks_count || 0), 0) || 0,
      newThisMonth: all?.filter(i => {
        const d = new Date(i.created_at)
        const now = new Date()
        return d.getMonth() === now.getMonth() && d.getFullYear() === now.getFullYear()
      }).length || 0,
      timeSeries: this.processTimeSeries(all || [])
    }
    
    return stats
  },

  processTimeSeries(data: any[]) {
    const months = ["Ene", "Feb", "Mar", "Abr", "May", "Jun", "Jul", "Ago", "Sep", "Oct", "Nov", "Dic"]
    const series = data.reduce((acc: any, curr: any) => {
      const date = new Date(curr.created_at)
      const month = months[date.getMonth()]
      acc[month] = (acc[month] || 0) + 1
      return acc
    }, {})

    return Object.entries(series).map(([name, total]) => ({ name, value: total }))
  }
}
