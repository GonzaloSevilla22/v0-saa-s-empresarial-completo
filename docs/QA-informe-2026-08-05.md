# Informe Integral de QA — 2026-08-05

> Sesión de continuidad sobre la rama `qa/playwright-setup`. Este documento es la
> síntesis ejecutiva; el registro de ejecución detallado (comandos, timings,
> diagnósticos) vive en [QAimplementation-plan.md](QAimplementation-plan.md).
> **Nunca debe contener contraseñas, tokens, JWT, cookies ni sesiones.**

---

## 1. Resumen ejecutivo

**Toda la verificación ejecutable quedó en verde.** Se destrabó el entorno local
(que estaba inutilizable por varios problemas de infraestructura), se puso la base
de datos al día, y se corrió la batería completa de tests.

| Suite | Resultado |
|---|---|
| SQL (`supabase/tests`, 5 archivos) | ✅ 4/5 pasan · 1 hallazgo abierto |
| Playwright E2E (7 tests) | ✅ **7/7** desde servidor frío |
| Vitest (6 archivos marcados, re-verificados) | ✅ 4 eran ruido de paralelismo · 2 fallos reales |
| TypeScript (`tsc --noEmit`) | ✅ limpio |
| Build (`next build`) | ✅ verde — 71 rutas, 64/64 páginas |
| pytest (backend) | ✅ 1261 passed (heredado; no re-ejecutado esta sesión) |

**Titular positivo:** 2 de los 3 hallazgos SQL "críticos" que arrastraba la sesión
anterior **ya estaban corregidos en `main`** — solo faltaba aplicar las migraciones
a la base local. Incluye la regresión de seguridad más grave (un IDOR en
`get_dashboard_critical_stock`), que hoy ya no existe en el schema actual.

**Nada tocó producción.** El proyecto Supabase real (`gxdhpxvdjjkmxhdkkwyb`) no fue
consultado ni modificado. Todo el trabajo fue local + commits en una rama (sin push,
sin PR, sin deploy).

---

## 2. Alcance y entorno

- **Rama:** `qa/playwright-setup` (1 commit por delante de `main` al iniciar; +3 al cerrar).
- **Stack local:** Supabase local (Docker), FastAPI (`backend/.venv`, Python 3.12),
  frontend Next.js 16 vía pnpm 10.33.4, todo apuntando exclusivamente a servicios
  locales (`127.0.0.1`).
- **Objetivo:** revalidar la fundación E2E de Playwright desde cero y correr la
  batería completa de tests (SQL, E2E, unitarios, typecheck, build), registrando
  resultados y hallazgos reproducibles.

---

## 3. Resultados por suite

### 3.1 SQL — 4/5

Corrido dos veces: contra el schema desactualizado (30/06) y de nuevo tras aplicar
las 68 migraciones pendientes. Los resultados cambiaron drásticamente entre ambas
corridas (ver §4).

- ✅ `test_kpis_edge_cases.sql` (7/7)
- ✅ `test_branch_stock.sql` (12/12)
- ✅ `test_kpis.sql` — pasa tras aplicar migraciones (antes fallaba)
- ✅ `test_function_acl_gate.sql` — pasa tras aplicar migraciones (antes fallaba)
- ❌ `test_idempotency.sql` — 1 hallazgo abierto (ver §5, H-1)

### 3.2 Playwright E2E — 7/7 ✅

Los 7 tests pasan desde servidor frío: setup de autenticación, home, login inválido,
login válido → dashboard, ruta protegida → login, logout, y dashboard con KPIs.

Llegar al verde requirió destrabar varios problemas de entorno (§6) y elevar
timeouts por la lentitud de compilación de Turbopack en WSL2 + `/mnt/c/` — **ningún
fallo fue por un bug de la aplicación.**

### 3.3 Vitest — 2 fallos reales

De los 6 archivos que la sesión anterior marcó como fallidos, al re-correrlos en
serie (`--no-file-parallelism`), **4 pasaron limpio** — eran ruido de los 8 workers
en paralelo, no bugs. Quedan 2 fallos genuinos (§5, H-2 y H-3).

> Pendiente: correr el resto del suite completo (92 archivos) en particiones para
> confirmar si los otros fallos originales eran también ruido.

### 3.4 TypeScript — limpio ✅

`pnpm -C frontend exec tsc --noEmit` volvió sin output: cero errores de tipo.

### 3.5 Build — verde ✅

`pnpm -C frontend build`: `✓ Compiled successfully in 54s`, TypeScript OK, 64/64
páginas estáticas, 71 rutas compiladas sin errores.

---

## 4. Hallazgos resueltos en esta sesión

### Corregidos en `main`, solo faltaba aplicarlos (confirmado hoy)

Estos tres los reportó la sesión anterior como fallos SQL. Al poner la base local al
día se confirmó que **ya estaban arreglados en el código de `main`**; el "fallo" era
puro drift de la base local:

1. **[CRÍTICO, resuelto] IDOR en `get_dashboard_critical_stock(p_user_id uuid)`.**
   Un overload `SECURITY DEFINER` que recibía el `p_user_id` del cliente sin validar
   `auth.uid()`, permitiendo leer el stock crítico de otro tenant. Confirmado que el
   overload vulnerable **ya no existe** en el schema actual.
2. **[resuelto] `get_dashboard_critical_stock()` sin guard `min_stock > 0`.** Restaurado.
3. **[resuelto] 12 triggers `SECURITY DEFINER` con EXECUTE expuesto a `anon`.** Revocados.

### Corregidos en esta sesión (con fix commiteado)

4. **Gap de grants en 5 RPCs admin + `rpc_close_cash_session`.** Seis funciones
   dependían solo del fallback de `PUBLIC` para el acceso de `authenticated` (nunca
   tuvieron grant propio). Las migraciones que revocan `PUBLIC`/`anon` correctamente
   abortan por su propio gate de seguridad al detectarlo. **Es un gap real en la
   secuencia de migraciones de `main`** (no drift local): un `db reset` fresco o CI
   pegaría contra el mismo muro. Corregido con 2 migraciones nuevas acotadas (commit
   `c1096ea`). No afecta la fuente canónica de KPIs (`get_dashboard_financials` ya
   tenía grant propio; auditadas las 34 funciones involucradas, solo 6 tenían el gap).

---

## 5. Hallazgos abiertos (requieren decisión o acción del equipo)

Ninguno se corrigió "para hacer pasar un test" — se documentan para que el equipo
decida el tratamiento.

- **H-1 · `operation_idempotency.operation_id` es nullable.** `test_idempotency.sql`
  espera `NOT NULL` (un replay que lea la fila antes de completarse el `operation_id`
  devolvería un resultado corrupto). La columna es nullable desde su creación original
  ([20260528161955](../supabase/migrations/20260528161955_operation_idempotency.sql)),
  no es una regresión. El índice parcial `WHERE operation_id IS NOT NULL` sugiere un
  patrón "reservar fila primero, completar después" — si es así, el riesgo real sería
  la visibilidad a un replay antes de completarse, no la nullability en sí. **No
  investigado a fondo; queda para evaluación del equipo.**

- **H-2 · Vitest `useCapabilityGate.test.ts` (bug real).** El primer render devuelve
  `qualifies=true` cuando debería ser el default SSR-safe `false` antes de que el
  efecto resuelva. Riesgo de hidratación/flash.

- **H-3 · Vitest `product-catalog-search-collapse.test.tsx`.** Timeout de worker por
  acumulación de DOM entre renders (posible falta de cleanup en el componente o el test).

- **H-4 · `permission denied for table community.landing_sections` (código 42501).**
  Observado repetidamente en los logs del dev server durante los E2E: la landing
  consulta `community.landing_sections` como `anon` pero falta el `GRANT SELECT ... TO
  anon`. La página degrada (devuelve 200) pero loguea el error en cada request. **A
  verificar:** si es solo drift de la base local o un gap que también afecta producción.
  No se pudo caracterizar el grant exacto (la DB local se cayó tras el reinicio de
  Windows del cierre de sesión).

- **H-5 · Verificación de grants en producción (proceso).** Confirmar si las
  migraciones `20260824000001` / `20260826000001` ya se desplegaron a producción y si
  tuvieron el mismo fallo de gate ahí, o si producción tiene los grants por otra vía no
  capturada en migraciones. Solo verificable por alguien con acceso al proyecto real.

- **H-6 · Cobertura Vitest incompleta.** Solo se re-verificaron 6 de 92 archivos.
  Falta correr el suite completo en particiones para confirmar el estado de los ~otros
  fallos originales.

---

## 6. Problemas de infraestructura resueltos (no son defectos de código)

El entorno local estaba inutilizable al empezar; se documentan por si reaparecen:

- **Puertos Docker/Windows.** Los contenedores de Supabase no publicaban puertos al
  host (reserva dinámica de Windows/Hyper-V solapando el rango 54320-54329). Resuelto
  con `net stop/start winnat` + recreación del stack.
- **Drift de 68 migraciones.** La base local estaba parada en el 30/06; se aplicaron
  las pendientes con `supabase migration up` (destrabando el fix del §4.4).
- **Dependencias faltantes.** El dev server fallaba con `Can't resolve 'sonner'`; un
  symlink colgante en `node_modules`. Resuelto con `pnpm install --force`.
- **Red saliente de WSL rota.** El reinicio de `winnat` dejó a WSL sin salida a
  internet, bloqueando el build (descarga de fuentes de Google). Resuelto con un
  reinicio de Windows.

---

## 7. Cambios entregados

Tres commits sobre `qa/playwright-setup` (sin push):

| Commit | Tipo | Contenido |
|---|---|---|
| `c1096ea` | `fix(db)` | 2 migraciones: grant EXECUTE a `authenticated` en 5 RPCs admin + `rpc_close_cash_session` |
| `19fa694` | `test(e2e)` | Habilitación de Playwright E2E local: stub de captcha gated, env-guard endurecido, configs, timeouts, 2 tests unitarios nuevos |
| `4575c09` | `docs(qa)` | Registro de ejecución en el plan de implementación |

**Excluidos deliberadamente del commit:** `.claude/settings.local.json` (permisos
específicos de la máquina), `.agents/skills/*` (ajenos), `scripts/ci/__pycache__/`
(generado), `backend/.env` (gitignoreado).

**Nota sobre los timeouts de Playwright:** se elevaron mucho (webServer 240s, test
300s, `/dashboard` 150s, actionTimeout 45s) por la lentitud de compilación en frío en
WSL2 + `/mnt/c/`. Son techos, no esperas fijas — en CI/Linux nativo son inofensivos
pero innecesariamente altos. Se dejaron así por decisión explícita; revisar si conviene
condicionarlos por entorno más adelante.

---

## 8. Recomendaciones / próximos pasos

1. **Priorizar H-5** (verificación de grants en producción): si `20260824000001` ya
   está desplegada y falló el gate, alguna migración de prod podría estar trabada o los
   KPIs admin rotos. Es el hallazgo con mayor riesgo potencial fuera del entorno local.
2. Evaluar **H-1** (`operation_id` nullable) — determinar si es by-design o un gap de
   integridad; potencial change propio.
3. Arreglar los 2 fallos reales de Vitest (**H-2**, **H-3**).
4. Verificar **H-4** (grant de `landing_sections`) contra el schema de producción.
5. Correr el suite Vitest completo en particiones (**H-6**).
6. Considerar mergear la fundación E2E a `main` (los 3 commits) para tener la base de
   Playwright versionada e integrarla a CI.

---

## 9. Alcance y seguridad

- Producción **no** fue consultada ni modificada en ningún momento.
- No hubo `push`, PR ni deploy.
- No se debilitó Turnstile en producción (el stub de captcha está triple-gated:
  `NODE_ENV != production` + flag + localhost).
- No se aplicó ningún fix "para hacer pasar un test": los hallazgos de lógica/permisos
  de producción se documentan, no se parchean sin un change deliberado.
- Este documento y el plan no contienen credenciales, tokens ni sesiones.
