import { LandingSection } from "@/lib/landing"
import { CheckCircle2 } from "lucide-react"

export function ImageTextSection({ section }: { section: LandingSection }) {
    return (
        <section className="bg-slate-950 py-24 sm:py-32 overflow-hidden">
            <div className="container mx-auto px-4">
                <div className="grid grid-cols-1 lg:grid-cols-2 gap-12 items-center">
                    <div className="order-2 lg:order-1">
                        <h2 className="text-3xl font-bold tracking-tight text-white sm:text-4xl mb-6">
                            {section.title}
                        </h2>
                        <h3 className="text-xl font-semibold text-emerald-400 mb-4">
                            {section.subtitle}
                        </h3>
                        <p className="text-lg text-slate-400 mb-8 leading-relaxed text-pretty">
                            {section.content}
                        </p>
                        <ul className="space-y-4">
                            {["Alertas Inteligentes ALIADA", "Predicción de Ventas IA", "Optimización de Inventario"].map((item, i) => (
                                <li key={i} className="flex items-center gap-3 text-slate-300">
                                    <CheckCircle2 className="h-5 w-5 text-emerald-500" />
                                    <span>{item}</span>
                                </li>
                            ))}
                        </ul>
                    </div>
                    <div className="order-1 lg:order-2 relative">
                        <div className="absolute -top-12 -right-12 w-64 h-64 bg-emerald-500/20 rounded-full blur-[80px]" />
                        <div className="relative rounded-2xl overflow-hidden border border-slate-800 shadow-2xl">
                            {section.image_url ? (
                                <img
                                    src={section.image_url}
                                    alt={section.title || "Feature"}
                                    className="w-full h-auto object-cover"
                                />
                            ) : (
                                <div className="aspect-video bg-slate-900 flex items-center justify-center">
                                    <span className="text-slate-700 italic">No image provided</span>
                                </div>
                            )}
                        </div>
                    </div>
                </div>
            </div>
        </section>
    )
}
