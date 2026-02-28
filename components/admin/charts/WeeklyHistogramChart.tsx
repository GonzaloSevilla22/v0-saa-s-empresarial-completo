"use client"

import React, { useEffect, useRef } from 'react'
import * as d3 from 'd3'

interface WeeklyHistogramChartProps {
    data: { active_days: number; users_count: number }[]
    width?: number
    height?: number
}

export default function WeeklyHistogramChart({ data, width = 600, height = 300 }: WeeklyHistogramChartProps) {
    const svgRef = useRef<SVGSVGElement>(null)

    useEffect(() => {
        if (!data || data.length === 0 || !svgRef.current) return

        const svg = d3.select(svgRef.current)
        svg.selectAll("*").remove()

        const margin = { top: 20, right: 30, bottom: 40, left: 50 }
        const innerWidth = width - margin.left - margin.right
        const innerHeight = height - margin.top - margin.bottom

        // Ensure we have buckets for 0 to 7 days
        const allDays = Array.from({ length: 8 }, (_, i) => i)
        const parsedData = allDays.map(day => {
            const match = data.find(d => d.active_days === day)
            return { active_days: day, users_count: match ? Number(match.users_count) : 0 }
        })

        const x = d3.scaleBand()
            .domain(parsedData.map(d => d.active_days.toString()))
            .range([0, innerWidth])
            .padding(0.1)

        const maxCount = d3.max(parsedData, d => d.users_count) || 0

        const y = d3.scaleLinear()
            .domain([0, maxCount * 1.2])
            .range([innerHeight, 0])

        const g = svg.append("g")
            .attr("transform", `translate(${margin.left},${margin.top})`)

        // X Axis
        g.append("g")
            .attr("transform", `translate(0,${innerHeight})`)
            .call(d3.axisBottom(x))
            .attr("color", "#6b7280")
        g.append("text")
            .attr("x", innerWidth / 2)
            .attr("y", innerHeight + margin.bottom - 5)
            .attr("text-anchor", "middle")
            .text("Días activos a la semana")
            .attr("fill", "#6b7280")
            .attr("font-size", "12px")

        // Y Axis
        g.append("g")
            .call(d3.axisLeft(y).ticks(5))
            .attr("color", "#6b7280")

        // Tooltip
        const tooltip = d3.select("body").append("div")
            .attr("class", "d3-tooltip absolute p-2 bg-white rounded shadow text-xs border hidden z-50 pointer-events-none")

        // Bars
        g.selectAll(".bar")
            .data(parsedData)
            .enter().append("rect")
            .attr("class", "bar")
            .attr("x", d => x(d.active_days.toString()) || 0)
            .attr("y", d => y(d.users_count))
            .attr("width", x.bandwidth())
            .attr("height", d => innerHeight - y(d.users_count))
            .attr("fill", "#8b5cf6") // violet-500
            .on("mouseover", (event, d) => {
                tooltip.style("display", "block").html(`<strong>Activos ${d.active_days} días:</strong> ${d.users_count} usuarios`)
                d3.select(event.currentTarget).attr("opacity", 0.8)
            })
            .on("mousemove", (event) => tooltip.style("left", (event.pageX + 10) + "px").style("top", (event.pageY - 20) + "px"))
            .on("mouseout", (event) => {
                tooltip.style("display", "none")
                d3.select(event.currentTarget).attr("opacity", 1)
            })

        // Labels
        g.selectAll(".label")
            .data(parsedData.filter(d => d.users_count > 0))
            .enter().append("text")
            .attr("x", d => (x(d.active_days.toString()) || 0) + x.bandwidth() / 2)
            .attr("y", d => y(d.users_count) - 5)
            .attr("text-anchor", "middle")
            .text(d => d.users_count)
            .attr("font-size", "10px")
            .attr("fill", "#374151")

        return () => d3.selectAll('.d3-tooltip').remove()
    }, [data, width, height])

    return (
        <div className="w-full overflow-x-auto">
            <svg ref={svgRef} width={width} height={height} viewBox={`0 0 ${width} ${height}`} className="mx-auto" />
        </div>
    )
}
