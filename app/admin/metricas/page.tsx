import React from 'react'
import { redirect } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getProfile } from '@/lib/supabase/services'
import { fetchBusinessKpis } from '@/lib/adminAnalytics'
import {
    Users,
    Crown,
    MessageSquare,
    Sparkles,
    TrendingUp,
    ArrowUpRight,
    Activity
} from 'lucide-react'

// Existing Chart Components
import TimeSeriesLinesChart from '@/components/admin/charts/TimeSeriesLinesChart'
import WeeklyHistogramChart from '@/components/admin/charts/WeeklyHistogramChart'

export const dynamic = 'force-dynamic'

export default async function AdminMetricasPage() {
    const supabase = createClient()

    // 1. Security check
    const { data: { user } } = await supabase.auth.getUser()
    if (!user) redirect('/auth')

    const profile = await getProfile(user.id)
    if (!profile || profile.role !== 'admin') redirect('/dashboard')

    // 2. Fetch Data
    const kpis = await fetchBusinessKpis()

    return (
        <div className="container mx-auto p-6 max-w-7xl animate-in fade-in duration-700 pb-20">
            <header className="flex flex-col gap-2 mb-10">
                <h1 className="text-3xl font-bold text-slate-100 tracking-tight">Métricas Estratégicas</h1>
                <p className="text-slate-400">Panel de control de KPIs del Ecosistema (MVP).</p>
            </header>

            {/* KPI Cards Row */}
            <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6 mb-12">
                {/* Adoption */}
                <KpiSummaryCard
                    title="Adopción (Total)"
                    value={kpis.adoption.total_users}
                    subtext={`${kpis.adoption.mau} Usuarios Activos (MAU)`}
                    icon={Users}
                    badge={`${kpis.adoption.activation_rate}% Activación`}
                />
                {/* Freemium */}
                <KpiSummaryCard
                    title="Ingresos (MRR)"
                    value={`$${kpis.freemium.mrr}`}
                    subtext={`${kpis.freemium.pro_users} Usuarios Pro`}
                    icon={Crown}
                    badge={`${kpis.freemium.conversion_rate}% Conv.`}
                    iconColor="text-yellow-500"
                />
                {/* Community */}
                <KpiSummaryCard
                    title="Comunidad"
                    value={kpis.community.total_activity}
                    subtext="Interacciones 30d"
                    icon={MessageSquare}
                    badge={`${kpis.community.active_pools} Pools`}
                    iconColor="text-blue-500"
                />
                {/* AI */}
                <KpiSummaryCard
                    title="IA Servida"
                    value={kpis.ai.total_insights}
                    subtext="Consejos generados"
                    icon={Sparkles}
                    badge={`${kpis.ai.alerts_triggered} Alertas`}
                    iconColor="text-purple-500"
                />
            </div>

            {/* Detailed Sections */}
            <div className="grid grid-cols-1 lg:grid-cols-2 gap-8">
                <section className="bg-slate-900/40 backdrop-blur-md p-8 rounded-2xl shadow-xl border border-slate-800">
                    <div className="flex items-center gap-2 mb-6">
                        <TrendingUp className="w-5 h-5 text-emerald-500" />
                        <h2 className="text-xl font-bold text-slate-100">Crecimiento de Usuarios</h2>
                    </div>
                    {/* We reuse the TimeSeriesLinesChart if it were ready for this data, 
              but for now it's a structural placeholder for the D3 integration */}
                    <div className="aspect-video w-full flex items-center justify-center text-slate-500 border border-dashed border-slate-800 rounded-xl">
                        [Gráfico de Tendencia D3]
                    </div>
                </section>

                <section className="bg-slate-900/40 backdrop-blur-md p-8 rounded-2xl shadow-xl border border-slate-800">
                    <div className="flex items-center gap-2 mb-6">
                        <Activity className="w-5 h-5 text-blue-500" />
                        <h2 className="text-xl font-bold text-slate-100">Actividad Semanal</h2>
                    </div>
                    <div className="aspect-video w-full flex items-center justify-center text-slate-500 border border-dashed border-slate-800 rounded-xl">
                        [Histograma de Hábitos D3]
                    </div>
                </section>
            </div>
        </div>
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
