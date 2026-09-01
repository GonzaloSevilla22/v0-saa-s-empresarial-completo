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

/**
 * fix/admin-timeseries-feria-copilot (mismo bug que #482 en
 * insuranceService): shape consumido DIRECTO por `TimeSeriesLinesChart`
 * (`period` ISO real, primero del mes UTC; `activations` = herramientas
 * IA dadas de alta ese mes) — sin adapter en el JSX. La feria IA no tiene
 * un segundo dato análogo a `umv_achieved`, por eso no se declara acá: el
 * componente lo trata como serie opcional.
 */
export interface TimeSeriesPoint {
  period: string
  activations: number
}

export interface AdminStats {
  total: number
  active: number
  totalClicks: number
  newThisMonth: number
  timeSeries: TimeSeriesPoint[]
}

const supabase = createClient()

export const fairAiToolsService = {
  async getAllTools() {
    const { data, error } = await supabase
      .schema("community").from("fair_ai_tools")
      .select("*")
      .order("created_at", { ascending: false })

    if (error) throw error
    return data as FairAiTool[]
  },

  async createTool(data: Partial<FairAiTool>) {
    const { data: result, error } = await supabase
      .schema("community").from("fair_ai_tools")
      .insert([data])
      .select()
      .single()

    if (error) throw error
    return result as FairAiTool
  },

  async updateTool(id: string, data: Partial<FairAiTool>) {
    const { data: result, error } = await supabase
      .schema("community").from("fair_ai_tools")
      .update(data)
      .eq("id", id)
      .select()
      .single()

    if (error) throw error
    return result as FairAiTool
  },

  async deleteTool(id: string) {
    const { error } = await supabase
      .schema("community").from("fair_ai_tools")
      .delete()
      .eq("id", id)

    if (error) throw error
  },

  async getAdminStats(): Promise<AdminStats> {
    const { data: all } = await supabase.schema("community").from("fair_ai_tools").select("*")

    const stats: AdminStats = {
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
  processTimeSeries(data: Pick<FairAiTool, "created_at">[]): TimeSeriesPoint[] {
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
