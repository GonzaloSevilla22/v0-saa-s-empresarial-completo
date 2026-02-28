"use client"

import React, { useEffect, useRef } from 'react'
import * as d3 from 'd3'

interface TimeSeriesLinesChartProps {
    data: { period: string; activations: number; umv_achieved: number }[]
    width?: number
    height?: number
}

export default function TimeSeriesLinesChart({ data, width = 600, height = 300 }: TimeSeriesLinesChartProps) {
    const svgRef = useRef<SVGSVGElement>(null)

    useEffect(() => {
        if (!data || data.length === 0 || !svgRef.current) return

        const svg = d3.select(svgRef.current)
        svg.selectAll("*").remove() // Clear previous renders

        const margin = { top: 20, right: 30, bottom: 30, left: 40 }
        const innerWidth = width - margin.left - margin.right
        const innerHeight = height - margin.top - margin.bottom

        const parsedData = data.map(d => ({
            ...d,
            date: new Date(d.period)
        }))

        const x = d3.scaleTime()
            .domain(d3.extent(parsedData, d => d.date) as [Date, Date])
            .range([0, innerWidth])

        const maxVal = d3.max(parsedData, d => Math.max(d.activations, d.umv_achieved)) || 0

        const y = d3.scaleLinear()
            .domain([0, maxVal * 1.2]) // Add 20% breathing room
            .range([innerHeight, 0])

        const g = svg.append("g")
            .attr("transform", `translate(${margin.left},${margin.top})`)

        // X Axis
        g.append("g")
            .attr("transform", `translate(0,${innerHeight})`)
            .call(d3.axisBottom(x).ticks(5))
            .attr("color", "#6b7280") // text-gray-500

        // Y Axis
        g.append("g")
            .call(d3.axisLeft(y).ticks(5))
            .attr("color", "#6b7280")

        // Activations Line
        const lineActivations = d3.line<typeof parsedData[0]>()
            .x(d => x(d.date))
            .y(d => y(d.activations))
            .curve(d3.curveMonotoneX)

        g.append("path")
            .datum(parsedData)
            .attr("fill", "none")
            .attr("stroke", "#3b82f6") // blue-500
            .attr("stroke-width", 2)
            .attr("d", lineActivations)

        // UMV Line
        const lineUmv = d3.line<typeof parsedData[0]>()
            .x(d => x(d.date))
            .y(d => y(d.umv_achieved))
            .curve(d3.curveMonotoneX)

        g.append("path")
            .datum(parsedData)
            .attr("fill", "none")
            .attr("stroke", "#10b981") // emerald-500
            .attr("stroke-width", 2)
            .attr("d", lineUmv)

        // Tooltip logic
        const tooltip = d3.select("body").append("div")
            .attr("class", "d3-tooltip absolute p-2 bg-white rounded shadow text-xs border hidden z-50 pointer-events-none")

        const dots = g.selectAll(".dot-group")
            .data(parsedData)
            .enter().append("g")
            .attr("class", "dot-group")

        dots.append("circle")
            .attr("cx", d => x(d.date))
            .attr("cy", d => y(d.activations))
            .attr("r", 4)
            .attr("fill", "#3b82f6")
            .on("mouseover", (event, d) => {
                tooltip.style("display", "block").html(`<strong>Actives:</strong> ${d.activations}`)
                d3.select(event.currentTarget).attr("r", 6)
            })
            .on("mousemove", (event) => tooltip.style("left", (event.pageX + 10) + "px").style("top", (event.pageY - 20) + "px"))
            .on("mouseout", (event) => {
                tooltip.style("display", "none")
                d3.select(event.currentTarget).attr("r", 4)
            })

        dots.append("circle")
            .attr("cx", d => x(d.date))
            .attr("cy", d => y(d.umv_achieved))
            .attr("r", 4)
            .attr("fill", "#10b981")
            .on("mouseover", (event, d) => {
                tooltip.style("display", "block").html(`<strong>UMV:</strong> ${d.umv_achieved}`)
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
        <div className="w-full overflow-x-auto">
            <svg ref={svgRef} width={width} height={height} viewBox={`0 0 ${width} ${height}`} className="mx-auto" />
        </div>
    )
}
