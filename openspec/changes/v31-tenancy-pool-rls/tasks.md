> **Modo TDD estricto.** Cada tarea de código va precedida por su test (RED) y el test debe fallar por la razón esperada antes de escribir la implementación (GREEN). Ninguna tarea `[x]` sin ejecución real de la suite.
> **Governance CRÍTICO** — aislamiento entre 34 cuentas con dinero real, sobre el código por el que pasa el 100% del backend. Los grupos 5 y 6+ tienen **gates explícitos**: no se avanza sin cumplir las condiciones de "probado bajo carga" (`design.md`) y sin sign-off del PO.
> **Los grupos 1-4 son el Paso 1. Los grupos 6-9 son el Paso 2 y NO se ejecutan hasta que el grupo 5 cierre.**
> **Amendment 2026-07-31 (sign-off del PO)** — las cuatro OQ del propose quedaron resueltas: ventana de observación = 7 días con los cuatro contadores en cero (un evento reinicia la ventana); rol de login dedicado = Paso 3 FUTURO, fuera de este change; colisiones de escritura = RPC por defecto (DEC-24), `fiscal_documents` y `cashboxes` al PO uno a uno antes de aplicar; corte del Paso 2 = **deploy silencioso** con rollback preparado. Ver `design.md` §Open Questions.

## 1. Red de seguridad y evidencia previa

- [ ] 1.1 Ejecutar la suite backend completa (`pytest backend/tests`) y registrar el baseline exacto. Si algo ya falla, **NO** arreglarlo: reportarlo como fallo preexistente y detenerse para confirmar con el orquestador.
- [ ] 1.2 Baseline acotado de `test_database.py`, más los tests de los dominios de mayor escritura (`test_sales.py`, `test_purchases.py`, `test_c28_cash_session.py`, `test_products.py`).
- [ ] 1.3 Re-verificar contra prod (read-only, MCP) los números que sostienen el diseño y pegarlos en el PR: `rolbypassrls` de `postgres` y `authenticated`; tablas en `public` con y sin RLS; tablas con SELECT para `authenticated`; **tablas con RLS y sin policy de INSERT/UPDATE/DELETE**; funciones `rpc_*` con y sin `EXECUTE` para `authenticated`. Si algún número difiere de `design.md` (§Context), detenerse y revisar D6/D7.
- [ ] 1.4 **Barrido de lectores de `app.jwt_claims`** (D2) sobre `supabase/migrations/`, `backend/`, `frontend/` y `supabase/functions/`. Esperado: 0 lectores. **Si aparece alguno, D2 se revisa antes de eliminar nada.** Guardar la salida en el PR.
- [ ] 1.5 Documentar el baseline de K5: cómo se reproduce hoy el 500 intermitente de compras (o, si no es reproducible a demanda, dónde se observa en los logs de Render) — es el criterio de cierre del Paso 1 y hay que poder medirlo antes y después.

## 2. Paso 1 — Transacción explícita y claims con alcance transaccional (D1, D2)

- [ ] 2.1 **RED** — Reescribir `backend/tests/test_database.py::test_get_db_conn_injects_jwt_claims`: hoy afirma literalmente el comportamiento defectuoso (`query.count(", false)") == 2` y la presencia de `app.jwt_claims`). El test nuevo exige transacción abierta, `set_config` con alcance transaccional (`true`) y **ausencia** de `app.jwt_claims`. Debe fallar. **No borrar el test viejo en silencio**: se reemplaza con la razón escrita en el mensaje de commit.
- [ ] 2.2 **GREEN** — Reescribir `get_db_conn` en `backend/core/database.py`: adquirir conexión, abrir transacción explícita, inyectar `request.jwt.claims` con alcance transaccional, `yield`, commit/rollback al cerrar. Eliminar `app.jwt_claims` y corregir el comentario que afirma que las policies lo leen. Ejecutar: 2.1 pasa.
- [ ] 2.3 **TRIANGULATE** — (a) un request que lanza excepción produce rollback y no deja escrituras; (b) dos requests consecutivos sobre la misma conexión mockeada no comparten claims; (c) el `set_config` se ejecuta **después** de abrir la transacción y **antes** del `yield` (el orden es normativo, no incidental).
- [ ] 2.4 **RED/GREEN** — Test de que la transacción del request no envuelve al camino de servicio: `get_service_conn` sigue entregando una conexión sin transacción de request ni claims (D5).
- [ ] 2.5 **GREEN** — Agregar `idle_in_transaction_session_timeout` con alcance transaccional dentro de la misma transacción (D4), con el valor documentado y configurable.
- [ ] 2.6 **REFACTOR** — Actualizar los docstrings de `database.py` para que describan el contrato real (transacción por request, alcance transaccional, camino de servicio separado) y borrar la afirmación falsa sobre `app.jwt_claims`. Ejecutar la suite completa: sin regresiones respecto de 1.1.

## 3. Paso 1 — Atomicidad por request: verificar el cambio de comportamiento (D3)

- [ ] 3.1 **RED** — Test explícito del cambio de D3: un request que escribe (a través de un repository que abre su propio `conn.transaction()`) y **después** falla, no deja trabajo persistido. Debe fallar con el comportamiento actual (hoy la escritura interna quedaría comiteada).
- [ ] 3.2 **GREEN** — Confirmar que el comportamiento nuevo lo satisface por construcción (los 9 `conn.transaction()` de repositories pasan a ser savepoints bajo la transacción externa). Ejecutar: 3.1 pasa.
- [ ] 3.3 **TRIANGULATE** — (a) un rollback interno de savepoint no aborta el request completo si el código lo maneja; (b) un request exitoso con escritura interna sí persiste. Ejecutar: ambos pasan.
- [ ] 3.4 Revisar los 9 call sites de `.transaction()` en `backend/repositories/` y documentar, uno por uno, si el cambio de "transacción de nivel superior" a "savepoint" altera alguna expectativa del código que los rodea. Cualquier caso dudoso se eleva antes de continuar.

## 4. Paso 1 — Palanca de rollout y despliegue (D8)

- [ ] 4.1 **RED/GREEN** — Agregar la variable de configuración del Paso 1 a `backend/core/config.py`, **apagada por defecto**, con tests que cubran ambos caminos (encendido: transacción + alcance transaccional; apagado: comportamiento actual byte a byte).
- [ ] 4.2 Ejecutar la suite completa dos veces con la palanca encendida y dos veces con la palanca apagada. Ambos conjuntos verdes.
- [ ] 4.3 Abrir el PR del Paso 1 con la tabla de evidencia TDD, la salida del barrido de 1.4 y los números de prod de 1.3. **Mergear deja el código inerte**: la palanca está apagada.
- [ ] 4.4 **PO** — Encender la variable en Render. Verificación inmediata (minutos): un request autenticado real llega con claims; el endpoint de compras responde 200; los logs no muestran errores de transacción.
- [ ] 4.5 Verificar contra una base real (no mocks) que la identidad observada dentro de un request corresponde al usuario del request — el spec de `asyncpg-pool` estuvo describiendo un comportamiento que el código nunca tuvo; esta verificación existe para no repetir el patrón.

## 5. GATE — "Probado bajo carga" (`design.md`)

> **Ninguna tarea del grupo 6 en adelante se ejecuta hasta que las cinco condiciones estén cumplidas y registradas.**

- [ ] 5.1 **Condición 1** — Suite backend completa verde dos veces seguidas con el Paso 1 activo, incluidos los tests de los grupos 2 y 3.
- [ ] 5.2 **Condición 2** — Escribir y ejecutar la prueba de concurrencia cross-tenant contra el entorno desplegado: ≥50 requests concurrentes (`asyncio` + `httpx`, ya en el proyecto) intercalando **dos usuarios de cuentas distintas**, afirmando que ninguna respuesta contiene datos de la otra cuenta y que ninguna falla por claims ausentes. Guardar el script en el repo: se vuelve a usar en el grupo 8.
- [ ] 5.3 **Condición 3** — 7 días naturales corridos de operación real con el Paso 1 activo, incluyendo al menos dos cierres de caja y un día de actividad alta. Registrar el volumen de requests observado **como dato**, no contra un umbral inventado. *(Ventana de 7 días confirmada por el PO el 2026-07-31 — OQ-1.)*
- [ ] 5.4 **Condición 4** — Sobre esos 7 días, verificar y registrar en cero los **cuatro** contadores: ocurrencias del 500 intermitente de compras (K5, contra el baseline de 1.5), `idle_in_transaction_session_timeout`, 403 anómalos de "cuenta no encontrada", errores de transacción abortada en logs de Render. **Un solo evento reinicia la ventana de 7 días** (OQ-1): no se acorta ni se compensa con volumen.
- [ ] 5.5 **Condición 5** — Presentar al PO el resultado de 5.1-5.4 **junto con el inventario del grupo 6** y obtener sign-off explícito para ejecutar el Paso 2. **Si alguna condición falla: apagar la palanca del Paso 1 y detenerse.**

## 6. Paso 2 — Inventario de escrituras directas (D7) — *previo al corte*

- [ ] 6.1 Construir el inventario completo: todas las escrituras directas (`INSERT`/`UPDATE`/`DELETE` sin función con privilegios de definidor) de `backend/repositories/*.py`, cruzadas contra `pg_policies` de prod. Punto de partida verificado: 15 tablas con INSERT directo, ~13 con UPDATE directo, **40 tablas con RLS y sin policy de escritura**.
- [ ] 6.2 Confirmar las cuatro colisiones ya identificadas y completar la lista: `fiscal_documents` (4 UPDATE directos, 0 policy de UPDATE), `cashboxes` (1 UPDATE, 0 policy), `events` (INSERT, 0 policy), `email_logs` (INSERT, 0 policy).
- [ ] 6.3 Verificar los `EXECUTE` de las 68 funciones `rpc_*` para `authenticated` (esperado: 66 con permiso) e identificar las 2 faltantes y la función que no es `SECURITY DEFINER`, decidiendo qué hacer con cada una.
- [ ] 6.4 Para cada colisión, resolver con el **RPC `SECURITY DEFINER` como vía por defecto** (OQ-3 resuelta, coherente con DEC-24). Agregar la policy de escritura faltante es la **excepción** y requiere justificación escrita en el inventario (admisible en tablas de infraestructura sin invariantes de negocio). **`fiscal_documents` y `cashboxes` se elevan al PO uno a uno ANTES de aplicar** su resolución.
- [ ] 6.5 **RED/GREEN** — Si el inventario obliga a policies nuevas: una migración idempotente con gates de comportamiento (patrón del proyecto), con test que verifique que la escritura funciona con el rol restringido y **falla** para una cuenta ajena.
- [ ] 6.6 Cerrar el inventario con **cero divergencias abiertas** y adjuntarlo al sign-off de 5.5.

## 7. Paso 2 — Adopción del rol restringido (D6)

- [ ] 7.1 **RED** — Test que afirma, desde dentro de un request, que el usuario efectivo **no** es el rol con BYPASSRLS. Debe fallar hoy.
- [ ] 7.2 **GREEN** — Adoptar el rol `authenticated` con alcance transaccional dentro de la misma transacción del Paso 1, en el mismo punto donde se inyectan los claims (D6: no pueden divergir). Detrás de su **propia** palanca de configuración, apagada por defecto. Ejecutar: 7.1 pasa.
- [ ] 7.3 **TRIANGULATE** — (a) el rol no persiste tras cerrar la transacción (la conexión vuelve al pool sin residuo); (b) el camino de servicio **no** adopta el rol y conserva su capacidad transversal; (c) una consulta que omite el filtro por cuenta no devuelve filas de otra cuenta.
- [ ] 7.4 **RED/GREEN** — Test de aislamiento por repository sobre al menos tres dominios de escritura distintos (ventas, caja, productos): con un identificador conocido de otra cuenta, la operación responde como si el registro no existiera.
- [ ] 7.5 Ejecutar la suite completa en las cuatro combinaciones de las dos palancas. Las cuatro verdes o, si alguna combinación es inválida por diseño, documentar por qué y hacer que falle explícitamente en el arranque.

## 8. Paso 2 — Corte en producción y verificación

- [ ] 8.0 **Precondición del corte** — Dejar el **rollback preparado y verificado** antes de encender: palanca del Paso 2 identificada, procedimiento de apagado escrito, y alguien con acceso a Render listo para ejecutarlo durante toda la verificación de 8.2. **Si el rollback no está listo, 8.1 no se ejecuta** — con deploy silencioso es la única mitigación disponible.
- [ ] 8.1 **PO** — Encender la palanca del Paso 2 en Render, en horario de baja actividad, con el PO presente y **sin anuncio a los usuarios** (OQ-4 resuelta: deploy silencioso).
- [ ] 8.2 Verificación inmediata: consultar el usuario efectivo dentro de un request real y confirmar que no es el rol con BYPASSRLS.
- [ ] 8.3 Smoke E2E de las operaciones críticas con una cuenta real: venta, compra, cobro, cierre de caja, emisión de comprobante. Cualquier "permiso denegado" indica una colisión no inventariada → **apagar la palanca inmediatamente** y volver al grupo 6.
- [ ] 8.4 Re-ejecutar la prueba de concurrencia cross-tenant de 5.2 — ahora con la RLS activa, que es donde su resultado significa algo.
- [ ] 8.5 Observación 48 h con atención específica a errores de permiso denegado y a los cuatro contadores de 5.4.
- [ ] 8.6 Verificar que el camino de servicio sigue operativo: procesar un aviso de pago (o su equivalente de prueba) y una corrida del relay CAE del cron. Son los tres consumidores que dependen de BYPASSRLS y la razón por la que se descartó `ALTER ROLE postgres NOBYPASSRLS`.

## 9. Cierre

- [ ] 9.1 Suite backend completa dos veces seguidas con ambas palancas encendidas; confirmar el conteo de tests nuevos respecto del baseline de 1.1.
- [ ] 9.2 Correr los advisors de Supabase y confirmar que las policies agregadas en 6.5 (si las hubo) no abren hallazgos nuevos.
- [ ] 9.3 Actualizar `knowledge-base/08_arquitectura_propuesta.md` y DEC-13: pasan de describir un JWT-passthrough aspiracional a describir el real, con la corrección de la nota de C-17 (`SET ROLE` de sesión vs. alcance transaccional) registrada explícitamente para que no se re-litigue.
- [ ] 9.4 Cerrar K5 en el registro de bugs con la evidencia de 5.4, o documentar por qué persiste si sobrevivió al Paso 1 (sería un hallazgo importante: significaría que la causa raíz era otra).
- [ ] 9.5 Actualizar la ficha de `v3-rbac-multirole` en `CHANGES.md`: dependencia dura `v31-tenancy-pool-rls` satisfecha, con la nota de que `is_account_writer`/`current_account_ids` ahora **sí** son efectivos para el backend y que migrarlos al pivot cambia comportamiento real.
- [ ] 9.6 Registrar el **Paso 3 FUTURO** (rol de login dedicado sin BYPASSRLS, OQ-2 opción (b)) como trabajo posterior donde el PO lo vea, con el criterio de arranque: sólo después de que el Paso 2 lleve tiempo estable. **No se ejecuta en este change.**
- [ ] 9.7 Anotar como deuda explícita la retirada de las dos palancas y del camino de código viejo, en un change de limpieza posterior, una vez que el Paso 2 lleve tiempo estable.
