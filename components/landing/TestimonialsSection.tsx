import { LandingSection } from "@/lib/landing"
import { Star } from "lucide-react"

export function TestimonialsSection({ section }: { section: LandingSection }) {
    let testimonials: any[] = []
    let introDescription: string | null = null

    try {
        if (section.content) {
            if (section.content.trim().startsWith('[')) {
                testimonials = JSON.parse(section.content)
            } else {
                introDescription = section.content
            }
        }
    } catch (e) {
        introDescription = section.content
    }

    if (testimonials.length === 0) {
        testimonials = [
            { name: "Carlos Rossi", role: "Usuario ALIADA", text: "La IA cambió mi forma de ver el negocio. Ahora sé exactamente qué comprar." },
            { name: "Lucía Méndez", role: "Emprendedora", text: "La comunidad ALIADA es increíble. Aprendí más aquí que en cualquier curso." },
        ]
    }

    return (
        <section className="bg-slate-950 py-24 sm:py-32">
            <div className="container mx-auto px-4">
                <div className="text-center mb-16 max-w-2xl mx-auto">
                    <h2 className="text-3xl font-bold text-white mb-4">{section.title || "Lo que dicen nuestros clientes"}</h2>
                    {introDescription && (
                        <p className="text-slate-400 text-lg">
                            {introDescription}
                        </p>
                    )}
                </div>
                <div className="grid grid-cols-1 md:grid-cols-2 gap-8 max-w-5xl mx-auto">
                    {testimonials.map((t, i) => (
                        <div key={i} className="p-8 rounded-2xl bg-slate-900 border border-slate-800">
                            <div className="flex gap-1 mb-4">
                                {[1, 2, 3, 4, 5].map(s => <Star key={s} className="w-4 h-4 fill-emerald-500 text-emerald-500" />)}
                            </div>
                            <p className="text-slate-300 italic mb-6">"{t.text}"</p>
                            <div>
                                <p className="text-white font-semibold">{t.name}</p>
                                <p className="text-slate-500 text-sm">{t.role}</p>
                            </div>
                        </div>
                    ))}
                </div>
            </div>
        </section>
    )
}
