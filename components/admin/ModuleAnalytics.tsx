"use client"

import React from 'react'
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import {
    TrendingUp,
    TrendingDown,
    DollarSign,
    Package,
    Users,
    ShoppingBag,
    ArrowRight
} from "lucide-react"
import { formatMoney } from "@/lib/format"
import ModuleSeriesChart from "./charts/ModuleSeriesChart"

interface ModuleAnalyticsProps {
    title: string
    subtitle: string
    stats: {
        summary: {
            users_count?: number
            count?: number
            avg_per_user?: number
        }
        time_series: any[]
    }
    moduleType: 'ventas' | 'compras' | 'stock' | 'clientes' | 'gastos'
}

export function ModuleAnalytics({ title, subtitle, stats, moduleType }: ModuleAnalyticsProps) {
    const { summary, time_series } = stats

    const renderKPIs = () => {
        switch (moduleType) {
            case 'ventas':
            case 'compras':
            case 'gastos':
            case 'stock':
            case 'clientes':
                return (
                    <>
                        <KpiCard
                            title="Usuarios Interactuando"
                            value={summary.users_count || 0}
                            icon={Users}
                            color="text-emerald-500"
                        />
                        <KpiCard
                            title="Operaciones Registradas"
                            value={summary.count || 0}
                            icon={ActivityIcon}
                            color="text-blue-500"
                        />
                        <KpiCard
                            title="Promedio x Usuario"
                            value={summary.avg_per_user || 0}
                            icon={TrendingUp}
                            color="text-purple-500"
                        />
                    </>
                )
        }
    }

    return (
        <div className="flex flex-col gap-8 animate-in fade-in slide-in-from-bottom-4 duration-700">
            <div className="flex justify-between items-end">
                <div>
                    <h2 className="text-2xl font-bold text-slate-100 tracking-tight">{title}</h2>
                    <p className="text-sm text-slate-400 mt-1">{subtitle}</p>
                </div>
            </div>

            <div className="grid grid-cols-1 md:grid-cols-3 gap-6">
                {renderKPIs()}
            </div>

            {time_series && time_series.length > 0 && (
                <Card className="bg-slate-900/40 border-slate-800 backdrop-blur-md">
                    <CardHeader>
                        <CardTitle className="text-lg font-semibold text-slate-100 flex items-center gap-2">
                            <TrendingUp className="w-5 h-5 text-emerald-500" />
                            Evolución Temporal
                        </CardTitle>
                    </CardHeader>
                    <CardContent>
                        <div className="h-[350px] w-full">
                            <ModuleSeriesChart data={time_series} width={800} height={350} />
                        </div>
                    </CardContent>
                </Card>
            )}
        </div>
    )
}

function KpiCard({ title, value, icon: Icon, color }: any) {
    return (
        <Card className="bg-slate-900/40 border-slate-800 backdrop-blur-md overflow-hidden relative group">
            <CardHeader className="pb-2">
                <CardTitle className="text-xs font-medium uppercase tracking-wider text-slate-500 flex items-center gap-2">
                    <Icon className={`w-4 h-4 ${color}`} />
                    {title}
                </CardTitle>
            </CardHeader>
            <CardContent>
                <p className="text-3xl font-bold text-slate-100">{value}</p>
            </CardContent>
            <div className={`absolute -right-4 -bottom-4 opacity-5 group-hover:opacity-10 transition-opacity ${color}`}>
                <Icon className="w-24 h-24" />
            </div>
        </Card>
    )
}

function ActivityIcon({ className }: { className?: string }) {
    return (
        <svg
            xmlns="http://www.w3.org/2000/svg"
            width="24"
            height="24"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            strokeWidth="2"
            strokeLinecap="round"
            strokeLinejoin="round"
            className={className}
        >
            <path d="M22 12h-4l-3 9L9 3l-3 9H2" />
        </svg>
    )
}
