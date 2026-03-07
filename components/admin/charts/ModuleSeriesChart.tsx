"use client"

import React, { useEffect, useRef } from 'react'
import * as d3 from 'd3'
import { chartGradients } from '@/lib/chart-utils'

interface ModuleSeriesChartProps {
    data: { period: string; users_count: number; count: number }[]
    width?: number
    height?: number
}

export default function ModuleSeriesChart({ data, width = 600, height = 300 }: ModuleSeriesChartProps) {
    const svgRef = useRef<SVGSVGElement>(null)

    useEffect(() => {
        if (!data || data.length === 0 || !svgRef.current) return

        const svg = d3.select(svgRef.current)
        svg.selectAll("*").remove()

        svg.append("g").html(chartGradients)

        const margin = { top: 20, right: 30, bottom: 30, left: 40 }
        const innerWidth = width - margin.left - margin.right
        const innerHeight = height - margin.top - margin.bottom

        const parseDate = d3.timeParse("%Y-%m-%dT%H:%M:%S%Z") || d3.timeParse("%Y-%m-%d")

        const parsedData = data.map((d: any) => {
            let parsed = parseDate(d.period)
            if (!parsed) parsed = new Date(d.period)
            return {
                ...d,
                date: parsed
            }
        }).sort((a, b) => a.date.getTime() - b.date.getTime())

        const x = d3.scaleTime()
            .domain(d3.extent(parsedData, d => d.date) as [Date, Date])
            .range([0, innerWidth])

        const maxVal = d3.max(parsedData, d => Math.max(d.users_count || 0, d.count || 0)) || 5

        const y = d3.scaleLinear()
            .domain([0, maxVal * 1.2])
            .range([innerHeight, 0])

        const g = svg.append("g")
            .attr("transform", `translate(${margin.left},${margin.top})`)

        // X Axis
        g.append("g")
            .attr("transform", `translate(0,${innerHeight})`)
            .call(d3.axisBottom(x).ticks(5).tickFormat(d3.timeFormat("%d %b") as any))
            .attr("color", "#6b7280")

        // Y Axis
        g.append("g")
            .call(d3.axisLeft(y).ticks(5))
            .attr("color", "#6b7280")

        // Draw Lines
        const lineUsers = d3.line<typeof parsedData[0]>()
            .x(d => x(d.date))
            .y(d => y(d.users_count || 0))
            .curve(d3.curveMonotoneX)

        g.append("path")
            .datum(parsedData)
            .attr("fill", "none")
            .attr("stroke", "#10b981") // emerald-500
            .attr("stroke-width", 3)
            .attr("stroke-linecap", "round")
            .attr("d", lineUsers)

        const lineCount = d3.line<typeof parsedData[0]>()
            .x(d => x(d.date))
            .y(d => y(d.count || 0))
            .curve(d3.curveMonotoneX)

        g.append("path")
            .datum(parsedData)
            .attr("fill", "none")
            .attr("stroke", "#3b82f6") // blue-500
            .attr("stroke-width", 3)
            .attr("stroke-linecap", "round")
            .attr("d", lineCount)

        // Tooltip logic
        const tooltip = d3.select("body").append("div")
            .attr("class", "d3-tooltip absolute p-2 bg-slate-800 text-slate-200 rounded shadow-xl text-xs border border-slate-700 hidden z-50 pointer-events-none")

        const dots = g.selectAll(".dot-group")
            .data(parsedData)
            .enter().append("g")
            .attr("class", "dot-group")

        dots.append("circle")
            .attr("cx", d => x(d.date))
            .attr("cy", d => y(d.users_count || 0))
            .attr("r", 4)
            .attr("fill", "#10b981")
            .on("mouseover", (event, d) => {
                tooltip.style("display", "block").html(`<div class="font-bold border-b border-slate-700 pb-1 mb-1">${d3.timeFormat("%d %b")(d.date)}</div><div class="flex items-center text-emerald-500"><span class="w-2 h-2 mr-1 rounded-full bg-emerald-500"></span>Usuarios Únicos: ${d.users_count || 0}</div>`)
                d3.select(event.currentTarget).attr("r", 6)
            })
            .on("mousemove", (event) => tooltip.style("left", (event.pageX + 10) + "px").style("top", (event.pageY - 20) + "px"))
            .on("mouseout", (event) => {
                tooltip.style("display", "none")
                d3.select(event.currentTarget).attr("r", 4)
            })

        dots.append("circle")
            .attr("cx", d => x(d.date))
            .attr("cy", d => y(d.count || 0))
            .attr("r", 4)
            .attr("fill", "#3b82f6")
            .on("mouseover", (event, d) => {
                tooltip.style("display", "block").html(`<div class="font-bold border-b border-slate-700 pb-1 mb-1">${d3.timeFormat("%d %b")(d.date)}</div><div class="flex items-center text-blue-500"><span class="w-2 h-2 mr-1 rounded-full bg-blue-500"></span>Operaciones: ${d.count || 0}</div>`)
                d3.select(event.currentTarget).attr("r", 6)
            })
            .on("mousemove", (event) => tooltip.style("left", (event.pageX + 10) + "px").style("top", (event.pageY - 20) + "px"))
            .on("mouseout", (event) => {
                tooltip.style("display", "none")
                d3.select(event.currentTarget).attr("r", 4)
            })

        return () => {
            d3.selectAll('.d3-tooltip').remove()
        }
    }, [data, width, height])

    return (
        <div className="w-full overflow-x-auto flex justify-center">
            <svg ref={svgRef} width={width} height={height} viewBox={`0 0 ${width} ${height}`} className="max-w-full" />
        </div>
    )
}
