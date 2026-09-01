import { z } from "zod"
import { createClient } from "@/lib/supabase/client"

/**
 * seguros-perfil-asesor (design.md D2/D3): `community.seguros` tiene dos
 * formas posibles, discriminadas por `entry_type`. 'offer' es la forma
 * legacy (texto libre); 'advisor' es el perfil estructurado de un Productor
 * Asesor de Seguros. El default de la columna en DB es 'offer', pero las
 * filas legacy/mocks pueden no declarar el campo en absoluto — por eso
 * `isAdvisorEntry` trata "ausente" igual que 'offer' (ver ese helper).
 */
export type EntryType = "offer" | "advisor"

/** Vías de contacto soportadas por el tracking por vía (D6/D7). */
export type ContactChannel = "whatsapp" | "email" | "phone" | "web"
export const CONTACT_CHANNELS: readonly ContactChannel[] = ["whatsapp", "email", "phone", "web"]

export interface ServiceLine {
  title: string
  description: string
}

export interface Pillar {
  title: string
  body: string
}

/**
 * Validación de forma en el borde de la app (D3): un CHECK de Postgres no
 * admite subconsulta, así que la DB sólo garantiza "es un array" —
 * la forma de cada elemento (title/description, title/body) se valida acá
 * antes de guardar.
 */
export const serviceLineSchema = z.object({
  title: z.string().min(1, "El título es obligatorio"),
  description: z.string().min(1, "La descripción es obligatoria"),
})
export const serviceLinesSchema = z.array(serviceLineSchema)

export const pillarSchema = z.object({
  title: z.string().min(1, "El título es obligatorio"),
  body: z.string().min(1, "El contenido es obligatorio"),
})
export const pillarsSchema = z.array(pillarSchema)

export interface Insurance {
  id: string
  title: string
  description: string
  coverage: string
  price: string
  contact_url: string
  is_visible: boolean
  created_at: string
  updated_at: string
  clicks_count?: number
  // ─── Perfil de asesor (seguros-perfil-asesor) — todo nullable/opcional:
  // las filas 'offer' (incluidas las legacy) no las usan. ───────────────
  entry_type?: EntryType
  slug?: string | null
  advisor_name?: string | null
  advisor_role?: string | null
  license_number?: string | null
  license_authority?: string | null
  headline?: string | null
  bio?: string | null
  photo_url?: string | null
  contact_phone?: string | null
  contact_whatsapp?: string | null
  contact_email?: string | null
  service_lines?: ServiceLine[] | null
  pillars?: Pillar[] | null
  coverage_areas?: string[] | null
  disclaimer?: string | null
  contact_clicks?: Record<string, number> | null
  is_featured?: boolean
  sort_order?: number
}

/**
 * Distingue una entrada de tipo `advisor` de una de tipo `offer`.
 * `entry_type` ausente (filas legacy construidas antes de este change, o
 * mocks de test que no lo declaran) se trata como `offer` — el mismo
 * default que la columna tiene en DB — para no romper el render existente.
 */
export function isAdvisorEntry(entry: Pick<Insurance, "entry_type">): boolean {
  return entry.entry_type === "advisor"
}

const supabase = createClient()

export const insuranceService = {
  /**
   * Fetch all visible insurances for the public page
   */
  async getVisibleInsurances() {
    const { data, error } = await supabase
      .schema("community").from("seguros")
      .select("*")
      .eq("is_visible", true)
      .order("created_at", { ascending: false })

    if (error) throw error
    return data as Insurance[]
  },

  /**
   * Fetch all insurances (for admin use)
   */
  async getAllInsurances() {
    const { data, error } = await supabase
      .schema("community").from("seguros")
      .select("*")
      .order("created_at", { ascending: false })

    if (error) throw error
    return data as Insurance[]
  },

  /**
   * Fetch a single insurance by ID
   */
  async getInsuranceById(id: string) {
    const { data, error } = await supabase
      .schema("community").from("seguros")
      .select("*")
      .eq("id", id)
      .single()

    if (error) throw error
    return data as Insurance
  },

  /**
   * Fetch a single advisor profile by its public slug (perfil de asesor,
   * ruta /seguros/[slug]). No filtra explícitamente por `is_visible`: la
   * RLS ("Public items are viewable by everyone" + "seguros_admin_all") ya
   * hace ese trabajo — un no-admin que pide el slug de una fila oculta
   * recibe 0 filas de PostgREST, indistinguible de "no existe", que es
   * exactamente el comportamiento que pide la spec (ambos casos resuelven
   * a la pantalla de no encontrado). `maybeSingle()` en vez de `single()`:
   * "no encontrado" es un resultado válido, no una excepción.
   */
  async getAdvisorBySlug(slug: string) {
    const { data, error } = await supabase
      .schema("community").from("seguros")
      .select("*")
      .eq("slug", slug)
      .eq("entry_type", "advisor")
      .maybeSingle()

    if (error) throw error
    return (data as Insurance | null) ?? null
  },

  /**
   * Create a new insurance entry
   */
  async createInsurance(data: Partial<Insurance>) {
    const { data: result, error } = await supabase
      .schema("community").from("seguros")
      .insert([data])
      .select()
      .single()

    if (error) throw error
    return result as Insurance
  },

  /**
   * Update an existing insurance entry
   */
  async updateInsurance(id: string, data: Partial<Insurance>) {
    const { data: result, error } = await supabase
      .schema("community").from("seguros")
      .update(data)
      .eq("id", id)
      .select()
      .single()

    if (error) throw error
    return result as Insurance
  },

  /**
   * Delete an insurance entry
   */
  async deleteInsurance(id: string) {
    const { error } = await supabase
      .schema("community").from("seguros")
      .delete()
      .eq("id", id)

    if (error) throw error
  },

  /**
   * Toggle visibility of an insurance
   */
  async toggleInsuranceVisibility(id: string, currentVisibility: boolean) {
    const { error } = await supabase
      .schema("community").from("seguros")
      .update({ is_visible: !currentVisibility })
      .eq("id", id)

    if (error) throw error
  },

  /**
   * Increment click count for an insurance (fire-and-forget: el tracking
   * nunca rompe la UX — ante error loguea y sigue, no re-lanza)
   */
  async incrementClicks(id: string) {
    try {
      const { error } = await supabase.rpc("increment_seguros_clicks", { row_id: id })
      if (error) throw error
    } catch (error) {
      console.error("Error incrementando clicks de seguro:", error)
    }
  },

  /**
   * Increment the per-channel contact click breakdown for an advisor
   * (design.md D6). Mismo contrato fire-and-forget que `incrementClicks`
   * (decisión PO 2026-08-01): ante cualquier error, loguea y no re-lanza,
   * y nunca cae en un fallback de escritura directa a la tabla — la
   * función nueva (`increment_seguros_contact_click`, migración
   * 20261017000001) valida el conjunto cerrado de vías del lado servidor,
   * así que una vía desconocida no lanza acá tampoco.
   * `incrementClicks` (arriba) NO se toca ni se renombra: es la red de
   * seguridad de este change.
   */
  async incrementContactClick(id: string, channel: ContactChannel) {
    try {
      const { error } = await supabase.rpc("increment_seguros_contact_click", {
        row_id: id,
        channel,
      })
      if (error) throw error
    } catch (error) {
      console.error("Error incrementando clicks por vía de contacto:", error)
    }
  },

  /**
   * Fetch admin dashboard metrics for seguros
   */
  async getAdminStats() {
    const { data: all } = await supabase.schema("community").from("seguros").select("is_visible, clicks_count, created_at")
    
    const stats = {
      total: all?.length || 0,
      visible: all?.filter(i => i.is_visible).length || 0,
      hidden: all?.filter(i => !i.is_visible).length || 0,
      totalClicks: all?.reduce((acc, curr) => acc + (curr.clicks_count || 0), 0) || 0,
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
