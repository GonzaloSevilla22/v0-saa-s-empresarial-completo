"use client"

import React, { useRef, useEffect } from "react"
import * as d3 from "d3"

export interface CommunityData {
    period: string
    event_name: 'post_created' | 'reply_created'
    count: number
    active_users: number
}

export default function CommunitySeriesChart({ data, width: initialWidth = 600, height: initialHeight = 350 }: any) {
    const containerRef = useRef<HTMLDivElement>(null)
    const svgRef = useRef<SVGSVGElement>(null)

    useEffect(() => {
        if (!data || data.length === 0 || !containerRef.current || !svgRef.current) return

        const container = containerRef.current
        const svg = d3.select(svgRef.current)
        svg.selectAll("*").remove()

        // Add tooltip div
        const tooltip = d3
            .select(container)
            .append("div")
            .attr("class", "absolute hidden bg-slate-800 text-slate-200 border border-slate-700 p-3 rounded-lg text-xs shadow-xl z-10 pointer-events-none")

        const margin = { top: 20, right: 30, bottom: 30, left: 40 }

        const resizeObserver = new ResizeObserver((entries) => {
            if (!entries.length) return
            const { width, height } = entries[0].contentRect
            if (width === 0 || height === 0) return

            svg.selectAll("*").remove()

            const innerWidth = width - margin.left - margin.right
            const innerHeight = height - margin.top - margin.bottom

            svg
                .attr("width", width)
                .attr("height", height)
                .attr("viewBox", `0 0 ${width} ${height}`)
                .attr("preserveAspectRatio", "xMidYMid meet")

            const g = svg.append("g").attr("transform", `translate(${margin.left},${margin.top})`)

            const parseDate = d3.timeParse("%Y-%m-%dT%H:%M:%S%Z")

            // Pivot data by period
            const dateMap = new Map<string, any>()
            data.forEach((d: any) => {
                let entry = dateMap.get(d.period)
                if (!entry) {
                    entry = { date: parseDate(d.period) || new Date(d.period), posts: 0, replies: 0 }
                    dateMap.set(d.period, entry)
                }
                if (d.event_name === 'post_created') entry.posts += d.count
                if (d.event_name === 'reply_created') entry.replies += d.count
            })

            const parsedData = Array.from(dateMap.values()).sort((a, b) => a.date.getTime() - b.date.getTime())

            if (parsedData.length === 0) return

            const x = d3.scaleTime()
                .domain(d3.extent(parsedData, d => d.date) as [Date, Date])
                .range([0, innerWidth])

            const yMax = d3.max(parsedData, d => Math.max(d.posts, d.replies)) || 5
            const y = d3.scaleLinear()
                .domain([0, yMax * 1.1])
                .range([innerHeight, 0])

            // X Axis
            g.append("g")
                .attr("transform", `translate(0,${innerHeight})`)
                .call(d3.axisBottom(x).ticks(5).tickFormat(d3.timeFormat("%d %b") as any))
                .attr("color", "hsl(var(--muted-foreground))")
                .selectAll("text")
                .attr("font-size", "10px")

            // Y Axis
            g.append("g")
                .call(d3.axisLeft(y).ticks(5))
                .attr("color", "hsl(var(--muted-foreground))")
                .selectAll("text")
                .attr("font-size", "10px")

            // Grid lines
            g.append("g")
                .attr("class", "grid")
                .call(d3.axisLeft(y).ticks(5).tickSize(-innerWidth).tickFormat(() => ""))
                .attr("color", "hsl(var(--border))")
                .attr("stroke-dasharray", "2,2")
                .attr("stroke-opacity", 0.2)

            // Line Posts
            const linePosts = d3.line<any>()
                .x(d => x(d.date))
                .y(d => y(d.posts))
                .curve(d3.curveMonotoneX)

            g.append("path")
                .datum(parsedData)
                .attr("fill", "none")
                .attr("stroke", "#a855f7") // purple-500
                .attr("stroke-width", 2)
                .attr("d", linePosts)

            // Line Replies
            const lineReplies = d3.line<any>()
                .x(d => x(d.date))
                .y(d => y(d.replies))
                .curve(d3.curveMonotoneX)

            g.append("path")
                .datum(parsedData)
                .attr("fill", "none")
                .attr("stroke", "#3b82f6") // blue-500
                .attr("stroke-width", 2)
                .attr("d", lineReplies)

            // Overlay for tooltip
            const generateTooltipContent = (d: any) => {
                const ratio = d.posts > 0 ? (d.replies / d.posts).toFixed(1) : 0
                return `
          <div class="font-bold border-b border-slate-700 pb-1 mb-1">${d3.timeFormat("%d %b %Y")(d.date)}</div>
          <div class="flex items-center text-[#a855f7]"><span class="w-2 h-2 rounded-full bg-[#a855f7] mr-1"></span> Posts: ${d.posts}</div>
          <div class="flex items-center text-[#3b82f6]"><span class="w-2 h-2 rounded-full bg-[#3b82f6] mr-1"></span> Replies: ${d.replies}</div>
          <div class="mt-1 pt-1 border-t border-slate-700 text-slate-400">Ratio Replies/Posts: ${ratio}</div>
        `
            }

            const bisectDate = d3.bisector((d: any) => d.date).left

            const mouseMove = (event: any) => {
                const [mx] = d3.pointer(event)
                const dateAtPoint = x.invert(mx)
                const index = bisectDate(parsedData, dateAtPoint, 1)
                const d0 = parsedData[index - 1]
                const d1 = parsedData[index]

                let d = d0
                if (d1 && dateAtPoint.getTime() - d0.date.getTime() > d1.date.getTime() - dateAtPoint.getTime()) {
                    d = d1
                }

                tooltip
                    .style("display", "block")
                    .style("left", `${event.pageX + 15}px`)
                    .style("top", `${event.pageY - 15}px`)
                    .html(generateTooltipContent(d))
            }

            g.append("rect")
                .attr("width", innerWidth)
                .attr("height", innerHeight)
                .attr("fill", "transparent")
                .on("mousemove", mouseMove)
                .on("mouseleave", () => tooltip.style("display", "none"))
                .on("mouseenter", () => tooltip.style("display", "block"))

        })

        resizeObserver.observe(container)
        return () => {
            resizeObserver.disconnect()
            d3.select(container).selectAll("div").remove()
        }
    }, [data])

    return (
        <div ref={containerRef} className="w-full h-[300px] relative">
            <svg ref={svgRef} className="w-full h-full" />
        </div>
    )
}
