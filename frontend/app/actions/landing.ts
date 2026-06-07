'use server'

import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import type { LandingSection } from '@/lib/landing'

export async function getLandingSectionsAction(): Promise<LandingSection[]> {
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

export async function getAllLandingSectionsAction(): Promise<LandingSection[]> {
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

export async function updateLandingSectionAction(
  id: string,
  updates: Partial<LandingSection>
): Promise<LandingSection> {
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

  revalidatePath('/', 'page')
  revalidatePath('/admin/landing', 'page')

  return data as LandingSection
}
