import { LandingSection } from "@/lib/landing"
import { HeroSection } from "./HeroSection"
import { FeaturesSection } from "./FeaturesSection"
import { ImageTextSection } from "./ImageTextSection"
import { BenefitsSection } from "./BenefitsSection"
import { TestimonialsSection } from "./TestimonialsSection"
import { CTASection } from "./CTASection"

const componentMap: Record<string, any> = {
    hero: HeroSection,
    features: FeaturesSection,
    image_text: ImageTextSection,
    benefits: BenefitsSection,
    testimonials: TestimonialsSection,
    cta: CTASection,
}

export function LandingRenderer({ sections }: { sections: LandingSection[] }) {
    if (!sections || sections.length === 0) {
        return (
            <div className="min-h-screen flex items-center justify-center bg-slate-950 text-slate-500">
                <p>No se encontraron secciones activas para la landing page.</p>
            </div>
        )
    }

    return (
        <main className="min-h-screen">
            {sections.map((section) => {
                const Component = componentMap[section.type]
                if (!Component) return null
                return <Component key={section.id} section={section} />
            })}
        </main>
    )
}
