import { getLandingSections } from "@/lib/landing"
import { LandingRenderer } from "@/components/landing/LandingRenderer"
import { Metadata } from "next"

export async function generateMetadata(): Promise<Metadata> {
  const sections = await getLandingSections()
  const hero = sections.find(s => s.type === 'hero')

  return {
    title: hero?.title || "ALIADATA - Gestión Inteligente",
    description: hero?.subtitle || "La plataforma integral que escala con tu negocio.",
    openGraph: {
      title: hero?.title || "ALIADATA - Gestión Inteligente",
      description: hero?.subtitle || "La plataforma integral que escala con tu negocio.",
      images: hero?.image_url ? [hero.image_url] : [],
    }
  }
}

export default async function HomePage() {
  const sections = await getLandingSections()

  return <LandingRenderer sections={sections} />
}
