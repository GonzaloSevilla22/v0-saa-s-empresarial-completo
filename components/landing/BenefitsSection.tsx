import { LandingSection } from "@/lib/landing"

export function BenefitsSection({ section }: { section: LandingSection }) {
    const benefits = [
        { title: "Reduce Costos", subtitle: "Hasta un 30% en desperdicio de stock." },
        { title: "Ahorra Tiempo", subtitle: "Automatizá tareas repetitivas." },
        { title: "Crece Mejor", subtitle: "Basado en datos, no en suposiciones." },
    ]

    return (
        <section className="bg-slate-900 py-24 sm:py-32">
            <div className="container mx-auto px-4">
                <div className="max-w-2xl mx-auto text-center mb-16">
                    <h2 className="text-3xl font-bold tracking-tight text-white sm:text-4xl">
                        {section.title || "Beneficios Estratégicos"}
                    </h2>
                </div>
                <div className="grid grid-cols-1 sm:grid-cols-3 gap-8">
                    {benefits.map((benefit, i) => (
                        <div key={i} className="text-center p-8 rounded-2xl bg-slate-800/30 border border-slate-800">
                            <div className="text-4xl font-bold text-emerald-500 mb-4">{i + 1}</div>
                            <h4 className="text-xl font-semibold text-white mb-2">{benefit.title}</h4>
                            <p className="text-slate-400">{benefit.subtitle}</p>
                        </div>
                    ))}
                </div>
            </div>
        </section>
    )
}
