import { LandingSection } from "@/lib/landing"
import { CheckCircle2, Zap, Shield, BarChart3, Users, Smartphone } from "lucide-react"

const iconMap: Record<string, any> = {
    "0": Zap,
    "1": Shield,
    "2": BarChart3,
    "3": Users,
    "4": Smartphone,
    "5": CheckCircle2,
}

export function FeaturesSection({ section }: { section: LandingSection }) {
    let features: any[] = []
    let introDescription: string | null = null

    try {
        if (section.content) {
            // Check if it's a JSON string
            if (section.content.trim().startsWith('[') || section.content.trim().startsWith('{')) {
                features = JSON.parse(section.content)
                // Ensure it's an array
                if (!Array.isArray(features)) {
                    features = []
                    introDescription = section.content
                }
            } else {
                // It's likely plain text, use it as description
                introDescription = section.content
            }
        }
    } catch (e) {
        // Fallback: use content as description if it fails to parse but exists
        introDescription = section.content
    }

    // Default placeholders if no structural items found
    if (features.length === 0) {
        features = [
            { title: "Gestión Proactiva", desc: "Monitoreá tu stock y ventas en tiempo real.", icon: Zap },
            { title: "Análisis con IA", desc: "Insights accionables para crecer rápido.", icon: BarChart3 },
            { title: "Comunidad ALIADATA", desc: "Interactuá con otros emprendedores.", icon: Users },
        ]
    }

    return (
        <section id="features" className="bg-slate-900 py-24 sm:py-32">
            <div className="container mx-auto px-4">
                <div className="mx-auto max-w-2xl text-center mb-16">
                    <h2 className="text-base font-semibold leading-7 text-emerald-400">Funcionalidades</h2>
                    <p className="mt-2 text-3xl font-bold tracking-tight text-white sm:text-4xl">
                        {section.title}
                    </p>
                    <p className="mt-6 text-lg leading-8 text-slate-400">
                        {introDescription || section.subtitle}
                    </p>
                </div>

                <div className="mx-auto mt-16 max-w-2xl sm:mt-20 lg:mt-24 lg:max-w-none">
                    <dl className="grid max-w-xl grid-cols-1 gap-x-8 gap-y-16 lg:max-w-none lg:grid-cols-3">
                        {features.map((feature, index) => {
                            const IconComponent = typeof feature.icon === 'string' ? (iconMap[feature.icon] || Zap) : (feature.icon || Zap)
                            return (
                                <div key={index} className="flex flex-col items-start p-6 rounded-2xl bg-slate-800/50 border border-slate-700/50 hover:bg-slate-800 transition-colors">
                                    <div className="mb-6 rounded-lg bg-emerald-500/10 p-3 ring-1 ring-emerald-500/20">
                                        <IconComponent className="h-6 w-6 text-emerald-400" aria-hidden="true" />
                                    </div>
                                <dt className="text-lg font-semibold leading-7 text-white">
                                    {feature.title}
                                </dt>
                                <dd className="mt-2 flex-auto text-base leading-7 text-slate-400">
                                    {feature.desc}
                                </dd>
                            </div>
                        )})}
                    </dl>
                </div>
            </div>
        </section>
    )
}
