# sucursal-guard-vaciado-auditoria — Design

## Context

### Lo que pasó (incidente real, 22→24 de agosto de 2026)

Una usuaria owner creó dos sucursales el 22-08 y desactivó la original desde la papelera de `/sucursales`. La original tenía 518 productos / 585 unidades. La baja se aceptó sin chistar.

La resolución de la sucursal por defecto de una cuenta toma *la más antigua que esté activa y abierta*, con caída a *la más antigua a secas* si no hay ninguna. Al quedar la original inactiva, el primer criterio pasó a devolver una sucursal nueva con 13 productos. Todas las ventas empezaron a descontar de ahí y fallaban con falta de stock, mientras el módulo de Stock seguía mostrando el total del catálogo (que suma todas las sucursales). Dos días invendible. Reparado a mano el 24-08: 518 transferencias completadas y baja definitiva de la sucursal ya vacía.

### Estado actual verificado (repositorio + producción, al proponer)

**Cuatro caminos de baja, un solo guard mal ubicado.**

| Camino | Qué hace | Guard de stock hoy |
|---|---|---|
| Comando de desactivación (`rpc_deactivate_branch`) — botón papelera de `/sucursales` | `is_active = FALSE` | **Ninguno**. Sólo verifica existencia y rol de escritura. Definición viva en producción capturada y **idéntica** al archivo de migración local. |
| Comando de cierre (`rpc_close_branch`) — botón "Cerrar" | `status = 'closed'` | **Sí** (`branch_has_stock`, `P0409`) — más "última sucursal operativa". |
| Actualización directa del backend (`BranchRepository.update`) — `PUT /branches/{id}` | `UPDATE branches SET …` construido dinámicamente sobre las claves del payload | **Ninguno**. Hoy el modelo de entrada sólo admite el nombre, así que no llega a apagar la sucursal — pero la consulta es genérica y bastaría con ampliar el modelo para abrirlo. |
| Escritura directa desde el navegador vía las políticas de fila | `UPDATE` y **`DELETE`** habilitados para owner/admin de la cuenta | **Ninguno**. |

El guard existente está en el camino que **no** se usó, y el camino que sí se usó no tiene ninguno. Esa asimetría es el bug.

**El borrado físico es peor que la desactivación.** Las claves foráneas que apuntan a la sucursal se reparten en tres comportamientos: **cascada** (inventario por sucursal, cajas, ambos extremos del historial de transferencias) — se borran sin dejar rastro; **anulación** (ventas, compras, gastos, movimientos de stock, presupuestos, puntos de venta, notificaciones) — pierden la imputación; y **sin acción** (pedidos, movimientos bancarios) — hacen fallar el borrado con un error de integridad ilegible. Es decir: hoy el borrado físico o destruye el inventario en silencio o revienta con un mensaje que no le dice nada a nadie, según qué haya en la cuenta.

**Autoría: no existe.** `branches` tiene `id, account_id, name, address, is_active, created_at, status, opened_at, closed_at`. Ni `created_by`, ni `updated_by`, ni autor de la baja. El log de auditoría de la plataforma no recibe nada del ciclo de vida de sucursales.

**La transferencia existe y es buena.** El diálogo de transferencia y su comando ya funcionan (518 filas completadas ayer lo prueban), pero se llega sólo por `/sucursales → [sucursal] → Stock → fila del producto`.

### Auditoría de daño histórico (producción, al proponer)

| Medición | Valor |
|---|---|
| Sucursales totales | 40 |
| Inactivas | 2 |
| **Inactivas con existencias** | **0** |
| **Cerradas con existencias** | **0** |
| Cuentas afectadas | 0 |

**No hay reparación pendiente.** El único caso conocido ya se arregló a mano. El guard entra en un parque limpio y por lo tanto **no necesita período de gracia ni excepciones para datos legados**.

### Restricciones de esta era

- **Paso 2 de tenencia ENCENDIDO en producción desde el 24-08**: el backend corre como rol `authenticated` y las políticas de fila le aplican. Verificado que los permisos sobre `branches` son **a nivel tabla** (`anon`, `authenticated`, `postgres`, `service_role` tienen el juego completo), no por columna: una columna nueva queda cubierta automáticamente y **no** hace falta emitir permisos por columna. Se deja como verificación explícita en tasks igualmente, porque es precondición nueva y barata de comprobar.
- Máximo de migraciones en producción al proponer: `20261013000001` (262 filas). **Se revalida en el apply** — hay sesiones paralelas del PO.
- Censo de códigos de error corrido en dos frentes: repositorio completo (SQL, Python, TypeScript, Markdown, workflows) y **funciones vivas de producción**. Ocupados en vivo: `P0001-2`, `P0400-1`, `P0403-4`, `P0409-14`, `P0422-26`, `P0431-34`, `P0450-51`. Reservados sólo en repositorio (propuestas/documentos): `P0402`, `P0405`, `P0408`, `P0427`, `P0430`, `P0B04`, `P0B10`. **`P0428` está libre en ambos frentes.**

## Goals / Non-Goals

**Goals**

- G1 — Que **ninguno de los cuatro caminos** pueda dar de baja una sucursal con contenido operativo adentro, y que el rechazo diga cuánto hay y qué hacer.
- G1b — Que el borrado físico de una sucursal sea imposible por cualquier camino.
- G2 — Que se pueda contestar "quién creó esta sucursal" y "quién la desactivó y cuándo" sin inferir sobre marcas de tiempo.
- G3 — Que un usuario que quiere mover mercadería entre sucursales encuentre la función donde la busca (el módulo de Stock) y desde el error que se la hace necesitar.
- Cero lógica de inventario nueva: el predicado de contenido se lee del ledger canónico por sucursal, no se recalcula.

**Non-Goals**

- **No** se cambia la resolución de la sucursal por defecto. Es tentador (un fallback más caritativo habría amortiguado el incidente), pero tocarla afecta a toda operación sin sucursal explícita del sistema y merece su propio change con su propia auditoría. Queda como candidato, en OQ-6.
- **No** se agrega borrado lógico de maestros (`deleted_at`/`deleted_by`) a `branches`: la política adoptada la excluye explícitamente — la sucursal se desactiva, no se borra (ver D6).
- **No** se toca el vaciado automático ni la transferencia masiva ("desactivar y mover todo a X de un saque"). El PO pidió que el usuario vacíe primero; automatizarlo es producto nuevo. OQ-3.
- **No** se toca autorización ni roles multi-rol (sigue bloqueado a sign-off del PO en otro change).
- **No** se corrige que el módulo de Stock muestre el agregado del catálogo en vez del desglose por sucursal. G3 lo hace *visible* al lado, no lo reemplaza. OQ-5.

## Decisions

### D1 — El guard vive en un disparador sobre la tabla, no en el comando

**Decisión.** Un disparador `BEFORE UPDATE OR DELETE` sobre `public.branches` que evalúa la transición y rechaza. Los comandos (`rpc_deactivate_branch`, `rpc_close_branch`) **conservan** su verificación propia como defensa en profundidad y para poder devolver un mensaje más rico, pero **no son** la garantía.

**Por qué.** Es el único punto que atraviesan los cuatro caminos de la tabla de arriba, incluidos la actualización genérica del backend y la escritura directa desde el navegador, que hoy no pasan por ninguna función. Es el mismo patrón que ya resolvió el guard de tenencia de cuenta corriente (verificación en el punto de paso obligado + verificación explícita en los comandos como defensa en profundidad) y el mismo que usa el guard de borrado de productos de la política de soft delete, que también es un disparador sobre la tabla.

**Alternativas descartadas.**
- *Sólo en `rpc_deactivate_branch`*: arregla el camino del incidente y deja abiertos los otros tres. Es exactamente el error que ya existe hoy con el cierre.
- *Sólo en el backend (capa de servicio)*: no cubre la escritura directa desde el navegador, que las políticas de fila habilitan hoy para todo owner/admin.
- *Quitar las políticas de escritura directa*: endurecimiento encubierto, rompería la edición de nombre desde el navegador y excede el alcance.

**Lección aplicada (de la revisión adversarial del change de tenencia de caja): un guard que delega en un chequeo posterior no es un guard.** El disparador SHALL ser autosuficiente: no puede depender de que el llamador haya verificado nada antes.

### D2 — "Vacía" se define por el ledger canónico, más caja y transferencias en vuelo

**Decisión.** Bloquean la baja, en este orden de evaluación:

1. **Existencias**: alguna fila del inventario por sucursal con cantidad distinta de cero. Se lee `branch_stock` tal cual — es el ledger único de stock desde la unificación de inventario; **no se recalcula nada** ni se toca `products`.
2. **Sesión de caja abierta** en alguna caja de la sucursal. Precedente directo: el change de guard de borrado encontró movimientos de caja huérfanos colgando de una sesión abierta desde julio. Desactivar la sucursal deja la sesión imposible de cerrar por la UI.
3. **Transferencias de stock sin completar** con la sucursal como origen o destino.

El predicado es `quantity <> 0`, no `> 0`: hay una restricción de no-negatividad sobre el inventario por sucursal, pero el guard **no** se apoya en ella — una cantidad negativa por una anomalía futura debe bloquear la baja, no autorizarla en silencio.

**Alternativa descartada.** Sólo existencias (lo mínimo que pidió el PO). Se rechaza porque los otros dos dejan basura que sólo se puede reparar por consola, con el mismo costo de implementación (tres subconsultas en la misma función).

### D3 — Un solo código de error nuevo: `P0428`, con detalle discriminante

**Decisión.** `P0428` — *sucursal no vacía*. Un solo código para los tres motivos, con el motivo concreto y sus cantidades en el mensaje. Mapea a **409** (conflicto de estado, misma familia que `P0423`/`P0425`/`P0426`).

**Por qué uno y no tres.** Los tres motivos comparten el mismo tratamiento en cliente (mostrar el mensaje y ofrecer transferir) y el mismo estado HTTP. Tres códigos serían tres entradas de mapeo y tres traducciones para la misma reacción. El proyecto ya quemó dos códigos por colisión (`P0412` y `P0424`); el criterio es no gastar de más.

**Censo.** `P0428` libre en el repositorio completo **y** en las funciones vivas de producción. Se re-corre el censo en el apply (regla del proyecto: el censo caduca).

**Compatibilidad del cierre.** El comando de cierre hoy lanza `P0409` con el texto `branch_has_stock`, y la traducción del cliente **matchea por texto, no por código**. Al unificar el cierre a `P0428` el **token de texto `branch_has_stock` se conserva** en el mensaje: la traducción existente sigue funcionando sin tocarla, y la nueva agrega el detalle. Cambiar `P0409 → P0428` no altera el estado HTTP (ambos 409).

### D4 — El borrado físico se prohíbe siempre, no sólo cuando hay contenido

**Decisión.** La rama de borrado del disparador rechaza **incondicionalmente**, con o sin contenido, y el mensaje nombra la desactivación como la vía correcta.

**Por qué incondicional.** Aunque la sucursal esté vacía de stock, el borrado se lleva en cascada sus cajas y todo el historial de transferencias donde participó, y anula la imputación de ventas, compras y gastos históricos. La política de borrado del proyecto ya lo dice — *las sucursales se desactivan, no se borran* — y hasta hoy era una frase sin cumplimiento. Esto no es endurecer: es aplicar lo ya decidido.

**Riesgo asumido.** Alguna rutina de limpieza o alguna prueba que hoy borre sucursales empieza a fallar. Se busca explícitamente en el apply (tasks 2.x) antes de escribir el disparador.

### D5 — Los comandos informan; el disparador garantiza

**Decisión.** `rpc_deactivate_branch` y `rpc_close_branch` se redefinen con **la misma firma** (`CREATE OR REPLACE`, sin borrar y recrear) para verificar el mismo predicado *antes* de escribir y devolver el mensaje detallado. El disparador queda como red final para los caminos que no pasan por ellos.

**Por qué firma intacta.** Borrar y recrear una función resetea sus permisos — un gotcha con seis antecedentes en este proyecto y una prueba de CI dedicada. Sin cambio de firma no hay reseteo, no hay que reemitir permisos, y no hay riesgo de dejar dos definiciones conviviendo.

**Gate de integridad de función (regla del proyecto, con cinco incidentes previos).** Ambas redefiniciones **SHALL** partir de la definición **viva** capturada de producción, no del archivo de migración local. Para `rpc_deactivate_branch` ya se comprobó al proponer que ambas coinciden; para el resto se captura en el apply.

**El predicado se escribe una vez.** Una función auxiliar interna devuelve el inventario de contenido bloqueante de una sucursal, y la usan el disparador y los dos comandos. Nada de tres copias de la misma consulta divergiendo.

### D6 — Autoría: columnas para alta y baja, log de auditoría para el resto

**Decisión.**

- Columnas nuevas sobre `branches`: **`created_by`**, **`deactivated_at`**, **`deactivated_by`**. Sin clave foránea dura al catálogo de usuarios — referencia lógica, exactamente como ya se hizo con el autor del borrado lógico de maestros y con el autor de las transferencias de stock.
- **No** se agregan `deleted_at`/`deleted_by`: la política de borrado adoptada **excluye a `branches` a propósito** ("se desactiva con `is_active`, no se borra — tiene movimientos referenciándola y su propia máquina de estados"). Agregarlas duplicaría la semántica de `is_active` y contradiría una decisión vigente. `deactivated_at`/`deactivated_by` son el equivalente exacto **dentro** del vocabulario que la sucursal ya usa.
- **No** se agrega `updated_by`. Una columna retiene sólo al último editor y no dice **qué** cambió; para la pregunta del PO ("quién le cambió el nombre") sirve el log, no la columna.
- El **ciclo de vida completo** se escribe en el log de auditoría de la plataforma con el tipo de entidad y el identificador de la sucursal poblados, y los datos del cambio en el campo de metadatos.

**Por qué el log de auditoría es seguro acá.** Ese log hoy se usa como sumidero del despachador del outbox y sus filas tienen el tipo de entidad nulo; se verificó que la interfaz **no lo lee** (las notificaciones al usuario salen de su propia tabla, no de este log). Escribir ahí **no** genera notificaciones ni ruido para el usuario. Se agrega la primera fila con tipo de entidad poblado, lo cual es el uso previsto de la tabla.

**Backfill: ninguno, declarado.** Las 40 sucursales existentes quedan con autoría nula. No se puede inventar. La pantalla muestra "no registrado" y el comentario de la columna lo dice para quien la consulte por SQL dentro de un año.

**Quién llena `created_by`.** El comando de alta lo toma de la identidad en curso. Los caminos **de sistema** (el alta perezosa de la sucursal por defecto cuando una cuenta nueva recibe su primer movimiento de stock, y las siembras de aprovisionamiento) lo dejan nulo a propósito: no hay persona detrás. Esa distinción **SHALL** quedar en el comentario de la columna, para que un nulo no se lea como un dato perdido.

### D7 — Superficie frontend (regla del PO: ruta y punto de entrada explícitos)

| Qué | Ruta | Punto de entrada | Componente |
|---|---|---|---|
| Confirmación de baja informada | `/sucursales` | Botón papelera de cada tarjeta de sucursal | `BranchList.tsx` — la confirmación pasa a mostrar **qué hay adentro** (unidades, productos, caja abierta) antes de preguntar, y si hay contenido **no ofrece confirmar**: ofrece ir a transferir. |
| Autoría visible | `/sucursales` | Línea secundaria de cada tarjeta | `BranchList.tsx` — "Creada por X" / "no registrado"; en las inactivas, quién y cuándo la desactivó. |
| Traducción del error nuevo | — | — | `use-branches.ts` — el traductor existente suma el caso nuevo. No se crea otro traductor. |
| **Transferir stock desde el módulo principal** | **`/stock`** | **Acción por fila del listado de productos** (visible sólo si la cuenta tiene el módulo de sucursales y más de una sucursal) | Abre el desglose por sucursal del producto con el hook de inventario por sucursal que ya existe; al elegir el origen se abre **`TransferStockModal` reutilizado tal cual**. No se escribe diálogo nuevo. |
| Camino directo desde el error de venta | `/ventas` y el mostrador | El aviso de error de la venta | `operation-errors.ts` pasa a devolver, además del texto, una **acción opcional** (etiqueta + destino) que los llamadores pasan al aviso. Destino: `/stock` con el producto preseleccionado. |

La estética usa los componentes y tokens del sistema de diseño ya existentes. Verificación obligatoria en **escritorio y móvil** y en **tema claro y oscuro** antes del merge.

### D8 — Migración: idempotente, aditiva, un solo archivo

- Columnas con `ADD COLUMN IF NOT EXISTS`; función auxiliar, comandos y función del disparador con `CREATE OR REPLACE`; disparador con `DROP TRIGGER IF EXISTS` + `CREATE TRIGGER`.
- **Sin borrar y recrear ninguna función**: ninguna firma cambia ⇒ **no** hay que reemitir permisos. Si en el apply apareciera un cambio de firma inevitable, se aplica el patrón completo del proyecto: borrar, crear, y volver a emitir y revocar permisos explícitamente en el mismo archivo (`PUBLIC` + `anon` + `authenticated`), que es lo que la prueba de permisos de CI verifica.
- El número de archivo se fija en el apply revalidando el máximo de producción. Referencia al proponer: `20261013000001`.
- **La cadena de reaplicación del workflow de validación de KPIs suma este archivo al final.** Precedente con cinco antecedentes: cada migración que redefine una función ya redefinida por una migración anterior de la cadena obliga a reconverger al final, o la reconstrucción del esquema desde cero deja la definición vieja.
- Permisos: verificado que sobre `branches` son a nivel tabla, así que las columnas nuevas quedan cubiertas. Se comprueba explícitamente en el apply (precondición nueva del Paso 2).

### D9 — Pruebas (TDD estricto)

Prueba SQL nueva `supabase/tests/test_sucursal_guard_vaciado.sql`, con fixture sintético que se limpia de hijo a padre:

1. Desactivar una sucursal **con** existencias **falla** con el código nuevo, y el mensaje contiene las unidades.
2. Desactivar una sucursal **sin** existencias **pasa**.
3. **Transferir y después desactivar pasa** — el recorrido completo del incidente, en verde.
4. Cerrar una sucursal con existencias sigue fallando, ahora con el código unificado y conservando el token de texto que el cliente ya traduce.
5. Los **cuatro caminos** rechazan: comando de desactivación, comando de cierre, **actualización directa de la tabla**, y **borrado directo de la fila**.
6. Borrar una sucursal **vacía** también falla (D4, incondicional).
7. Sesión de caja abierta bloquea; transferencia sin completar bloquea.
8. Reactivar una sucursal inactiva **no** se ve afectada (el guard mira la transición hacia la baja, no cualquier actualización) — y editar el nombre de una sucursal **con** stock **sigue funcionando**.
9. El alta registra autor; el alta por camino de sistema deja autor nulo; la baja registra autor y momento; el ciclo de vida deja rastro en el log de auditoría.

El punto 8 es la **matriz de evasión** que la revisión adversarial del change anterior exigió: un guard que bloquea de más es un incidente nuevo.

Del lado Python: pruebas de mapeo del código nuevo a su estado HTTP y del recorrido del repositorio de sucursales. Del lado del navegador: pruebas de la confirmación informada, de la traducción del error y de la acción de transferir desde el módulo de Stock.

## Barrido de escritores (tasks 2.1-2.4, ejecutado en el apply — 2026-08-25)

**Funciones vivas de prod que escriben sobre `public.branches`** (vía `pg_get_functiondef`, no grep): sólo 6 — `rpc_deactivate_branch` (UPDATE `is_active`), `rpc_close_branch` (UPDATE `status`), `rpc_open_branch` (UPDATE `status` — NO es un camino de "baja", no se toca), `rpc_create_branch` (INSERT), `c21_apply_branch_stock_delta` (INSERT, alta perezosa) y `handle_new_user` (INSERT `'Casa Central'`, alta perezosa del signup). Los dos INSERT de sistema no los alcanza el disparador (`BEFORE UPDATE OR DELETE`, no `INSERT`) — verificado, no razonado. Ninguna otra función viva escribe sobre `branches` (`check_branch_low_stock`, `rpc_open_cash_session`, `rpc_close_cash_session`, `c28_register_cash_movement`, `rpc_soft_delete_cashbox` sólo la LEEN vía JOIN).

**Código de aplicación**: `BranchRepository.update` (genérico, hoy sólo admite `name` desde `BranchUpdate`, pero cruza igual el disparador si se ampliara) y la escritura directa del navegador vía RLS — ambos cubiertos por ser el disparador el choke point real, sin cambios de código necesarios.

**HALLAZGO NO PREVISTO EN EL PROPOSE — el borrado físico de `branches` está referenciado en el cleanup de 15 gates SQL preexistentes.** `branches.account_id REFERENCES accounts(id) ON DELETE CASCADE`: un `DELETE FROM public.accounts` cascadea a `branches`, y ese cascade **SÍ dispara** los triggers `BEFORE DELETE` del hijo (comportamiento estándar de Postgres para acciones referenciales, no sólo para el `DELETE` explícito). Los 16 gates SQL (los 15 preexistentes + este) que crean tenants sintéticos y los limpian con `DELETE FROM public.branches WHERE account_id = …` antes de borrar la cuenta habrían empezado a fallar en CI apenas este archivo se aplicara, porque el disparador nuevo rechaza **cualquier** `DELETE` sobre `branches`, incondicional (D4) — exactamente lo que el Risk del design ya anticipaba ("Alguna rutina interna borra o desactiva sucursales y empieza a fallar") pero sin que el barrido original hubiera mirado los *tests*, sólo funciones vivas y código de aplicación.

Fix aplicado (mecánico, un wrap de 2 líneas por cada `DELETE FROM public.branches` de cleanup, en los 15 archivos preexistentes + este mismo):

```sql
SET session_replication_role = replica;
DELETE FROM public.branches WHERE account_id = ANY(v_accounts);
SET session_replication_role = DEFAULT;
```

`session_replication_role` sólo lo puede fijar un rol con privilegio de superusuario/owner (`postgres`, el rol con el que corre CI y `psql` local) — **no abre ningún camino nuevo para `authenticated`/`anon` vía PostgREST**, que no pueden ejecutar `SET` arbitrario fuera de las RPCs definidas. Es el mecanismo estándar de Postgres para bypass de triggers en limpieza de fixtures, no un flag custom nuevo.

**TRES rondas de barrido, no una — la última la encontró CI, no el apply local.** Después de que las dos primeras rondas (ver abajo) dejaran el `supabase db reset` local y el gate SQL en verde, el PR #465 falló en CI (`validate-kpis`) en un tercer archivo: `test_payment_method_report.sql` — que **ya estaba en la lista de los 15 arreglados de la ronda 1**. Causa: el archivo tiene DOS bloques de cleanup con conjuntos de cuentas DISTINTOS — el primero borra `branches` explícito para `v_account_id` (arreglado en ronda 1), pero el segundo (una fixture de "intruso" separada) borra `public.accounts WHERE owner_user_id IN (v_user_id, v_intruder_id)` **directo**, sin haber borrado `branches` de esas cuentas antes — la cuenta del intruso nunca pasó por el `DELETE FROM branches` de la ronda 1. Barrido correctivo: grep de **TODAS** las ocurrencias de `DELETE FROM public.accounts` en los 20 archivos (no sólo en los 4 "nuevos" de la ronda 2) encontró **20 líneas más**, repartidas en 16 de los 20 archivos — la mayoría de los archivos de este proyecto limpian en dos pasadas con conjuntos de cuentas parcialmente distintos (principal + "otro"/"intruso"/"secundario"), y sólo la pasada que coincidía con el `DELETE FROM branches` explícito de la ronda 1 había quedado cubierta. Las 20 líneas nuevas reciben el mismo wrap; **41 wraps en total** sobre 19 archivos preexistentes + este mismo. Re-verificado en local uno por uno tras el fix — 16/17 en verde (el archivo #17, `test_cuentas_billetera_tipo.sql`, no se pudo re-verificar end-to-end por el mismo artefacto de método ya documentado abajo — `\i` con ruta relativa al cwd de `psql`, sin relación con este fix). La lección: **grepear un patrón de escritura una sola vez y asumir que "ya está cubierto" porque el archivo apareció en una ronda anterior es exactamente el error que ronda 1 cometió consigo misma** — cada archivo puede tener más de un bloque de cleanup con conjuntos de datos distintos, y hay que barrer el patrón completo en TODOS los archivos, no sólo en los que todavía no aparecían en ninguna lista.

**Dos rondas de barrido locales (antes del hallazgo de CI de arriba).** La primera ronda (grep de `DELETE FROM public.branches`) encontró y arregló 15 archivos. Verificando contra un `supabase db reset` local real (no contra CI, que todavía no había corrido), **`test_errcode_5char_gate.sql` reventó igual** — su cleanup borra `public.accounts` directo (`DELETE FROM public.accounts WHERE owner_user_id = ...`) y el `ON DELETE CASCADE` de `branches.account_id` dispara el mismo trigger sin que exista ningún `DELETE FROM public.branches` literal que el primer grep pudiera encontrar. Segunda ronda: grep de `DELETE FROM public.accounts` (20 archivos) cruzado contra los 15 ya arreglados → 4 archivos más (`test_cuenta_corriente_party_guard.sql`, `test_cuentas_billetera_tipo.sql`, `test_errcode_5char_gate.sql`, `test_pos_payment_vocabulary.sql`) recibieron el mismo wrap alrededor de su `DELETE FROM public.accounts`. Verificado además que **ningún** archivo borra `auth.users` sin haber borrado `public.accounts` antes (0 archivos huérfanos por esa vía) y que los 6 archivos con `INSERT INTO auth.users` restantes (`test_asiento_venta_formulario.sql`, `test_banco_caja_historial_ajustes.sql`, `test_compras_proveedor_cuenta_corriente.sql`, `test_delete_guard_ledgers.sql`, `test_pagos_cableados_restantes.sql`, `test_pos_banco_movimientos.sql`) **no tienen cleanup de ningún tipo** (fixtures con IDs fijos / upsert) — no están en riesgo, no se tocaron. **19 archivos preexistentes + este mismo change = 20 archivos con el bypass**, los 20 re-ejercitados contra `supabase db reset` local hasta verde (`test_cuentas_billetera_tipo.sql` no se pudo re-verificar end-to-end por un artefacto del método de verificación —usa `\i` con ruta relativa al cwd de `psql`, y correrlo vía `docker exec -i psql -f -` no tiene el checkout del repo dentro del contenedor— pero las líneas previas a ese punto, incluida la del propio bypass, pasaron limpias).

## Risks / Trade-offs

- **[El disparador bloquea de más y rompe una edición legítima]** → El disparador SHALL evaluar la **transición** (activa→inactiva, abierta→cerrada, y todo borrado), no el estado. Renombrar, cambiar dirección o **reactivar** una sucursal con stock no se toca. Cubierto por el punto 8 de las pruebas, ejecutado, no razonado.
- **[Alguna rutina interna borra o desactiva sucursales y empieza a fallar]** → Barrido explícito antes de escribir el disparador (tasks 2.x): funciones vivas de producción que escriban sobre `branches`, siembras de aprovisionamiento, y el alta perezosa de la sucursal por defecto. El alta perezosa **inserta**, no borra, así que el disparador no la alcanza — se verifica igual.
- **[Un usuario queda encerrado: no puede desactivar y no sabe cómo vaciar]** → Es precisamente el riesgo que G3 existe para cubrir. El mensaje de error nombra la transferencia, la confirmación ofrece el camino en vez de un botón muerto, y la transferencia pasa a estar en el módulo de Stock. **Si G3 no entra, G1 empeora la experiencia** en vez de mejorarla: van juntos o no van.
- **[La cuenta con UNA sola sucursal con stock no puede desactivarla nunca]** → Correcto y deseado: no tiene a dónde transferir y desactivarla dejaría la cuenta sin sucursal operativa (el comando de cierre ya lo prohíbe por otra vía). El mensaje SHALL distinguir este caso y decir que primero hay que crear la sucursal destino, en vez de mandar a una transferencia imposible.
- **[Cambiar el código de error del cierre rompe algún cliente]** → El cliente traduce por **texto**, no por código, y el token de texto se conserva. El estado HTTP no cambia (409→409). Verificado leyendo el traductor.
- **[La migración choca de número con una sesión paralela del PO]** → El número se fija revalidando el máximo de producción en el apply. Ya pasó tres veces en el change de guard de cuenta corriente.
- **[El log de auditoría se llena de ruido]** → El ciclo de vida de sucursales es de muy baja frecuencia (40 filas en toda la base). Ni comparación con las 246 filas del evento de venta que ya conviven ahí.

## Migration Plan

1. Revalidar en producción: máximo de migraciones, censo de códigos de error, y definición viva de las dos funciones a redefinir (gate de integridad de función).
2. Barrido de escritores de `branches` (funciones vivas, siembras, código de aplicación).
3. Un archivo de migración, aditivo e idempotente: columnas de autoría → función auxiliar del predicado → redefinición de los dos comandos → función del disparador → disparador → registro de auditoría del ciclo de vida → comentarios.
4. Prueba SQL nueva y encadenado del archivo en la cadena de reaplicación del workflow de KPIs.
5. Backend: mapeo del código nuevo, exposición de autoría y estado en el modelo de salida.
6. Frontend: las cinco superficies de D7, verificadas en escritorio y móvil, tema claro y oscuro.
7. Verificación post-merge en producción: máximo de migraciones, existencia del disparador, definición viva con el guard, y re-medición de los cuatro conteos de la auditoría de daño.

**Rollback.** Aditivo. En producción no se revierte: se desactivaría el disparador (`DROP TRIGGER`) y las columnas quedarían inertes. La referencia queda escrita en la cabecera del archivo.

## Open Questions

- **OQ-1 — ¿La sesión de caja abierta y las transferencias en vuelo bloquean, o sólo el stock?** El PO pidió literalmente "vaciarla". *Recomendación: bloquear las tres.* Cuesta lo mismo y evita dos clases de basura que sólo se reparan por consola.
- **OQ-2 — ¿El borrado físico se prohíbe siempre o sólo con contenido?** *Recomendación: siempre* (D4). Es aplicar la política de borrado ya adoptada, que hasta hoy no tenía cumplimiento.
- **OQ-3 — ¿Se ofrece "vaciar y desactivar" en un paso (transferir todo el stock a otra sucursal de un saque)?** *Recomendación: NO en este change.* Es producto nuevo (elegir destino, resolver conflictos de producto, confirmar en bloque) y el PO pidió el guard, no la automatización. Candidato propio si el guard genera fricción real.
- **OQ-4 — ¿La autoría se muestra a todos los miembros o sólo a owner/admin?** *Recomendación: a todos los miembros* — es la misma información que ya ve cualquiera que mire el historial de transferencias.
- **OQ-5 — El módulo de Stock muestra el total del catálogo, no el desglose por sucursal; eso es la mitad de por qué el incidente fue invisible.** ¿Se agrega una columna "en esta sucursal" al listado? *Recomendación: fuera de alcance acá* — G3 agrega el desglose bajo demanda (al transferir); cambiar la columna principal afecta a toda cuenta sin sucursales. Candidato propio.
- **OQ-6 — ¿La resolución de la sucursal por defecto debería avisar cuando cambia de sucursal?** Un fallback más caritativo (o un aviso) habría amortiguado el incidente aunque el guard no existiera. *Recomendación: candidato propio*, no acá — toca toda operación sin sucursal explícita del sistema.
- **OQ-7 — Observación lateral, sin cambio propuesto:** `anon` tiene permisos de escritura y borrado **a nivel tabla** sobre `branches`; hoy lo frena únicamente que las políticas de fila exigen membresía de cuenta y `anon` no tiene identidad. Es defensa de segundo orden, no un incidente, y es la **misma familia** que el hallazgo lateral h3 que dejó abierto el change de guard de cuenta corriente. Se registra para que el PO decida si los agrupa en un change de endurecimiento.
