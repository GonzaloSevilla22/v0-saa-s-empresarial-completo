import React from 'react'
import { redirect } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getProfile } from '@/lib/supabase/services'
import {
    fetchKpiOverview,
    fetchRetention,
    fetchWeeklyUsageDistribution
} from '@/lib/adminAnalytics'

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
        <div className="container mx-auto p-6 max-w-7xl">
            <h1 className="text-3xl font-bold mb-8 text-slate-800">Admin Analytics Dashboard</h1>

            {/* Section 1: Resumen Ejecutivo (Cards) */}
            <section className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6 mb-12">
                <div className="bg-white p-6 rounded-xl shadow-sm border border-slate-100">
                    <p className="text-sm font-medium text-slate-500 mb-1">Total Activations (30d)</p>
                    <p className="text-3xl font-bold text-slate-800">{summary.total_activations_in_range}</p>
                </div>
                <div className="bg-white p-6 rounded-xl shadow-sm border border-slate-100">
                    <p className="text-sm font-medium text-slate-500 mb-1">Total UMV Reached (30d)</p>
                    <p className="text-3xl font-bold text-slate-800">{summary.total_umv_in_range}</p>
                </div>
                <div className="bg-white p-6 rounded-xl shadow-sm border border-slate-100">
                    <p className="text-sm font-medium text-emerald-600 mb-1">30d Retention Rate</p>
                    <p className="text-3xl font-bold text-emerald-700">
                        {latestCohort ? `${latestCohort.retention_rate}%` : 'N/A'}
                    </p>
                    {latestCohort && <p className="text-xs text-slate-400 mt-1">Cohort: {new Date(latestCohort.cohort_start).toLocaleDateString()}</p>}
                </div>
                <div className="bg-white p-6 rounded-xl shadow-sm border border-slate-100">
                    <p className="text-sm font-medium text-blue-600 mb-1">Avg Active Days/Week</p>
                    <p className="text-3xl font-bold text-blue-700">{avgActiveDays}</p>
                </div>
            </section>

            {/* Section 2: Activación y UMV */}
            <section className="mb-12 bg-white p-6 rounded-xl shadow-sm border border-slate-100">
                <h2 className="text-xl font-bold mb-4 text-slate-700">Activations & UMV Series</h2>
                <div className="w-full">
                    <TimeSeriesLinesChart data={timeSeries} width={1000} height={350} />
                </div>
            </section>

            {/* Section 3: Retención */}
            <section className="mb-12 bg-white p-6 rounded-xl shadow-sm border border-slate-100">
                <h2 className="text-xl font-bold mb-4 text-slate-700">30-Day Cohort Retention</h2>
                <div className="w-full">
                    <CohortRetentionChart data={retentionData} width={1000} height={350} />
                </div>
            </section>

            <div className="grid grid-cols-1 lg:grid-cols-2 gap-12 mb-12">
                {/* Section 4: Hábito de Uso */}
                <section className="bg-white p-6 rounded-xl shadow-sm border border-slate-100">
                    <h2 className="text-xl font-bold mb-4 text-slate-700">Weekly Usage Habit</h2>
                    <div className="w-full">
                        <WeeklyHistogramChart data={weeklyUsage} width={500} height={300} />
                    </div>
                </section>

                {/* Section 5: Uso IA */}
                <section className="bg-white p-6 rounded-xl shadow-sm border border-slate-100">
                    <h2 className="text-xl font-bold mb-4 text-slate-700">AI Generation Distribution</h2>
                    <div className="w-full">
                        <StackedBarsChart data={insightsBreakdown} width={500} height={300} />
                    </div>
                </section>
            </div>

        </div>
    )
}
