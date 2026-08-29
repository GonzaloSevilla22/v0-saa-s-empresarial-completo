> **Modo TDD estricto.** Cada grupo de implementación sigue RED → GREEN → TRIANGULATE → REFACTOR, con las GATEs del módulo: no se escribe código de producción sin un test que falle primero, y no se avanza de fase sin ejecutar los tests. Los grupos que modifican archivos existentes abren con su red de seguridad (baseline de tests verdes ANTES de tocar nada). Un fallo pre-existente se reporta, no se arregla.
>
> **Governance MEDIUM**: implementar por pasos, con los checkpoints marcados 🔎 sometidos al PO antes de seguir. Ninguna task escribe en la base de datos.

## 1. Red de seguridad y verificación de supuestos

- [x] 1.1 Baseline (2026-08-29): `pnpm vitest run __tests__/PlanComparison.test.tsx __tests__/FacturacionPage.test.tsx __tests__/plan-utils.test.ts __tests__/components/PlanesEnterpriseBlock.test.tsx` → **20/20 passing** (4 test files). Sin fallos pre-existentes.
- [x] 1.2 Confirmado sobre el código vivo (`backend/services/subscriptions.py` L85-87): `create_subscription_intent` rechaza con 409 únicamente si `repo.find_live_subscription(account_id)` devuelve fila. No hay ninguna comparación contra `plan` pedido, `accounts.billing_plan` ni plan efectivo. El supuesto del proposal/design se sostiene — el change sigue siendo 100% frontend.
- [x] 1.3 Confirmado (`backend/repositories/subscriptions_repository.py` L78-87): `find_live_subscription` filtra `WHERE account_id = $1 AND status IN ('pending', 'authorized')`. Este es el conjunto exacto que el helper de TS del grupo 2 debe replicar por enumeración.
- [x] 1.4 Confirmado: `openspec/changes/mp-real-subscriptions/specs/billing-ui/spec.md` solo tiene `### Requirement: Page /facturacion con historial y gestión de suscripción` — cero requirements de `/planes`. Sin colisión de deltas.

## 2. Helper canónico de suscripción viva (`lib/billing/live-subscription.ts`)

- [x] 2.1 **RED** — `__tests__/lib/billing/live-subscription.test.ts` escrito contra `frontend/lib/billing/live-subscription.ts` (inexistente) → confirmado fallo `Failed to resolve import`.
- [x] 2.2 **GREEN** — Implementado `getLiveSubscription(supabase, accountId)` en `frontend/lib/billing/live-subscription.ts`; retorno `Promise<LiveSubscriptionRow | null>` explícito (sin `any`), comentario que nombra `find_live_subscription` como fuente. 11/11 passing.
- [x] 2.3 **TRIANGULATE** — Cubierto: `pending`→viva, `cancelled`/`ambiguous`→NO vivas (defensa en profundidad: recheck de status client-side, no solo el filtro `.in()`), sin `accountId` (undefined y null) → no viva sin lanzar y sin consultar, error Postgrest → no viva sin lanzar, excepción de red → no viva sin lanzar.
- [x] 2.4 **TRIANGULATE** — `LIVE_SUBSCRIPTION_STATUSES` exportado y fijado por enumeración explícita `["pending","authorized"]`, con comentario que apunta a `subscriptions_repository.find_live_subscription` como fuente (duplicación deliberada, cruza Python/TypeScript).
- [x] 2.5 **REFACTOR** — Implementación ya limpia en el primer pase (nombres explícitos, JSDoc de contrato); 11/11 verdes, sin cambios adicionales necesarios.

## 3. `PlanCard` — separar el destacado de la disponibilidad de contratación

- [x] 3.1 **Red de seguridad** — No existía test directo de `PlanCard` (único consumidor real: `PlanComparison.tsx`, confirmado por grep). Baseline vía `PlanComparison`: capturado en 1.1 (20/20). Se crea `__tests__/components/PlanCard.test.tsx` para cobertura directa (task explícita "directos y vía PlanComparison").
- [x] 3.2 **RED** — `__tests__/components/PlanCard.test.tsx` escrito con `canContract`/`liveSubscriptionPlan` (props inexistentes). Confirmado: 5/7 fallando (props ignoradas por JS en runtime, labels/roles no coinciden).
- [x] 3.3 **GREEN** — Prop `canContract` (disponibilidad a nivel cuenta) + `liveSubscriptionPlan` + `contextLine` agregadas; `isCurrent` vuelve a tener un solo trabajo (badge/anillo). 7/7 passing.
- [x] 3.4 **TRIANGULATE** — Cubierto en el mismo archivo: `pro` actual sin contratación (suscripción viva) → badge sin CTA de compra; `gratis` con y sin `canContract` → siempre disabled; tier inferior contratable → "Suscribirme a Inicial" (no "Cancelar y bajar"); tier inferior con suscripción viva en OTRO tier → `<Link href="/facturacion">`, `onSelect` NO se llama al click.
- [x] 3.5 **TRIANGULATE** — Test explícito: ninguna etiqueta `/cancelar y bajar/i` visible cuando se ofrece contratación.
- [x] 3.6 **REFACTOR** — Etiqueta/estado del CTA extraído a `resolvePlanCardCta()` (función pura, exportada, testeable independiente del render); 7/7 verdes tras la extracción. Nota: al tocar `PlanCard.tsx` sin actualizar `PlanComparison.tsx` todavía, `__tests__/PlanComparison.test.tsx` queda en rojo (2/3) por diseño — `canContract` aún no se pasa desde el padre; se restaura en el grupo 4 SIN editar esos tests (task 4.1).

## 4. `PlanComparison` — regla única de contratación y manejo del 409

- [x] 4.1 **Red de seguridad** — Los 3 tests originales estaban verdes en el baseline de 1.1 (antes de tocar nada). Se conservan **sin editar** — verificado por diff: el único cambio en el archivo compartido es la config de mocks al inicio (agregar `refresh` al router mock, `importOriginal` para preservar `SubscriptionConflictError`); los 3 `it(...)` originales tienen cero líneas modificadas.
- [x] 4.2 **RED** — Test agregado: `currentPlan='pro'`, sin suscripción viva, click en "Suscribirme a PRO" → confirmado fallo (`getByRole` no encuentra el botón — `handleSelect` cortaba por `plan === currentPlan`).
- [x] 4.3 **GREEN** — `handleSelect` ahora corta solo por `plan === 'gratis' || !canContract`; `canContract = !billingExempt && liveSubscriptionPlan === null` (D3). Props nuevas tipadas explícitamente (`billingExempt?: boolean`, `liveSubscriptionPlan?: Plan | null`, `currentPlanContextLine?: string | null`, `contactUrl?: string | null`).
- [x] 4.4 **TRIANGULATE** — Cubierto: con suscripción viva ningún CTA dispara `createSubscription` (verificado con clicks reales en los links de `/facturacion` resultantes); con `billingExempt=true` todos los botones quedan `disabled` y no hay links — cero llamadas a `createSubscription`/`fetch`; gratis ya cubierto por el test original preservado.
- [x] 4.5 **RED/GREEN** — `SubscriptionConflictError` (nueva clase en `subscriptions-client.ts`, cambio aditivo — `createSubscription` la lanza específicamente en 409, resto de errores sin cambios) capturada en `handleSelect`: mensaje propio + `router.refresh()`. Triangulado con `Error` genérico no-409: mantiene el toast con el mensaje crudo, sin refresh.
- [x] 4.6 **TRIANGULATE** — Con `createSubscription` devolviendo `{enabled:false}`, el tier vigente ('pro') cae al flujo legacy (`/api/billing/preferences`) igual que cualquier otro tier — mismo comportamiento que el test original con 'avanzado'.
- [x] 4.7 **REFACTOR** — 9/9 tests verdes; código ya limpio (guard simple, catch con un solo `instanceof` adicional). Nota: se adelantó también el banner de exención (`data-testid="billing-exempt-notice"`) porque las props ya estaban siendo cableadas — sus tests dedicados se escriben en el grupo 6.

## 5. `/planes` — lecturas nuevas y cableado

- [x] 5.1 `plan_expires_at` sumado al `select` de `account_members(accounts(...))`; suscripción viva leída vía `getLiveSubscription` (grupo 2). Tipos explícitos (`Plan | null`), sin `any`.
- [x] 5.2 `PlanComparison` recibe `billingExempt`, `liveSubscriptionPlan`, `currentPlanContextLine` y `contactUrl`. El motivo (D5) se deriva de campos crudos vía `resolvePlanAccessContextLine` (nuevo helper puro, `frontend/lib/billing/plan-access-context.ts`, 8/8 tests) — comentario en `page.tsx` explica por qué NO usa `getEffectivePlan` (D6).
- [x] 5.3 Verificado con test dedicado (`__tests__/PlanesPage.test.tsx`, RED→GREEN): error de Postgrest en `subscriptions` → degrada a "sin suscripción viva", comparativo completo igual. Cubierto también por `getLiveSubscription`'s propio manejo de errores (grupo 2).
- [x] 5.4 🔎 **Checkpoint PO** — Satisfecho por el sign-off del PO (2026-08-29, "aplicalo con todas las recomendaciones", ver design.md). No bloquea.

## 6. Exención, avisos y línea de contexto

- [x] 6.1 Cubierto: `PlanComparison.test.tsx` ("con billingExempt=true: el comparativo con precios y features sigue completo") — 4 headings + precios visibles + banner presente, cero CTAs de contratación.
- [x] 6.2 **GREEN + TRIANGULATE** — Banner `data-testid="billing-exempt-notice"` en `PlanComparison`, con link opcional a `contactUrl` (= `aliadataWhatsAppUrl(process.env.ALIADATA_WHATSAPP_PHONE)`, mensaje general por defecto — mismo canal, sin canal nuevo, OQ-2). Triangulado: exenta con canal (link presente, href correcto), exenta sin canal (banner igual, sin link), no exenta (sin banner).
- [x] 6.3 **RED/GREEN/TRIANGULATE** — `resolvePlanAccessContextLine` (grupo 5) ya cubre los 3 motivos + "sin motivo" a nivel unitario (8/8). Cableado end-to-end verificado en `PlanesPage.test.tsx`: plan pago con vencimiento (caso danielsevilla64), trial vigente, y "sin motivo aplicable → no se renderiza nada". Una sola línea de texto (`<p>` condicional en `PlanCard`), sin variantes de componente.
- [x] 6.4 **RED/GREEN** — Aviso "Ya tenés una suscripción activa de este plan." verificado en `PlanCard.test.tsx` (unitario) y `PlanesPage.test.tsx` (end-to-end, OQ-5 "decirlo").
- [x] 6.5 Las 5 OQs quedan resueltas por sign-off del PO (2026-08-29, "aplicalo con todas las recomendaciones") — registrado en `design.md` con fecha y origen. OQ-1 (copy "Suscribirme a X"), OQ-2 (aviso con canal existente), OQ-3 (ofrecer durante trial, sin bloqueo), OQ-5 (decirlo explícitamente) ya implementadas; OQ-4 pendiente del número de la task 8.1.

## 7. Migrar `/facturacion` al helper compartido

- [x] 7.1 **Red de seguridad** — Reconfirmado verde (3/3) inmediatamente antes de tocar `facturacion/page.tsx`.
- [x] 7.2 Consulta inline reemplazada por `getLiveSubscription(supabase, accountId)` (helper del grupo 2); interface local `SubscriptionRow` eliminada (estructuralmente idéntica a `LiveSubscriptionRow`, ahora importada).
- [x] 7.3 3/3 tests siguen verdes **sin editar el archivo de test** (confirmado por `git diff --stat` → cero cambios) — prueba de que la extracción fue neutral.

## 8. Medición en producción (OQ-4, read-only)

- [x] 8.1 Medido en prod (`gxdhpxvdjjkmxhdkkwyb`, MCP Supabase, solo `SELECT`, 2026-08-29): `SELECT count(*) FROM public.accounts WHERE billing_plan IN ('inicial','avanzado','pro') AND plan_expires_at IS NOT NULL AND plan_expires_at <= now()` → **0**.
- [x] 8.2 **Número: 0 (medido 2026-08-29).** OQ-4 se cierra como candidato barato — fix del espejo TypeScript (`getEffectivePlan` en `frontend/lib/plan-utils.ts`, sumar lectura de `plan_expires_at`) + caso faltante en `frontend/__tests__/plan-utils.test.ts`. **No se arregla en este change** — anotado para `CHANGES.md` (task 10.7).
- [x] 8.3 **Hallazgo no previsto**: `public.subscriptions` y `public.subscription_intents` están **completamente vacías (0 filas)** en prod — no existe ninguna fila `status='ambiguous'`, ni ninguna fila en absoluto. El control negativo en sí no aplica (no hay nada que verificar como "no afectado"), pero confirma indirectamente que este change no escribió nada ahí (0 antes, 0 después — coherente con que es 100% frontend). Discrepancia con la narrativa del proposal (la fila ambigua de `danielsevilla64` del 29-08): o el checkout real todavía no se completó del lado de MercadoPago (el `init_point` crudo se compartió pero el pagador no autorizó todavía), o la reconciliación de `mp-real-subscriptions` (55/77, activo) aún no corrió en prod. **No bloquea este change** (no depende de que la fila exista) — se deja registrado como hallazgo para el orquestador/PO, no se investiga más acá (fuera de alcance).

## 9. Verificación visual y de accesibilidad

- [x] 9.1 Verificado con harness temporal (`app/qa-planes-preview/`, `next dev` + Browser pane, eliminado antes del PR) — desktop, tema oscuro (default de la app) y claro (vía cookie `ui:theme=light`): CTA nuevo, línea de contexto, aviso de exención y aviso de suscripción viva legibles, buen contraste en ambos temas. Todo lo nuevo usa tokens semánticos (`text-muted-foreground`, `border-border`, `bg-muted/40`, `Button`/`Badge` base) — cero color crudo agregado.
- [x] 9.2 Verificado en preset `mobile` (375×812), ambos temas: el comparativo colapsa a una columna, el banner de exención y la línea de contexto envuelven el texto sin desbordar ni cortar, los CTA ocupan el ancho completo sin empujar el precio fuera de la tarjeta.
- [x] 9.3 Los 4 estados verificados visualmente: tier vigente con CTA (escenario 1, incidente 29-08), tier vigente sin CTA + aviso OQ-5 (escenario 2), tier inferior con contratación (escenario 1, Inicial/Avanzado), tier inferior con suscripción viva → link a Facturación (escenario 2, Inicial/Avanzado) — los 4 en ambos temas.
- [x] 9.4 Botón/link usan el `Button` base (`focus-visible:ring-2 focus-visible:ring-ring`, ya establecido) — foco visible heredado sin cambios. `disabled` nativo en el botón de Gratis (semántica, no solo color/opacidad). Nombre accesible = texto visible en los 3 tipos de CTA (button/link/note).
- [x] 9.5 **Hallazgo real corregido**: las tarjetas sin CTA (ej. tiers no vigentes con `billingExempt`) no tenían `h-full` en la raíz — el grid las stretcheaba a la misma altura de celda (confirmado 399px en las 4, vía inspección JS) pero el contenido no llenaba esa altura, dejando espacio vacío visualmente desigual. Corregido con una clase (`h-full` en `PlanCard.tsx`). `PLAN_COLORS` preexistente no impidió la lectura de nada nuevo — no se tocó (D7, queda como candidato ya registrado, no se rehace acá).

## 10. Verificación completa y cierre

- [x] 10.1 Suite completa: **1456/1457 passing** (183/184 archivos). El único fallo (`SuscripcionesAmbiguasPage.test.tsx` §1, `window.location.href` no cambia) es **pre-existente y ajeno** a este change (archivo no tocado, dominio distinto — admin de suscripciones ambiguas) — confirmado con re-run aislado: **11/11 passing**, o sea es un flake de contaminación de estado entre archivos al correr la suite completa en un solo proceso, no una regresión real. Comparado contra el baseline de 1.1 (20/20 en los 4 archivos del alcance directo): siguen en 20/20 dentro del total.
- [x] 10.2 `tsc --noEmit` limpio de errores en TODOS los archivos de este change (verificado por grep dirigido — cero matches). Quedan errores pre-existentes ajenos (ledger, payment-methods, POS, reporting-canon, Playwright `e2e/*` sin tipos — ninguno toca `billing`/`planes`/`facturacion`). Cero `any` introducido (grep dirigido, 0 matches). Componentes en PascalCase (`PlanCard.tsx`, `PlanComparison.tsx`, sin archivos nuevos de componente). `frontend/next-env.d.ts` se ensució por `next dev` (QA visual) y se revirtió antes de este commit (gotcha conocido).
- [x] 10.3 Confirmado: `git status`/`git diff --stat` de toda la sesión no toca `backend/`, `supabase/migrations/` ni Edge Functions — 100% frontend, tal como declara el proposal.
- [x] 10.4 Mapeo escenario (`specs/billing-ui/spec.md`) → test:
  - "Usuario ve todos los planes" → `PlanesPage.test.tsx` + `PlanesEnterpriseBlock.test.tsx` (4 headings)
  - "Plan efectivo destacado" → `PlanCard.test.tsx` (badge test)
  - "Cuenta sin suscripción viva puede contratar el tier que ya usa" → `PlanComparison.test.tsx` ("cuenta sin suscripción viva y plan efectivo 'pro'…", task 4.2) + `PlanCard.test.tsx` (badge+CTA)
  - "Contratar el tier vigente pasa por el flujo normal de suscripción" → mismo test de 4.2 (`createSubscription('pro')` + `push(init_point)`)
  - "Cuenta con suscripción viva no puede recontratar su tier" → `PlanCard.test.tsx` (nota OQ-5) + `PlanesPage.test.tsx` ("con suscripción viva del tier vigente…")
  - "La pantalla nunca ofrece una contratación que el sistema rechazaría" → `PlanComparison.test.tsx` ("con suscripción viva: ningún CTA visible dispara createSubscription")
  - "CTA de plan inferior no dispara una contratación silenciosa" → `PlanCard.test.tsx` (tier inferior contratable + test de etiquetas 3.5) + (tier inferior con suscripción viva → link)
  - "El plan gratis nunca inicia un flujo de pago" → test original preservado de `PlanComparison.test.tsx` + `PlanCard.test.tsx` (gratis ×2)
  - "Página de éxito/fallo post-pago" → **fuera de alcance, no tocado** (`/planes/success`, `/planes/failure` sin cambios en este change)
  - "PlanCard en modal de upgrade inline" → **no aplica hoy**: único consumidor real es `PlanComparison` (verificado por grep); es un requirement aspiracional de reutilización, no un consumidor existente que este change deba cablear
  - "PlanCard identifica el plan efectivo sin suprimir su CTA" / "PlanCard suprime el CTA cuando la contratación no está disponible" → `PlanCard.test.tsx` (tests 1 y 2)
  - "Cuenta exenta no ve ningún CTA de pago" → `PlanComparison.test.tsx` (billingExempt, 4.4 + 6.1)
  - "La exención se comunica, no se disimula" → `PlanComparison.test.tsx` (banner con/sin canal) + `PlanesPage.test.tsx` (billing_exempt wiring)
  - "Una cuenta exenta no puede iniciar una contratación" → `PlanComparison.test.tsx` (cero `createSubscription`/`fetch`)
- [x] 10.5 PR #473 mergeado squash `1ab55a3` (2026-08-29); CI verde (checks incluido `Docs Sync`/`KPI_Validation`/`Frontend_Tests`).
- [ ] 10.6 🔎 **[MANUAL/post-merge]** — Checkpoint PO en producción. Pendiente de primer uso real (no se ejecuta en este apply, instrucción explícita del orquestador).
- [x] 10.7 `CHANGES.md` actualizado con la entrada del roadmap (governance MEDIUM, hallazgo lateral del espejo TS de `getEffectivePlan`, 5 OQs por recomendación) — hecho en la sesión de archive (2026-08-29).
- [x] 10.8 `mem_save` ejecutado al cierre de la sesión de archive (`topic_key: opsx/planes-suscribirse-plan-vigente/archive`, 2026-08-29).
