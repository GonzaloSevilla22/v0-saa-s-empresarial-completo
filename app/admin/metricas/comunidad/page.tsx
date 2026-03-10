"use client"

import { useEffect, useState } from 'react'
import { createClient } from '@/lib/supabase/client'
import { fetchModuleStats } from '@/lib/adminAnalytics'
import { ModuleAnalytics } from '@/components/admin/ModuleAnalytics'
import { Button } from '@/components/ui/button'
import { ArrowLeft } from 'lucide-react'
import Link from 'next/link'

export default function AdminComunidadAnalytics() {
    const [stats, setStats] = useState<any>(null)
    const [loading, setLoading] = useState(true)
    const [error, setError] = useState<string | null>(null)

    const loadData = async () => {
        setLoading(true)
        setError(null)
        try {
            const supabase = createClient()
            const { data: { user } } = await supabase.auth.getUser()
            if (!user) { window.location.href = '/auth'; return }

            const { data: profile } = await supabase.from('profiles').select('role').eq('id', user.id).single()
            if (!profile || profile.role !== 'admin') { window.location.href = '/dashboard'; return }

            const dateTo = new Date().toISOString()
            const dateFrom = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000).toISOString()
            const data = await fetchModuleStats('comunidad', dateFrom, dateTo)
            setStats(data)
        } catch (err: any) {
            console.error("Error loading community stats:", err)
            setError(err.message || "Error al cargar las analíticas de comunidad.")
        } finally {
            setLoading(false)
        }
    }

    useEffect(() => {
        loadData()
    }, [])

    if (loading) return (
        <div className="flex flex-col items-center justify-center py-32 gap-4">
            <div className="h-8 w-8 animate-spin rounded-full border-2 border-emerald-500 border-t-transparent" />
            <p className="text-slate-400 text-sm animate-pulse">Cargando analíticas...</p>
        </div>
    )

    if (error || !stats) return (
        <div className="flex flex-col items-center justify-center py-32 gap-6 container max-w-md text-center">
            <div className="p-4 bg-red-500/10 border border-red-500/20 rounded-full">
                <ArrowLeft className="w-8 h-8 text-red-500" />
            </div>
            <div className="space-y-2">
                <h3 className="text-xl font-bold text-slate-100">Error de Carga</h3>
                <p className="text-slate-400 text-sm">{error || "No se pudieron obtener los datos de la comunidad."}</p>
            </div>
            <div className="flex gap-4 items-center">
                <Button variant="outline" asChild>
                    <Link href="/admin/metricas">Volver</Link>
                </Button>
                <Button onClick={loadData}>Reintentar</Button>
            </div>
        </div>
    )

    return (
        <div className="container mx-auto p-6 max-w-7xl">
            <div className="mb-8">
                <Button variant="ghost" asChild className="mb-4 -ml-2 text-slate-400 hover:text-slate-100">
                    <Link href="/admin/metricas"><ArrowLeft className="w-4 h-4 mr-2" />Volver a Métricas</Link>
                </Button>
                <ModuleAnalytics
                    title="Actividad de la Comunidad"
                    subtitle="Interacción en posts y respuestas de emprendedores"
                    stats={stats}
                    moduleType="comunidad" as any
                />
            </div>
        </div>
    )
}
