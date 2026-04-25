"use client"

import { useState } from "react"
import { LandingSection } from "@/lib/landing"
import { updateLandingSectionActionAction } from "@/app/actions/landing"
import { Button } from "@/components/ui/button"
import { Badge } from "@/components/ui/badge"
import { ArrowUp, ArrowDown, Edit2, Eye, EyeOff, LayoutGrid } from "lucide-react"
import Link from "next/link"
import { toast } from "sonner"

export function LandingManager({ initialSections }: { initialSections: LandingSection[] }) {
    const [sections, setSections] = useState(initialSections)

    const handleToggleActive = async (section: LandingSection) => {
        try {
            const updated = await updateLandingSectionAction(section.id, { active: !section.active })
            setSections(sections.map(s => s.id === section.id ? updated : s))
            toast.success(updated.active ? "Sección activada" : "Sección desactivada")
        } catch (error) {
            toast.error("Error al actualizar la sección")
        }
    }

    const handleMove = async (index: number, direction: 'up' | 'down') => {
        if (direction === 'up' && index === 0) return
        if (direction === 'down' && index === sections.length - 1) return

        const newIndex = direction === 'up' ? index - 1 : index + 1
        const newSections = [...sections]
        const temp = newSections[index]
        newSections[index] = newSections[newIndex]
        newSections[newIndex] = temp

        // Update positions in state
        const reordered = newSections.map((s, i) => ({ ...s, position: i + 1 }))
        setSections(reordered)

        // Ideally we should have a bulk update RPC, but we'll do individual updates for now
        try {
            await Promise.all([
                updateLandingSectionAction(reordered[index].id, { position: index + 1 }),
                updateLandingSectionAction(reordered[newIndex].id, { position: newIndex + 1 })
            ])
            toast.success("Orden actualizado")
        } catch (error) {
            toast.error("Error al actualizar el orden")
        }
    }

    return (
        <div className="space-y-4">
            {sections.map((section, index) => (
                <div
                    key={section.id}
                    className="flex items-center justify-between p-4 rounded-lg bg-slate-800/50 border border-slate-700/50 group"
                >
                    <div className="flex items-center gap-4">
                        <div className="flex flex-col gap-1 text-slate-500">
                            <button
                                onClick={() => handleMove(index, 'up')}
                                disabled={index === 0}
                                className="hover:text-emerald-500 disabled:opacity-30"
                            >
                                <ArrowUp className="w-4 h-4" />
                            </button>
                            <button
                                onClick={() => handleMove(index, 'down')}
                                disabled={index === sections.length - 1}
                                className="hover:text-emerald-500 disabled:opacity-30"
                            >
                                <ArrowDown className="w-4 h-4" />
                            </button>
                        </div>
                        <div className="p-2 rounded bg-slate-900 border border-slate-700">
                            <LayoutGrid className="w-5 h-5 text-slate-400" />
                        </div>
                        <div>
                            <div className="flex items-center gap-2">
                                <span className="font-semibold text-slate-100">{section.title || section.slug}</span>
                                <Badge variant="secondary" className="capitalize text-[10px] py-0">{section.type}</Badge>
                            </div>
                            <p className="text-sm text-slate-400 truncate max-w-[400px]">
                                {section.subtitle || section.content || "Sin descripción"}
                            </p>
                        </div>
                    </div>

                    <div className="flex items-center gap-2">
                        <Button
                            variant="ghost"
                            size="icon"
                            onClick={() => handleToggleActive(section)}
                            className={section.active ? "text-emerald-500" : "text-slate-500"}
                        >
                            {section.active ? <Eye className="w-4 h-4" /> : <EyeOff className="w-4 h-4" />}
                        </Button>
                        <Button variant="outline" size="icon" asChild>
                            <Link href={`/admin/landing/edit/${section.id}`}>
                                <Edit2 className="w-4 h-4" />
                            </Link>
                        </Button>
                    </div>
                </div>
            ))}
        </div>
    )
}
