# Design: app-timezone-argentina

## Context

Tres anclajes de "día de negocio" conviven hoy:

| Capa | Anclaje actual | Estado |
|------|----------------|--------|
| SQL — 3 RPCs de reporting (v3-reporting-invariants) | `reporting_local_today()` → `now() AT TIME ZONE 'America/Argentina/Mendoza'` | ✅ canon existente |
| Frontend — `lib/date-range.ts` (dashboard KPIs) | Día calendario **local del browser**, materializado a medianoche UTC | ⚠️ correcto solo si el browser está en ART |
| Frontend — formularios y filtros con `toISOString().split('T')[0]` | Día calendario **UTC** | ❌ corrido 21:00–24:00 ART |
| Edge Functions — fallbacks rolling | `new Date()` del server (UTC) | ❌ ídem |
| Backend FastAPI | Sin cómputo de día de negocio propio relevante (fechas vienen del cliente); AFIP con reglas propias | ⚠️ verificar en sweep |

Restricción de almacenamiento (NO cambia): las filas guardan `date` a **medianoche UTC keyed a una fecha calendario** — la fecha calendario es el dato; el instante es un artefacto del tipo de columna. Todo el reporting filtra por esa fecha calendario. Por eso el fix es "qué fecha calendario elegimos", no "cómo la guardamos".

## Goals / Non-Goals

**Goals:**
- Un único reloj de negocio: el día calendario en `America/Argentina/Mendoza`, independiente del huso del server Y del browser.
- Helpers canónicos por capa con paridad verificada (mismos casos de prueba).
- Migrar los sitios de escritura y de lectura enumerados en el proposal.

**Non-Goals:**
- Cambiar tipos de columna o el esquema de almacenamiento de fechas.
- Timezone por tenant (`organizations.timezone`) — el comentario de `reporting_local_today()` ya lo deja apuntado como evolución futura; hoy 100% de los usuarios son de Mendoza.
- Fechas de comprobantes AFIP/WSFE (reglas de ARCA, zona intocable).
- Nombres de archivo de exportaciones (cosmético).
- Backfill de filas históricas (ver OQ-1).

## Decisions

**D1 — El día argentino se computa con `Intl.DateTimeFormat` (frontend/Deno) y `ZoneInfo` (Python), nunca con offset fijo −3.**
Argentina no tiene DST desde 2009, así que un `-3` hardcodeado funcionaría hoy; pero IANA cuesta lo mismo y si Argentina reintroduce DST (pasó varias veces en su historia) el fix es gratis. Alternativa descartada: librería de fechas nueva (date-fns-tz) — `Intl.DateTimeFormat('en-CA', { timeZone })` da el `YYYY-MM-DD` directo sin dependencia nueva.

**D2 — `lib/date-range.ts` se re-ancla por dentro; su API pública no cambia.**
`utcDayRange`/`utcMonthRange`/`monthKey`/`parseMonthKey` conservan firma y semántica de salida (ventanas materializadas a medianoche UTC, como están guardadas las filas); solo cambia de dónde sale el Y/M/D: de `getFullYear()` local del browser a `argentinaToday()`. Los ~10 call sites existentes no se tocan. Alternativa descartada: helper paralelo nuevo + migrar call sites — más superficie de cambio para el mismo resultado.

**D3 — Un helper por runtime, paridad por test (patrón heredado de `kpi-ia-canonical-revenue`).**
`frontend/lib/date-range.ts` (que absorbe `argentinaToday()`) y `supabase/functions/_shared/argentina-time.ts` duplican la aritmética porque Next y Deno no comparten bundle (mismas razones evaluadas y descartadas en el design de ese change: import cruzado frontend↔_shared, paquete workspace). La paridad se asegura con una tabla de casos compartida en los tests de ambos lados — divergencia = CI rojo. Casos obligatorios: 20:59 ART, 21:00 ART, 23:59 ART, 00:00 ART, cambio de mes en esa franja (30/31 → 1), cambio de año (31-dic 22:00 ART).

**D4 — El path de escritura defaultea al día argentino, y el `max` de los date pickers también.**
En los 3 formularios de operaciones el default y el `max` pasan de día UTC a `argentinaToday()`. Efecto: a las 22:00 ART el formulario defaultea al día correcto (hoy) y deja de ofrecer "mañana" como fecha válida.

**D5 — SQL: sweep de RPCs vigentes con `CURRENT_DATE`/`now()::date` → `reporting_local_today()`.**
Solo definiciones VIGENTES (última migración que define cada función); una sola migración `CREATE OR REPLACE` idempotente. Sin `DROP` (firmas intactas). Si el sweep encuentra 0 sitios, la migración no se crea y se documenta en el PR.

**D6 — Secuencia con `kpi-ia-canonical-revenue`: ese change primero.**
Ambos tocan `buildBusinessSnapshot.ts` y las 4 Edge Functions IA. Aplicar KPIs primero (ya apply-ready) evita conflictos y este change re-ancla ventanas sobre código ya canónico. Los sitios IA de este change se implementan como rebase sobre ese resultado.

## Risks / Trade-offs

- [Los números de "hoy" cambian para usuarios nocturnos] → Es la corrección buscada; documentar en el PR igual que el delta de `v3-reporting-invariants`.
- [Tests existentes que asuman día UTC o browser-local] → El safety net del ciclo TDD (baseline antes de tocar) los detecta; se actualizan con intención explícita, no mecánicamente.
- [Vitest corre en el huso de la máquina/CI (UTC en Actions, ART local)] → Los tests de los helpers fijan instantes absolutos (`Date` construidos de ISO con Z) y afirman el día ART esperado — deterministas en cualquier huso. Prohibido `new Date()` sin argumento en asserts.
- [Duplicación frontend/Deno del helper] → Test de paridad con tabla de casos compartida (D3).
- [Alguna RPC no-reporting usa `CURRENT_DATE` con semántica deliberada (vencimientos, crons)] → El sweep clasifica cada sitio antes de tocar; los deliberados se anotan y se excluyen.

## Migration Plan

1. Helpers + tests de paridad (frontend y `_shared`) — sin comportamiento visible aún.
2. Re-anclaje de `date-range.ts` (cubre dashboard KPIs de una vez).
3. Formularios (escritura) + filtros de lectura frontend.
4. Edge Functions (fallbacks) — después del apply de `kpi-ia-canonical-revenue`.
5. Migración SQL del sweep (si aplica) — `db push` automático al mergear.
Rollback: revert del PR; sin cambios de esquema ni de datos.

## Open Questions

- **OQ-1 (PO)**: filas históricas escritas 21:00–24:00 ART tienen fecha del día siguiente. Se puede re-derivar la fecha correcta desde `created_at` (timestamptz). **Recomendación: NO backfillear** — el delta es chico, tocaría historial contable ya conciliado (cierres de caja, arqueos) y el corte queda documentado. Decisión del PO si prefiere backfill.
- **OQ-2 (PO, futuro)**: cuando exista un tenant fuera de Argentina, `organizations.timezone` por cuenta (ya anticipado en el comentario de `reporting_local_today()`). No bloquea.
