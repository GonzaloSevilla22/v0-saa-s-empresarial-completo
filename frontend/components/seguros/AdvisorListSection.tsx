import { Card, CardContent } from "@/components/ui/card"

interface AdvisorListSectionItem {
  title: string
  text: string
}

interface AdvisorListSectionProps {
  heading: string
  items: AdvisorListSectionItem[]
  /** Grilla de 2-3 columnas (líneas de servicio) vs. columna única (pilares). */
  layout?: "grid" | "stack"
}

/**
 * Sección de lista ordenada del perfil de asesor (líneas de servicio /
 * pilares comparten exactamente esta forma: título + texto, renderizados en
 * el orden en que fueron cargados). Extraído en el REFACTOR de la task 5.7
 * para no repetir el mismo `Card > heading > map` dos veces.
 */
export function AdvisorListSection({ heading, items, layout = "stack" }: AdvisorListSectionProps) {
  if (items.length === 0) return null

  return (
    <Card className="border-border bg-card">
      <CardContent className="flex flex-col gap-4 p-6">
        <h2 className="text-sm font-semibold uppercase tracking-wide text-muted-foreground">{heading}</h2>
        <div className={layout === "grid" ? "grid gap-4 sm:grid-cols-2 lg:grid-cols-3" : "flex flex-col gap-4"}>
          {items.map((item, index) => (
            <div
              key={`${item.title}-${index}`}
              className={layout === "grid" ? "flex flex-col gap-1 rounded-lg border border-border p-4" : "flex flex-col gap-1"}
            >
              <p className="text-sm font-semibold text-card-foreground">{item.title}</p>
              <p className="text-xs leading-relaxed text-muted-foreground sm:text-sm">{item.text}</p>
            </div>
          ))}
        </div>
      </CardContent>
    </Card>
  )
}
