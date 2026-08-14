/**
 * Card compartida del tier Empresa — change `plan-empresa-contacto`.
 *
 * Un solo componente para las dos superficies de precios (landing pública y
 * `/planes`), con dos variantes visuales resueltas por `cva` (design.md D2/D7):
 * - `app`: exclusivamente tokens semánticos del design system (`bg-card`,
 *   `text-foreground`, `text-muted-foreground`, `border-border`, `bg-primary`),
 *   legible en tema claro y oscuro — igual que `PlanCard`.
 * - `landing`: la paleta `slate/emerald` de la sección `#pricing`, dark-only
 *   por diseño (deuda de unificación fuera de alcance, ver design.md OQ-4).
 *
 * Presentación pura: NO lee `process.env`, no hace `fetch`, no tiene estado.
 * Recibe `whatsappUrl` ya armada por el servidor (`app/page.tsx` o
 * `app/(dashboard)/planes/page.tsx`) — así la misma pieza sirve en un árbol de
 * cliente y en uno de servidor sin arrastrar el número de teléfono al bundle
 * (design.md D5). El contenido sale siempre de `ENTERPRISE_TIER`
 * (`lib/enterprise-tier.ts`): un cambio de copy alcanza a ambas superficies.
 *
 * Se monta como HERMANA de la grilla comparativa, nunca como una quinta
 * columna (design.md D3) — la decisión de dónde montarla vive en cada
 * superficie, no acá.
 */

import { cva, type VariantProps } from "class-variance-authority"
import { MessageCircle } from "lucide-react"
import { cn } from "@/lib/utils"
import { ENTERPRISE_TIER } from "@/lib/enterprise-tier"

const cardVariants = cva(
  "relative flex flex-col gap-6 rounded-2xl border p-6 md:flex-row md:items-center md:gap-10 md:p-8",
  {
    variants: {
      variant: {
        app: "bg-card border-border",
        landing: "border-emerald-500/30 bg-slate-900 shadow-2xl shadow-emerald-900/10",
      },
    },
    defaultVariants: { variant: "app" },
  },
)

const headingVariants = cva("text-xl font-bold md:text-2xl", {
  variants: {
    variant: {
      app: "text-foreground",
      landing: "text-white",
    },
  },
  defaultVariants: { variant: "app" },
})

const priceVariants = cva("text-sm font-semibold uppercase tracking-wide", {
  variants: {
    variant: {
      app: "text-primary",
      landing: "text-emerald-400",
    },
  },
  defaultVariants: { variant: "app" },
})

const taglineVariants = cva("mt-2 text-sm", {
  variants: {
    variant: {
      app: "text-muted-foreground",
      landing: "text-slate-400",
    },
  },
  defaultVariants: { variant: "app" },
})

const featureTextVariants = cva("text-sm", {
  variants: {
    variant: {
      app: "text-foreground",
      landing: "text-slate-300",
    },
  },
  defaultVariants: { variant: "app" },
})

const featureIconVariants = cva("h-4 w-4 shrink-0", {
  variants: {
    variant: {
      app: "text-primary",
      landing: "text-emerald-400",
    },
  },
  defaultVariants: { variant: "app" },
})

const ctaVariants = cva(
  // min-h/min-w garantizan el área táctil mínima de 44×44 px CSS incluso si
  // el contenido del label la achica en pantallas angostas.
  "inline-flex min-h-[44px] min-w-[44px] shrink-0 items-center justify-center gap-2 whitespace-nowrap rounded-full px-6 py-3 text-sm font-semibold transition-colors duration-base ease-standard focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-offset-2",
  {
    variants: {
      variant: {
        app: "bg-primary text-primary-foreground hover:bg-primary/90 focus-visible:ring-ring",
        landing:
          "bg-emerald-600 text-white shadow-lg shadow-emerald-900/40 hover:bg-emerald-500 focus-visible:ring-emerald-400 focus-visible:ring-offset-slate-900",
      },
    },
    defaultVariants: { variant: "app" },
  },
)

export interface EnterprisePlanCardProps extends VariantProps<typeof cardVariants> {
  /** URL `wa.me` ya armada (con el mensaje del tier). Nunca `null`: la superficie que la computa decide no montar la card cuando es `null` (D6). */
  whatsappUrl: string
  variant: "landing" | "app"
}

export function EnterprisePlanCard({ whatsappUrl, variant }: EnterprisePlanCardProps) {
  return (
    <div className={cn(cardVariants({ variant }))}>
      <div className="flex-1">
        <p className={cn(priceVariants({ variant }))}>{ENTERPRISE_TIER.priceDisplay}</p>
        <h3 className={cn(headingVariants({ variant }))}>{ENTERPRISE_TIER.name}</h3>
        <p className={cn(taglineVariants({ variant }))}>{ENTERPRISE_TIER.tagline}</p>
        <ul className="mt-4 grid grid-cols-1 gap-x-6 gap-y-2 md:grid-cols-2">
          {ENTERPRISE_TIER.features.map((feature) => (
            <li key={feature} className="flex items-start gap-2">
              <MessageCircle aria-hidden="true" className={cn(featureIconVariants({ variant }))} />
              <span className={cn(featureTextVariants({ variant }))}>{feature}</span>
            </li>
          ))}
        </ul>
      </div>
      <a
        href={whatsappUrl}
        target="_blank"
        // Sin `noopener`, la pestaña destino recibe `window.opener` y puede
        // redirigir la nuestra (tabnabbing) — mismo contrato que el FAB y el
        // link "Contacto" del footer.
        rel="noopener noreferrer"
        aria-label={ENTERPRISE_TIER.ctaAccessibleLabel}
        className={cn(ctaVariants({ variant }))}
      >
        {ENTERPRISE_TIER.ctaLabel}
      </a>
    </div>
  )
}
