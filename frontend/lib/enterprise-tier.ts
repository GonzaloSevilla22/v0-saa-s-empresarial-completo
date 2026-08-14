/**
 * Tier "Empresa" — oferta de contacto directo, no un `Plan` de facturación.
 * Change `plan-empresa-contacto`, design.md D1.
 *
 * POR QUÉ NO vive en `PLAN_LIMITS` (`lib/constants.ts`):
 *
 * 1. `PLAN_LIMITS` es `as const satisfies Record<string, { priceMonthly: number,
 *    maxUsers: number, maxProducts: number, … }>` — obligaría a inventar ~17
 *    números para un tier que por definición no los tiene (precio "a medida").
 * 2. `PLAN_LIMITS` está documentado como espejo del seed de `plan_limits` en
 *    DB. Divergir rompe ese contrato y empuja a "completar" la tabla real con
 *    un quinto plan — que es exactamente lo que contaminaría el MRR de
 *    `rpc_admin_business_kpis` (deriva el ingreso recurrente de `plan_limits`
 *    × poblaciones por plan).
 * 3. Cualquier consumidor que derive claves de `PLAN_LIMITS` (hoy
 *    `usePlanLimits`) empezaría a ver un quinto tier sin límites definidos.
 *
 * El tier Empresa NO participa de gating, checkout ni KPIs de billing. Su
 * único propósito es abrir una conversación de WhatsApp ya calificada — ver
 * `lib/aliadata-contact.ts` (`ALIADATA_WHATSAPP_MESSAGE_EMPRESA`) y
 * `components/shared/EnterprisePlanCard.tsx`.
 *
 * El test de guardia en `__tests__/lib/enterprise-tier.test.ts` (D8) afirma
 * que `PLAN_LIMITS` sigue teniendo exactamente sus 4 claves y que el nombre
 * de este tier no coincide con ningún plan real — rompe el CI si alguien
 * cruza el límite en vez de dejarlo como una frase en el proposal.
 */

export interface EnterpriseTier {
  readonly name: string
  /** Texto de precio sin importe numérico — "a medida", nunca un monto. */
  readonly priceDisplay: string
  readonly tagline: string
  readonly features: readonly string[]
  readonly ctaLabel: string
  /** Nombre accesible del CTA — lo consume `EnterprisePlanCard` como `aria-label`. */
  readonly ctaAccessibleLabel: string
}

export const ENTERPRISE_TIER: EnterpriseTier = {
  name: "Empresa",
  priceDisplay: "A medida",
  tagline: "Adaptamos el sistema a la forma de trabajar de tu empresa.",
  features: [
    "Más sucursales y usuarios de los que cubre el plan Pro",
    "Integraciones con los sistemas que ya usás",
    "Migración de datos y onboarding acompañados",
    "Soporte prioritario con canal directo",
  ],
  ctaLabel: "Hablemos",
  ctaAccessibleLabel: "Hablemos por WhatsApp sobre el plan Empresa (abre una pestaña nueva)",
} as const
