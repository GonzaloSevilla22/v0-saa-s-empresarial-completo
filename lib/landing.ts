import { createClient } from '@/lib/supabase/client'

export type LandingSection = {
    id: string
    slug: string
    type: 'hero' | 'features' | 'image_text' | 'benefits' | 'testimonials' | 'cta'
    title: string | null
    subtitle: string | null
    content: string | null
    image_url: string | null
    button_text: string | null
    button_link: string | null
    position: number
    active: boolean
    created_at: string
    updated_at: string
}

export async function getLandingSections() {
    const supabase = createClient()
    const { data, error } = await supabase
        .from('landing_sections')
        .select('*')
        .eq('active', true)
        .order('position', { ascending: true })

    if (error) {
        console.error('Error fetching landing sections:', error)
        return []
    }

    return data as LandingSection[]
}

export async function getAllLandingSections() {
    const supabase = createClient()
    const { data, error } = await supabase
        .from('landing_sections')
        .select('*')
        .order('position', { ascending: true })

    if (error) {
        console.error('Error fetching all landing sections:', error)
        return []
    }

    return data as LandingSection[]
}

export async function updateLandingSection(id: string, updates: Partial<LandingSection>) {
    const supabase = createClient()
    const { data, error } = await supabase
        .from('landing_sections')
        .update(updates)
        .eq('id', id)
        .select()
        .single()

    if (error) {
        console.error('Error updating landing section:', error)
        throw error
    }

    return data as LandingSection
}

export async function uploadLandingImage(file: File) {
    const supabase = createClient()
    const fileExt = file.name.split('.').pop()
    const fileName = `${Math.random()}-${Date.now()}.${fileExt}`
    const filePath = `images/${fileName}`

    const { error: uploadError } = await supabase.storage
        .from('landing')
        .upload(filePath, file)

    if (uploadError) {
        throw uploadError
    }

    const { data: { publicUrl } } = supabase.storage
        .from('landing')
        .getPublicUrl(filePath)

    return publicUrl
}
