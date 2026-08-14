## Context

La oferta pública son 4 planes de precio cerrado. Dos superficies los muestran, y **no comparten código**:

| Superficie | Componente | Fuente de datos | Paleta |
|---|---|---|---|
| Landing `/` → `#pricing` | `Pricing()` dentro de `components/landing/LandingPageFull.tsx` (array literal, precios hardcodeados) | ninguna — literal | `slate/emerald` hardcodeada, dark-only |
| App `/planes` | `components/billing/PlanComparison.tsx` → `PlanCard` | tabla `plan_limits` (DB) vía Server Component | tokens semánticos, theme-aware |

El canal de WhatsApp ya está resuelto y es canónico desde `landing-whatsapp-fab` (PR #360/#376): `frontend/lib/aliadata-contact.ts` expone `aliadataWhatsAppUrl(phone)` con un mensaje inicial fijo; el número vive en la env var **de servidor** `ALIADATA_WHATSAPP_PHONE`, se lee en `app/page.tsx` y baja como prop. Hoy tiene dos consumidores: el FAB y el link "Contacto" del footer.

Restricciones que condicionan el diseño:

- `frontend/lib/types.ts`: `export type Plan = "gratis" | "inicial" | "avanzado" | "pro"` — union cerrada usada por gating, billing y tipos de la DB.
- `frontend/lib/constants.ts`: `PLAN_LIMITS` es `as const satisfies Record<string, { priceMonthly: number, maxUsers: number, … }>` y su comentario declara que **espeja el seed de `plan_limits`**.
- `rpc_admin_business_kpis` deriva el MRR de `plan_limits` × poblaciones por plan: un quinto plan en DB con precio inventado contamina el MRR real (recién saneado en el programa de remediación de KPIs).
- El PO pidió un tier de **contacto**, no un producto comprable: no hay precio que cobrar ni checkout que disparar.

## Goals / Non-Goals

**Goals:**
- Una card "Empresa" visible en las dos superficies de precios, con copy de adaptación a medida y un CTA que abra WhatsApp con contexto ya escrito.
- Un único origen para el contenido del tier y un único componente para las dos superficies.
- Reutilizar el canal de WhatsApp canónico, extendiéndolo lo mínimo (mensaje por superficie) en vez de duplicarlo.
- Cero impacto en billing: ni tipos, ni catálogo, ni gating, ni KPIs, ni checkout.

**Non-Goals:**
- Aprovisionar, cobrar o limitar cuentas "Empresa" (no existe tal plan técnico).
- Un formulario de contacto, un CRM de leads o telemetría de conversión del CTA.
- Unificar la paleta de la landing con el design system de la app (deuda preexistente, OQ-4).
- Tocar `/landing` (usa `LandingRenderer`, otro árbol de componentes) ni el FAB.

## Decisions

### D1 — El tier Empresa NO es un `Plan`: vive en su propio módulo canónico

Contenido del tier en **`frontend/lib/enterprise-tier.ts`** (constante `ENTERPRISE_TIER`: nombre, precio de display, tagline, bullets, label del CTA), separado de `PLAN_LIMITS` y del tipo `Plan`.

*Alternativa considerada y descartada:* agregar `empresa` a `PLAN_LIMITS` con un flag `contactOnly`. Se rechaza por tres razones concretas, no estéticas: (1) el `satisfies Record<string, { priceMonthly: number, maxUsers: number, maxProducts: number, … }>` obliga a inventar ~17 números para un tier que por definición no los tiene; (2) `PLAN_LIMITS` está documentado como espejo del seed de `plan_limits` en DB — divergir rompe ese contrato y empuja a "completar" la tabla, que es exactamente lo que contaminaría el MRR; (3) cualquier consumidor que derive claves de ese objeto (hoy `usePlanLimits`) empezaría a ver un quinto tier sin límites definidos.

Vive en `lib/` (capa canónica) y no dentro del componente: es contenido testeable sin render y reutilizable si mañana lo consume una tercera superficie.

### D2 — Un solo componente compartido con dos variantes visuales

**`frontend/components/shared/EnterprisePlanCard.tsx`**, presentación pura, props: `whatsappUrl: string` y `variant: "landing" | "app"`. Las clases por variante se resuelven con `cva`; el contenido sale siempre de `ENTERPRISE_TIER`.

*Alternativa descartada:* un componente por superficie. Duplicaría copy, bullets, CTA y atributos del enlace — el patrón exacto que la regla de reutilización del proyecto existe para evitar (la lógica repetida diverge; ya pasó con la criticidad de stock en 5 lugares).

El componente **no lee env vars ni computa URLs**: recibe la URL ya armada. Así la misma pieza sirve en un árbol de cliente (landing) y en uno de servidor (`/planes`) sin arrastrar `process.env` al bundle.

### D3 — Panel a lo ancho debajo de la grilla, no una quinta columna

En ambas superficies la card Empresa se monta **después** de la grilla de 4 planes, ocupando el ancho completo del contenedor (layout horizontal en `md+`, apilado en mobile).

Razones: (1) pasar la landing a `lg:grid-cols-5` angosta cuatro cards que hoy funcionan y que ya cargan hasta 9 bullets; (2) un tier sin precio dentro de una grilla de comparación precio-a-precio invita a comparar lo que no es comparable; (3) en `/planes` deja `PlanComparison` **intacto** — su grid `xl:grid-cols-4`, su `planOrder` y sus tres tests no se tocan, que es el punto de menor riesgo posible junto al motor de checkout.

Corolario de montaje: en `/planes` la card se monta en `app/(dashboard)/planes/page.tsx` como hermana de `PlanComparison`, **no adentro** — `PlanComparison` sigue siendo solo el comparativo comprable.

### D4 — Extender el helper canónico con un mensaje opcional

`aliadataWhatsAppUrl(phone, message = ALIADATA_WHATSAPP_MESSAGE)` + nueva constante exportada en el mismo módulo:

```
ALIADATA_WHATSAPP_MESSAGE_EMPRESA =
  "Hola ALIADATA 👋 Me interesa el plan Empresa. Quiero que adaptemos el sistema a mi negocio."
```

El default preserva el comportamiento de los dos consumidores actuales (FAB y footer) — la no-regresión la prueban sus tests existentes sin modificarlos. Se conserva intacta la validación previa del número: sin número válido devuelve `null`, nunca la URL `wa.me/?text=…` que abre el selector de contactos.

*Alternativa descartada:* armar la URL del tier Empresa con `buildWhatsAppUrl` directamente desde la nueva superficie. Saltearía la validación deliberada del helper y sería el tercer lugar que sabe cómo se arma un link de WhatsApp.

### D5 — El número se resuelve en servidor en las dos superficies

- Landing: `app/page.tsx` ya lee la env var; suma una segunda URL con el mensaje del tier (`enterpriseWhatsAppUrl`) y la pasa a `LandingPageFull`, que la baja a `Pricing()` igual que hoy baja `contactWhatsAppUrl` al `Footer`.
- `/planes`: `app/(dashboard)/planes/page.tsx` ya es Server Component y hace `getUser()`; lee la misma env var y computa la URL ahí.

*Alternativa descartada:* exponer el número como `NEXT_PUBLIC_*`. Metería el número comercial en el bundle de cliente y cambiaría el contrato de una variable ya configurada en producción, sin ganar nada: ambas superficies tienen un ancestro de servidor.

### D6 — Sin número válido, la card no se renderiza

Misma degradación que el FAB. Un CTA de "Hablemos" que no abre nada en una sección de precios es peor que no ofrecer el tier: el visitante interpreta la falla como falta de seriedad justo en el momento de decisión.

*Alternativa descartada:* renderizar la card con el botón deshabilitado o con `href="#"` (lo que hace el footer). El footer puede permitírselo porque su link es secundario dentro de una lista; una card de precios entera cuyo único propósito es el CTA, no.

### D7 — Cada variante usa la paleta de la superficie que la contiene

Variante `app`: exclusivamente tokens semánticos (`bg-card`, `text-foreground`, `text-muted-foreground`, `border-border`, `bg-primary`), verificada en claro y oscuro — igual que `PlanCard`.
Variante `landing`: la paleta `slate/emerald` de la sección `#pricing` (`bg-slate-900`, `text-emerald-400`), que es dark-only por diseño.

Esto **no** es una excepción a la regla de tokens del proyecto: es la regla aplicada a dos design systems que hoy conviven. Usar tokens semánticos en la landing produciría una card clara sobre fondo oscuro en tema claro del visitante. La deuda de unificación queda como OQ-4, fuera de alcance.

### D8 — Guardia explícita contra la contaminación de billing

Un test de guardia afirma que `PLAN_LIMITS` sigue teniendo exactamente las 4 claves conocidas y que el tier Empresa no aparece en el orden de planes de `PlanComparison`. Convierte el límite del change en algo que el CI rompe si alguien lo cruza, en vez de una frase en un documento.

### Copy propuesto (es-AR, voseo)

| Campo | Texto |
|---|---|
| Nombre | **Empresa** |
| Precio | **A medida** (sin período) |
| Tagline | Adaptamos el sistema a la forma de trabajar de tu empresa. |
| Bullet 1 | Más sucursales y usuarios de los que cubre el plan Pro |
| Bullet 2 | Integraciones con los sistemas que ya usás |
| Bullet 3 | Migración de datos y onboarding acompañados |
| Bullet 4 | Soporte prioritario con canal directo |
| CTA (visible) | **Hablemos** |
| CTA (nombre accesible) | Hablemos por WhatsApp sobre el plan Empresa (abre una pestaña nueva) |

Los bullets describen acompañamiento sobre capacidades que ya existen (multi-sucursal, roles internos, exportaciones) y una promesa comercial que se cierra a mano en la conversación; ninguno compromete desarrollo no construido.

## Risks / Trade-offs

- **Alguien "completa" el catálogo agregando `empresa` a `plan_limits` en DB** → el MRR de admin sumaría un precio inventado sobre una población fantasma. Mitigación: D8 (test de guardia), el límite explícito en el proposal y el comentario en `lib/enterprise-tier.ts` que dice por qué no está en `PLAN_LIMITS`.
- **`ALIADATA_WHATSAPP_PHONE` no configurada en el entorno** → la card desaparece silenciosamente y parece que el change no se implementó. Mitigación: verificar la variable en Vercel antes del merge (task explícita) y dejar la degradación documentada en el spec, no como sorpresa.
- **Promesa comercial sin alcance definido** ("a medida") → expectativas que no se pueden cumplir. Mitigación: bullets acotados a lo que existe; el alcance real se acuerda en la conversación de WhatsApp. Ver OQ-1.
- **La sección de precios se alarga en mobile** (5 bloques apilados) → más scroll antes del footer. Mitigación: panel compacto (bullets en 2 columnas desde `md`), verificado en 375 px.
- **Dos paletas conviviendo en un mismo componente** → riesgo de que una variante quede sin mantener. Mitigación: variantes con `cva` en un solo archivo y verificación obligatoria de las dos superficies en ambos temas antes del merge.

## Migration Plan

Sin migraciones, sin backend, sin datos. Deploy por merge a `main` (Vercel). Rollback = revertir el PR; nada persiste ni cambia de forma. Palanca operativa de facto: borrar `ALIADATA_WHATSAPP_PHONE` oculta la card (y también el FAB — no usarla como palanca del tier).

## Open Questions

- **OQ-1 (PO, no bloquea):** ¿cómo se aprovisiona técnicamente una cuenta Empresa cerrada? Hoy no existe un plan `empresa`: presumiblemente Pro + `billing_exempt`. Define qué se promete en la conversación, no el código de este change.
- **OQ-2 (PO, no bloquea):** ¿el mismo WhatsApp para consultas enterprise que para consultas generales? Si el PO quiere separarlos alcanza con una segunda env var; el diseño ya lo admite sin refactor porque el helper recibe el número por parámetro.
- **OQ-3 (PO, decidido con reversa barata):** se monta en las **dos** superficies. La landing capta al que todavía no es usuario; `/planes` capta al usuario que topa los límites de Pro, que es el lead enterprise mejor calificado del sistema. Si el PO prefiere solo landing, se quita una línea de `planes/page.tsx`.
- **OQ-4 (deuda, fuera de alcance):** la landing pública no usa el design system de la app. Mientras convivan, todo componente compartido entre ambas necesita variantes.
