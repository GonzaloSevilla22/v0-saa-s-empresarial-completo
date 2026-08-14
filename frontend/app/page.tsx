import { getLandingSectionsAction } from "@/app/actions/landing"
import { LandingPageFull } from "@/components/landing/LandingPageFull"
import { WhatsAppFab } from "@/components/landing/WhatsAppFab"
import { aliadataWhatsAppUrl, ALIADATA_WHATSAPP_MESSAGE_EMPRESA } from "@/lib/aliadata-contact"
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
  // La URL se computa UNA vez acá (server) desde la env var y alimenta las dos
  // superficies del canal: el link "Contacto" del footer y el FAB. Sin número
  // válido es null → el footer conserva su "#" inerte y el FAB no se renderiza.
  const contactWhatsAppUrl = aliadataWhatsAppUrl(process.env.ALIADATA_WHATSAPP_PHONE)
  // Segunda URL con el mensaje del tier Empresa (plan-empresa-contacto, D5):
  // se computan DOS URLs porque cada superficie del canal necesita su propio
  // mensaje pre-cargado (D4) — la del FAB/footer llega genérica, la de la
  // card Empresa llega ya calificada. El número NO se expone como
  // `NEXT_PUBLIC_*`: ambas URLs se arman en el servidor y bajan ya armadas,
  // el bundle de cliente nunca ve el teléfono.
  const enterpriseWhatsAppUrl = aliadataWhatsAppUrl(
    process.env.ALIADATA_WHATSAPP_PHONE,
    ALIADATA_WHATSAPP_MESSAGE_EMPRESA,
  )
  return (
    <>
      <LandingPageFull
        sections={sections}
        contactWhatsAppUrl={contactWhatsAppUrl ?? undefined}
        enterpriseWhatsAppUrl={enterpriseWhatsAppUrl ?? undefined}
      />
      {/* El FAB de WhatsApp se monta acá y NO dentro de `LandingPageFull` (que
          es un Client Component): así no entra al bundle de cliente y su alcance
          queda limitado a esta ruta por construcción — no vive en ningún layout
          ni componente compartido. Sin `ALIADATA_WHATSAPP_PHONE` configurada no
          renderiza nada. Ver `openspec/changes/archive/2026-08-11-landing-whatsapp-fab/design.md` D2. */}
      <WhatsAppFab phone={process.env.ALIADATA_WHATSAPP_PHONE} />
    </>
  )
}
