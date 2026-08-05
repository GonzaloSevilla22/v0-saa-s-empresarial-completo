import { getLandingSectionsAction } from "@/app/actions/landing"
import { LandingPageFull } from "@/components/landing/LandingPageFull"
import { WhatsAppFab } from "@/components/landing/WhatsAppFab"
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
  return (
    <>
      <LandingPageFull sections={sections} />
      {/* El FAB de WhatsApp se monta acá y NO dentro de `LandingPageFull` (que
          es un Client Component): así no entra al bundle de cliente y su alcance
          queda limitado a esta ruta por construcción — no vive en ningún layout
          ni componente compartido. Sin `ALIADATA_WHATSAPP_PHONE` configurada no
          renderiza nada. Ver `openspec/changes/landing-whatsapp-fab/design.md` D2. */}
      <WhatsAppFab phone={process.env.ALIADATA_WHATSAPP_PHONE} />
    </>
  )
}
