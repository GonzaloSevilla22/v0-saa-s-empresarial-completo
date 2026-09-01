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

/**
 * fix/admin-timeseries-feria-copilot (mismo bug que #482 en
 * insuranceService): shape consumido DIRECTO por `TimeSeriesLinesChart`
 * (`period` ISO real, primero del mes UTC; `activations` = prompts dados
 * de alta ese mes) — sin adapter en el JSX. El copiloto no tiene un
 * segundo dato análogo a `umv_achieved`, por eso no se declara acá: el
 * componente lo trata como serie opcional.
 */
export interface TimeSeriesPoint {
  period: string
  activations: number
}

export interface AdminStats {
  total: number
  active: number
  totalUsage: number
  mostUsed: string
  timeSeries: TimeSeriesPoint[]
}

const supabase = createClient()

export const copilotPromptsService = {
  async getAllPrompts() {
    const { data, error } = await supabase
      .schema("community").from("copilot_prompts")
      .select("*")
      .order("created_at", { ascending: false })

    if (error) throw error
    return data as CopilotPrompt[]
  },

  async createPrompt(data: Partial<CopilotPrompt>) {
    const { data: result, error } = await supabase
      .schema("community").from("copilot_prompts")
      .insert([data])
      .select()
      .single()

    if (error) throw error
    return result as CopilotPrompt
  },

  async updatePrompt(id: string, data: Partial<CopilotPrompt>) {
    const { data: result, error } = await supabase
      .schema("community").from("copilot_prompts")
      .update(data)
      .eq("id", id)
      .select()
      .single()

    if (error) throw error
    return result as CopilotPrompt
  },

  async deletePrompt(id: string) {
    const { error } = await supabase
      .schema("community").from("copilot_prompts")
      .delete()
      .eq("id", id)

    if (error) throw error
  },

  async getAdminStats(): Promise<AdminStats> {
    const { data: all } = await supabase.schema("community").from("copilot_prompts").select("*")

    const stats: AdminStats = {
      total: all?.length || 0,
      active: all?.filter(i => i.status === 'active').length || 0,
      totalUsage: all?.reduce((acc, curr) => acc + (curr.usage_count || 0), 0) || 0,
      mostUsed: all?.sort((a,b) => (b.usage_count || 0) - (a.usage_count || 0))[0]?.name || "N/A",
      timeSeries: this.processTimeSeries(all || [])
    }

    return stats
  },

  /**
   * fix/admin-timeseries-feria-copilot (mismo bug que #482): agrega por
   * AÑO+mes (UTC) — antes agregaba solo por nombre de mes en español
   * ("Mar"), así que marzo 2026 y marzo 2027 se mezclaban en el mismo
   * bucket. El `period` que emite cada punto es una fecha ISO real
   * (primero del mes, UTC) — `TimeSeriesLinesChart` hace
   * `new Date(d.period)` para su escala temporal D3, y `"Mar"` daba
   * `Invalid Date` (eje/extent rotos). UTC explícito (no el mes local del
   * browser) para que la agregación sea determinística en tests y CI sin
   * importar el timezone de la máquina.
   */
  processTimeSeries(data: Pick<CopilotPrompt, "created_at">[]): TimeSeriesPoint[] {
    const buckets = data.reduce<Record<string, number>>((acc, curr) => {
      const date = new Date(curr.created_at)
      const key = `${date.getUTCFullYear()}-${String(date.getUTCMonth() + 1).padStart(2, "0")}`
      acc[key] = (acc[key] || 0) + 1
      return acc
    }, {})

    return Object.entries(buckets)
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([key, activations]) => {
        const [year, month] = key.split("-").map(Number)
        return {
          period: new Date(Date.UTC(year!, month! - 1, 1)).toISOString(),
          activations,
        }
      })
  }
}
