## Context

**Lo que hay hoy en prod** (`gxdhpxvdjjkmxhdkkwyb`, verificado por SELECT el 2026-08-19):

| Hecho | Evidencia |
|---|---|
| `sales` (681 filas) y `purchases` (427) **no tienen** columna de forma de pago | `information_schema.columns` |
| `sales_orders.payment_method` TEXT NOT NULL DEFAULT `'other'`, CHECK `{cash,transfer,card,other,credit}` | `pg_constraint` |
| Valores vivos: 63 `cash` + 57 `other`, todas `confirmed` (22-jun → 15-ago) | `SELECT payment_method, count(*)` |
| Sólo el POS lo escribe, y su UI ofrece **dos botones**: "Efectivo" y "Otro / Transferencia" | `app/(dashboard)/ventas/pos/page.tsx` |
| `cash` **ya mueve caja**: 63 `cash_movements` de tipo `sale`, `reference_id` → `sales_orders` (63/63) | `cash_movements` |
| `credit` **ya está cableado** en `rpc_confirm_sales_order` (C-30: exige `client_id`, postea cargo en `customer_account_movements`) **pero no tiene ninguna puerta de entrada en la UI** | migración `20260720000001` + POS |
| Cuenta corriente vacía: `customer_account_movements` = 0, `supplier_account_movements` = 0, `payments_received` = 0, `payments_made` = 0 | conteos |
| Banco: `bank_accounts` = 6, `bank_movements` = 0 | conteos |
| Segunda taxonomía viva: RPCs de cobro/pago con `p_payment_method ∈ {cash,transfer,card,check}` + `p_bank_account_id` → rutean a `bank_movements` y al asiento 1110 | `20260804000007_bank_payment_routing.sql` |
| `v3-provisioning-seed` declaró "formas de pago" fuera de alcance por no existir catálogo | `20260812000001`, líneas 31-33 |
| Última migración aplicada | `20260927000001` |

**Precedente que este change copia casi literalmente**: el change `cost-center-surface` (tabla `cost_centers` + `cost_center_id` en `purchases`/`expenses` + `CostCenterSelect` + `CostCenterManager` en `/configuracion` + `rpc_cost_center_report` + `/reportes/centros-costo` + entrada de sidebar + filtro y badge en el listado de compras). Y el precedente de "campo de header en operación" es `sales.canal` (columna replicada por línea, `p_canal =>` como parámetro nombrado de la RPC, `SALE_CHANNELS` en el form, KPI de margen por canal).

**Restricciones**: governance MEDIUM; migración idempotente (la integración GitHub de Supabase auto-aplica al mergear, antes del `db push` de Actions); las 4 RPCs de operaciones tienen base vigente `20260927000001` y no se puede tocar el acarreo de líneas (#415) ni el espejo de `stock_movements` (#417); strict TDD.

## Goals / Non-Goals

**Goals**

1. Que el usuario pueda decir **con qué se pagó** cada venta y cada compra, con un catálogo que él mismo puede renombrar y ampliar.
2. Que el sistema pueda razonar sobre eso de forma estable (`kind`) sin depender del texto que el usuario escriba.
3. Que se vea y se filtre donde ya se opera (forms y listados) y que exista una lectura agregada (reporte).
4. Cero regresión en ventas, compras, stock, líneas, caja, POS y facturación.

**Non-Goals**

- Tocar el POS (`rpc_quick_sale`, `rpc_confirm_sales_order`) o el CHECK de `sales_orders.payment_method`.
- Cablear efectos: caja obligatoria, cargo automático en cuenta corriente, movimiento bancario, asiento contable.
- Tocar las RPCs de cobro/pago (`rpc_register_payment_received/made`) ni su ruteo bancario.
- Pagos parciales o múltiples formas de pago en una misma operación (un método por operación).
- Plan de cuentas / mapeo contable por forma de pago (V2.6).

## Decisions

### D1 — Tabla maestra `payment_methods`, no enum fijo

El PO escribió "efectivo, banco, cuenta corriente, **etc**": el conjunto es abierto y cada negocio nombra distinto lo mismo ("Mercado Pago", "Cuenta DNI", "Naranja X"). Un enum obligaría a una migración por cada alta.

*Alternativa descartada*: enum fijo en TEXT + CHECK (es lo que ya tiene `sales_orders`, y por eso el POS quedó con dos opciones durante un año). *Alternativa descartada*: catálogo global del sistema (`is_system = true`, como unidades de medida) — no aplica: la lista es idiosincrática de cada negocio.

Estructura = espejo de `cost_centers` (tenancy account-direct, RLS por `account_id`, unique case-insensitive) más `sort_order` (el orden de un selector de uso diario importa) y soft delete `deleted_at`/`deleted_by` (`soft-delete-policy`, que `cost_centers` ya adoptó).

### D2 — `kind` cerrado como contrato interno, `name` libre como etiqueta

`kind ∈ {cash, transfer, card, check, wallet, credit, other}`. Es deliberadamente el **superset de las dos taxonomías que ya existen**: el CHECK de `sales_orders` (`cash, transfer, card, other, credit`) y la de las RPCs de cobro/pago (`cash, transfer, card, check`). Así, el día que se cablee de verdad, no hay traducción que inventar: `kind` ya habla el idioma de ambos lados. `wallet` es el único valor nuevo (billeteras virtuales, muy usadas en Mendoza) y hoy no tiene consumidor.

Consecuencia deliberada: renombrar no cambia el comportamiento; el usuario manda en el rótulo, el sistema manda en la semántica.

### D3 — `payment_method_id` nullable en `sales` y `purchases`, por operación

Columna `uuid NULL REFERENCES payment_methods(id) ON DELETE SET NULL`, replicada en todas las filas de la operación. Es exactamente lo que ya hacen `purchases.cost_center_id` y `sales.canal` sobre el header plano (RN-97 sigue vigente hasta el DROP del Grupo 10 de C-20).

*Alternativa descartada*: tabla `operation_payments` (N formas por operación). Correcta para pagos mixtos, pero el pedido es "categorías de pago", no split de cobros; agrega una tabla, una UI de reparto y un problema de cuadre que nadie pidió. Si aparece la necesidad, `payment_method_id` NULL + tabla hija es una evolución compatible.

*Alternativa descartada*: guardar el texto del método en la operación (desnormalizado). Rompe el renombrado y obliga a normalizar en cada reporte.

### D4 — Las 4 RPCs de operaciones: `DROP` + `CREATE` con cuerpo preservado

`rpc_create_sale_operation`, `rpc_create_purchase_operation`, `rpc_atomic_update_sale_operation`, `rpc_atomic_update_purchase_operation` ganan un parámetro trailing `p_payment_method_id uuid DEFAULT NULL`. Cambiar la aridad con `CREATE OR REPLACE` **crea un overload** y deja la llamada anterior ambigua (42725) — el error que ya nos mordió. Por lo tanto: `DROP FUNCTION IF EXISTS <firma vieja exacta>` + `CREATE` + `REVOKE`/`GRANT` re-emitidos **en el mismo archivo** (los GRANTs no sobreviven al DROP).

El cuerpo se copia **byte a byte** desde la base vigente (`20260924000001` para las de alta, `20260927000001` para las de edición, que es la última que las redefine), con el único agregado del parámetro, su validación de pertenencia y su persistencia. El dispatcher del flag `sale_items_rpc_v2` y las versiones `_v2` se preservan tal cual; el parámetro se propaga al `_v2` igual que ya se propaga `p_canal`.

Desde el repositorio Python se llama por **parámetro nombrado** (`p_payment_method_id => $N`), como ya se hace con `p_canal =>`, para que el orden posicional no sea una bomba futura.

### D5 — Edición: `NULL` significa "no informado", no "borrar"

La semántica de preservación se resuelve con un COALESCE contra el valor vigente de la operación: si la edición no envía método, se conserva el que había (incluido en las líneas nuevas de esa edición). Para **desimputar** hay que elegir explícitamente "Sin especificar" en el selector, lo que en el payload viaja como un sentinel distinto de "ausente".

*Alternativa descartada*: que ausente = borrar. Convertiría cualquier edición hecha desde un cliente viejo en una pérdida silenciosa de datos — el mismo tipo de hueco que dejó la edición sin líneas (OQ-1 de `deudas-menores-agosto`).

### D6 — Históricos: `NULL` = "Sin especificar", sin inventar nada

Los 1.108 documentos previos no dicen con qué se pagó. Backfillear "Efectivo" sería fabricar un dato y contaminaría el primer reporte con una afirmación falsa. Se muestran como "Sin especificar", que es la verdad.

Única excepción propuesta (**OQ-5**, gateada): las 120 ventas nacidas en el POS **sí** tienen el dato, declarado por el usuario en su orden (63 `cash`, 57 `other`). Backfillear `sales.payment_method_id` de esas operaciones desde el texto de la orden no inventa nada, sólo lo copia.

### D7 — El POS no se toca; el listado lo lee

Unificar el POS al catálogo implicaría reescribir `rpc_quick_sale` y `rpc_confirm_sales_order` — dos funciones grandes con caja, cuenta corriente, AFIP e idempotencia — en el mismo change que ya reescribe otras cuatro. Se difiere (**OQ-1**).

Mientras tanto, para que el listado de ventas no muestre "Sin especificar" en operaciones que sí tienen el dato, se deriva **de lectura**: `LEFT JOIN sales_orders so ON so.sale_operation_id = s.operation_id` y se mapea `so.payment_method` → la forma de pago sembrada con ese `kind`. Cero escritura, y la imputación explícita siempre gana.

### D8 — Etiqueta honesta: el selector dice lo que NO hace

Elegir "Cuenta corriente" en el form de venta **no** genera cargo en la cuenta corriente del cliente, y elegir "Efectivo" **no** entra a la caja. Si el selector no lo dice, el usuario va a asumir que sí, y el sistema va a mentir en silencio (es el mismo patrón de superficie huérfana que dejó `credit` cableado sin UI y la cuenta corriente en cero). El form muestra un texto de apoyo cuando el `kind` elegido es `credit` o `cash`, apuntando a la pantalla donde eso sí se registra.

### D9 — Reporte: espejo de `rpc_cost_center_report`, con la excepción RN-D1 declarada

`rpc_payment_method_report(p_account_id, p_start, p_end)`: `SECURITY DEFINER`, `search_path` fijo, verificación de membresía (P0401), `COALESCE(total, amount)`, `COUNT(DISTINCT COALESCE(operation_id, id))`, bordes `>= p_start AND < p_end + 1`, salidas `NUMERIC`. Lee `sales` y `purchases` (documentos operativos), no `journal_lines` — mismo motivo que el reporte de centros de costo: el asiento es async por outbox y no cubre todo.

**No resta notas de crédito**: una NC no tiene forma de pago atribuible, y repartirla proporcionalmente sería inventar. Es una excepción explícita a RN-D1, del mismo tipo que la ya documentada para el margen por canal, y se declara tanto en la spec como en la propia pantalla ("no descuenta notas de crédito").

### D10 — Superficie: nada nuevo que no tenga puerta de entrada

- `PaymentMethodSelect` (espejo de `CostCenterSelect`) → forms de venta y compra + filtro de ambos listados.
- `PaymentMethodManager` (espejo de `CostCenterManager`) → montado en `/configuracion`, en la misma pasada en que se lo escribe (la regla PO existe justamente porque `CostCenterManager` estuvo construido y sin montar).
- `/reportes/formas-pago` + entrada en el sidebar, grupo "Inteligencia", **sin gate de plan** — mismo argumento que el reporte de centros de costo: el catálogo está disponible en todos los planes, gatear su único lector dejaría al free imputando datos que no puede leer.
- Badge del método en las tarjetas de operación de ambos listados.
- Todo con tokens semánticos y componentes base vía `cva`; verificación explícita desktop + mobile y claro + oscuro antes del merge.

### D11 — Seed por provisioning: patrón `v3-provisioning-seed` textual

Parte A: backfill idempotente de las cuentas existentes (`INSERT ... WHERE NOT EXISTS`). Parte B: `CREATE OR REPLACE handle_new_user()` sobre la base exacta `20260812000001`, agregando **sólo** un sub-bloque `BEGIN ... EXCEPTION WHEN OTHERS THEN RAISE WARNING ... END` — un fallo del seed nunca puede abortar un signup. Parte C: gate de comportamiento auto-limpiante que dispara el trigger real y degrada con NOTICE si el contexto no lo permite.

## Risks / Trade-offs

- **Romper las 4 RPCs al recrearlas (alto impacto: ventas y compras dejan de funcionar)** → cuerpo copiado byte a byte desde la migración base; gates SQL obligatorios que verifican, sobre la nueva versión, que la creación sigue escribiendo `sale_items`/`purchase_items` (#415) y que la edición sigue escribiendo `stock_movements` (#417), además de los de método.
- **Overload fantasma (42725) si el DROP no matchea la firma vieja** → el `DROP FUNCTION IF EXISTS` se escribe con la firma exacta leída de `pg_get_function_identity_arguments`, y un gate falla si tras la migración existe más de una función con el mismo `proname`.
- **GRANTs perdidos por el DROP** → `REVOKE ALL FROM PUBLIC` + `GRANT EXECUTE TO authenticated` re-emitidos en el mismo archivo, con gate de ACL (`test_function_acl_gate.sql` ya corre en cada PR).
- **El usuario cree que "Cuenta corriente" fía** → D8 (texto explícito) + OQ-2 al PO. Riesgo residual aceptado y visible.
- **Asimetría de caja**: el arqueo sigue cuadrando sólo contra el POS; una venta "Efectivo" cargada desde el form no entra a la sesión de caja → declarado en el reporte y en OQ-3.
- **Dos fuentes de verdad transitorias** (texto en `sales_orders` vs `payment_method_id` en `sales`) → mitigado por D7 (la derivación es de lectura y la imputación explícita gana) y cerrado por OQ-1.
- **`handle_new_user` es el trigger de signup** → sólo se agrega un sub-bloque protegido; el core (profile/account/membership/emails) queda intacto y fail-fast.

## Migration Plan

1. Migración única `202609280000xx_payment_methods_operaciones.sql`, idempotente y re-ejecutable (la integración GitHub auto-aplica antes del `db push`): (1) tabla + RLS + índices + unique parcial; (2) columnas en `sales`/`purchases`; (3) backfill del catálogo por cuenta; (4) `handle_new_user`; (5) `DROP`+`CREATE`+`GRANT` de las 4 RPCs; (6) `rpc_payment_method_report`; (7) gates de comportamiento en DO-blocks que degradan con NOTICE.
2. Backend (repos/services/routers/schemas) y frontend en el mismo PR; el manager se monta en `/configuracion` en esa misma pasada.
3. Verificar `MAX(version)` en prod antes de numerar (última conocida `20260927000001`).
4. **Rollback**: `UPDATE payment_methods SET is_active = false` deja el selector vacío sin tocar datos. Rollback duro = restaurar las 4 RPCs desde `20260924000001`/`20260927000001` y `handle_new_user` desde `20260812000001` (esos archivos las contienen íntegras); las columnas y la tabla se dejan (son aditivas e inocuas, y borrarlas perdería imputación real).

## Open Questions

> **Firma del PO — 2026-08-19** (previa a codear): backfill de las 120 ventas del POS = **SÍ** (OQ-5). Cableados profundos (OQ-1/OQ-2/OQ-3/OQ-4) = **FUERA de este change**, recomendados como change siguiente `pos-catalogo-pagos`. Detalle por OQ abajo.

- **OQ-1 — Unificar el POS al catálogo** (`rpc_quick_sale`/`rpc_confirm_sales_order` reciben `payment_method_id`, derivan el texto legacy y lo persisten en `sales`). *Recomendación: SÍ, como change siguiente*, no acá: son las dos funciones con caja + cuenta corriente + AFIP, y meterlas en el mismo change que reescribe otras cuatro multiplica el blast radius. **DECISIÓN PO 2026-08-19: gateado — FUERA de `metodos-pago-operaciones`. Recomendado para `pos-catalogo-pagos`.** Mientras tanto D7 (derivación de lectura desde `sales_orders.payment_method`) resuelve el listado sin escribir nada.
- **OQ-2 — ¿"Cuenta corriente" debe generar el cargo automático en `customer_account_movements`?** El backend **ya lo hace** en `rpc_confirm_sales_order` desde C-30, pero ninguna pantalla lo ofrece: por eso el ledger tiene 0 filas. *Recomendación: exponerlo primero en el POS (junto con OQ-1) y recién después evaluarlo en el form de venta*. **DECISIÓN PO 2026-08-19: gateado — FUERA. Se mantiene D8 (texto explícito: elegir "Cuenta corriente" en el form NO genera el cargo).**
- **OQ-3 — ¿"Efectivo" fuera del POS debe exigir sesión de caja abierta y generar `cash_movement`?** *Recomendación: NO por ahora*. **DECISIÓN PO 2026-08-19: confirmado NO — gateado, FUERA. Asimetría de caja declarada en el reporte y en el PR.**
- **OQ-4 — ¿Ampliar el CHECK de `sales_orders.payment_method` y el ruteo contable a `wallet` y `check`?** *Recomendación: junto con OQ-1*. **DECISIÓN PO 2026-08-19: gateado — FUERA, junto con OQ-1.**
- **OQ-5 — ¿Backfillear las 120 ventas del POS** (63 `cash` → "Efectivo", 57 `other` → "Otro") desde el texto de su orden? *Recomendación: SÍ*. **DECISIÓN PO 2026-08-19: SÍ, confirmado.** Implementado como script firmado no-migración (`scripts/sql/backfill_payment_method_pos_sales.sql`), ejecutado una vez post-merge vía MCP con conteos antes/después. Tolera las 3 `sales_orders` sin operación viva (huérfanas de un borrado previo, decisión PO del mismo día: no se reconstruyen).
- **OQ-6 — ¿La forma de pago debe volverse obligatoria en las altas nuevas?** *Recomendación: NO ahora*. Sin cambios — sigue opcional.
- **OQ-7 — ¿Aplica también a gastos (`expenses`)?** *Recomendación: fuera de alcance*. Sin cambios — `expenses.cost_center_id` ya existe, la extensión a `payment_method_id` sería mecánica si el PO la pide más adelante.
