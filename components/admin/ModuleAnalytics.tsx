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
import TimeSeriesLinesChart from "./charts/TimeSeriesLinesChart"

interface ModuleAnalyticsProps {
    title: string
    subtitle: string
    stats: {
        summary: {
            total_amount?: number
            count?: number
            avg_ticket?: number
            total_items?: number
            low_stock_count?: number
            total_inventory_value?: number
            total_count?: number
            active_count?: number
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
                return (
                    <>
                        <KpiCard
                            title="Total Acumulado"
                            value={formatMoney(summary.total_amount || 0)}
                            icon={DollarSign}
                            color="text-emerald-500"
                        />
                        <KpiCard
                            title="Transacciones"
                            value={summary.count || 0}
                            icon={ShoppingBag}
                            color="text-blue-500"
                        />
                        <KpiCard
                            title="Ticket Promedio"
                            value={formatMoney(summary.avg_ticket || 0)}
                            icon={TrendingUp}
                            color="text-purple-500"
                        />
                    </>
                )
            case 'stock':
                return (
                    <>
                        <KpiCard
                            title="Items en Stock"
                            value={summary.total_items || 0}
                            icon={Package}
                            color="text-amber-500"
                        />
                        <KpiCard
                            title="Alertas Stock Bajo"
                            value={summary.low_stock_count || 0}
                            icon={TrendingDown}
                            color="text-red-500"
                        />
                        <KpiCard
                            title="Valor Inventario"
                            value={formatMoney(summary.total_inventory_value || 0)}
                            icon={DollarSign}
                            color="text-emerald-500"
                        />
                    </>
                )
            case 'clientes':
                return (
                    <>
                        <KpiCard
                            title="Total Clientes"
                            value={summary.total_count || 0}
                            icon={Users}
                            color="text-emerald-500"
                        />
                        <KpiCard
                            title="Clientes Activos"
                            value={summary.active_count || 0}
                            icon={ActivityIcon}
                            color="text-blue-500"
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
                            <TimeSeriesLinesChart data={time_series} width={800} height={350} />
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
