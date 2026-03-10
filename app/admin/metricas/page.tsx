"use client"

import { useEffect, useState } from 'react'
import { createClient } from '@/lib/supabase/client'
import { fetchBusinessKpis } from '@/lib/adminAnalytics'
import {
    Users, Crown, MessageSquare, Sparkles, TrendingUp, Activity
} from 'lucide-react'
import TimeSeriesLinesChart from '@/components/admin/charts/TimeSeriesLinesChart'
import WeeklyHistogramChart from '@/components/admin/charts/WeeklyHistogramChart'

export default function AdminMetricasPage() {
    const [kpis, setKpis] = useState<any>(null)
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

            const data = await fetchBusinessKpis()
            setKpis(data)
        } catch (err: any) {
            console.error("Error loading business metrics:", err)
            setError(err.message || "Error al cargar las métricas estratégicas.")
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
            <p className="text-slate-400 text-sm animate-pulse">Cargando métricas estratégicas...</p>
        </div>
    )

    if (error || !kpis) return (
        <div className="flex flex-col items-center justify-center py-32 gap-6 container max-w-md text-center">
            <div className="p-4 bg-red-500/10 border border-red-500/20 rounded-full">
                <Activity className="w-8 h-8 text-red-500" />
            </div>
            <div className="space-y-2">
                <h3 className="text-xl font-bold text-slate-100">Error de Carga</h3>
                <p className="text-slate-400 text-sm">{error || "No se pudieron obtener los KPIs del negocio."}</p>
            </div>
            <button
                onClick={loadData}
                className="px-6 py-2 bg-slate-800 hover:bg-slate-700 text-slate-100 rounded-lg border border-slate-700 transition-colors"
            >
                Reintentar
            </button>
        </div>
    )

    return (
        <div className="container mx-auto p-6 max-w-7xl animate-in fade-in duration-700 pb-20">
            <header className="flex flex-col gap-2 mb-10">
                <h1 className="text-3xl font-bold text-slate-100 tracking-tight">Métricas Estratégicas</h1>
                <p className="text-slate-400">Panel de control de KPIs del Ecosistema (MVP).</p>
            </header>

            <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6 mb-12">
                <KpiSummaryCard title="Adopción (Total)" value={kpis.adoption?.total_users} subtext={`${kpis.adoption?.mau} Usuarios Activos (MAU)`} icon={Users} badge={`${kpis.adoption?.activation_rate}% Activación`} />
                <KpiSummaryCard title="Ingresos (MRR)" value={`$${kpis.freemium?.mrr}`} subtext={`${kpis.freemium?.pro_users} Usuarios Pro`} icon={Crown} badge={`${kpis.freemium?.conversion_rate}% Conv.`} iconColor="text-yellow-500" />
                <KpiSummaryCard title="Comunidad" value={kpis.community?.total_activity} subtext="Interacciones 30d" icon={MessageSquare} badge={`${kpis.community?.active_pools} Pools`} iconColor="text-blue-500" />
                <KpiSummaryCard title="IA Servida" value={kpis.ai?.total_insights} subtext="Consejos generados" icon={Sparkles} badge={`${kpis.ai?.alerts_triggered} Alertas`} iconColor="text-purple-500" />
            </div>

            <div className="grid grid-cols-1 lg:grid-cols-2 gap-8">
                <section className="bg-slate-900/40 backdrop-blur-md p-8 rounded-2xl shadow-xl border border-slate-800">
                    <div className="flex items-center gap-2 mb-6">
                        <TrendingUp className="w-5 h-5 text-emerald-500" />
                        <h2 className="text-xl font-bold text-slate-100">Crecimiento de Usuarios</h2>
                    </div>
                    <div className="aspect-video w-full flex items-center justify-center p-4">
                        {kpis?.time_series && kpis.time_series.length > 0 ? (
                            <TimeSeriesLinesChart data={kpis.time_series} width={600} height={300} />
                        ) : (
                            <span className="text-slate-500">Datos insuficientes para el gráfico</span>
                        )}
                    </div>
                </section>
                <section className="bg-slate-900/40 backdrop-blur-md p-8 rounded-2xl shadow-xl border border-slate-800">
                    <div className="flex items-center gap-2 mb-6">
                        <Activity className="w-5 h-5 text-blue-500" />
                        <h2 className="text-xl font-bold text-slate-100">Actividad Semanal</h2>
                    </div>
                    <div className="aspect-video w-full flex items-center justify-center p-4">
                        {kpis?.habit_histogram && kpis.habit_histogram.length > 0 ? (
                            <WeeklyHistogramChart data={kpis.habit_histogram} width={600} height={300} />
                        ) : (
                            <span className="text-slate-500">Datos insuficientes para el gráfico</span>
                        )}
                    </div>
                </section>
            </div>
            <section className="mt-12">
                <div className="flex items-center gap-2 mb-6">
                    <Activity className="w-5 h-5 text-emerald-500" />
                    <h2 className="text-xl font-bold text-slate-100">Detalle por Módulo</h2>
                </div>
                <div className="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-5 gap-4">
                    <ModuleLink href="/admin/metricas/ventas" label="Ventas" />
                    <ModuleLink href="/admin/metricas/compras" label="Compras" />
                    <ModuleLink href="/admin/metricas/gastos" label="Gastos" />
                    <ModuleLink href="/admin/metricas/stock" label="Stock" />
                    <ModuleLink href="/admin/metricas/clientes" label="Clientes" />
                    <ModuleLink href="/admin/metricas/ai" label="Consejo IA" />
                    <ModuleLink href="/admin/metricas/simulador" label="Simulador" />
                    <ModuleLink href="/admin/metricas/comunidad" label="Comunidad" />
                    <ModuleLink href="/admin/metricas/cursos" label="Cursos" />
                </div>
            </section>
        </div>
    )
}

function ModuleLink({ href, label }: { href: string, label: string }) {
    return (
        <a href={href} className="bg-slate-900/40 backdrop-blur-md p-4 rounded-xl border border-slate-800 text-center text-sm font-medium text-slate-300 hover:border-emerald-500/50 hover:text-emerald-400 transition-all">
            {label}
        </a>
    )
}

function KpiSummaryCard({ title, value, subtext, icon: Icon, badge, iconColor = "text-emerald-500" }: any) {
    return (
        <div className="bg-slate-900/40 backdrop-blur-md p-6 rounded-2xl shadow-xl border border-slate-800 relative overflow-hidden group">
            <div className={`absolute top-0 right-0 p-4 opacity-5 group-hover:opacity-10 transition-opacity ${iconColor}`}>
                <Icon className="w-12 h-12" />
            </div>
            <div className="flex items-center space-x-2 text-slate-400 mb-2">
                <Icon className={`w-4 h-4 ${iconColor}`} />
                <p className="text-xs font-medium uppercase tracking-wider text-slate-500">{title}</p>
            </div>
            <div className="flex items-end justify-between">
                <div>
                    <p className="text-3xl font-bold text-slate-100">{value}</p>
                    <p className="text-xs text-slate-500 mt-1">{subtext}</p>
                </div>
                <span className={`flex items-center text-[10px] font-bold px-2 py-0.5 rounded uppercase ${iconColor} bg-current/10 border border-current/20`}>
                    {badge}
                </span>
            </div>
        </div>
    )
}
