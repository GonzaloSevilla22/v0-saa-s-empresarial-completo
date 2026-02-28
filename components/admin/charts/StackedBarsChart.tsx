"use client"

import React, { useEffect, useRef } from 'react'
import * as d3 from 'd3'
import { chartGradients } from '@/lib/chart-utils'

interface StackedBarsChartProps {
    data: { period: string; insight_type: string; count: number }[]
    width?: number
    height?: number
}

export default function StackedBarsChart({ data, width = 600, height = 300 }: StackedBarsChartProps) {
    const svgRef = useRef<SVGSVGElement>(null)

    useEffect(() => {
        if (!data || data.length === 0 || !svgRef.current) return

        const svg = d3.select(svgRef.current)
        svg.selectAll("*").remove()

        svg.append("g").html(chartGradients)

        const margin = { top: 20, right: 30, bottom: 40, left: 40 }
        const innerWidth = width - margin.left - margin.right
        const innerHeight = height - margin.top - margin.bottom

        // Pivot data: { period, general: X, prediction: Y, simulation: Z }
        const periods = Array.from(new Set(data.map(d => new Date(d.period).toLocaleDateString(undefined, { month: 'short', day: 'numeric' }))))
        const types = Array.from(new Set(data.map(d => d.insight_type)))

        const pivotedData = periods.map(periodObj => {
            const obj: any = { period: periodObj }
            types.forEach(t => { obj[t] = 0 })

            const related = data.filter(d => new Date(d.period).toLocaleDateString(undefined, { month: 'short', day: 'numeric' }) === periodObj)
            related.forEach(r => {
                obj[r.insight_type] = Number(r.count)
            })
            return obj
        })

        const stack = d3.stack().keys(types)(pivotedData as Iterable<{ [key: string]: number }>)

        const x = d3.scaleBand()
            .domain(periods)
            .range([0, innerWidth])
            .padding(0.2)

        const y = d3.scaleLinear()
            .domain([0, d3.max(stack, d => d3.max(d, d => d[1])) || 0])
            .range([innerHeight, 0])

        const color = d3.scaleOrdinal()
            .domain(types)
            .range(["#f59e0b", "#8b5cf6", "#ec4899", "#3b82f6", "#10b981"])

        const g = svg.append("g")
            .attr("transform", `translate(${margin.left},${margin.top})`)

        // X Axis
        g.append("g")
            .attr("transform", `translate(0,${innerHeight})`)
            .call(d3.axisBottom(x))
            .selectAll("text")
            .attr("transform", "rotate(-45)")
            .style("text-anchor", "end")
            .attr("color", "#6b7280")

        // Y Axis
        g.append("g")
            .call(d3.axisLeft(y).ticks(5))
            .attr("color", "#6b7280")

        const tooltip = d3.select("body").append("div")
            .attr("class", "d3-tooltip absolute p-2 bg-white rounded shadow text-xs border hidden z-50 pointer-events-none")

        // Bars
        g.append("g")
            .selectAll("g")
            .data(stack)
            .enter().append("g")
            .attr("fill", d => color(d.key) as string)
            .selectAll("rect")
            .data(d => d.map(item => { return { ...item, key: d.key }; }))
            .enter().append("rect")
            .attr("x", d => x((d.data.period as unknown) as string) || 0)
            .attr("y", d => y(d[1]))
            .attr("height", d => y(d[0]) - y(d[1]))
            .attr("width", x.bandwidth())
            .attr("rx", 2)
            .on("mouseover", (event, d) => {
                tooltip.style("display", "block").html(`<strong>Type:</strong> ${d.key}<br/><strong>Count:</strong> ${d[1] - d[0]}`)
                d3.select(event.currentTarget).attr("stroke", "black").attr("stroke-width", 1)
            })
            .on("mousemove", (event) => tooltip.style("left", (event.pageX + 10) + "px").style("top", (event.pageY - 20) + "px"))
            .on("mouseout", (event) => {
                tooltip.style("display", "none")
                d3.select(event.currentTarget).attr("stroke", "none")
            })

        return () => {
            d3.selectAll('.d3-tooltip').remove()
        }
    }, [data, width, height])

    return (
        <div className="w-full overflow-x-auto">
            <svg ref={svgRef} width={width} height={height} viewBox={`0 0 ${width} ${height}`} className="mx-auto" />
        </div>
    )
}
