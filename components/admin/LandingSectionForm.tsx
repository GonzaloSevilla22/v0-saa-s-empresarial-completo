"use client"

import { useState } from "react"
import { LandingSection, uploadLandingImage } from "@/lib/landing"
import { updateLandingSectionAction } from "@/app/actions/landing"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Textarea } from "@/components/ui/textarea"
import { Label } from "@/components/ui/label"
import { toast } from "sonner"
import { useRouter } from "next/navigation"
import { Upload, Save, X, ImageIcon, Loader2, Info, FileCode } from "lucide-react"
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert"

export function LandingSectionForm({ section }: { section: LandingSection }) {
    const [formData, setFormData] = useState<Partial<LandingSection>>(section)
    const [uploading, setUploading] = useState(false)
    const [saving, setSaving] = useState(false)
    const router = useRouter()

    const handleSubmit = async (e: React.FormEvent) => {
        e.preventDefault()
        setSaving(true)
        try {
            await updateLandingSectionAction(section.id, formData)
            toast.success("Sección guardada correctamente")
            router.push('/admin/landing')
        } catch (error) {
            toast.error("Error al guardar la sección")
        } finally {
            setSaving(false)
        }
    }

    const templates: Record<string, string> = {
        features: `[
  { "title": "Gestión Proactiva", "desc": "Monitoreá tu stock y ventas en tiempo real.", "icon": "0" },
  { "title": "Análisis con IA", "desc": "Insights accionables para crecer rápido.", "icon": "2" },
  { "title": "Comunidad ALIADATA", "desc": "Interactuá con otros emprendedores.", "icon": "3" }
]`,
        benefits: `[
  { "title": "Reduce Costos", "subtitle": "Hasta un 30% en desperdicio de stock." },
  { "title": "Ahorra Tiempo", "subtitle": "Automatizá tareas repetitivas." },
  { "title": "Crece con ALIADATA", "subtitle": "Basado en datos, no en suposiciones." }
]`,
        testimonials: `[
  { "name": "Carlos Rossi", "role": "Usuario ALIADATA", "text": "La IA cambió mi forma de ver el negocio." },
  { "name": "Lucía Méndez", "role": "Emprendedora", "text": "La comunidad ALIADATA es increíble." }
]`
    }

    const insertTemplate = (type: string) => {
        if (templates[type]) {
            setFormData({ ...formData, content: templates[type] })
            toast.info(`Plantilla de ${type} insertada`)
        }
    }

    const needsJson = ["features", "benefits", "testimonials"].includes(section.type)

    const handleImageUpload = async (e: React.ChangeEvent<HTMLInputElement>) => {
        const file = e.target.files?.[0]
        if (!file) return

        setUploading(true)
        try {
            const publicUrl = await uploadLandingImage(file)
            setFormData({ ...formData, image_url: publicUrl })
            toast.success("Imagen subida correctamente")
        } catch (error) {
            toast.error("Error al subir la imagen")
        } finally {
            setUploading(false)
        }
    }

    return (
        <form onSubmit={handleSubmit} className="space-y-6 max-w-2xl">
            <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                <div className="space-y-2">
                    <Label htmlFor="title">Título</Label>
                    <Input
                        id="title"
                        value={formData.title || ""}
                        onChange={(e) => setFormData({ ...formData, title: e.target.value })}
                        className="bg-slate-800 border-slate-700"
                    />
                </div>
                <div className="space-y-2">
                    <Label htmlFor="subtitle">Subtítulo</Label>
                    <Input
                        id="subtitle"
                        value={formData.subtitle || ""}
                        onChange={(e) => setFormData({ ...formData, subtitle: e.target.value })}
                        className="bg-slate-800 border-slate-700"
                    />
                </div>
            </div>

            <div className="space-y-2">
                <div className="flex items-center justify-between">
                    <Label htmlFor="content">Contenido / Descripción</Label>
                    {needsJson && (
                        <Button 
                            type="button" 
                            variant="outline" 
                            size="sm" 
                            onClick={() => insertTemplate(section.type)}
                            className="h-7 text-[10px] gap-1 border-emerald-500/30 text-emerald-500 hover:bg-emerald-500/10"
                        >
                            <FileCode className="w-3 h-3" />
                            Insertar JSON
                        </Button>
                    )}
                </div>
                {needsJson && (
                    <Alert className="bg-blue-500/10 border-blue-500/20 mb-2">
                        <Info className="h-4 w-4 text-blue-400" />
                        <AlertTitle className="text-xs font-semibold text-blue-300">Formato Estructurado</AlertTitle>
                        <AlertDescription className="text-[10px] text-blue-400/80">
                            Esta sección utiliza un formato JSON para mostrar tarjetas. Podés usar la descripción simple, pero se recomienda seguir el formato de la plantilla.
                        </AlertDescription>
                    </Alert>
                )}
                <Textarea
                    id="content"
                    value={formData.content || ""}
                    onChange={(e) => setFormData({ ...formData, content: e.target.value })}
                    className={`bg-slate-800 border-slate-700 min-h-[150px] font-mono text-sm ${needsJson ? 'border-blue-500/30 ring-blue-500/10' : ''}`}
                    placeholder={needsJson ? "Pega el JSON aquí..." : "Escribe el contenido de la sección..."}
                />
            </div>

            <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                <div className="space-y-2">
                    <Label htmlFor="button_text">Texto del Botón</Label>
                    <Input
                        id="button_text"
                        value={formData.button_text || ""}
                        onChange={(e) => setFormData({ ...formData, button_text: e.target.value })}
                        className="bg-slate-800 border-slate-700"
                    />
                </div>
                <div className="space-y-2">
                    <Label htmlFor="button_link">Enlace del Botón</Label>
                    <Input
                        id="button_link"
                        value={formData.button_link || ""}
                        onChange={(e) => setFormData({ ...formData, button_link: e.target.value })}
                        className="bg-slate-800 border-slate-700"
                    />
                </div>
            </div>

            <div className="space-y-4">
                <Label>Imagen de la Sección</Label>
                <div className="flex items-center gap-4">
                    {formData.image_url ? (
                        <div className="relative group rounded-lg overflow-hidden border border-slate-700 bg-slate-900 w-40 h-24">
                            <img
                                src={formData.image_url}
                                alt="Preview"
                                className="w-full h-full object-cover"
                            />
                            <button
                                type="button"
                                onClick={() => setFormData({ ...formData, image_url: null })}
                                className="absolute top-1 right-1 p-1 bg-red-500 rounded-full text-white opacity-0 group-hover:opacity-100 transition-opacity"
                            >
                                <X className="w-3 h-3" />
                            </button>
                        </div>
                    ) : (
                        <div className="w-40 h-24 rounded-lg bg-slate-900 border-2 border-dashed border-slate-700 flex flex-col items-center justify-center text-slate-500">
                            <ImageIcon className="w-6 h-6 mb-1 opacity-20" />
                            <span className="text-[10px]">Sin imagen</span>
                        </div>
                    )}

                    <div className="flex-1">
                        <Label
                            htmlFor="image-upload"
                            className="flex items-center gap-2 px-4 py-2 rounded-md bg-slate-800 border border-slate-700 hover:bg-slate-700 cursor-pointer transition-colors w-fit text-sm"
                        >
                            {uploading ? (
                                <Loader2 className="w-4 h-4 animate-spin text-emerald-500" />
                            ) : (
                                <Upload className="w-4 h-4 text-emerald-400" />
                            )}
                            Subir nueva imagen
                        </Label>
                        <input
                            id="image-upload"
                            type="file"
                            accept="image/*"
                            onChange={handleImageUpload}
                            className="hidden"
                            disabled={uploading}
                        />
                        <p className="text-[10px] text-slate-500 mt-2">Recomendado: 1200x800px (PNG o JPG)</p>
                    </div>
                </div>
            </div>

            <div className="flex gap-4 pt-4 border-t border-slate-800">
                <Button
                    type="submit"
                    className="bg-emerald-600 hover:bg-emerald-500 text-white gap-2 px-6"
                    disabled={saving || uploading}
                >
                    {saving ? <Loader2 className="w-4 h-4 animate-spin" /> : <Save className="w-4 h-4" />}
                    Guardar Cambios
                </Button>
                <Button
                    type="button"
                    variant="ghost"
                    onClick={() => router.push('/admin/landing')}
                    disabled={saving || uploading}
                >
                    Cancelar
                </Button>
            </div>
        </form>
    )
}
