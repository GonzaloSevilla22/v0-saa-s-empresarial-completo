import { LandingPageFull } from "@/components/landing/LandingPageFull"
import { Metadata } from "next"

export const metadata: Metadata = {
  title: "ALIADATA - Gestion Inteligente para tu Negocio",
  description: "Controla ventas, stock, compras e informes desde un solo lugar. Con Inteligencia Artificial incluida.",
  openGraph: {
    title: "ALIADATA - Gestion Inteligente para tu Negocio",
    description: "Controla ventas, stock, compras e informes desde un solo lugar. Con Inteligencia Artificial incluida.",
  },
}

export default function HomePage() {
  return <LandingPageFull />
}
