## Context

**Pedido del PO (2026-09-25):** *"quiero que en la venta se pueda elegir el punto de venta o al facturar, por si tienen más de 1"*. Llegó el mismo día en que Sumar (cuenta `3834e5d7…`, CUIT 27213790337) emitió su primera factura real: Factura C, PV 3, número 501 (ARCA tenía 500 en ese PV: la app continúa la numeración del sistema anterior vía `FECompUltimoAutorizado + 1`, #580), CAE autorizado.

**Estado medido (sólo lectura, prod `gxdhpxvdjjkmxhdkkwyb`, 2026-09-25):**

| Medición | Valor |
|---|---|
| Cuentas con puntos de venta | 2 (`3834e5d7` Sumar, `9b52ebe0` plataforma) |
| …con **dos o más** PV activos | **2 de 2** — las dos tienen 3 y 9999 |
| …con algún PV inactivo | 0 |
| PV con `branch_id` no nulo | 0 de 4 |
| Sucursales activas por cuenta | 1 y 1 (Sumar tiene 3 filas, 1 activa) |
| `fiscal_profiles` con CUIT distinto | 2 de 2 (el duplicado de CUIT de `fiscal-emision-segura` ya se corrigió) |
| `delegacion_autorizada` | `true` en los dos perfiles |
| Comprobantes de venta emitidos | 1 (Sumar, PV 3, desde `/ventas`) |

**Caminos de facturación hoy (código en `main` `57791247`):**

1. **`/ventas`** → `components/ventas/sale-operations-list.tsx`: "Facturar" promueve la venta legacy a `sales_order` (`rpc_promote_legacy_sale_to_order`) y muestra `EmitInvoiceButton` con `pointOfSaleId = pointsOfSale?.[0]?.id` (L163). `GET /fiscal/points-of-sale` devuelve **activos e inactivos** ordenados por `numero` (`point_of_sale_repository.list_by_account`), así que `[0]` puede ser un PV inactivo → `P0404`. Con dos activos, factura siempre por el de menor número sin preguntar.
2. **`/ventas/ordenes`** → `app/(dashboard)/ventas/ordenes/page.tsx`: pasa un PV sólo si hay **uno** activo; con dos o más pasa `null` → `rpc_emit_sale_invoice` → `rpc_emit_pending_cae` → **`P0422 ambiguous_point_of_sale`**. El POS no emite inline (requisito de `sales-order`, `facturar-venta-afip`) y su banner "Facturar esta venta →" lleva acá, así que **ninguna venta del POS se puede facturar en las dos cuentas que facturan**. El texto amigable ("Seleccioná cuál usar", `use-sales-orders.ts:142` y `pos/page.tsx:94`) no tiene dónde seleccionar.
3. **`/admin/pagos`** (suscripciones de la plataforma) → `EmitirSuscripcionDialog`, que sí tiene selector de PV (copia propia) y exige elegir cuando hay varios. `rpc_emit_subscription_payment_cae` (última definición `20261029000001`) tiene la misma resolución D11 que la RPC de ventas.

**Código muerto relevante:** `components/fiscal/EmitirComprobanteDialog.tsx` (v22) implementa exactamente el diálogo con selector de PV y no tiene ningún consumidor. Su bloque de selección es casi idéntico al de `EmitirSuscripcionDialog`.

**RPC de emisión:** `rpc_emit_pending_cae` (9 parámetros, `SECURITY DEFINER`, RPC de usuario con `EXECUTE` para `authenticated`), última definición en `20261059000001_fiscal_marca_previa_e_insert_interno.sql` L516 con `COMMENT` propio (R4). La resuelve `rpc_emit_sale_invoice(p_sales_order_id, p_point_of_sale_id)` (última definición `20261061000001`), que le pasa el PV tal cual.

**Trigger de `points_of_sale`:** `trg_guard_pos_cuit_cross_account` (`BEFORE INSERT OR UPDATE`, G9 de `fiscal-emision-segura`) retorna temprano en un `UPDATE` que no cambia `is_active`/`numero`/`fiscal_profile_id` — un `UPDATE` de `is_default` no lo dispara (verificado leyendo el cuerpo vivo).

## Goals / Non-Goals

**Goals:**
- Que toda cuenta con dos o más PV activos pueda facturar una venta, eligiendo el PV, desde **los dos** caminos (`/ventas` y `/ventas/ordenes`).
- Que la cuenta con un solo PV no note ningún cambio (cero pasos agregados).
- Un predeterminado por cuenta para no tener que elegir en cada factura, y memoria de la última elección en la sesión.
- Una sola implementación del selector y de la regla de preselección.
- No tocar numeración, CAE, relay, ARCA ni la facturación de suscripciones del lado del servidor.

**Non-Goals:**
- **Elegir el PV en el formulario de la venta** (ver D1).
- PV por sucursal (`points_of_sale.branch_id`) — ver D2 opción (b).
- Imprimir la factura con CAE y QR (candidato `comprobante-fiscal-visible`, change aparte).
- Reactivar un PV inactivo o editar su número desde la UI.
- Cambiar la resolución de `rpc_emit_subscription_payment_cae`.
- Unificar los guards de rol heredados de crear/desactivar PV (`require_role(auth, ["user","admin"])`, anteriores a `v3-rbac-multirole`) — se anota como candidato.

## Decisions

### D1 — El punto de venta se elige **al facturar**, no en la venta

El PO dejó abiertas las dos ("en la venta … o al facturar"). Se elige **al facturar** porque:
- El PV es un atributo **del comprobante fiscal** (`fiscal_documents.point_of_sale_id`), no de la venta: una venta sin factura no tiene PV, y la mayoría de las ventas no se facturan (1 comprobante de venta en prod).
- La venta y la factura son momentos separados por diseño (requisito "La confirmación de venta no emite comprobante inline" de `sales-order`): el POS y el formulario de venta no emiten. Guardar un PV en la venta obligaría a una columna nueva en `sales`/`sales_orders`, a mantenerla sincronizada en la edición (`_sales_order_sync_from_operation`) y a decidir qué pasa si el PV se desactiva entre la venta y la factura — todo para un dato que sólo se usa al facturar.
- Con el predeterminado + memoria de sesión, el caso "siempre facturo por el mismo PV" queda en un clic sin tocar la venta.

*Alternativa descartada:* selector de PV en el POS y en el formulario de venta, persistido en `sales_orders.point_of_sale_id`. Más superficie, más estado, ningún beneficio para el caso real.

### D2 — PV predeterminado: `points_of_sale.is_default` (opción a), no por sucursal (opción b)

**(a) `is_default` por cuenta** — columna `boolean NOT NULL DEFAULT false`, índice único parcial `(account_id) WHERE is_default`, CHECK `NOT is_default OR is_active`. Editable en Configuración → Datos fiscales → Puntos de venta.

**(b) Defaultear por `points_of_sale.branch_id`** según la sucursal de la venta.

**Se recomienda (a).** (b) no resuelve el caso real: las dos cuentas tienen **una sola sucursal activa** y sus dos PV serían de esa misma sucursal, así que (b) seguiría siendo ambiguo — y además exigiría resolver la sucursal de la venta en la emisión (una venta legacy puede no tenerla: 0/507 compras tenían `branch_id` antes de `caja-compras-cobranzas`; las ventas manuales tienen un historial parecido), cargar `branch_id` en los 4 PV existentes (hoy 0/4) y definir qué pasa con dos PV en la misma sucursal. (b) es una extensión natural **después** de (a) si aparece una cuenta con un PV por local; se anota como candidato.

*Por qué índice único parcial y no un `default_point_of_sale_id` en `fiscal_profiles`:* la marca vive en la fila que describe, la desactivación la limpia en la misma sentencia (un FK desde el perfil quedaría apuntando a un PV inactivo o exigiría un trigger), y `points_of_sale` ya tiene RLS de escritura por `is_account_writer`. `fiscal_profiles` tiene privilegios de columna estrictos (familia de `accounts-update-por-columnas`) que no conviene ampliar.

*Por qué CHECK además de limpiar en la desactivación:* defensa en profundidad — cualquier camino futuro que desactive un PV sin pasar por el repository no puede dejar un predeterminado inactivo; falla en vez de mentir.

### D3 — La RPC de ventas usa el predeterminado sólo cuando no se especifica PV

`rpc_emit_pending_cae`, rama "sin PV explícito y más de un activo": antes de levantar `P0422`, busca `WHERE account_id = v_account_id AND is_active AND is_default`; si lo encuentra, lo usa. El resto de la resolución no cambia (explícito inválido → `P0404` aunque haya predeterminado; cero activos → `P0404`). Misma firma de 9 parámetros → `CREATE OR REPLACE` sin riesgo de overload (`42725`). El cuerpo se parte del **`pg_get_functiondef` vivo de prod** (regla del proyecto), se conserva el `COMMENT` vivo (lección de #579) y se re-aplican `REVOKE`/`GRANT`.

*Por qué tocar la RPC si la UI siempre manda un PV explícito (D4):* porque la UI no es el único caller posible (`POST /fiscal/documents/emit`, futuros automatismos, una pestaña vieja con el bundle anterior al deploy), y "predeterminado" que la UI respeta pero el servidor ignora sería una definición a medias. El servidor es la fuente de verdad de la regla; la UI la replica para **preseleccionar**, no para decidir.

*Por qué no extraer un helper `_fiscal_resolve_point_of_sale` compartido con la RPC de suscripciones:* haría falta reescribir `rpc_emit_subscription_payment_cae` (facturación de la plataforma, dinero real), que no necesita el cambio (D5). Con un solo caller no se alcanza la Regla de Tres.

### D4 — La UI **siempre** manda el PV explícito; `EmitInvoiceButton` lo resuelve solo

`EmitInvoiceButton` pasa a leer `usePointsOfSale()` (TanStack Query ya cachea la lista 5 min; las dos pantallas ya la consultan, así que no hay request extra) y elimina la prop `pointOfSaleId`. Comportamiento:

| PV activos | Clic en emitir |
|---|---|
| 0 | No se ofrece emitir: aviso "Sin punto de venta" con enlace a `/configuracion/fiscal` (hoy la RPC fallaba con `no_active_point_of_sale`) |
| 1 | Emite directo con ese PV explícito (igual que hoy, 1 clic) |
| ≥2 | Abre `EmitirComprobanteDialog` con la preselección de D6; confirmar emite con el PV elegido explícito |

Las dos pantallas (`sale-operations-list.tsx`, `ventas/ordenes/page.tsx`) dejan de calcular un PV. Esto elimina de raíz los dos bugs (el `[0]` inactivo y el `null` con varios) en vez de parchear cada pantalla, y cualquier pantalla futura que use el botón hereda la selección.

*Por qué explícito aunque exista predeterminado:* lo que el usuario vio marcado en el diálogo es lo que se emite. Si mandáramos `null` y el predeterminado cambiara entre abrir el diálogo y confirmar (otra pestaña, otro usuario), la factura saldría por un PV distinto al mostrado.

### D5 — La facturación de suscripciones no cambia del lado del servidor

`rpc_emit_subscription_payment_cae` queda intacta. Su único caller (`EmitirSuscripcionDialog`) ya exige elegir con varios PV activos. En el frontend gana el selector compartido y la preselección del predeterminado (D7), sin cambiar su llamada. Un gate SQL fija el `md5` del cuerpo vivo de esa RPC para que el apply no la toque por accidente.

### D6 — Regla de preselección: una función pura en `lib/fiscal-point-of-sale.ts`

```
resolvePreselectedPointOfSale(pvs, { lastUsedId }) →
  activos = pvs.filter(isActive)
  1. lastUsedId si está entre los activos
  2. el activo con isDefault
  3. el único activo
  4. null
```

Más `activePointsOfSale(pvs)` y `formatPointOfSaleNumber(numero)` (4 dígitos, el mismo formato que `formatComprobante` de `lib/fiscal-comprobante.ts`, del que se reutiliza el padding — hoy los dos diálogos usan 5 dígitos y Configuración 4). Pura y sin imports de `python-client` para que sea testeable sin mockear media app (mismo criterio que `lib/fiscal-comprobante.ts`).

*Última elección antes que predeterminado:* dentro de una misma sesión, lo que el usuario acaba de elegir expresa mejor su intención actual que un ajuste de configuración (el caso típico: "hoy estoy facturando todo por el 9999"). Queda como OQ-2 por si el PO prefiere lo contrario.

### D7 — Un solo selector: `components/fiscal/PointOfSaleSelect.tsx`

El bloque `<Select>` de PV está hoy en `EmitirComprobanteDialog` y en `EmitirSuscripcionDialog`; este change agrega un tercer uso (el diálogo revivido en los dos caminos), así que se extrae (Regla de Tres). Props: `pointsOfSale`, `value`, `onValueChange`, `id` (para el `<Label htmlFor>`). Con un solo activo muestra el PV como texto ("Único PV activo"); con varios, el `<Select>` con el badge "Predeterminado" en el ítem correspondiente.

### D8 — Memoria por sesión con `useSessionStorage`, clave por cuenta

`hooks/persistence/use-session-storage.ts` ya existe (envuelve `usePersistentState`, que maneja el `try/catch` de un storage bloqueado). Clave `fiscal:last-pv:<accountId>`: por cuenta para que un usuario con acceso a dos cuentas no arrastre un id que en la otra no existe (y aun así D6 lo descarta si no está entre los activos). Se escribe **sólo** cuando la emisión responde OK, no al cambiar el select ni al cancelar. `accountId` sale de la fila del PV (`PointOfSale.accountId`), sin hook de cuenta adicional.

### D9 — Endpoints del predeterminado y transacción

- `POST /fiscal/points-of-sale/{pv_id}/default` → service: `require_account_role(conn, auth, CAN_CONFIGURE)` (el guard canónico de `v3-rbac-multirole`, el mismo de centros de costo y formas de pago); repository: dos sentencias en la transacción del request — `UPDATE … SET is_default = false WHERE account_id = $1 AND is_default AND id <> $2`, luego `UPDATE … SET is_default = true WHERE id = $2 AND account_id = $1 AND is_active RETURNING *`. Si la segunda no devuelve fila → 404 y la transacción se revierte (la marca anterior queda intacta). Dos sentencias y no una sola con `SET is_default = (id = $2)` porque un índice único (no constraint) se verifica fila por fila y no admite `DEFERRABLE`: una sola sentencia puede fallar según el orden físico de las filas.
- `DELETE /fiscal/points-of-sale/default` → `UPDATE … SET is_default = false WHERE account_id = $1 AND is_default` → 204.
- `deactivate` pasa a `SET is_active = false, is_default = false`.
- Todas las sentencias filtran por `account_id` explícito (regla dura de `project_tenancy_leak_hotfix`: la RLS es red, no guard).
- Rutas: `/default` como sub-recurso evita chocar con el `PATCH /{pv_id}` existente, cuyo cuerpo vacío significa "desactivar" (contrato legacy que no se toca).

### D10 — El diálogo revivido: qué se conserva y qué cambia

Se conserva: título, tipo de comprobante resuelto por el backend (no editable), aviso de "comprobante fiscal real", estados sin perfil / sin PV. Cambia: el selector pasa a `PointOfSaleSelect`; los colores `amber-*` literales pasan a los tokens semánticos de advertencia del design system (gate `token-contrast-aa`); el enlace a `/configuracion/fiscal` se mantiene (la ruta existe). El **bloqueo por delegación no autorizada** (`delegacionAutorizada = false` deshabilita confirmar) se convierte en **aviso no bloqueante** (OQ-4): el camino de un solo PV nunca lo tuvo, la RPC no lo verifica, y con el bloqueo una cuenta de varios PV quedaría más restringida que una de uno. En prod los dos perfiles tienen la delegación en `true`, así que hoy no cambia nada observable.

## Risks / Trade-offs

- **[Reescribir `rpc_emit_pending_cae`, que emite comprobantes reales]** → partir del `pg_get_functiondef` vivo; diff mínimo (sólo la rama `> 1`); gate SQL que **ejecuta** la RPC en los cinco casos de resolución (regla del proyecto: un gate que sólo verifica que la función existe no sirve — `rpc_promote_legacy_sale_to_order` vivió rota tres meses así); checkpoint de apply que compara el cuerpo nuevo contra el vivo línea a línea (CRLF del checkout Windows no es divergencia).
- **[Otro PR reescribe `rpc_emit_pending_cae` en paralelo]** (la zona fiscal tuvo 6 PRs en una semana) → el checkpoint del apply re-lee el cuerpo vivo inmediatamente antes de escribir la migración, no el del propose; si cambió, se parte del nuevo.
- **[El predeterminado hace que una emisión sin PV "salga por algún lado" en vez de fallar]** → es exactamente lo que el dueño configuró; la UI igual manda el PV explícito (D4), así que el fallback sólo alcanza a callers que no eligen.
- **[Una pestaña abierta con el bundle viejo]** sigue mandando `[0]`/`null` hasta recargar → con predeterminado configurado, el `null` pasa a funcionar; el `[0]` sigue siendo el comportamiento de hoy. Sin regresión.
- **[`sessionStorage` bloqueado o vacío]** → `usePersistentState` ya lo tolera; D6 cae al predeterminado.
- **[Tests existentes que fijan el comportamiento viejo]** (`sale-operations-list-facturar.test.tsx` mockea dos PV y espera el primero) → se actualizan como parte del RED: el cambio de expectativa ES el cambio de comportamiento pedido.
- **[Número de migración]** `20261062000001` lo tomó `ventas-unidades-conversion` (PR #584, nota del 2026-09-25) y este change pasó a `20261063000001`, que también puede tomarlo otro PR antes del merge → renumerar en el apply (precedente: `cuenta-corriente-party-guard` renumeró tres veces).

## Migration Plan

1. Migración `20261063000001_punto_venta_predeterminado.sql`: `ADD COLUMN IF NOT EXISTS is_default`, CHECK e índice idempotentes (el auto-apply de Supabase GitHub exige migraciones re-ejecutables), `CREATE OR REPLACE rpc_emit_pending_cae` + `COMMENT` + ACLs, y un bloque `DO` de introspección que asserta lo prometido (columna, índice, CHECK, la RPC contiene la rama del predeterminado, ACLs sin `anon`, `md5` de `rpc_emit_subscription_payment_cae` sin cambios).
2. Sin backfill: `is_default = false` en los 4 PV existentes. La facturación desde `/ventas/ordenes` empieza a funcionar igual (el usuario elige en el diálogo); el predeterminado es opcional.
3. Merge → CI/CD aplica la migración y despliega (`feedback_cicd_merge_pipeline`); verificar `MAX(version)` y el cuerpo vivo en prod, y que Render desplegó (`GET /deploys`, el auto-deploy no siempre dispara).
4. **Rollback**: revertir el PR de frontend/backend es inocuo (la columna nueva queda sin uso). Para la RPC, re-aplicar el cuerpo anterior (guardado en el archivo de migración `20261059000001`) en una migración nueva; la columna puede quedarse.

## Open Questions

- **OQ-1 — ¿Al facturar o en la venta?** Recomendado: **al facturar** (D1). Si el PO quiere además verlo en la venta, se evalúa como change aparte cuando haya una cuenta con un PV por local.
- **OQ-2 — Orden de preselección.** Recomendado: última elección de la sesión **antes** que el predeterminado (D6). Alternativa: el predeterminado siempre primero y la memoria sólo cuando no hay predeterminado.
- **OQ-3 — ¿La facturación de suscripciones (`/admin/pagos`) también debería usar el predeterminado del lado del servidor?** Recomendado: **no** en este change (D5) — sólo gana la preselección en la UI.
- **OQ-4 — Delegación no autorizada en el diálogo.** Recomendado: **aviso no bloqueante** (D10). Alternativa: bloquear, y entonces agregar el mismo bloqueo al camino de un solo PV para que sean consistentes.
- **OQ-5 — ¿Marcar un predeterminado automáticamente para Sumar?** Recomendado: **no** — no sabemos cuál prefiere; el dueño lo marca en Configuración (el diálogo funciona sin predeterminado). Si el PO dice cuál, es un `UPDATE` de una fila con su OK, fuera de la migración.

## Sign-off del PO (2026-09-26)

El PO firmó el 2026-09-26: *"arrancá la implementación con lo recomendado de los 2 proposes"*. Cada OQ se resuelve por su opción **recomendada**:

- **OQ-1 → al facturar** (D1). El PV no se elige en la venta ni se persiste en `sales`/`sales_orders`.
- **OQ-2 → última elección de la sesión primero, después el predeterminado** (D6): `resolvePreselectedPointOfSale` = última de la sesión (si sigue activa) > predeterminado > único activo > ninguno.
- **OQ-3 → no** (D5): `/admin/pagos` sólo gana la preselección en pantalla; `rpc_emit_subscription_payment_cae` no se toca (el gate fija su `md5`).
- **OQ-4 → aviso no bloqueante** (D10): con la delegación ARCA no autorizada el diálogo muestra un aviso y deja confirmar.
- **OQ-5 → no** se marca ningún predeterminado automáticamente para Sumar: lo marca el dueño en Configuración. La migración no hace backfill.

## Notas del apply (2026-09-26)

- **D8 — la memoria de la sesión se lee al abrir el diálogo**, no como estado de `useSessionStorage`: ese hook hidrata una sola vez al montar y en `/ventas/ordenes` hay un `EmitInvoiceButton` por fila montados a la vez, así que lo que elegía una fila no lo veía la siguiente. `hooks/persistence/use-session-storage.ts` gana `readSessionValue`/`writeSessionValue` sobre los helpers (ahora exportados) de `use-persistent-state.ts` — mismo formato JSON y mismo `try/catch`, sin duplicarlos.
- **D4 — dos estados más en `EmitInvoiceButton`**: con la lista de PV cargando el botón queda deshabilitado, y si la lista falla muestra un aviso en vez de emitir sin saber por qué PV.
- **D10 — `operationLabel` pasa a opcional** en `EmitirComprobanteDialog` (el botón no conoce el importe; la descripción dice "esta venta").
- **D9 — `PointOfSaleOut.is_default` con default `False`** para que un backend desplegado antes que la migración no rompa la respuesta.
- **Migración**: además del gate, la reaplicación de `20261063000001` se suma a la cadena de `KPI_Validation.yml` sobre el estado reconvergido (idempotencia permanente, schema idéntico).
- El gate y el bloque `DO` comparan el `md5` de `pg_get_functiondef` **sin `\r`**: el checkout de Windows agrega CR a los cuerpos locales (mismo md5 que prod una vez quitados).

## Hallazgos de red-team corregidos antes del merge (2026-09-26)

Una revisión adversarial sobre el apply encontró seis hallazgos (todos `minor`), corregidos en la misma rama antes de abrir el PR — la migración `20261063000001` no estaba aplicada en prod todavía, así que se pudo editar en el lugar:

1. **`is_default` escribible por cualquiera de los 7 roles `is_writer`, no sólo owner/admin** — la RLS de `points_of_sale` habilita UPDATE a todos los roles con `is_writer=true` (`is_account_writer`, desde v3-rbac-multirole), así que un vendedor/cajero podía marcar el predeterminado directo por PostgREST, saltando el guard `CAN_CONFIGURE` del backend. Fix: trigger `trg_points_of_sale_guard_default` (`BEFORE INSERT OR UPDATE`) que rechaza con `P0401` cualquier cambio de `is_default` hecho por un actor sin rol owner/admin en la cuenta — no protege `numero`/`is_active`/`fiscal_profile_id` (deuda preexistente, no de este change). Gate nuevo: bloque `(i)` en `test_punto_venta_predeterminado.sql` (seller rechazado, owner permitido, control negativo sobre otros campos).
2. **TOCTOU en las tres ramas de resolución de PV** — sin lock, una desactivación/cambio de predeterminado concurrente podía dejar un `pending_cae` en un PV que termina inactivo. Fix: los tres `SELECT` toman `FOR SHARE` (conflictúa con el `FOR NO KEY UPDATE` implícito de la desactivación) y la rama de un solo PV activo gana su propio `IF NOT FOUND` → `P0404` (antes reventaba más abajo, en `rpc_next_document_number`, con otro error). Verificado con dos conexiones reales: `test_punto_venta_predeterminado_race.sh` (nuevo, en CI), que confirma con `pg_blocking_pids` que la emisión REALMENTE esperó y nunca queda un comprobante en el PV que quedó inactivo.
3. **Gate sin cobertura para un PV explícito de otra cuenta** — ningún caso ejercitaba `rpc_emit_pending_cae(..., point_of_sale_id => PV ajeno)`; el único freno real hoy es `AND account_id = v_account_id` en la rama explícita, sin ningún gate que lo proteja. Fix: caso `(e3)` nuevo en el gate estático (P0404, cero reserva de número, cero comprobante en ninguna cuenta).
4. **`set_default` sin serializar por cuenta** — dos marcados concurrentes en PVs distintos de la misma cuenta podían chocar con un `23505` genérico (409) en vez de resolverse en orden. Fix: `pg_advisory_xact_lock(hashtextextended(account_id, 0))` antes de la limpieza, en `PointOfSaleRepository.set_default`.
5. **El `md5` de `rpc_emit_subscription_payment_cae` fijado dentro de la MIGRACIÓN** — la migración corre de nuevo en el paso de reaplicación de `KPI_Validation.yml`; una reescritura futura A PROPÓSITO de esa RPC rompería el `DO` block para siempre (a diferencia del gate, la migración no se puede editar una vez aplicada en prod). Fix: el chequeo de `md5` se retiró del `DO` block de la migración y vive sólo en `test_punto_venta_predeterminado.sql`.
6. **Atribución sin verificar del "1 Issue" del overlay de Next en las capturas de `/ventas`** — el hallazgo original de red-team encontró que el overlay aparecía justo al abrir `PointOfSaleSelect`, contradiciendo la nota de `CHANGES.md` que lo atribuía al Tablero sin re-chequear. Pendiente de una repasada con `console.on('pageerror')` abriendo el Select — no bloqueante, candidato anotado en `CHANGES.md`.
