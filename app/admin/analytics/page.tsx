import React from 'react'
import { redirect } from 'next/navigation'
import { cookies } from 'next/headers'
import { createClient } from '@/lib/supabase/server'
import { getProfile } from '@/lib/supabase/services'
import {
    fetchKpiOverview,
    fetchRetention,
    fetchWeeklyUsageDistribution
} from '@/lib/adminAnalytics'

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

export const dynamic = 'force-dynamic' // Ensure fresh analytics data

export default async function AdminAnalyticsPage() {
    const supabase = createClient()

    // 1. Strict Security Route Protection (is_admin checks)
    const { data: { user } } = await supabase.auth.getUser()
    if (!user) {
        redirect('/auth')
    }

    const profile = await getProfile(user.id)
    if (!profile || profile.role !== 'admin') {
        redirect('/dashboard') // Or throw 403
    }

    // 2. Fetch Data with default ranges (Last 30 days)
    const dateTo = new Date().toISOString()
    const dateFrom = new Date(new Date().setDate(new Date().getDate() - 30)).toISOString()

    // For cohort, we might want last 90 days to see meaningful 30d retention
    const retentionDateFrom = new Date(new Date().setDate(new Date().getDate() - 90)).toISOString()

    const [
        kpiOverview,
        retentionData,
        weeklyUsage
    ] = await Promise.all([
        fetchKpiOverview(dateFrom, dateTo, 'day'),
        fetchRetention(retentionDateFrom, dateTo, 'week'),
        fetchWeeklyUsageDistribution(dateFrom, dateTo)
    ])

    const timeSeries = kpiOverview.time_series || []
    const insightsBreakdown = kpiOverview.insights_breakdown || []
    // const communityEngagement = kpiOverview.community_engagement || []
    const summary = kpiOverview.summary || {}

    // Calculate generic retention metric (last reliable cohort)
    // The last cohort might not have had 30 days yet, so we pick a slightly older one
    const validCohorts = retentionData.filter((c: any) => new Date(c.cohort_start).getTime() < new Date().getTime() - (37 * 24 * 60 * 60 * 1000))
    const latestCohort = validCohorts.length > 0 ? validCohorts[validCohorts.length - 1] : null

    // Calculate average active days
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

            {/* Section 1: Resumen Ejecutivo (Cards) */}
            <section className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6 mb-12">
                <div className="bg-slate-900/40 backdrop-blur-md p-6 rounded-2xl shadow-xl border border-slate-800 relative overflow-hidden group">
                    <div className="absolute top-0 right-0 p-4 opacity-10 group-hover:opacity-20 transition-opacity">
                        <Users className="w-12 h-12" />
                    </div>
                    <div className="flex items-center space-x-2 text-slate-400 mb-2">
                        <Users className="w-4 h-4" />
                        <p className="text-xs font-medium uppercase tracking-wider text-slate-500">Activaciones (30d)</p>
                    </div>
                    <div className="flex items-end justify-between">
                        <p className="text-3xl font-bold text-slate-100">{summary.total_activations_in_range}</p>
                        <span className="flex items-center text-xs text-emerald-500 bg-emerald-500/10 px-1.5 py-0.5 rounded">
                            <TrendingUp className="w-3 h-3 mr-1" /> 12%
                        </span>
                    </div>
                </div>

                <div className="bg-slate-900/40 backdrop-blur-md p-6 rounded-2xl shadow-xl border border-slate-800 relative overflow-hidden group">
                    <div className="absolute top-0 right-0 p-4 opacity-10 group-hover:opacity-20 transition-opacity">
                        <Zap className="w-12 h-12" />
                    </div>
                    <div className="flex items-center space-x-2 text-slate-400 mb-2">
                        <Zap className="w-4 h-4" />
                        <p className="text-xs font-medium uppercase tracking-wider text-slate-500">UMV Reached (30d)</p>
                    </div>
                    <div className="flex items-end justify-between">
                        <p className="text-3xl font-bold text-slate-100">{summary.total_umv_in_range}</p>
                        <span className="flex items-center text-xs text-blue-500 bg-blue-500/10 px-1.5 py-0.5 rounded">
                            <ArrowUpRight className="w-3 h-3 mr-1" /> High
                        </span>
                    </div>
                </div>

                <div className="bg-slate-900/40 backdrop-blur-md p-6 rounded-2xl shadow-xl border border-slate-800 relative overflow-hidden group">
                    <div className="absolute top-0 right-0 p-4 opacity-10 group-hover:opacity-20 transition-opacity text-emerald-500">
                        <Activity className="w-12 h-12" />
                    </div>
                    <div className="flex items-center space-x-2 text-emerald-500 mb-2">
                        <Activity className="w-4 h-4" />
                        <p className="text-xs font-medium uppercase tracking-wider text-emerald-500/70">30d Retention</p>
                    </div>
                    <div className="flex items-end justify-between">
                        <p className="text-3xl font-bold text-slate-100">
                            {latestCohort ? `${latestCohort.retention_rate}%` : 'N/A'}
                        </p>
                        {latestCohort && <p className="text-[10px] text-slate-500 mt-1 truncate max-w-[80px]">Coh: {new Date(latestCohort.cohort_start).toLocaleDateString()}</p>}
                    </div>
                </div>

                <div className="bg-slate-900/40 backdrop-blur-md p-6 rounded-2xl shadow-xl border border-slate-800 relative overflow-hidden group">
                    <div className="absolute top-0 right-0 p-4 opacity-10 group-hover:opacity-20 transition-opacity text-blue-500">
                        <Calendar className="w-12 h-12" />
                    </div>
                    <div className="flex items-center space-x-2 text-blue-500 mb-2">
                        <Calendar className="w-4 h-4" />
                        <p className="text-xs font-medium uppercase tracking-wider text-blue-500/70">Engagement Avg</p>
                    </div>
                    <div className="flex items-end justify-between">
                        <p className="text-3xl font-bold text-slate-100">{avgActiveDays}</p>
                        <p className="text-xs text-slate-500 font-medium tracking-tight">días / semana</p>
                    </div>
                </div>
            </section>

            {/* Section 2: Activación y UMV */}
            <section className="mb-12 bg-slate-900/40 backdrop-blur-md p-8 rounded-2xl shadow-xl border border-slate-800">
                <div className="flex items-center space-x-2 mb-6 text-slate-100">
                    <TrendingUp className="w-5 h-5 text-emerald-500" />
                    <h2 className="text-xl font-bold">Activations & UMV Series</h2>
                </div>
                <div className="w-full">
                    <TimeSeriesLinesChart data={timeSeries} width={1000} height={350} />
                </div>
            </section>

            {/* Section 3: Retención */}
            <section className="mb-12 bg-slate-900/40 backdrop-blur-md p-8 rounded-2xl shadow-xl border border-slate-800">
                <div className="flex items-center space-x-2 mb-6 text-slate-100">
                    <Users className="w-5 h-5 text-blue-500" />
                    <h2 className="text-xl font-bold">30-Day Cohort Retention</h2>
                </div>
                <div className="w-full">
                    <CohortRetentionChart data={retentionData} width={1000} height={350} />
                </div>
            </section>

            <div className="grid grid-cols-1 lg:grid-cols-2 gap-12 mb-12">
                {/* Section 4: Hábito de Uso */}
                <section className="bg-slate-900/40 backdrop-blur-md p-8 rounded-2xl shadow-xl border border-slate-800">
                    <div className="flex items-center space-x-2 mb-6 text-slate-100">
                        <MousePointerClick className="w-5 h-5 text-purple-500" />
                        <h2 className="text-xl font-bold">Weekly Usage Habit</h2>
                    </div>
                    <div className="w-full">
                        <WeeklyHistogramChart data={weeklyUsage} width={500} height={300} />
                    </div>
                </section>

                {/* Section 5: Uso IA */}
                <section className="bg-slate-900/40 backdrop-blur-md p-8 rounded-2xl shadow-xl border border-slate-800">
                    <div className="flex items-center space-x-2 mb-6 text-slate-100">
                        <Sparkles className="w-5 h-5 text-amber-500" />
                        <h2 className="text-xl font-bold">Distribución de Consejos AI</h2>
                    </div>
                    <div className="w-full">
                        <StackedBarsChart data={insightsBreakdown} width={500} height={300} />
                    </div>
                </section>
            </div>

        </div>
    )
}
