import { getLandingSectionsAction } from "@/app/actions/landing"
import { LandingPageFull } from "@/components/landing/LandingPageFull"
import { Metadata } from "next"

export const dynamic = "force-dynamic"

export async function generateMetadata(): Promise<Metadata> {
  const sections = await getLandingSectionsAction()
  const hero = sections.find(s => s.type === "hero")
  return {
    title: hero?.title ?? "ALIADATA - Gestion Inteligente para tu Negocio",
    description: hero?.subtitle ?? "Controla ventas, stock, compras e informes desde un solo lugar. Con IA incluida.",
    openGraph: {
      title: hero?.title ?? "ALIADATA - Gestion Inteligente para tu Negocio",
      description: hero?.subtitle ?? "Controla ventas, stock, compras e informes desde un solo lugar. Con IA incluida.",
      images: hero?.image_url ? [hero.image_url] : [],
    },
  }
}

export default async function HomePage() {
  const sections = await getLandingSectionsAction()
  return <LandingPageFull sections={sections} />
}
