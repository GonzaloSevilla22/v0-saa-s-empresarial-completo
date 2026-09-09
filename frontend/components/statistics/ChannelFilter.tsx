"use client"

/**
 * filtro-canal-estadisticas (CLAUDE.md candidato "filtro de canal sin
 * superficie en /estadisticas"): selector de canal de venta para
 * `/estadisticas`, molde de components/branches/BranchFilter.tsx (mismo
 * patrón de sincronización con la URL, ?canal=).
 *
 * El catálogo es SALE_CHANNELS — el mismo que alimenta el selector de canal
 * del formulario de venta (components/forms/sale-form.tsx) y el desglose por
 * canal de este mismo módulo (lib/sales-statistics.ts) — sin repetir la
 * lista (regla "reutilización antes que repetición").
 */

import { useRouter, useSearchParams } from "next/navigation"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import { SALE_CHANNELS } from "@/lib/kpi-format"

export function ChannelFilter() {
  const router = useRouter()
  const searchParams = useSearchParams()

  const currentChannel = searchParams.get("canal") ?? ""

  function handleChange(value: string) {
    const params = new URLSearchParams(searchParams.toString())
    if (value === "__all__") {
      params.delete("canal")
    } else {
      params.set("canal", value)
    }
    router.push(`?${params.toString()}`)
  }

  return (
    <Select value={currentChannel || "__all__"} onValueChange={handleChange}>
      <SelectTrigger className="w-44 bg-background border-border text-foreground text-sm h-9">
        <SelectValue placeholder="Todos los canales" />
      </SelectTrigger>
      <SelectContent className="bg-popover border-border">
        <SelectItem value="__all__">Todos los canales</SelectItem>
        {SALE_CHANNELS.map((c) => (
          <SelectItem key={c.value} value={c.value}>
            {c.label}
          </SelectItem>
        ))}
      </SelectContent>
    </Select>
  )
}
