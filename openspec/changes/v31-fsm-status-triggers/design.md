## Context

`v3-document-status-history` dejó tres piezas en la base:

- `document_status_transitions` — el catálogo (18 filas, 6 `document_type`, todas con `allowed_role = NULL`).
- `is_valid_transition(document_type, from, to)` — helper `STABLE` que consulta el catálogo, con `GRANT EXECUTE` a `authenticated`.
- `record_status_transition(...)` — helper `SECURITY DEFINER`, revocado de `authenticated`, que valida (`P0409`), exige `reason` si corresponde (`P0400`) e inserta la fila de historial.

La validación vive **dentro de `record_status_transition`**. Eso significa que la FSM se respeta exactamente en la medida en que cada camino de escritura decida llamarla.

### Estado real de los caminos de escritura (verificado 2026-07-30)

| Tabla | Policy `UPDATE` para `authenticated` | Camino de escritura del `status` | ¿Registra historial? |
|---|---|---|---|
| `quotes` | **SÍ** (`quotes_update`, `20260702000001`) | `rpc_accept_quote` (definer) **y** `UPDATE` directo desde `quote_repository.transition_quote` | accept sí; send/reject/expire **no** |
| `sales_orders` | no | `_c29_confirm_order_core` (definer) | sí |
| `fiscal_documents` | no (solo `INSERT`) | `UPDATE` directo del backend con `service_role` + `rpc_record_fiscal_transition` | sí |
| `cash_sessions` | no | `rpc_open/close_cash_session` (definer) | sí |
| `reconciliation_sessions` | no | `rpc_open/close_reconciliation_session` (definer) | sí |
| `stock_transfers` | no | nace `completed`, nunca se actualiza | sí (creación) |

Dos agujeros concretos, no teóricos:

1. **PostgREST sobre `quotes`.** Es la única tabla de documento con policy de `UPDATE` expuesta a `authenticated`. Un cliente puede escribir cualquier `status` que pase el `CHECK` de la columna, saltándose el catálogo.
2. **El pool del backend ignora RLS.** Conecta como `postgres` con `rolbypassrls = true` (H-05, sin remediar). Para el backend, las policies de escritura de las otras cinco tablas **no son una barrera**: cualquier repositorio que emita un `UPDATE ... SET status` lo logra. `quote_repository.transition_quote` ya lo hace.

Además hay **tres definiciones divergentes de la FSM de Quote** conviviendo hoy:

| Transición | spec `quote` | `_VALID_TRANSITIONS` (Python) | catálogo (DB) |
|---|---|---|---|
| `draft→sent` | ✓ | ✓ | ✓ |
| `draft→expired` | ✓ | ✓ | ✓ |
| `draft→accepted` | ✗ | vía RPC | ✓ |
| `draft→rejected` | ✗ | ✗ | ✓ |
| `sent→accepted` | ✓ | vía RPC | ✓ |
| `sent→rejected` | ✓ | ✓ | ✓ |
| `sent→expired` | ✓ | ✓ | ✓ |

El catálogo es un **superconjunto** de las otras dos. Eso importa para la compatibilidad (ver D5) y es un hallazgo que este change documenta pero no resuelve.

**Restricción de plataforma**: la integración GitHub de Supabase auto-aplica las migraciones al mergear, **antes** del `db push` de Actions. Toda migración debe ser re-ejecutable sin error.

## Goals / Non-Goals

**Goals:**
- Que la matriz de transiciones ya catalogada sea **inevadible**: ningún camino de escritura —PostgREST, backend con `BYPASSRLS`, `service_role`, psql— puede mover un documento a un estado no catalogado.
- Que el enforcement no dependa de que el escritor "se porte bien", que es la única garantía que existe hoy.
- Que `v3-rbac-multirole` pueda poblar `allowed_role` sobre una base donde la dimensión `(from, to)` ya se cumple de verdad.
- Cero cambio de comportamiento en los flujos de producción vigentes.

**Non-Goals:**
- **La matriz rol × transición (RN-A4) NO está acá.** Poblar `allowed_role` y validar el rol del actor es `v3-rbac-multirole` (CRÍTICO, con sign-off propio). Este change solo hace inevadible la matriz `(document_type, from, to)` **existente**. Decisión firmada por el PO el 2026-07-30.
- **El gancho maker-checker (`requires_second_approval`) NO va acá** — vive en el DDL del pivot de `v3-rbac-multirole` (sign-off 2026-07-30).
- **No** se completa el historial de las transiciones de Quote que hoy no registran (`send`/`reject`/`expire`) — ver G1 en Gaps conocidos.
- **No** se reconcilian las tres definiciones divergentes de la FSM de Quote — ver G2.
- **No** se toca RLS, ni el pool, ni `BYPASSRLS` (`v31-tenancy-pool-rls`).
- **No** se agrega FSM a `purchases`, que hoy no está en el catálogo — ver G4.

## Decisions

### D1 — El trigger **valida y no registra**

Ésta es la decisión central del change y la que el brief pide justificar explícitamente. El trigger es un **guard**; `record_status_transition` sigue siendo el **único registrador**. Tres razones, en orden de peso:

1. **Duplicaría el historial de forma irreparable.** Los 9 RPCs retrofiteados llaman `record_status_transition` y *después* (o antes) emiten el `UPDATE`. Si el trigger también registrara, cada transición de negocio produciría **dos** filas. Y `document_status_history` es append-only por diseño estructural: `UPDATE`/`DELETE` están revocados y no hay policy de escritura (RN-A3). Limpiar filas duplicadas exigiría una migración que rompa la propia invariante que la tabla existe para garantizar.

2. **El trigger no puede conocer el `reason` (RN-A5).** El motivo es contexto de negocio, no de fila: `rpc_close_cash_session` lo genera a partir de la diferencia de arqueo, `rpc_close_reconciliation_session` lo exige del usuario, el relay CAE usa el `last_error` de ARCA. Un trigger `BEFORE UPDATE` solo ve `OLD`/`NEW` y registraría siempre `reason = NULL` — violando RN-A5 en silencio justamente en las transiciones donde el motivo es la señal antifraude.

3. **Separación de responsabilidades.** Un guard que además escribe es un guard que puede fallar por razones que no son "la transición es inválida", y vuelve el diagnóstico ambiguo. Validar es idempotente y sin efectos; registrar no.

**Consecuencia asumida**: las transiciones que hoy no registran historial (Quote `send`/`reject`/`expire`) siguen sin registrarlo. El trigger las valida, pero no las hace visibles en el timeline. Es un gap real, explícito, y con follow-up nombrado (G1). **No** se cierra acá porque exige convertir `transition_quote` en un RPC definer y tocar la spec de `quote` — otro change, otro diff.

### D2 — Una función genérica parametrizada, no seis funciones

```
CREATE OR REPLACE FUNCTION public.trg_enforce_status_transition() RETURNS trigger ...
-- p_document_type llega por TG_ARGV[0]

CREATE TRIGGER <tabla>_enforce_status_transition
  BEFORE UPDATE ON public.<tabla>
  FOR EACH ROW
  WHEN (OLD.status IS DISTINCT FROM NEW.status)
  EXECUTE FUNCTION public.trg_enforce_status_transition('<document_type>');
```

Una sola función; el mapeo tabla → `document_type` vive en la definición de cada trigger. **Por qué no seis funciones**: seis copias de la misma lógica es seis lugares donde arreglar el próximo bug, y la spec de `document-status-history` es explícita en que la política vive como datos y no como condicionales dispersos — replicarla seis veces en PL/pgSQL sería exactamente eso.

La cláusula `WHEN (OLD.status IS DISTINCT FROM NEW.status)` es la que evita el falso positivo más obvio: `_c29_confirm_order_core` actualiza `total`, `sale_operation_id` y `fiscal_document_id` en el mismo `UPDATE` que el `status`; `rpc_close_cash_session` actualiza seis columnas de arqueo. Y los `UPDATE` que **no** tocan `status` sobre documentos terminales (agregar un `cae`, corregir un `total`) ni siquiera invocan la función — es también la opción más barata, porque `WHEN` se evalúa antes de entrar a PL/pgSQL.

La función delega en `is_valid_transition()` en vez de re-consultar el catálogo: un solo predicado, ya probado, ya usado por `record_status_transition`. Si mañana la semántica de "transición válida" cambia, cambia en un solo lugar.

### D3 — `SECURITY DEFINER` con `search_path` fijo

La función se declara `SECURITY DEFINER SET search_path = public`, igual que el resto de los helpers del change original.

**Por qué DEFINER**: la validación no debe depender de los privilegios de lectura que tenga el rol que ejecuta el `UPDATE` sobre `document_status_transitions`. Si un rol futuro perdiera el `SELECT` sobre el catálogo, un trigger `INVOKER` fallaría con un error de privilegios en vez de validar — convirtiendo un guard en una fuente de caídas. Con `DEFINER` el guard funciona igual para `authenticated`, `service_role` y `postgres`.

**Por qué no es una escalada de privilegios**: la función solo lee un catálogo global de solo lectura (`REVOKE INSERT, UPDATE, DELETE ... FROM authenticated, anon`, policy `SELECT USING (true)`) y en el peor caso emite un `RAISE EXCEPTION`. No escribe, no acepta entrada del usuario más allá de los valores de `status` que ya pasaron el `CHECK` de la columna, y `search_path` fijo cierra el vector de shadowing de `public`.

### D4 — **Sin GUC de bypass**. El único escape es deshabilitar el trigger en una migración

El brief pide decidir si hay excepciones (jobs de sistema, backfills) y con qué mecanismo. La decisión es **no agregar ninguna excepción en runtime**.

**Por qué no un GUC** (`app.fsm_bypass`, o similar): el escritor que más necesita ser contenido es el pool del backend, que corre como `postgres`. Cualquier GUC que el pool pueda setear con `SET LOCAL` es un GUC que un bug en un repositorio puede setear sin querer — y reintroduciríamos exactamente la evadibilidad que el change existe para eliminar, solo que con una llave y sin auditoría. Peor: un bypass alcanzable desde el proceso que hoy ya ignora RLS deja al sistema sin **ninguna** barrera efectiva.

**Cuál es el escape entonces**: para un backfill o una corrección de datos legítima, la migración correspondiente hace

```
ALTER TABLE public.<tabla> DISABLE TRIGGER <tabla>_enforce_status_transition;
-- ... el UPDATE excepcional, con su justificación en comentario ...
ALTER TABLE public.<tabla> ENABLE TRIGGER <tabla>_enforce_status_transition;
```

Tres propiedades que un GUC no tiene: exige **ownership de la tabla** (no lo puede hacer `authenticated`), es **visible en el diff del PR** (alguien lo revisa antes de mergear), y está **acotado a esa migración** (no queda una puerta abierta para el runtime). Postgres además ofrece `session_replication_role = 'replica'` como escape de superusuario para restores completos, sin que tengamos que construir nada.

**Alternativa descartada**: eximir a `service_role`. Sería cómodo (el relay CAE y los jobs corren así) pero rompe el invariante central — el relay CAE ejecuta transiciones **catalogadas** (`pending_cae→authorized|rejected`), así que no necesita la exención, y concedérsela abriría un boquete permanente por comodidad futura.

### D5 — El trigger es un **techo**, no un piso

El trigger define el conjunto **máximo** de transiciones posibles; no obliga a que la aplicación permita todas. Los guards de aplicación pueden ser —y son— más estrictos: `_VALID_TRANSITIONS` en `backend/services/quotes.py` no permite `draft→rejected`, que el catálogo sí tiene.

Esto es lo que garantiza **cero cambio de comportamiento**: como el catálogo es un superconjunto de lo que la aplicación ejecuta hoy (tabla de la sección Context, verificada camino por camino), ninguna operación vigente pasa a fallar. Lo que cambia es que las operaciones **no previstas** ahora fallan.

Corolario para `v3-rbac-multirole`: cuando se pueble `allowed_role`, el enforcement por rol seguirá viviendo en `record_status_transition` (que conoce al actor). Este trigger no valida rol — no lo intenta y no debería: `BEFORE UPDATE` no tiene forma confiable de saber en nombre de quién corre cuando el escritor es el pool con `BYPASSRLS` y `auth.uid()` es NULL.

### D6 — Cobertura: las 6 tablas del catálogo, incluida `stock_transfers`

Se cubren los 6 `document_type` del `CHECK` de `document_status_history`. `stock_transfers` se incluye aunque su `CHECK` de columna hoy admite un único valor (`'completed'`), lo que hace al trigger inerte: la uniformidad vale más que ahorrar una línea, y el día que se habiliten `dispatched`/`received` (que el enum ya contempla) el guard está puesto en vez de olvidado.

Tablas explícitamente **fuera**: `branches.status` (no es un documento, es el ciclo de vida de una sucursal), `reconciliation_matches.status`, `bank_movements.reconciliation_status`. Ninguna es un `document_type` del catálogo.

### D7 — `ERRCODE P0409`, reutilizado a propósito

El trigger levanta `P0409`, el mismo que usa `record_status_transition` para una transición no catalogada. **Por qué reutilizarlo en vez de inventar uno nuevo**: el mapeo de errores del backend ya traduce `P0409` a HTTP 409 (`backend/services/quotes.py::_map_postgres_error` y equivalentes). Reutilizarlo hace que un rechazo del trigger llegue al cliente como un conflicto de estado bien formado **sin tocar una línea de Python**. Un código nuevo obligaría a modificar cada mapeador — más diff, más superficie, cero beneficio. El mensaje del error distingue el origen (`fsm_violation` con tabla, `from` y `to`) para que el diagnóstico no sea ambiguo.

### D8 — Gates de comportamiento en la migración (patrón vigente)

La migración cierra con un bloque `DO $$` en dos partes, siguiendo el patrón ya usado por `v3-document-status-history` y `bank-reconciliation`:

- **Estructurales (siempre)**: los 6 triggers existen sobre las 6 tablas y apuntan a la función; la función existe con `prosecdef = true`; el `CHECK` de `operation_idempotency.operation_kind` **no** cambió (gate negativo, lección C3); el catálogo sigue teniendo sus 18 filas.
- **De comportamiento (solo con `accounts` vacía = CI)**: con un anchor sintético, un `UPDATE` de `quotes` a un estado no catalogado debe abortar con `P0409`; un `UPDATE` a un estado catalogado debe tener éxito; y un `UPDATE` que **no** toca `status` sobre un documento terminal debe tener éxito. Este último es el gate que protege contra el falso positivo más caro.

Cada gate degrada con `RAISE NOTICE` salvo su propio `GATE (x) FAILED`, que sí aborta — igual que los existentes, para que un entorno con datos no rompa el despliegue por un gate pensado para base vacía.

## Gaps conocidos (documentados, fuera de alcance)

- **G1 — Quote `send`/`reject`/`expire` no registran historial.** Van por `UPDATE` directo sin `record_status_transition`, así que el timeline del presupuesto tiene un hueco entre la creación y la aceptación. La spec vigente de `quote` solo exige historial de creación y de `accepted`, así que **no** es una violación de spec hoy — pero sí es incompleto respecto de RN-A1. Cerrarlo exige convertir `transition_quote` en un RPC `SECURITY DEFINER` que valide, registre y actualice, y un delta sobre la spec de `quote`. **Follow-up nombrado**, no scope de este change.
- **G2 — Tres definiciones divergentes de la FSM de Quote** (tabla en Context). El trigger convierte al catálogo en el techo; el diccionario Python, al ser más estricto, sigue mandando en la práctica. No hay cambio observable, pero mantener tres fuentes es deuda. Reconciliarlas (idealmente: la aplicación consulta `is_valid_transition` en vez de su propio dict) es follow-up.
- **G3 — `sales_order → canceled`** está en el `CHECK` de la columna pero **no** en el catálogo (decisión D6 del change original: no se siembra lo que ningún RPC ejecuta). Tras este change, un `UPDATE` a `canceled` sería rechazado por el trigger. Hoy nadie lo ejecuta. El change que introduzca la anulación (`v31-sales-delete-rpc-reversal`, H-10) **deberá sembrar la fila del catálogo en su propia migración** — queda anotado acá para que no se descubra en producción.
- **G4 — `purchases` no tiene FSM** en `document_status_transitions` (no es uno de los 6 `document_type`). Queda fuera; la regla RN-A4 "STOCK ajusta con motivo pero no confirma compras" no tendrá dónde aplicarse hasta que compras entre al patrón.

## Risks / Trade-offs

- **[Un falso positivo bloquea una operación de negocio real — ventas, caja o CAE]** → Es el riesgo dominante y la razón del governance ALTO. Mitigación en tres capas: (a) la cláusula `WHEN` hace que el trigger ni se invoque si `status` no cambia; (b) se verificó camino por camino que las transiciones vigentes están catalogadas (tabla en Context) **antes** de escribir la migración, y hay una tarea bloqueante que lo re-verifica contra los datos de producción; (c) el gate de comportamiento en CI comprueba explícitamente que una transición válida sigue pasando, no solo que una inválida falla.

- **[Filas de producción en estados desde los que ningún `UPDATE` catalogado sale]** → Un documento en un estado no previsto quedaría congelado. No se detectó ninguno en la revisión de los `CHECK` de columna, pero es una tarea bloqueante del apply: consultar la distribución real de `status` por tabla en prod (read-only) y contrastarla contra el catálogo **antes** de mergear. Si aparece un estado huérfano, se siembra su transición o se documenta por qué debe quedar congelado.

- **[Costo por `UPDATE` en el camino caliente]** → `_c29_confirm_order_core` es el hot path del POS. El sobrecosto es una llamada a `is_valid_transition`, un `EXISTS` sobre una tabla de 18 filas que Postgres mantiene en caché, y solo cuando `status` cambia (una vez por venta). Despreciable frente al resto de la transacción (stock, caja, fiscal, outbox). Aun así se mide en el gate de CI para no asumirlo.

- **[Doble validación: el RPC valida y el trigger vuelve a validar]** → Redundancia deliberada. El costo es el `EXISTS` de arriba; el beneficio es que el guard cubre también a los escritores que **no** pasan por un RPC, que son precisamente el motivo del change. Un `P0409` puede ahora provenir de dos capas, por eso el mensaje del trigger identifica su origen (D7).

- **[Migración re-aplicada por la integración GitHub de Supabase]** → `CREATE OR REPLACE FUNCTION` + `DROP TRIGGER IF EXISTS` antes de cada `CREATE TRIGGER` la hacen re-ejecutable sin error. Se verifica ejecutándola dos veces seguidas sobre una base local antes de abrir el PR.

- **[Alguien "resuelve" un bloqueo futuro deshabilitando el trigger y no lo vuelve a habilitar]** → El gate estructural de la migración verifica que los 6 triggers existen, pero **no** que estén habilitados. Se agrega la verificación de `tgenabled` al gate estructural para que un trigger deshabilitado y olvidado rompa CI en el próximo PR.

## Migration Plan

Una migración nueva, con timestamp posterior a la última vigente. Contiene: la función genérica, los 6 triggers, y el bloque `DO $$` de gates. Sin DDL de tablas, sin cambios de RLS, sin tocar RPCs.

Aplicación: al mergear a main. **Nunca** `db push` manual ni el MCP `apply_migration` (desincroniza el historial). Ojo con el orden real: la integración GitHub de Supabase auto-aplica al mergear, **antes** del `db push` del workflow de Actions — de ahí el requisito de idempotencia.

**Rollback**: `DROP TRIGGER IF EXISTS <tabla>_enforce_status_transition ON public.<tabla>;` para las 6 tablas, y luego `DROP FUNCTION IF EXISTS public.trg_enforce_status_transition();`. Sin pérdida de datos: el trigger solo valida, no escribe nada. El rollback devuelve exactamente el estado actual. La secuencia completa va comentada en la cabecera de la migración, como en el resto del proyecto.

**Verificación post-merge (read-only, MCP)**: los 6 triggers presentes y habilitados (`tgenabled = 'O'`); la función con `prosecdef = true`; el catálogo intacto en 18 filas; y una prueba negativa dentro de una transacción con `ROLLBACK` sobre un documento real, confirmando que una transición no catalogada aborta con `P0409`.

## Open Questions

Ninguna que requiera decisión del PO. Las tres decisiones que podrían haberla requerido ya están firmadas (sign-off 2026-07-30) y este change las respeta: la matriz rol×transición queda para `v3-rbac-multirole`, el gancho maker-checker va en el DDL del pivot, y esta secuencia va primero sin gate crítico adicional.

Las decisiones técnicas propias del change —trigger que valida y no registra (D1), y ausencia de mecanismo de bypass en runtime (D4)— se resuelven acá con su justificación, sin escalar. Los cuatro gaps conocidos (G1–G4) están documentados como follow-ups, no como preguntas abiertas: ninguno bloquea este change ni exige una decisión antes de implementarlo.
