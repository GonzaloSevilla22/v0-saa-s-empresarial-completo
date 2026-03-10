import { getAllLandingSections } from "@/lib/landing"
import { LandingSectionForm } from "@/components/admin/LandingSectionForm"
import { Card, CardHeader, CardTitle, CardContent } from "@/components/ui/card"
import { notFound } from "next/navigation"

export default async function EditLandingSectionPage({ params }: { params: Promise<{ id: string }> }) {
    const { id } = await params
    const sections = await getAllLandingSections()
    const section = sections.find(s => s.id === id)

    if (!section) {
        notFound()
    }

    return (
        <div className="flex-1 space-y-4 p-8 pt-6">
            <div className="flex items-center justify-between space-y-2">
                <h2 className="text-3xl font-bold tracking-tight">Editar Sección: {section.type}</h2>
            </div>

            <Card className="bg-slate-900/50 border-slate-800 backdrop-blur-md">
                <CardHeader>
                    <CardTitle>Configuración de Bloque</CardTitle>
                </CardHeader>
                <CardContent>
                    <LandingSectionForm section={section} />
                </CardContent>
            </Card>
        </div>
    )
}
