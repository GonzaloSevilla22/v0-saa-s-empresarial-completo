"use client"

import React, { useEffect, useRef } from 'react'
import * as d3 from 'd3'

interface CohortRetentionChartProps {
    data: { cohort_start: string; cohort_size: number; retained_30d: number; retention_rate: number }[]
    width?: number
    height?: number
}

export default function CohortRetentionChart({ data, width = 600, height = 300 }: CohortRetentionChartProps) {
    const svgRef = useRef<SVGSVGElement>(null)

    useEffect(() => {
        if (!data || data.length === 0 || !svgRef.current) return

        const svg = d3.select(svgRef.current)
        svg.selectAll("*").remove()

        const margin = { top: 20, right: 30, bottom: 40, left: 60 }
        const innerWidth = width - margin.left - margin.right
        const innerHeight = height - margin.top - margin.bottom

        // Parse dates for label
        const parsedData = data.map(d => ({
            ...d,
            label: new Date(d.cohort_start).toLocaleDateString(undefined, { month: 'short', day: 'numeric' })
        }))

        const x = d3.scaleBand()
            .domain(parsedData.map(d => d.label))
            .range([0, innerWidth])
            .padding(0.2)

        const y = d3.scaleLinear()
            .domain([0, 100]) // Rate is 0 to 100%
            .range([innerHeight, 0])

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
            .call(d3.axisLeft(y).ticks(5).tickFormat(d => d + '%'))
            .attr("color", "#6b7280")

        // Color scale for heatmap effect on bars
        const colorScale = d3.scaleSequential(d3.interpolateBlues).domain([0, 100])

        // Tooltip
        const tooltip = d3.select("body").append("div")
            .attr("class", "d3-tooltip absolute p-2 bg-white rounded shadow text-xs border hidden z-50 pointer-events-none")

        // Bars
        g.selectAll(".bar")
            .data(parsedData)
            .enter().append("rect")
            .attr("class", "bar")
            .attr("x", d => x(d.label) || 0)
            .attr("y", d => y(d.retention_rate))
            .attr("width", x.bandwidth())
            .attr("height", d => innerHeight - y(d.retention_rate))
            .attr("fill", d => colorScale(d.retention_rate) as string)
            .on("mouseover", (event, d) => {
                tooltip.style("display", "block")
                    .html(`<strong>Cohort:</strong> ${d.label}<br/><strong>Size:</strong> ${d.cohort_size}<br/><strong>Retained:</strong> ${d.retained_30d}<br/><strong>Rate:</strong> ${d.retention_rate}%`)
                d3.select(event.currentTarget).attr("opacity", 0.8)
            })
            .on("mousemove", (event) => tooltip.style("left", (event.pageX + 10) + "px").style("top", (event.pageY - 20) + "px"))
            .on("mouseout", (event) => {
                tooltip.style("display", "none")
                d3.select(event.currentTarget).attr("opacity", 1)
            })

        // Labels on top of bars
        g.selectAll(".label")
            .data(parsedData)
            .enter().append("text")
            .attr("x", d => (x(d.label) || 0) + x.bandwidth() / 2)
            .attr("y", d => y(d.retention_rate) - 5)
            .attr("text-anchor", "middle")
            .text(d => `${d.retention_rate}%`)
            .attr("font-size", "10px")
            .attr("fill", "#374151")

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
