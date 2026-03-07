"use client"

import { useEffect, useState } from 'react'
import { createClient } from '@/lib/supabase/client'
import Link from 'next/link'
import {
    Activity,
    ArrowUpRight,
    Zap,
    Calendar,
    TrendingUp,
    Users,
    Sparkles,
    MousePointerClick
} from 'lucide-react'
import TimeSeriesLinesChart from '@/components/admin/charts/TimeSeriesLinesChart'
import CohortRetentionChart from '@/components/admin/charts/CohortRetentionChart'
import WeeklyHistogramChart from '@/components/admin/charts/WeeklyHistogramChart'
import StackedBarsChart from '@/components/admin/charts/StackedBarsChart'
import CommunitySeriesChart from '@/components/admin/charts/CommunitySeriesChart'
import {
    fetchKpiOverview,
    fetchRetention,
    fetchWeeklyUsageDistribution
} from '@/lib/adminAnalytics'

export default function AdminAnalyticsPage() {
    const [data, setData] = useState<any>(null)
    const [loading, setLoading] = useState(true)
    const [unauthorized, setUnauthorized] = useState(false)

    useEffect(() => {
        async function load() {
            const supabase = createClient()
            const { data: { user } } = await supabase.auth.getUser()
            if (!user) { window.location.href = '/auth'; return }

            const { data: profile } = await supabase.from('profiles').select('role').eq('id', user.id).single()
            if (!profile || profile.role !== 'admin') { setUnauthorized(true); return }

            const dateTo = new Date().toISOString()
            const dateFrom = new Date(new Date().setDate(new Date().getDate() - 30)).toISOString()
            const retentionDateFrom = new Date(new Date().setDate(new Date().getDate() - 90)).toISOString()

            const [kpiOverview, retentionData, weeklyUsage] = await Promise.all([
                fetchKpiOverview(dateFrom, dateTo, 'day'),
                fetchRetention(retentionDateFrom, dateTo, 'week'),
                fetchWeeklyUsageDistribution(dateFrom, dateTo)
            ])

            setData({ kpiOverview, retentionData, weeklyUsage })
            setLoading(false)
        }
        load().catch(() => setLoading(false))
    }, [])

    if (unauthorized) return (
        <div className="flex flex-col items-center justify-center gap-4 py-20">
            <p className="text-slate-400">Acceso restringido a administradores.</p>
            <Link href="/dashboard" className="text-emerald-500 underline">Volver al dashboard</Link>
        </div>
    )

    if (loading || !data) return (
        <div className="flex items-center justify-center py-20">
            <div className="h-8 w-8 animate-spin rounded-full border-2 border-emerald-500 border-t-transparent" />
        </div>
    )

    const { kpiOverview, retentionData, weeklyUsage } = data
    const timeSeries = kpiOverview.time_series || []
    const insightsBreakdown = kpiOverview.insights_breakdown || []
    const summary = kpiOverview.summary || {}

    const totalActivations = summary.total_activations_in_range || 0
    const totalUmv = summary.total_umv_in_range || 0
    const umvPercentage = totalActivations > 0 ? Math.round((totalUmv / totalActivations) * 100) : 0

    // Insights & Community
    const totalInsights = insightsBreakdown.reduce((acc: any, curr: any) => acc + curr.count, 0)
    const communityActivity = kpiOverview.community_engagement || []
    const totalCommunityUsers = communityActivity.reduce((acc: any, curr: any) => acc + curr.active_users, 0)

    const validCohorts = retentionData.filter((c: any) => new Date(c.cohort_start).getTime() < new Date().getTime() - (37 * 24 * 60 * 60 * 1000))
    const latestCohort = validCohorts.length > 0 ? validCohorts[validCohorts.length - 1] : null
    const validWeeks = weeklyUsage.reduce((acc: any, curr: any) => acc + curr.users_count, 0)
    const totalActiveDays = weeklyUsage.reduce((acc: any, curr: any) => acc + (curr.active_days * curr.users_count), 0)
    const avgActiveDays = validWeeks > 0 ? (totalActiveDays / validWeeks).toFixed(1) : 0

    return (
        <div className="container mx-auto p-6 max-w-7xl animate-in fade-in duration-700">
            <header className="flex items-center justify-between mb-10">
                <div>
                    <h1 className="text-3xl font-bold text-slate-100 tracking-tight">Admin Analytics</h1>
                    <p className="text-slate-400 mt-1">Monitoreo de métricas MVP y tracción de usuarios.</p>
                </div>
                <div className="flex space-x-2">
                    <span className="px-3 py-1 bg-emerald-500/10 text-emerald-500 rounded-full text-xs font-semibold border border-emerald-500/20 flex items-center">
                        <Activity className="w-3 h-3 mr-1.5" /> Directo
                    </span>
                </div>
            </header>

            <section className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 xl:grid-cols-6 gap-6 mb-12">
                <KpiCard title="% UMV" value={`${umvPercentage}%`} badge="Umv/Act" icon={Zap} iconColor="text-yellow-500" />
                <KpiCard title="Activaciones" value={totalActivations} badge="30d" icon={Users} />
                <KpiCard title="Retención 30d" value={latestCohort ? `${latestCohort.retention_rate}%` : '0%'} badge="Última" icon={Activity} iconColor="text-emerald-500" />
                <KpiCard title="Frecuencia Semanal" value={`${avgActiveDays}`} badge="días/sem" icon={Calendar} iconColor="text-blue-500" />
                <KpiCard title="Insights Generados" value={totalInsights} badge="30d" icon={Sparkles} iconColor="text-amber-500" />
                <KpiCard title="Usuarios Comunidad" value={totalCommunityUsers} badge="Activos" icon={Users} iconColor="text-purple-500" />
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
                    <StackedBarsChart data={insightsBreakdown} width={500} height={300} />
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

function KpiCard({ title, value, badge, icon: Icon, iconColor = "text-slate-400" }: any) {
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
