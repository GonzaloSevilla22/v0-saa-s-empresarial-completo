"use client"

import { useEffect, useState } from 'react'
import { createClient } from '@/lib/supabase/client'
import { fetchModuleStats } from '@/lib/adminAnalytics'
import { ModuleAnalytics } from '@/components/admin/ModuleAnalytics'
import { Button } from '@/components/ui/button'
import { ArrowLeft } from 'lucide-react'
import Link from 'next/link'

export default function AdminStockAnalytics() {
    const [stats, setStats] = useState<any>(null)
    const [loading, setLoading] = useState(true)

    useEffect(() => {
        async function load() {
            const supabase = createClient()
            const { data: { user } } = await supabase.auth.getUser()
            if (!user) { window.location.href = '/auth'; return }
            const { data: profile } = await supabase.from('profiles').select('role').eq('id', user.id).single()
            if (!profile || profile.role !== 'admin') { window.location.href = '/dashboard'; return }
            const dateTo = new Date().toISOString()
            const dateFrom = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000).toISOString()
            const data = await fetchModuleStats('stock', dateFrom, dateTo)
            setStats(data)
            setLoading(false)
        }
        load().catch(() => setLoading(false))
    }, [])

    if (loading) return <div className="flex items-center justify-center py-20"><div className="h-8 w-8 animate-spin rounded-full border-2 border-emerald-500 border-t-transparent" /></div>

    return (
        <div className="container mx-auto p-6 max-w-7xl">
            <div className="mb-8">
                <Button variant="ghost" asChild className="mb-4 -ml-2 text-slate-400 hover:text-slate-100">
                    <Link href="/admin/metricas"><ArrowLeft className="w-4 h-4 mr-2" />Volver a Métricas</Link>
                </Button>
                <ModuleAnalytics title="Estado de Inventario Global" subtitle="Monitoreo de existencias y valorización total" stats={stats} moduleType="stock" />
            </div>
        </div>
    )
}
