"use client"

import React, { useEffect, useState } from 'react'
import { fetchModuleStats } from '@/lib/adminAnalytics'
import { ModuleAnalytics } from '@/components/admin/ModuleAnalytics'
import { Skeleton } from '@/components/ui/skeleton'
import { AlertCircle } from 'lucide-react'
import { Alert, AlertDescription, AlertTitle } from '@/components/ui/alert'

interface ModuleMetricsWrapperProps {
    moduleType: 'ventas' | 'compras' | 'stock' | 'clientes' | 'gastos'
    title: string
    subtitle: string
}

export function ModuleMetricsWrapper({ moduleType, title, subtitle }: ModuleMetricsWrapperProps) {
    const [stats, setStats] = useState<any>(null)
    const [loading, setLoading] = useState(true)
    const [error, setError] = useState<string | null>(null)

    useEffect(() => {
        async function loadStats() {
            try {
                setLoading(true)
                const dateTo = new Date().toISOString()
                const dateFrom = new Date(new Date().setDate(new Date().getDate() - 30)).toISOString()
                const data = await fetchModuleStats(moduleType, dateFrom, dateTo)
                setStats(data)
                setError(null)
            } catch (err) {
                console.error(`Error loading metrics for ${moduleType}:`, err)
                setError("No se pudieron cargar las métricas.")
            } finally {
                setLoading(false)
            }
        }

        loadStats()
    }, [moduleType])

    if (loading) {
        return (
            <div className="grid grid-cols-1 md:grid-cols-3 gap-6 mb-8">
                {[1, 2, 3].map((i) => (
                    <Skeleton key={i} className="h-32 w-full bg-slate-900/40 rounded-2xl border border-slate-800" />
                ))}
            </div>
        )
    }

    if (error) {
        return (
            <Alert variant="destructive" className="mb-8 bg-red-500/10 border-red-500/20 text-red-400">
                <AlertCircle className="h-4 w-4" />
                <AlertTitle>Error</AlertTitle>
                <AlertDescription>{error}</AlertDescription>
            </Alert>
        )
    }

    if (!stats) return null

    return (
        <div className="mb-8">
            <ModuleAnalytics
                title={title}
                subtitle={subtitle}
                stats={stats}
                moduleType={moduleType}
            />
        </div>
    )
}
