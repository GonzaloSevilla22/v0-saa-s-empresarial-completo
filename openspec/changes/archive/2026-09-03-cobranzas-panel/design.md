## Context

La saga de cobranzas cerrada el 2026-09-02 dejó el **registro** del cobro completo: `rpc_register_payment_received` mueve cuenta corriente, caja, banco y asiento contable de forma atómica; `cobranzas-reverso` agregó la anulación; `cobranzas-catalogo-pagos` unificó la forma de pago al catálogo. Lo que nunca se construyó es la **visibilidad**: no existe hoy ningún `GET` de listado de cuentas corrientes ni ningún RPC de agregado de deuda (verificado por grep sobre las 263 migraciones y sobre `backend/routers/customer_accounts.py`, que expone solo `POST /customer-accounts`, `GET /clientes/{id}/cuenta`, `GET /customer-accounts/{id}/movements`, `POST /customer-accounts/payments` y `DELETE /customer-accounts/payments/{id}` — todos por **un** cliente).

Estado del dominio al escribir este design:

- `customer_accounts`: `balance numeric(15,2)` materializado con `CHECK (balance >= 0)`, `UNIQUE (account_id, client_id)`, RLS solo de `SELECT` (`account_id IN (SELECT current_account_ids())`). Escritura exclusivamente por RPC `SECURITY DEFINER`.
- `customer_account_movements`: ledger append-only con `movement_type ∈ {sale, payment_received, payment_received_reversal, credit_note, adjustment}` y `balance_after` persistido. Índice existente `customer_account_movements_account_customer_created_at_idx`.
- Producción hoy: 5 tenants con cuentas, **11 deudores**, **$567.000** por cobrar, saldo máximo $167.800. El uso arrancó el 2026-08-20 — escala chica y reciente.
- `clients` tiene soft delete (`deleted_at`, `20260811000001_v3_soft_delete_masters.sql`) y el listado lo respeta vía `not_deleted_clause('c')`.

Restricciones de plataforma que aplican: `api-standards` (RFC 7807, envelope `{items,total,page,pages}`), `business-day-timezone` (los días se cuentan en día calendario argentino vía `reporting_local_today()`, nunca `now()`), `responsive-shell` (shell con `min-w-0` desde `qa-integral-modulos`; el breadcrumb deriva un nombre del último segmento para toda ruta no mapeada), y la regla dura del proyecto de **superficie frontend planificada en el propose**.

Governance: **MEDIO-bajo**. Lectura agregada y navegación; ninguna RPC de dinero cambia. El tramo que impide llamarlo "bajo" es `_classified_activity_cte` en `client_repository.py`: es el hot path de `/clientes`, compartido por lista y detalle, y una regresión ahí rompe una pantalla de uso diario entera, no solo la columna nueva.

## Goals / Non-Goals

**Goals:**

- Responder de forma agregada "quién me debe y cuánto" en una sola pantalla, sin recorrer clientes uno por uno.
- Que el cobro esté a un click de esa pantalla, **reutilizando el flujo existente sin modificarlo**.
- Que el total por cobrar sea visible desde el Tablero sin entrar a ninguna pantalla.
- Nivelar `/clientes` con `/proveedores`: saldo visible en la fila y acceso directo a la cuenta corriente.
- No tocar el modelo de datos ni ningún camino de escritura de dinero.

**Non-Goals:**

- **Vencimientos y mora**: `due_date` por cargo, plazo de pago por cliente, aging FIFO por buckets (0-30/31-60/61-90/90+) y avisos automáticos por `pg_cron` son la **Etapa B**, un change futuro ya en discusión con el PO. Sin vencimientos **no existe la mora**, y este change no la insinúa (ver D4).
- **`clients.credit_limit`**: campo huérfano desde C-30. Sigue huérfano; este change no lo activa ni lo lee.
- **Cualquier escritura nueva**: sin RPC de dinero nueva, sin columna nueva, sin trigger, sin evento al outbox, sin backfill.
- **Refactor de `CustomerAccountBalance`** a tokens semánticos (ver D14): se declara el hallazgo, no se arregla acá.
- **Ordenar `/clientes` por saldo**: la columna viaja, pero `_SORT_COLUMNS` no gana una entrada nueva. La tabla ordenable es la de `/cobranzas`.

## Decisions

### D1 — El agregado vive en un RPC `SECURITY DEFINER`, no en un `SELECT` plano del repository

`rpc_receivables_report(p_account_id uuid)`, molde textual de `rpc_payment_method_report`: guard de membresía contra `account_members` con `RAISE ... USING ERRCODE = 'P0401'` como primera sentencia, `SET search_path TO 'public'`, y en el mismo archivo de migración `REVOKE ALL ... FROM PUBLIC`, `REVOKE EXECUTE ... FROM anon`, `GRANT EXECUTE ... TO authenticated`.

*Alternativa considerada*: un `SELECT` plano en el repository apoyado en la RLS de `customer_accounts` — es lo que ya hace `get_account()`, y desde `v31-tenancy-pool-rls` la RLS **sí** se evalúa para el backend, así que sería correcto y más barato. Se descarta por dos razones que se refuerzan: (a) los **dos** reportes agregados que ya existen (`rpc_cost_center_report`, `rpc_payment_method_report`) son RPC con guard explícito, y un tercero que rompa el patrón obliga a cada lector futuro a averiguar por qué; (b) la regla dura del proyecto tras la fuga de tenancy de agosto es *"todo repository filtra explícito por `account_id`, la RLS es red y no guard único"* — con el `P0401` dentro de la función, el chequeo de tenant es responsabilidad de la función y no de un `WHERE` que un caller futuro puede olvidar.

### D2 — El resumen se deriva del mismo RPC, sin una segunda función

`GET /reports/receivables/summary` no llama a un `rpc_receivables_summary` propio: el repository agrega **sobre el RPC del detalle**:

```sql
SELECT COALESCE(SUM(balance), 0)  AS total_receivable,
       COUNT(*)::int              AS debtor_count
FROM   public.rpc_receivables_report($1::uuid)
```

Así el predicado de "quién es deudor" existe **una sola vez**. Un segundo RPC con su propio `WHERE balance > 0 AND deleted_at IS NULL` es exactamente la clase de duplicación que produce que el total de la cabecera no cierre contra la suma de la tabla el día que uno de los dos cambie.

*Alternativa considerada*: devolver el total dentro del envelope de la lista. Se descarta: `api-standards` fija el envelope en `{items, total, page, pages}` —donde `total` es **cantidad de filas**, no dinero— y meter un campo de plata ahí rompe el contrato uniforme y además haría que el KPI del Tablero tuviera que pedir una página de filas que no va a mostrar.

### D3 — Paginación estándar con orden en el servidor

El listado usa `?page&size&sort&sort_dir` y el helper canónico `paginate()` (`select_sql` = `SELECT * FROM public.rpc_receivables_report($1::uuid)`, `count_sql` = `SELECT COUNT(*) FROM ...`), devolviendo el envelope estándar. `sort` y `sort_dir` se validan como `Literal` en la firma del router —mismo patrón que `GET /clients/activity`, donde un valor fuera del dominio ni siquiera llega al service— y se traducen por diccionario a columna, nunca por interpolación.

El orden es **del servidor y no del cliente**: con paginación server-side, ordenar en el navegador ordenaría únicamente la página visible y le mentiría al usuario sobre quién debe más. Orden por defecto: `balance DESC` — la primera pregunta del cobrador.

*Alternativa considerada*: no paginar (hoy son 11 filas). Se descarta porque `api-standards` exige el envelope en **todos** los listados y porque el costo de agregarlo después, cuando la pantalla ya tiene consumidores, es mayor que el de tenerlo ahora.

### D4 — "Días desde el último cargo" no es "días de mora", y se nombra así

El RPC expone dos derivados por deudor:

- `days_since_last_charge`: días entre `reporting_local_today()` y el día del `MAX(created_at)` de los movimientos de tipo **`sale`** de esa cuenta.
- `days_since_last_payment`: ídem sobre los de tipo **`payment_received`**.

Ambos son `NULL` cuando no existe ningún movimiento de ese tipo, y la superficie muestra `—`, nunca `0` (un cliente que nunca pagó no pagó "hoy").

Tres precisiones normativas:

1. **`payment_received_reversal` no cuenta como cobro.** Deshace uno. Contarlo haría que anular un cobro *rejuveneciera* la deuda del cliente en la pantalla.
2. **`credit_note` y `adjustment` no cuentan como cargo.** El primero revierte un cargo; el segundo es corrección manual. Solo `sale` es "le vendí a crédito".
3. **Los días se cuentan en día calendario argentino** vía `reporting_local_today()`, la fuente canónica que `client-activity` ya usa. Nunca `now()` ni el huso del servidor: con el servidor en UTC, un cargo de las 22 h de Mendoza aparecería con un día más de antigüedad.

El rótulo de la columna es **"Último cargo"** / **"Días desde el último cargo"**, no "Días de mora" ni "Vencido hace". Sin vencimientos —Non-Goal explícito— la mora no está definida, y prometer en la etiqueta un dato que el sistema no tiene es cómo un tablero de lectura termina usándose para decisiones que no puede sostener. Un pie de pantalla lo dice con todas las letras.

### D5 — Quién entra en la lista: `balance > 0` y cliente no borrado

`CHECK (balance >= 0)` garantiza que no hay saldos a favor: `balance = 0` es "al día" y no aparece. Los clientes con `deleted_at IS NOT NULL` se **excluyen**, igual que los excluye `/clientes`.

Consecuencia declarada: un cliente borrado con deuda viva queda invisible en el panel. Es coherente —no se puede accionar la cobranza de un cliente que la aplicación ya no lista— pero es una ocultación, no una ausencia. La task de verificación mide el conteo en producción (esperado **0**) y, si no lo fuera, el hallazgo se reporta al PO en vez de resolverse en silencio dentro de este change.

### D6 — El KPI va en la grilla diaria del Tablero, no en el bloque "Resumen KPI"

El bloque `KpiSummaryBlock` calcula 5 tarjetas mensuales con **badge de variación contra el mes anterior** sobre `rpc_dashboard_kpi_summary`. "Por cobrar" es un **stock** —el saldo al instante en que se mira—, no un flujo del período: un delta mensual sobre un stock compararía el saldo de hoy contra el saldo de un día del mes pasado que nadie guardó, y el RPC mensual no tiene de dónde sacarlo. Va, entonces, en la grilla de tarjetas de **hoy** ("Así está tu negocio hoy"), que ya mezcla flujos del día con un stock (`Productos en alerta`).

La grilla pasa de `grid-cols-1 sm:grid-cols-2 lg:grid-cols-4` a `grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-5`, espejo del breakpoint que el bloque mensual ya usa para sus 5 tarjetas (`md:grid-cols-3 xl:grid-cols-5`): cinco tarjetas a 1024 px quedan ilegibles.

### D7 — `KpiCard` gana una prop `href` opcional

La tarjeta enlaza a `/cobranzas`. En vez de envolverla en un `<Link>` en la página del Tablero, la prop vive en el componente canónico: el foco visible, el área clickeable y el `aria` quedan definidos **una vez** para las cinco tarjetas y para las que vengan. Es literalmente la regla de *reutilización antes que repetición* aplicada a la capa canónica.

### D8 — El cobro se reutiliza entero, y la invalidación vive en el hook, no en la pantalla

El botón **Cobrar** de cada fila abre un `Dialog` con `RegisterPaymentForm` tal cual está: trae ya el selector del catálogo (`context="collection"`), el guard de cuenta bancaria, el opt-in de caja pre-marcado y la idempotencia. **Cero formulario nuevo, cero prop nueva.**

La invalidación de las claves de `receivables` se agrega **dentro de `useRegisterPayment` y `useReversePayment`** (capa canónica), no en el `onSuccess` de la pantalla nueva. Si se hiciera solo en la pantalla, cobrarle a un cliente desde `/clientes/[id]/cuenta` dejaría el panel y el KPI mostrando una deuda ya cobrada hasta el próximo refetch — exactamente el defecto que el proyecto ya registró como lección ("invalidar cuentas corrientes en TODAS las mutaciones que postean cargos").

Por la misma razón, las mutaciones que **crean** deuda (venta a crédito desde el formulario y desde el POS) también invalidan las claves nuevas.

### D9 — El saldo de `/clientes` viaja en el read-model existente, no en una consulta por fila

`_classified_activity_cte` suma un `LEFT JOIN public.customer_accounts ca ON ca.account_id = c.account_id AND ca.client_id = c.id` y proyecta `COALESCE(ca.balance, 0)::numeric AS current_balance`. El `JOIN` es 1:0..1 sobre el índice `UNIQUE (account_id, client_id)` que ya existe: no multiplica filas ni cambia el `COUNT` de la paginación.

Se elige el CTE compartido y no una consulta aparte por tres razones: la spec de `client-activity` exige *"una sola consulta por página, sin N+1"*; el CTE lo usan **lista y detalle** por igual, así que el saldo aparece en los dos sin escribirlo dos veces; y una llamada por fila a `GET /clientes/{id}/cuenta` sería un N+1 sobre el hot path.

`ClientActivityOut` gana `current_balance: Decimal` (default `0`, no `None`): "sin cuenta corriente" y "cuenta corriente en cero" son lo mismo para el lector.

### D10 — Sin gate de plan

`GET /reports/receivables` y su `/summary` están disponibles a todo miembro de la cuenta, sin `require_plan`. Mismo criterio ya firmado para el reporte de formas de pago y el de centros de costo: la cuenta corriente está disponible en todos los planes, y gatear su único lector agregado dejaría al plan free registrando deuda que no puede leer.

### D11 — Entrada de sidebar en **Operaciones**, no en Análisis

`/cobranzas` va en el grupo **Operaciones**, junto a Caja y Banco. Es una tarea diaria del negocio —abrir, mirar, llamar, cobrar—, no un reporte de análisis; el grupo Análisis agrupa lecturas que se consultan para decidir, no para operar. Sin `pro`/`proOnly`, coherente con D10. El grupo Operaciones queda oculto para el admin de plataforma, igual que hoy.

`/cobranzas` se agrega además al mapa de nombres del breadcrumb: `responsive-shell` ya garantiza un nombre derivado del último segmento para rutas no mapeadas, pero el mapa explícito es el que produce el rótulo correcto en la pantalla de uso diario.

### D12 — Sin índice nuevo

El agregado de días recorre `customer_account_movements` filtrando por `customer_account_id` y `movement_type`, tomando el `MAX(created_at)` — cubierto por el índice existente `(account_id, customer_account_id, created_at)`. A 11 deudores y unos pocos cientos de movimientos, un índice parcial por `movement_type` sería optimización sin medición. Se declara para que la ausencia sea decisión y no olvido; si el padrón crece un orden de magnitud, se mide con `EXPLAIN ANALYZE` antes de agregarlo.

### D13 — El RPC devuelve el nombre del cliente, no solo su id

La fila del reporte trae `client_id`, `client_name`, `balance`, `days_since_last_charge`, `days_since_last_payment` y `last_payment_date`. Resolver el nombre en el frontend contra un segundo fetch de clientes sería un N+1 disfrazado; resolverlo en el RPC es un `JOIN` que ya está ahí por el filtro de soft delete.

### D14 — La cabecera usa tokens semánticos, no los literales de `CustomerAccountBalance`

El patrón de cabecera de saldo que se pide reutilizar (`CustomerAccountBalance`) usa `text-yellow-400`, `text-emerald-400`, `bg-yellow-500/10` **hardcodeados**, fuera del sistema de tokens que `tokens-contraste-aa` canonizó y sin garantía de contraste AA en tema claro. Se reutiliza la **estructura** (rótulo, monto grande tabular, leyenda, ícono en píldora) y se traduce el color a tokens semánticos (`text-warning`, `text-success`, `text-foreground`, `bg-warning/10`).

`CustomerAccountBalance` **no se refactoriza acá**: es superficie de otra pantalla, el change no la toca por ningún otro motivo y arrastrarla convertiría un change de lectura en un change de design system. Queda anotado como candidato.

## Risks / Trade-offs

- **[Tocar `_classified_activity_cte` rompe `/clientes` entero]** → Es el único tramo de riesgo real del change. Mitigación: red de seguridad del TDD estricto (correr y registrar los tests existentes del read-model de actividad **antes** de tocarlo, y exigir el mismo verde después); el `JOIN` es 1:0..1 sobre un `UNIQUE` existente, de modo que no puede alterar el `COUNT` de la paginación ni duplicar filas; y un test explícito fija que la cantidad de filas y el `total` del envelope no cambian al agregar la columna.
- **[El usuario lee "días desde el último cargo" como mora]** → Rótulo explícito (D4) + nota al pie de la pantalla diciendo que el sistema todavía no tiene vencimientos. La Etapa B convierte el dato en mora real; hasta entonces la pantalla no promete lo que no puede sostener.
- **[Un deudor con cliente borrado queda invisible]** → Declarado en D5; se mide el conteo en producción durante la verificación (esperado 0) y, si aparece, se reporta en vez de taparse.
- **[Una request más en el render del Tablero]** → El KPI consume `/summary`, que devuelve dos escalares y ninguna fila.
- **[`paginate()` ejecuta el RPC dos veces (`SELECT` + `COUNT`)]** → Aceptado a esta escala; es el precio de reutilizar el helper canónico en vez de escribir un conteo a mano. Se mide si el padrón de deudores crece.
- **[El panel muestra el saldo materializado, no la suma del ledger]** → Deliberado y consistente con todo el módulo: `balance` es la fuente de verdad del saldo y sumar el ledger en el hot path está explícitamente prohibido por la spec de `customer-account`. Si el materializado divergiera del ledger, el defecto está aguas arriba y no es este panel quien debe compensarlo.

## Migration Plan

1. **Migración** `20261021000001_receivables_report.sql` (la última viva es `20261020000001`): `CREATE OR REPLACE FUNCTION public.rpc_receivables_report(...)` + `COMMENT ON FUNCTION` + los tres statements de ACL en el mismo archivo. Idempotente ante reaplicación (auto-apply de Supabase GitHub). Sin DDL sobre tablas.
2. **Backend**: repository → service → router; el `report_router` nuevo se registra en `main.py` junto a los otros `/reports/*`.
3. **Frontend**: pantalla, hooks, mapper, sidebar, breadcrumb, KPI, columna de `/clientes`.
4. **Deploy**: el merge dispara build + deploy + `supabase db push` automáticos (pipeline vigente). Nada manual.
5. **Verificación post-merge en producción**: `MAX(version)` de `supabase_migrations`, ACLs exactas de la función nueva (`anon` sin `EXECUTE`), conteo de deudores del panel contra `SELECT count(*) FROM customer_accounts WHERE balance > 0` y contra los $567.000 medidos en la exploración.
6. **Rollback**: `DROP FUNCTION public.rpc_receivables_report(uuid)`. Sin datos que revertir —el change no escribe ninguna fila—; la pantalla degrada a su `EmptyState` y `/clientes` a la columna de saldo en `0`.

## Open Questions

- **OQ-1 — ¿Incluir la sección/pestaña espejo "Por pagar" (`supplier_accounts`) en `/cobranzas`?**
  *Recomendación: **sí, incluirla.*** `supplier-account` es el espejo simétrico de `customer-account` —mismo agregado, mismo ledger append-only, mismos tipos de movimiento— así que el RPC, el endpoint, el mapper y la tabla salen del mismo molde con el nombre cambiado, y el PO tiene el mismo problema de visibilidad del otro lado del mostrador (`/proveedores` tampoco agrega la deuda). El costo marginal es bajo y el costo de agregarlo después es un segundo change con su propia migración. Requiere sign-off del PO porque duplica la superficie de este change.
- **OQ-2 — ¿La fila del deudor debe ofrecer contacto directo (teléfono / WhatsApp)?**
  *Recomendación: no en la Etapa A.* La ficha del cliente ya está a un click desde la fila y trae los datos de contacto. El contacto asistido pertenece a la Etapa B, junto con los avisos automáticos, para no construir dos veces la misma plantilla de mensaje.
- **OQ-3 — ¿El KPI "Por cobrar" del Tablero debe respetar el `BranchFilter`?**
  *Recomendación: no.* `customer_accounts` no referencia sucursal: la deuda es de la cuenta, no de la sucursal donde se originó la venta. Filtrarla por sucursal exigiría repartir el saldo entre las ventas que lo formaron, que es exactamente el aging FIFO de la Etapa B. La tarjeta declara que el total es de la cuenta.
- **OQ-4 — ¿Mostrar deudores cuyo saldo nació de un `adjustment`, sin ninguna venta a crédito?**
  *Recomendación: sí, con `—` en "último cargo".* Deben plata igual; ocultarlos por no tener el derivado haría que el total de la cabecera no cerrara contra la tabla.
