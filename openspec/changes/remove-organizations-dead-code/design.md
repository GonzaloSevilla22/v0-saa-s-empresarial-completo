## Context

El dominio `organizations` nació en C-16 (`v2-api-migration`, 2026-06-07) como uno de los 8 dominios que se migraron del acceso directo a Supabase hacia el backend FastAPI. A diferencia de los otros 7, este nunca tuvo una tabla detrás: `OrganizationRepository` emite `SELECT * FROM organizations` y `UPDATE organizations SET ...`, y la tabla `organizations` **no existe** en el proyecto Supabase de producción (`gxdhpxvdjjkmxhdkkwyb`). Lo que sí existe es `companies` (la organización legacy pre-V2) y `accounts` (la raíz de tenancy adoptada en C-19 `v2-tenancy-cleanup`).

Consecuencia: los dos endpoints del dominio (`GET /organizations/{org_id}` y `PUT /organizations/{org_id}/settings`) devuelven 500 por `asyncpg.UndefinedTableError` desde el día uno. La condición estuvo oculta porque `backend/tests/test_organizations.py` (62 líneas, 4 tests) mockea el repositorio completo: los tests verifican el contrato router→service sin tocar la base, por eso siempre estuvieron en verde.

En el frontend la situación es análoga pero más benigna: `frontend/hooks/data/use-organizations.ts` (65 líneas) exporta `useOrganization` y `useUpdateOrganization`, y **ningún componente ni página los importa**. El único importador en todo el repo es `frontend/__tests__/hooks/use-clients-purchases-branches-stock-orgs.test.ts`. Es decir, el hook existe únicamente para que su test pase.

Cuatro specs vigentes describen este dominio como si fuera operativo (`python-backend`, `data-api-endpoints`, `domain-repositories`, `domain-react-query-hooks`), lo que convierte a la fuente de verdad del proyecto en una fuente de error para cualquier agente que la lea.

Nivel de governance: **MEDIUM** (toca backend y frontend, pero ninguna lógica de auth, billing ni RLS; el código eliminado nunca funcionó).

## Goals / Non-Goals

**Goals:**
- Eliminar la cadena completa del dominio `organizations` (backend y frontend) sin dejar imports colgados ni referencias huérfanas.
- Alinear las 4 specs afectadas con la realidad post-eliminación: conteos y listas de dominios correctos.
- Mantener las suites de tests verdes con un delta de conteo esperado y documentado (backend −4, frontend −3).
- Dejar registrado el motivo del borrado para que nadie reintroduzca el dominio "porque falta en la lista de 8".

**Non-Goals:**
- **NO** se crea la tabla `organizations` ni se re-apunta el repositorio a `companies` o `accounts` (ver Decisión 1).
- **NO** se toca el dominio de tenancy real: `accounts`, `branches`, RLS, claims del JWT ni el hook de autorización quedan intactos.
- **NO** se elimina `companies` ni ninguna referencia legacy a esa tabla — es un tema separado, ligado a RN-97 y al roadmap de limpieza de legacy.
- **NO** se agrega una funcionalidad de "settings de la cuenta". Si el producto llega a necesitarla, será un change propio con su propia spec, su propio consumidor y su propio modelo de datos.
- **NO** hay migraciones SQL en este change.

## Decisions

### Decisión 1: Eliminar, no re-apuntar a `companies`

**Elegido:** borrar los 5 archivos de backend, el hook de frontend y sus registros/keys.

**Alternativa rechazada — re-apuntar `OrganizationRepository` a `companies` (o a `accounts`):** habría "arreglado" el 500 con un cambio de una línea en el `FROM`, pero el resultado sería peor que el problema:

1. **Escritura sin consumidor.** `update_settings` construye un `UPDATE` dinámico (`SET` armado por interpolación de nombres de campo del payload) contra la tabla que actúa como raíz de tenancy. Habilitar ese camino de escritura sobre `accounts`/`companies` sin ningún consumidor que lo pida es abrir superficie de ataque a cambio de cero valor de producto.
2. **Sin cobertura real.** Los tests actuales mockean el repo; re-apuntar no agrega ni una sola verificación contra la tabla verdadera. Quedaría exactamente el mismo agujero que ocultó el bug 8 semanas.
3. **Semántica ambigua.** `companies` es legacy y `accounts` ya tiene su propio lenguaje de dominio en V2/V3. Un dominio llamado `organizations` conviviendo con `accounts` reintroduce el vocabulario que C-19 justamente unificó.
4. **YAGNI.** Nadie pidió el endpoint. El día que se necesite editar los datos de la cuenta, el change correspondiente definirá qué campos son editables, con qué rol y con qué validación — decisiones que hoy no existen.

Borrar es reversible: el código queda en el historial de git y este documento explica dónde estaba y por qué se fue.

### Decisión 2: Borrar los tests junto con el código que cubren

El proyecto opera en modo TDD estricto, donde la regla habitual es "no toques los tests para que pase el código". En un borrado la regla se invierte: un test que ejercita código eliminado no puede sobrevivir. `backend/tests/test_organizations.py` se elimina completo (los 4 tests cubren exclusivamente el router/service borrado). En el frontend el archivo de test es **compartido** con otros cuatro hooks, así que se quitan solamente el import y los dos bloques `describe` (`useOrganization`, `useUpdateOrganization`) y se conservan intactos los de `useClients`, `usePurchases`, `useBranches` y `useStock`.

La red de seguridad del borrado es el **conteo esperado**: se corre la suite completa ANTES (backend ~1023+, frontend ~443+ según el estado de la rama) y DESPUÉS, y el único delta admisible es `−4` backend y `−3` frontend, con cero fallos nuevos. Cualquier otro delta indica que se borró de más.

### Decisión 3: El archivo de test de frontend conserva su nombre

`use-clients-purchases-branches-stock-orgs.test.ts` quedará con un `-orgs` en el nombre que ya no corresponde. Se decide **no renombrarlo** en este change: el rename no aporta valor funcional, ensucia el diff (git lo puede mostrar como delete+add) y el nombre es puramente descriptivo. Si molesta, es un rename trivial en un change de higiene posterior. Ningún archivo del repo referencia ese nombre (verificado por grep), así que la decisión no tiene efectos colaterales en ninguna dirección.

### Decisión 4: El `Purpose` de las specs se corrige a mano en el archive

Los delta specs de OpenSpec solo expresan operaciones sobre **requirements**; la sección `## Purpose` de un spec no se sincroniza automáticamente. Tres de las cuatro specs afectadas mencionan `organizations` también en su `Purpose` (`data-api-endpoints`, `domain-repositories` y — vía el conteo de dominios — la narrativa general). Por eso `tasks.md` incluye una tarea explícita de edición manual del `Purpose` en `openspec/specs/<capability>/spec.md` durante el archive, después de que el sync haya aplicado los requirements. Sin esa tarea el borrado quedaría a medias en la fuente de verdad.

Detalle a favor: el escenario "Query interna usa account_id como filtro, no user_id" de `domain-repositories` ya decía **"los 7 repositorios"** mientras el requirement listaba 8. Tras este change la spec queda internamente consistente por primera vez.

### Decisión 5: Orden de ejecución backend → frontend → specs

Se ejecuta primero el backend (elimina la causa raíz: los endpoints 500), después el frontend (elimina al consumidor fantasma) y por último se verifica el conjunto. El orden inverso también funcionaría porque no hay acoplamiento real entre las dos capas — el hook llama por HTTP, no por import — pero mantener este orden hace que cada commit intermedio sea coherente por sí mismo si el reviewer quiere leer el PR por partes.

## Risks / Trade-offs

- **[Riesgo] Existe un consumidor externo desconocido de `/organizations/*` (script, integración, cliente móvil).** → Mitigación: es imposible por construcción — el endpoint devuelve HTTP 500 por tabla inexistente desde su creación en C-16; cualquier consumidor real habría reportado el fallo hace semanas. La búsqueda por `grep` sobre todo el repo confirma que el único importador del hook es su propio test.

- **[Riesgo] Un import huérfano rompe el arranque de la app (`backend/main.py` importa un módulo borrado).** → Mitigación: el import y el `include_router` se eliminan en el mismo commit que los archivos; la suite de backend levanta la app vía `TestClient`, de modo que un import roto falla inmediatamente y de forma ruidosa en la primera prueba que corra.

- **[Riesgo] La caída del conteo de tests se lee como una regresión en el CI o en la revisión.** → Mitigación: el delta exacto (`−4` backend, `−3` frontend) queda escrito en `tasks.md` y en el cuerpo del PR; se exige "cero fallos nuevos" como criterio, no "mismo conteo".

- **[Riesgo] Alguien reintroduce el dominio al ver "8 dominios" en documentación vieja (CHANGES.md, knowledge-base, changes archivados).** → Mitigación: las 4 specs vigentes — que son la fuente de verdad que leen los agentes — quedan corregidas; los changes archivados son registro histórico y no se editan. Este `design.md` documenta el motivo del borrado para que quede rastreable desde el historial de OpenSpec.

- **[Trade-off] Se pierde el "esqueleto listo" por si mañana hace falta un endpoint de settings de cuenta.** → Aceptado: el esqueleto apunta a una tabla que no existe y usa un `UPDATE` dinámico que no querríamos copiar tal cual. Reescribirlo bien cuando haya un requisito real cuesta menos que mantener código muerto que induce a error.

- **[Trade-off] El nombre del archivo de test de frontend queda desalineado (`-orgs`).** → Aceptado conscientemente (Decisión 3).

## Migration Plan

No hay migración de datos ni de esquema: **cero migraciones SQL**. El despliegue es el pipeline normal del proyecto (merge a `main` → GitHub Actions → deploy Vercel del frontend + redeploy del backend en Render).

**Rollback:** `git revert` del PR. Al no haber cambios de esquema ni de datos, el revert es total e instantáneo; lo único que se restauraría son dos endpoints que devuelven 500.

## Open Questions

Ninguna que bloquee la implementación. Queda anotada, fuera de alcance, una pregunta de producto para el PO: si en algún momento se quiere una pantalla de "datos de la cuenta" editable (razón social, datos de contacto), eso requerirá un change propio sobre `accounts` con su modelo de permisos por rol — no es la resurrección de este dominio.
