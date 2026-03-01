import React from 'react'
import { redirect } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getProfile } from '@/lib/supabase/services'
import { fetchModuleStats } from '@/lib/adminAnalytics'
import { ModuleAnalytics } from '@/components/admin/ModuleAnalytics'
import { Button } from '@/components/ui/button'
import { ArrowLeft } from 'lucide-react'
import Link from 'next/link'

export const dynamic = 'force-dynamic'

export default async function AdminComprasAnalytics() {
    const supabase = createClient()

    // 1. Security
    const { data: { user } } = await supabase.auth.getUser()
    if (!user) redirect('/auth')

    const profile = await getProfile(user.id, supabase)
    if (!profile || profile.role !== 'admin') redirect('/dashboard')

    // 2. Data
    const dateTo = new Date().toISOString()
    const dateFrom = new Date(new Date().setDate(new Date().getDate() - 30)).toISOString()
    const stats = await fetchModuleStats('compras', dateFrom, dateTo, supabase)

    return (
        <div className="container mx-auto p-6 max-w-7xl">
            <div className="mb-8">
                <Button variant="ghost" asChild className="mb-4 -ml-2 text-slate-400 hover:text-slate-100">
                    <Link href="/admin/metricas">
                        <ArrowLeft className="w-4 h-4 mr-2" />
                        Volver a Métricas
                    </Link>
                </Button>
                <ModuleAnalytics
                    title="Analíticas de Compras"
                    subtitle="Abastecimiento y reposición global"
                    stats={stats}
                    moduleType="compras"
                />
            </div>
        </div>
    )
}
