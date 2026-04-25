import { getAllLandingSectionsAction } from "@/app/actions/landing"
import { LandingManager } from "@/components/admin/LandingManager"
import { Card, CardHeader, CardTitle, CardContent } from "@/components/ui/card"

export default async function AdminLandingPage() {
    const sections = await getAllLandingSectionsAction()

    return (
        <div className="flex-1 space-y-4 p-8 pt-6">
            <div className="flex items-center justify-between space-y-2">
                <h2 className="text-3xl font-bold tracking-tight">Gestión de Landing Page</h2>
            </div>

            <Card className="bg-slate-900/50 border-slate-800">
                <CardHeader>
                    <CardTitle>Secciones Activas</CardTitle>
                </CardHeader>
                <CardContent>
                    <LandingManager initialSections={sections} />
                </CardContent>
            </Card>
        </div>
    )
}
