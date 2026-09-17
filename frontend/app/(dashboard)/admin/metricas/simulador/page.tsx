"use client"

import { useEffect, useState } from 'react'
import { useAdminGate } from '@/hooks/auth/use-admin-gate'
import { fetchModuleStats } from '@/lib/adminAnalytics'
import { ModuleAnalytics } from '@/components/admin/ModuleAnalytics'
import { Button } from '@/components/ui/button'
import { ArrowLeft } from 'lucide-react'
import Link from 'next/link'

export default function AdminSimuladorAnalytics() {
    const gate = useAdminGate()
    const [stats, setStats] = useState<any>(null)
    const [loading, setLoading] = useState(true)

    useEffect(() => {
        if (gate !== "allowed") return

        async function load() {
            const dateTo = new Date().toISOString()
            const dateFrom = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000).toISOString()
            const data = await fetchModuleStats('simulador', dateFrom, dateTo)
            setStats(data)
            setLoading(false)
        }
        load().catch(() => setLoading(false))
    }, [gate])

    if (loading) return <div className="flex items-center justify-center py-20"><div className="h-8 w-8 animate-spin rounded-full border-2 border-emerald-500 border-t-transparent" /></div>

    return (
        <div className="container mx-auto p-6 max-w-7xl">
            <div className="mb-8">
                <Button variant="ghost" asChild className="mb-4 -ml-2 text-slate-400 hover:text-slate-100">
                    <Link href="/admin/metricas"><ArrowLeft className="w-4 h-4 mr-2" />Volver a Métricas</Link>
                </Button>
                <ModuleAnalytics
                    title="Uso del Simulador de Negocios"
                    subtitle="Frecuencia de simulaciones estratégicas realizadas"
                    stats={stats}
                    moduleType="simulador"
                />
            </div>
        </div>
    )
}
