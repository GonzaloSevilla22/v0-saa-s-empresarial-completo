import { createClient } from "@/lib/supabase/client"

export interface CopilotPrompt {
  id: string
  name: string
  category: string
  description: string
  prompt_text: string
  usage_count: number
  status: 'active' | 'inactive'
  created_at: string
  updated_at: string
}

const supabase = createClient()

export const copilotPromptsService = {
  async getAllPrompts() {
    const { data, error } = await supabase
      .from("copilot_prompts")
      .select("*")
      .order("created_at", { ascending: false })

    if (error) throw error
    return data as CopilotPrompt[]
  },

  async createPrompt(data: Partial<CopilotPrompt>) {
    const { data: result, error } = await supabase
      .from("copilot_prompts")
      .insert([data])
      .select()
      .single()

    if (error) throw error
    return result as CopilotPrompt
  },

  async updatePrompt(id: string, data: Partial<CopilotPrompt>) {
    const { data: result, error } = await supabase
      .from("copilot_prompts")
      .update(data)
      .eq("id", id)
      .select()
      .single()

    if (error) throw error
    return result as CopilotPrompt
  },

  async deletePrompt(id: string) {
    const { error } = await supabase
      .from("copilot_prompts")
      .delete()
      .eq("id", id)

    if (error) throw error
  },

  async incrementUsage(id: string) {
    const { data } = await supabase.from("copilot_prompts").select("usage_count").eq("id", id).single()
    await supabase.from("copilot_prompts").update({ usage_count: (data?.usage_count || 0) + 1 }).eq("id", id)
  },

  async getAdminStats() {
    const { data: all } = await supabase.from("copilot_prompts").select("*")
    
    const stats = {
      total: all?.length || 0,
      active: all?.filter(i => i.status === 'active').length || 0,
      totalUsage: all?.reduce((acc, curr) => acc + (curr.usage_count || 0), 0) || 0,
      mostUsed: all?.sort((a,b) => (b.usage_count || 0) - (a.usage_count || 0))[0]?.name || "N/A",
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
