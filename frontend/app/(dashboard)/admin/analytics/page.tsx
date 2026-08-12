"use client"

import { useEffect, useState } from 'react'
import { createClient } from '@/lib/supabase/client'
import Link from 'next/link'
import {
    Activity,
    Zap,
    Calendar,
    TrendingUp,
    Users,
    Sparkles,
    MousePointerClick,
    AlertTriangle,
    LucideIcon
} from 'lucide-react'
import TimeSeriesLinesChart from '@/components/admin/charts/TimeSeriesLinesChart'
import CohortRetentionChart from '@/components/admin/charts/CohortRetentionChart'
import WeeklyHistogramChart from '@/components/admin/charts/WeeklyHistogramChart'
import StackedBarsChart from '@/components/admin/charts/StackedBarsChart'
import CommunitySeriesChart from '@/components/admin/charts/CommunitySeriesChart'
import {
    fetchKpiOverview,
    fetchRetention,
    fetchWeeklyUsageDistribution,
    mapKpiHeaderMetrics,
    selectLatestMatureCohort,
    shouldShowDataCoverageWarning,
    type AdminKpiOverview,
    type AdminRetentionCohort,
    type AdminWeeklyUsageBucket,
} from '@/lib/adminAnalytics'

interface AdminAnalyticsData {
    kpiOverview: AdminKpiOverview
    retentionData: AdminRetentionCohort[]
    weeklyUsage: AdminWeeklyUsageBucket[]
}

export default function AdminAnalyticsPage() {
    const [data, setData] = useState<AdminAnalyticsData | null>(null)
    const [loading, setLoading] = useState(true)
    const [unauthorized, setUnauthorized] = useState(false)
    const [error, setError] = useState<string | null>(null)

    const loadData = async () => {
        setLoading(true)
        setError(null)
        try {
            const supabase = createClient()
            const { data: { user } } = await supabase.auth.getUser()
            if (!user) { window.location.href = '/auth'; return }

            const { data: profile } = await supabase.from('profiles').select('role').eq('id', user.id).single()
            if (!profile || profile.role !== 'admin') { setUnauthorized(true); setLoading(false); return }

            const dateTo = new Date().toISOString()
            const dateFrom = new Date(new Date().setDate(new Date().getDate() - 30)).toISOString()
            const retentionDateFrom = new Date(new Date().setDate(new Date().getDate() - 90)).toISOString()

            const [kpiOverview, retentionData, weeklyUsage] = await Promise.all([
                fetchKpiOverview(dateFrom, dateTo, 'day'),
                fetchRetention(retentionDateFrom, dateTo, 'week'),
                fetchWeeklyUsageDistribution(dateFrom, dateTo)
            ])

            setData({ kpiOverview, retentionData, weeklyUsage })
        } catch (err) {
            console.error("Error loading admin analytics:", err)
            const message = err instanceof Error ? err.message : "Error al cargar las métricas. Por favor verifica que las funciones RPC existan en la base de datos."
            setError(message)
        } finally {
            setLoading(false)
        }
    }

    useEffect(() => {
        loadData()
    }, [])

    if (unauthorized) return (
        <div className="flex flex-col items-center justify-center gap-4 py-20">
            <p className="text-slate-400">Acceso restringido a administradores.</p>
            <Link href="/dashboard" className="text-emerald-500 underline">Volver al dashboard</Link>
        </div>
    )

    if (loading) return (
        <div className="flex flex-col items-center justify-center py-32 gap-4">
            <div className="h-8 w-8 animate-spin rounded-full border-2 border-emerald-500 border-t-transparent" />
            <p className="text-slate-400 text-sm animate-pulse">Cargando métricas técnicas...</p>
        </div>
    )

    if (error || !data) return (
        <div className="flex flex-col items-center justify-center py-32 gap-6 container max-w-md text-center">
            <div className="p-4 bg-red-500/10 border border-red-500/20 rounded-full">
                <Activity className="w-8 h-8 text-red-500" />
            </div>
            <div className="space-y-2">
                <h3 className="text-xl font-bold text-slate-100">Error de Carga</h3>
                <p className="text-slate-400 text-sm">{error || "No se pudieron obtener los datos de analíticas."}</p>
            </div>
            <button
                onClick={loadData}
                className="px-6 py-2 bg-slate-800 hover:bg-slate-700 text-slate-100 rounded-lg border border-slate-700 transition-colors"
            >
                Reintentar
            </button>
        </div>
    )

    const { kpiOverview, retentionData, weeklyUsage } = data
    const timeSeries = kpiOverview.time_series ?? []
    const insightsBreakdown = kpiOverview.insights_breakdown ?? []
    const communityActivity = kpiOverview.community_engagement ?? []

    // D1: los KPI de cabecera se leen tal cual de `summary` — sin reduce ni
    // aritmética de fechas del lado del cliente (frontend/lib/adminAnalytics.ts).
    const header = mapKpiHeaderMetrics(kpiOverview)
    const latestMatureCohort = selectLatestMatureCohort(retentionData)
    const showCoverageWarning = shouldShowDataCoverageWarning(kpiOverview.summary.data_coverage)
    const staleDays = kpiOverview.summary.data_coverage.operation_events_stale_days

    return (
        <div className="container mx-auto p-6 max-w-7xl animate-in fade-in duration-700">
            <header className="flex flex-col gap-4 mb-10">
                <div className="flex items-center justify-between">
                    <div>
                        <h1 className="text-3xl font-bold text-slate-100 tracking-tight">Admin Analytics</h1>
                        <p className="text-slate-400 mt-1">Monitoreo de métricas MVP y tracción de usuarios.</p>
                    </div>
                    <div className="flex space-x-2">
                        <span className="px-3 py-1 bg-emerald-500/10 text-emerald-500 rounded-full text-xs font-semibold border border-emerald-500/20 flex items-center">
                            <Activity className="w-3 h-3 mr-1.5" /> Directo
                        </span>
                    </div>
                </div>
                {showCoverageWarning && (
                    <div className="flex items-start gap-3 rounded-xl border border-amber-500/30 bg-amber-500/10 px-4 py-3">
                        <AlertTriangle className="w-5 h-5 text-amber-500 shrink-0 mt-0.5" />
                        <p className="text-sm text-amber-200">
                            La telemetría de operación no se actualiza hace {staleDays ?? '—'} días. Las métricas de activación, UMV y retención de este período pueden reflejar un hueco de medición, no una caída real del negocio.
                        </p>
                    </div>
                )}
            </header>

            <section className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 xl:grid-cols-6 gap-6 mb-12">
                <KpiCard title="% UMV" value={`${header.umvRate}%`} badge="Umv/Act" icon={Zap} iconColor="text-yellow-500" />
                <KpiCard title="Activaciones" value={header.totalActivations} badge="30d" icon={Users} />
                <KpiCard title="Retención" value={latestMatureCohort ? `${latestMatureCohort.retention_rate}%` : '0%'} badge={latestMatureCohort ? `Últ. (${latestMatureCohort.observation_window_days}d)` : 'Última'} icon={Activity} iconColor="text-emerald-500" />
                <KpiCard title="Frecuencia Semanal" value={`${header.avgActiveDaysPerUserWeek}`} badge="días/sem" icon={Calendar} iconColor="text-blue-500" />
                <KpiCard title="Insights Generados" value={header.totalInsights} badge="30d" icon={Sparkles} iconColor="text-amber-500" />
                <KpiCard title="Usuarios Comunidad" value={header.communityActiveUsers} badge="Personas" icon={Users} iconColor="text-purple-500" />
            </section>

            <section className="mb-12 bg-slate-900/40 backdrop-blur-md p-8 rounded-2xl shadow-xl border border-slate-800">
                <div className="flex items-center space-x-2 mb-6 text-slate-100">
                    <TrendingUp className="w-5 h-5 text-emerald-500" />
                    <h2 className="text-xl font-bold">Activations &amp; UMV Series</h2>
                </div>
                <TimeSeriesLinesChart data={timeSeries} width={1000} height={350} />
            </section>

            <section className="mb-12 bg-slate-900/40 backdrop-blur-md p-8 rounded-2xl shadow-xl border border-slate-800">
                <div className="flex items-center space-x-2 mb-6 text-slate-100">
                    <Users className="w-5 h-5 text-blue-500" />
                    <h2 className="text-xl font-bold">30-Day Cohort Retention</h2>
                </div>
                <CohortRetentionChart data={retentionData} width={1000} height={350} />
            </section>

            <div className="grid grid-cols-1 lg:grid-cols-2 gap-12 mb-12">
                <section className="bg-slate-900/40 backdrop-blur-md p-8 rounded-2xl shadow-xl border border-slate-800">
                    <div className="flex items-center space-x-2 mb-6 text-slate-100">
                        <MousePointerClick className="w-5 h-5 text-purple-500" />
                        <h2 className="text-xl font-bold">Weekly Usage Habit</h2>
                    </div>
                    <WeeklyHistogramChart data={weeklyUsage} width={500} height={300} />
                </section>
                <section className="bg-slate-900/40 backdrop-blur-md p-8 rounded-2xl shadow-xl border border-slate-800">
                    <div className="flex items-center space-x-2 mb-6 text-slate-100">
                        <Sparkles className="w-5 h-5 text-amber-500" />
                        <h2 className="text-xl font-bold">Distribución de Consejos AI</h2>
                    </div>
                    <StackedBarsChart
                        data={insightsBreakdown.map((i) => ({ ...i, insight_type: i.insight_type ?? 'uncategorized' }))}
                        width={500}
                        height={300}
                    />
                </section>
            </div>

            <section className="mb-12 bg-slate-900/40 backdrop-blur-md p-8 rounded-2xl shadow-xl border border-slate-800">
                <div className="flex items-center space-x-2 mb-6 text-slate-100">
                    <Users className="w-5 h-5 text-indigo-500" />
                    <h2 className="text-xl font-bold">Comunidad: Posts vs Replies</h2>
                </div>
                <CommunitySeriesChart data={communityActivity} width={1000} height={350} />
            </section>
        </div>
    )
}

interface KpiCardProps {
    title: string
    value: string | number
    badge: string
    icon: LucideIcon
    iconColor?: string
}

function KpiCard({ title, value, badge, icon: Icon, iconColor = "text-slate-400" }: KpiCardProps) {
    return (
        <div className="bg-slate-900/40 backdrop-blur-md p-6 rounded-2xl shadow-xl border border-slate-800 relative overflow-hidden group">
            <div className={`absolute top-0 right-0 p-4 opacity-10 group-hover:opacity-20 transition-opacity ${iconColor}`}>
                <Icon className="w-12 h-12" />
            </div>
            <div className={`flex items-center space-x-2 mb-2 ${iconColor}`}>
                <Icon className="w-4 h-4" />
                <p className="text-xs font-medium uppercase tracking-wider text-slate-500">{title}</p>
            </div>
            <div className="flex items-end justify-between">
                <p className="text-3xl font-bold text-slate-100">{value}</p>
                <span className={`text-[10px] font-bold px-2 py-0.5 rounded uppercase bg-slate-800 text-slate-400 border border-slate-700`}>{badge}</span>
            </div>
        </div>
    )
}
