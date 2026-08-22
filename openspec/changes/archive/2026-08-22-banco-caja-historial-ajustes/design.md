## Context

### Lo que hay hoy (verificado contra prod `gxdhpxvdjjkmxhdkkwyb`, sólo SELECTs, 2026-08-22)

**Caja (C-28 / `v21-cash-session`)**

| Pieza | Estado real |
|---|---|
| Ruta | `frontend/app/(dashboard)/sucursales/[id]/caja/page.tsx` — **sin entrada de sidebar**; sólo se llega desde el detalle de sucursal (40 sucursales en prod) |
| `cashboxes` | `id, branch_id, name, currency, created_at, deleted_at, deleted_by` — 37 activas |
| `cash_sessions` | `+ status ('open'\|'closed'), opening/closing/counted/expected_balance, difference, opened_by/at, closed_by/at`; índice único parcial `one_open_per_cashbox` — 2 sesiones, **ambas abiertas** |
| `cash_movements` | `id, session_id, amount, movement_type, reference_id, balance_after, created_by, created_at` — **sin columna de motivo**, sin `account_id` (RLS por cadena `session→cashbox→branch→account`) — 65 filas (63 `sale`, 2 `sale_reversal`) |
| CHECK de tipo | `sale, purchase_payment, expense, advance, withdrawal, sale_reversal` — **ningún tipo de ajuste** |
| Escritura | `rpc_register_cash_movement` (guard `is_account_writer`) → `c28_register_cash_movement` (helper intra-tx: `FOR UPDATE` sobre la sesión, `balance_after = opening + Σamount + p_amount`, exige sesión `open` `P0409` y sucursal activa `P0422`) |
| Cierre | `rpc_close_cash_session` — `expected = opening + Σ(amount)`, `difference = counted − expected`, `record_status_transition`, evento `CashSessionClosed`, idempotencia por `operation_idempotency` |
| Lectura frontend | `useCashMovements(sessionId)` → `GET /sessions/{id}/movements` — **lista plana, sólo la sesión activa, sin paginación** |

**Banco (V2.5 C1/C2/C3)**

| Pieza | Estado real |
|---|---|
| Ruta | `frontend/app/(dashboard)/finanzas/conciliacion/page.tsx`, sidebar "Bancos" → esa ruta. **No hay pantalla de movimientos** |
| `bank_movements` | `id, bank_account_id, account_id (denormalizado), amount, balance_after, movement_type, value_date, branch_id, source_doc_type, source_doc_ref, description, created_at, reconciliation_status, reconciled_at` — 3 filas, todas `transfer_in`, **las 3 con `description` NULL** |
| CHECK de tipo | `transfer_in, transfer_out, card_settlement, fee, tax_debit, interest, **manual_adjustment**` — el tipo de ajuste **ya existe** |
| Escritura manual | `rpc_register_bank_movement(p_idempotency_key, p_bank_account_id, p_amount, p_type, p_value_date, p_branch_id, p_description)` — idempotente, rechaza `card_settlement` con `P0410`, `p_description` **opcional** |
| Conciliación (C3) | Opera sólo sobre `bank_movements` vs `bank_statement_lines`; `reconciliation_status ∈ {unreconciled, matched}` |

**Contabilidad**

`_journal_post_from_event` se alimenta de **9 event types de negocio** (`SaleConfirmed`, `PaymentReceived`, `PaymentMade`, `PurchaseCreated`, `SaleOperationCreated`, `SaleOperationAdjusted`, `SaleOperationDeleted`, `PurchaseDeleted`, …) y **nunca de una fila de ledger**. Plan de cuentas hardcodeado: `1100 Caja`, `1110 Banco`, `1300 Deudores`, `2100 Proveedores`, `4100 Ventas`, `4200 IVA Débito`, `5100 CMV/Compras`, `5200 IVA Crédito`, `5300 Gastos (reservado)`. En prod hay 6 códigos usados: `1100, 1110, 1300, 2100, 4100, 5100`. El spec `bank-movement` tiene la requirement literal **"C1 no postea al journal contable"**.

**Molde de UX**: `frontend/components/stock/stock-movements-panel.tsx` — `Collapsible.Root` + cabecera con resumen, `MOVEMENT_META` (label/ícono/color/familia por tipo), píldoras de filtro **empujadas al servidor** (`.in("type", …)`), búsqueda client-side sobre lo cargado, `pageRef` para evitar el double-fetch de Strict Mode, `MovementRow` memoizado, "Ver más" de a 30 y export CSV.

### Restricciones

- `cash_movements.session_id` es `NOT NULL` ⇒ **todo movimiento de caja, incluido el ajuste, necesita una sesión**. Esto ata el ajuste de caja al modelo de sesiones actual (ver OQ-1).
- El ledger es **append-only** por spec en ambos libros (RN-98): sin UPDATE ni DELETE.
- `expected_balance = opening + Σ(cash_movements.amount)` y su `difference` son **señal antifraude (RN-95)**, ya declarada como requirement en `cash-session`.
- Gobernanza **MEDIUM**: toca dinero sobre helpers ya en producción → implementar con checkpoints y superficie explícita.

## Goals / Non-Goals

**Goals**

1. Caja como módulo de primer nivel con ruta y entrada de sidebar propias, sin obligar a pasar por Sucursales.
2. Banco como módulo de primer nivel con la conciliación adentro, reutilizando los componentes C3 sin reescribirlos.
3. Un historial de movimientos **legible y filtrable** en ambos libros, al molde del de Stock, con **un solo componente compartido**.
4. Un ajuste manual con **motivo obligatorio**, append-only, en ambos libros.
5. Que el ajuste de caja **no pueda tapar** la diferencia de arqueo.

**Non-Goals**

- Rediseñar el modelo de sesiones de caja ("caja siempre abierta") — **OQ-1**, decisión del PO, y este design no depende de la respuesta.
- Postear asientos contables por ajustes — **OQ-2**, requiere `event_type` y cuentas nuevas.
- Tocar el algoritmo de matching, las sugerencias o el cierre de conciliación de C3.
- Multi-caja por sucursal (el modelo real sigue siendo 1 caja por sucursal; la UI queda preparada con selector pero no lo introduce).
- Editar o borrar movimientos existentes.

## Decisions

### D1 — Un solo componente de historial, dos configuraciones de libro

`components/ledger/LedgerMovementsPanel.tsx` calcado del molde de Stock, parametrizado por un descriptor de libro:

```
LedgerBookConfig = {
  book: 'cash' | 'bank'
  meta: Record<MovementType, { label, icon, className, family }>
  families: { key, label, types[] }[]     // píldoras de filtro
  columns: …                              // columna extra por libro
  fetchPage(params): Promise<Page<LedgerMovementRow>>
  csvName: string
}
```

Caja aporta la columna **Sesión** (fecha de apertura + badge abierta/cerrada); Banco aporta la columna **Conciliación** (badge `unreconciled`/`matched`) y el filtro por estado.

*Alternativa descartada*: dos paneles independientes (`CashMovementsPanel` + `BankMovementsPanel`). Se descarta por la regla PO de **reutilización antes que repetición** — es exactamente el caso que produjo los 5 cálculos divergentes de criticidad de stock. Las diferencias reales entre libros son una columna y un filtro, no una estructura.

*Qué se hereda del molde y qué se corrige*: se heredan `Collapsible`, `MOVEMENT_META`, filtros server-side, `pageRef`, fila memoizada, "Ver más" y CSV. Se **corrige** el atajo del molde de tener el buscador sólo client-side sobre las páginas cargadas: acá el filtro de texto va al servidor junto con el resto, para que no repita el bug que el propio molde documenta ("filtrar por Pérdidas no mostraba resultados").

**Tokens semánticos, no colores crudos**: el molde de Stock usa `text-emerald-400` / `bg-red-500/15` literales, que es exactamente lo que `tokens-contraste-aa` (2026-08-17) sacó del resto de la app. El componente nuevo usa el patrón superficie/texto por rol vía `cva` y pasa el gate `token-contrast-aa.test.ts`.

### D2 — El historial de caja es por **caja (cashbox)**, no por sesión

Hoy la lectura es `GET /sessions/{id}/movements`. El PO pidió "historial como el de stock": continuo, no cortado por sesión. Endpoint nuevo:

```
GET /cashboxes/{cashbox_id}/movements?page&size&types&q&from&to
  → {items, total, page, pages}            # api-standards
```

El repositorio hace `cash_movements ⋈ cash_sessions` filtrando por `cashbox_id`, ordenado `created_at DESC`, y devuelve `session_id`, `session_opened_at`, `session_status` en cada fila. RLS de `cash_movements` ya cubre el aislamiento por la cadena de FKs; el pool va con **JWT-passthrough**, sin `service_role`.

Índice nuevo `cash_movements(session_id, created_at DESC)` — el existente es `(session_id, created_at)` ascendente, que sirve pero fuerza backward scan en el orden que usa la pantalla.

`GET /sessions/{id}/movements` **se conserva** (lo usa el panel de sesión activa); no se rompe nada.

### D3 — El historial de banco es por **cuenta bancaria**

```
GET /bank-accounts/{bank_account_id}/movements?page&size&types&status&q&from&to
  → {items, total, page, pages}
```

Sobre `bank_movements` con `account_id IN (SELECT current_account_ids())` (RLS denormalizada existente) más `bank_account_id`. El índice `(bank_account_id, value_date DESC)` ya existe y cubre el orden natural; el orden de la pantalla es `value_date DESC, created_at DESC` para desempatar movimientos del mismo día.

Vive en un router propio `backend/routers/bank_movements.py` (+ `services/bank_movements.py`), no dentro de `bank_reconciliation.py`: el historial no es conciliación, y `bank_reconciliation.py` ya tiene 13 endpoints.

### D4 — Ajuste de caja: tipo nuevo + columna de motivo + CHECK

```sql
ALTER TABLE cash_movements ADD COLUMN IF NOT EXISTS description text;
-- CHECK de tipo ampliado con 'adjustment' (drop + recreate del constraint)
-- motivo obligatorio SÓLO para adjustment:
ALTER TABLE cash_movements ADD CONSTRAINT cash_movements_adjustment_needs_reason
  CHECK (movement_type <> 'adjustment' OR (description IS NOT NULL AND btrim(description) <> ''))
  NOT VALID;
```

`NOT VALID` porque las 65 filas históricas tienen `description` NULL y ninguna es `adjustment`: el CHECK gobierna lo nuevo sin reescribir el pasado. Se valida acto seguido (`VALIDATE CONSTRAINT`) porque el predicado ya se cumple — el `NOT VALID` es sólo para no bloquear la tabla durante el ADD.

El motivo se propaga por firma: `rpc_register_cash_movement(p_session_id, p_amount, p_type, p_reference_id, **p_description**)` → `c28_register_cash_movement(..., p_description)`. Firma nueva ⇒ **REVOKE explícito** de `PUBLIC`, `anon` y `authenticated` + `GRANT` selectivo en el mismo archivo de migración (gotcha visto 6 veces: `DROP+CREATE` resetea ACLs).

*Alternativa descartada*: dos tipos `adjustment_in` / `adjustment_out`. El `amount` ya es signado en todo el ledger (patrón de C-28 y de C1 bancario) — duplicar el signo en el tipo es redundante y rompe la simetría con `bank_movements.manual_adjustment`, que es un tipo único signado.

*Alternativa descartada*: reusar `withdrawal` / `advance` para ajustar. Enmascara el ajuste como una operación real y hace imposible separarlo en el arqueo (D5).

### D5 — El ajuste no tapa el arqueo: `adjustments_total` + `difference_before_adjustments`

Sin esto el ajuste es un agujero antifraude directo: `expected = opening + Σamount` incluye los ajustes, así que un ajuste de +100 antes del cierre lleva `difference` a 0.

```sql
ALTER TABLE cash_sessions ADD COLUMN IF NOT EXISTS adjustments_total numeric(12,2);
```

En `rpc_close_cash_session`, en la misma transacción del cierre:

```
adjustments_total := Σ(amount) FILTER (movement_type = 'adjustment')   -- de la sesión
expected          := opening + Σ(amount)          -- SIN CAMBIOS (incluye ajustes)
difference        := counted − expected           -- SIN CAMBIOS
difference_before_adjustments := difference + adjustments_total
```

`expected` y `difference` **no cambian de definición** — cambiarlas rompería el arqueo y la requirement vigente de `cash-session`. Lo que se agrega es la cifra que permite reconstruir qué habría dado el arqueo sin los ajustes. El evento `CashSessionClosed` suma `adjustments_total` al payload; el `close_reason` de `record_status_transition` menciona los ajustes cuando `adjustments_total <> 0`, para que la señal quede en el historial de estados y no sólo en la fila.

La UI muestra siempre las dos cifras juntas cuando hay ajustes: *"Dif. $0 · 1 ajuste manual de +$100 (sin ajustes: +$100)"*. Un ajuste no borra evidencia — la deja escrita al lado.

`adjustments_total` es un **snapshot al cierre** (patrón `v3-snapshot-pattern`), no un cálculo en tiempo de lectura: el ledger es append-only, así que el snapshot no puede quedar desactualizado, y sobrevive a futuras reinterpretaciones del tipo `adjustment`. Para sesiones abiertas la cifra se calcula al vuelo en la lectura.

### D6 — Ajuste de banco: sólo endurecer el motivo, nada más

`rpc_register_bank_movement` ya acepta `manual_adjustment` y ya es idempotente por `Idempotency-Key`. El único cambio:

```
IF p_type = 'manual_adjustment'
   AND (p_description IS NULL OR btrim(p_description) = '') THEN
  RAISE EXCEPTION 'adjustment_reason_required' USING ERRCODE = 'P0413';
END IF;
```

`P0413` es libre en el rango que ya usan `P0410` (tipo reservado) y `P0412` (cuenta inexistente/inactiva) en esta misma función. Se agrega el mismo CHECK a nivel tabla (`NOT VALID`) para que ningún camino futuro lo esquive. Las 3 filas históricas son `transfer_in`, no `manual_adjustment` — no las alcanza.

Se reescribe partiendo del `pg_get_functiondef` **vivo** de prod, no de la migración original (regla nacida de la regresión silenciosa del bloque `credit` de C-30).

*Por qué no un endpoint nuevo*: `POST /bank-accounts/{id}/movements` ya existe (`routers/bank_reconciliation.py:120`) y ya invoca la RPC. Sólo hay que darle superficie y pasar el motivo obligatorio para `manual_adjustment`.

### D7 — Los ajustes no postean asiento contable (decisión fundada, con gate)

Tres hechos verificados lo determinan:

1. `bank-movement` tiene la requirement vigente **"C1 no postea al journal contable"** — postear un ajuste bancario la contradiría de frente.
2. `_journal_post_from_event` consume **eventos de negocio**, no filas de ledger. Un ajuste no tiene documento detrás; postearlo exigiría un `event_type` nuevo y una rama nueva en un consumidor que ya tiene 9.
3. El plan de cuentas real **no tiene** cuenta de resultado para diferencias. Un ajuste de caja necesitaría `4300 Otros ingresos` (sobrante) / `5400 Diferencias de caja y banco` (faltante) — códigos que hoy no existen en `journal_lines` (los 6 usados son `1100, 1110, 1300, 2100, 4100, 5100`).

Además, el drift libro↔contabilidad **ya existe y es de diseño**: el `difference` del arqueo no postea nada, y los movimientos bancarios manuales (`fee`, `tax_debit`, `interest`) tampoco. El ajuste se suma a esa categoría; no abre una brecha nueva.

**Gate (OQ-2)**: si el PO quiere el asiento, el diseño está listo y es un change chico y separable — dos códigos de cuenta nuevos, un `event_type` `LedgerAdjustmentPosted` y una rama en el consumidor. Se decide **después** de que el PO vea el ajuste funcionando, no antes.

### D8 — Rutas y superficie (regla PO de superficie frontend)

| Módulo | Ruta canónica | Sidebar | Rutas viejas |
|---|---|---|---|
| Caja | `/caja` | grupo **Operaciones**, título "Caja", ícono `Banknote`, `pro:false` `proOnly:false` | `/sucursales/[id]/caja` → redirige a `/caja?branch=<id>` |
| Banco | `/banco` (tabs `Movimientos` \| `Conciliación`) | grupo **Operaciones**, "Bancos" pasa a **"Banco"** → `/banco`, ícono `Landmark` (se conserva) | `/finanzas/conciliacion` → redirige a `/banco?tab=conciliacion` |

`/caja` resuelve sucursal y caja adentro: selector de sucursal (auto-seleccionada si hay una sola) → selector de caja (auto si hay una sola, que es el caso de las 37 cajas de prod). Estructura: tarjeta de sesión (`CashSessionPanel` existente) + barra de acción (abrir/cerrar/**Registrar ajuste**) + `LedgerMovementsPanel` en modo `cash`.

`/banco`: selector de cuenta + tarjeta de saldo + barra de acción (**Registrar ajuste** / Registrar movimiento) + `LedgerMovementsPanel` en modo `bank`, y la tab de conciliación montando `ReconciliationBoard`, el importador y `BankAccountFormDialog` **tal como están** (cero reescritura de C3).

Los redirects son `redirect()` de Next en un Server Component — no `useEffect`, para que no haya flash ni links rotos en marcadores del PO.

Verificación obligatoria antes del merge: **desktop y mobile**, **tema claro y oscuro**, tokens semánticos, componentes base vía `cva`.

### D9 — Diálogo de ajuste compartido

`components/ledger/LedgerAdjustmentDialog.tsx`, un solo diálogo para ambos libros: importe con signo explícito (radio *Sobrante (+)* / *Faltante (−)* + monto absoluto, para que nadie se equivoque de signo), **motivo obligatorio** (validado en el cliente con Zod y en el servidor con el CHECK — el cliente no es la autoridad), y un aviso claro de que el ajuste es **irreversible y queda registrado**: se corrige con otro ajuste, no se borra.

En Banco suma `value_date` (default hoy) y manda `Idempotency-Key`. En Caja exige sesión abierta y lo dice en el propio diálogo si no la hay.

## Risks / Trade-offs

- **El ajuste de caja se convierte en el nuevo camino para "arreglar" cualquier cosa, incluidos errores que deberían corregirse en la operación** → El diálogo nombra el ajuste como *consolidación contra el conteo real*, no como corrección de operaciones; el historial lo muestra con badge propio y motivo visible; el arqueo lo separa (D5). Se mide en la primera revisión: si aparecen ajustes con motivos del tipo "venta mal cargada", el problema es de la edición de operaciones, no de la caja.
- **`adjustments_total` se calcula al cierre; una sesión que nunca se cierra nunca lo materializa** → En prod hay **2 sesiones abiertas, una desde el 17-07**. La lectura de sesión abierta calcula la cifra al vuelo, así que la señal está disponible aunque nadie cierre. El snapshot es una optimización de las cerradas, no la única fuente.
- **El CHECK de motivo obligatorio corre sobre una tabla con tráfico de ventas** → `NOT VALID` en el `ADD`, `VALIDATE` inmediato después (el predicado ya se cumple para las 65 filas). Sin reescritura de tabla, sin lock largo.
- **`rpc_register_cash_movement` y `c28_register_cash_movement` cambian de firma y están en el hot path de la venta** (63 de los 65 movimientos son `sale`) → Parámetro nuevo con `DEFAULT NULL` al final ⇒ los llamadores existentes compilan sin tocarse. Aun así: **gate ANTI-OVERLOAD** en la migración (fallar si queda más de una firma viva, gotcha `42725`), `REVOKE`+`GRANT` explícitos, y verificación de que la venta desde POS y desde formulario sigue registrando caja.
- **`p_type='manual_adjustment'` sin motivo pasa de aceptado a rechazado (BREAKING de contrato)** → 0 filas `manual_adjustment` en prod y ningún llamador productivo. El riesgo real es cero; se declara igual porque el contrato de la RPC cambia.
- **Dos rutas nuevas + dos redirects tocan navegación en producción** → Los redirects son server-side y permanentes; los tests E2E de conciliación se actualizan al nuevo path en el mismo PR; la entrada de sidebar vieja no queda huérfana (se repunta, no se borra).
- **El historial de banco muestra `unreconciled` para movimientos viejos y puede leerse como "algo está mal"** → El badge se acompaña de leyenda; `unreconciled` es el estado natural de nacimiento, no un error. El filtro por estado permite aislar lo pendiente sin que domine la vista.
- **Un componente compartido para dos libros puede volverse un `if book === 'cash'` por todos lados** → El descriptor de libro (D1) concentra las diferencias en un objeto de configuración; si aparece un tercer punto de divergencia estructural (no de datos), se revisa la abstracción antes de agregarlo.

## Migration Plan

1. **Antes de escribir la migración**: `SELECT MAX(version) FROM supabase_migrations.schema_migrations` — verificado hoy = `20261005000001` (255 migraciones). El archivo nuevo es `supabase/migrations/20261006000001_banco_caja_historial_ajustes.sql`.
2. **Migración única, idempotente** (`IF NOT EXISTS` / `DROP CONSTRAINT IF EXISTS` + `ADD`): columnas, CHECKs, índice, y las 4 RPCs redefinidas partiendo de su `pg_get_functiondef` vivo. Gate ANTI-OVERLOAD por función con firma nueva. `REVOKE ALL ... FROM PUBLIC, anon, authenticated` + `GRANT EXECUTE TO authenticated` explícitos en el mismo archivo, después de cada `CREATE OR REPLACE`.
3. **`.github/workflows/KPI_Validation.yml`**: agregar el eslabón de reapply de `20261006000001` después del de `20261005000001`, con el comentario de reconvergencia si el reapply de la anterior dispara su propio gate.
4. **Backend** (3 capas, JWT-passthrough, RFC 7807): endpoints de listado paginado + ajuste de caja; router de movimientos bancarios.
5. **Frontend**: componentes compartidos → páginas nuevas → sidebar → redirects. La migración se aplica sola al mergear (CI/CD).
6. **Rollback**: las columnas son aditivas y nullable; los CHECKs se pueden `DROP` sin pérdida de datos; las RPCs vuelven a su definición previa (guardada en `baseline/` del change). Ninguna fila existente se reescribe, así que el rollback no pierde información.

## Open Questions

**OQ-1 — ¿Se conservan las sesiones de caja con arqueo, o se pasa a "caja siempre abierta"? (PO, bloqueante sólo para un change futuro)**

El PO pidió el 2026-08-21, al firmar `delete-guard-ledgers` OQ-3, *"que siempre esté abierta la caja"*; el pedido del 2026-08-22 **no lo reafirma** — reemplaza la parte de módulo unificado pero deja esta sin mencionar.

Este design **no depende de la respuesta**: el historial y el ajuste valen igual en los dos mundos. Lo único que se apoya en el modelo actual es que el ajuste de caja **exige una sesión abierta** (porque `cash_movements.session_id` es `NOT NULL`), y eso queda **gateado** en una sola requirement, aislable.

- **Opción A — conservar sesiones con arqueo (recomendada por ahora).** El historial + el ajuste **atacan la molestia real** que motivó el pedido: la caja dejaba de ser consultable al cerrar y no había forma de corregirla. Con las dos piezas, la sesión deja de ser una cárcel. Costo: cero. Se conserva la señal antifraude RN-95, que es lo que hace auditable el efectivo.
- **Opción B — caja siempre abierta.** Elimina de raíz el escenario que `P0426` bloquea como interino. Costo: es un **rediseño de C-28/RN-95** — sin cierre no hay `expected_balance`, no hay `difference`, no hay arqueo, y `cash_sessions` pierde su razón de ser. Requiere su propio explore/propose y toca producción.
- **Opción C — híbrida**: sesión permanente por caja con "cortes de arqueo" periódicos que fotografían el saldo sin cerrar el libro. Conserva el arqueo y elimina el bloqueo, a cambio de un modelo nuevo.

**Pregunta concreta al PO**: con el historial completo y el ajuste manual ya disponibles, ¿la sesión de caja sigue molestando lo suficiente como para justificar rediseñar el arqueo?

**OQ-2 — ¿Los ajustes deben generar asiento contable? (PO, no bloqueante)**

Este change decide que **no** (D7), por tres razones verificadas: contradiría la requirement vigente *"C1 no postea al journal contable"*, el consumidor sólo entiende eventos de negocio, y el plan de cuentas no tiene cuenta de diferencias. Si el PO quiere el asiento, el diseño está listo: `4300 Otros ingresos` (sobrante, crédito) / `5400 Diferencias de caja y banco` (faltante, débito) contra `1100 Caja` o `1110 Banco`, vía un `event_type` `LedgerAdjustmentPosted` y una rama nueva en `_journal_post_from_event`. Es un change chico y separable — se decide viendo el ajuste funcionando.

**OQ-3 — ¿Quién puede registrar un ajuste? (PO / RBAC)**

V1 usa el guard existente `is_account_writer`, el mismo que gobierna abrir/cerrar caja y registrar movimientos. Si el ajuste debe ser privilegio de `owner`/`admin` (defendible: es la operación que puede tapar un faltante), la restricción entra por `v3-rbac-multirole`, que es **CRÍTICO y sigue esperando sign-off del PO**. Se deja anotado, no se adelanta.

**OQ-4 — ¿Cuánto historial mostrar por defecto? (producto, resoluble sin PO)**

V1: sin rango por defecto, orden descendente, `size=30` como el molde de Stock, con filtros de fecha disponibles. Con 65 movimientos de caja y 3 bancarios en prod no hay presión de volumen; se revisa si algún libro pasa las decenas de miles.

**OQ-5 — ¿Multi-caja por sucursal? (producto, diferido)**

El modelo permite N cajas por sucursal pero la UI actual asume la primera (`cashboxes[0]`) y prod tiene 37 cajas para 40 sucursales — es decir, 1:1. `/caja` incluye el selector de caja (oculto cuando hay una sola), así que el día que aparezca la segunda la pantalla ya la soporta. No se agrega ABM de cajas en este change.
