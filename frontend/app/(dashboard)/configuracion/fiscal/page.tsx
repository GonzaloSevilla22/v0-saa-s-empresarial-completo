"use client"

/**
 * C-27 v21-fiscal-profile — Página standalone `/configuracion/fiscal`.
 *
 * Wrapper fino con breadcrumb + header sobre `<FiscalSettings />`.
 * El mismo contenido se embebe en la tab "Facturación AFIP" de `/configuracion`.
 */

import { ChevronLeft } from "lucide-react"
import Link from "next/link"

import { FiscalSettings } from "@/components/settings/FiscalSettings"

export default function FiscalConfiguracionPage() {
  return (
    <div className="flex flex-col gap-6 max-w-2xl">
      {/* Breadcrumb */}
      <div className="flex items-center gap-2">
        <Link
          href="/configuracion"
          className="flex items-center gap-1 text-sm text-muted-foreground hover:text-foreground transition-colors"
        >
          <ChevronLeft className="h-3.5 w-3.5" />
          Configuración
        </Link>
        <span className="text-muted-foreground/40">/</span>
        <span className="text-sm text-foreground">Facturación AFIP</span>
      </div>

      {/* Header */}
      <div>
        <h1 className="text-2xl font-bold text-foreground tracking-tight">Facturación AFIP</h1>
        <p className="text-sm text-muted-foreground mt-1">
          Configurá tu perfil fiscal para emitir comprobantes electrónicos (Facturas A, B y C).
        </p>
      </div>

      <FiscalSettings />
    </div>
  )
}
