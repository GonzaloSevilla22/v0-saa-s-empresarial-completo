## Context

La Etapa A (`cobranzas-panel`) dejó el tablero de deudores en pie y escribió explícitamente el hueco que esta etapa cierra: *"Sin vencimientos no existe la mora, y este change no la insinúa"* (su D4). Este change crea el dato que faltaba.

Estado del dominio al escribir este design, verificado contra el repo y contra producción (2026-09-02):

- **No existe ninguna noción de vencimiento**. `due_date`, `payment_terms`, `plazo` y `dias_credito` no aparecen en ninguna migración, schema Pydantic ni tipo TypeScript del dominio de cuentas corrientes. La columna `clients.credit_limit` existe desde C-30 y sigue huérfana (Non-Goal firmado: sigue así).
- **El ledger es append-only y el saldo está materializado**: `customer_accounts.balance numeric(15,2) CHECK (balance >= 0)`, `UNIQUE (account_id, client_id)`; `customer_account_movements` con `amount`, `balance_after`, `movement_type ∈ {sale, payment_received, payment_received_reversal, credit_note, adjustment}` y `reference_id`. Espejo exacto del lado proveedor con `{purchase, payment_made, payment_made_reversal, debit_note, adjustment}`. Las seis tablas tienen RLS **sólo de `SELECT`**: la escritura es exclusivamente por RPC `SECURITY DEFINER`.
- **Punto de paso único de los cargos**: `_pay_register_party_charge(p_account_id, p_party_kind, p_party_id, p_amount, p_reference_id, p_operation_id)`, que despacha a `c30_get_or_create_*_account` + `c30_register_*_account_movement` y emite `CustomerAccountCharged`/`SupplierAccountCharged` al outbox. Lo llaman los tres caminos de alta: `rpc_create_sale_operation` (formulario de venta), `_c29_confirm_order_core` (POS) y `rpc_create_purchase_operation` (compra). El helper fue **revocado de `authenticated`** por el hotfix `20261010000001` — sólo lo invocan RPCs `SECURITY DEFINER`.
- **Cobros y reversos ya completos**: `rpc_register_payment_received`/`_made` con 7 argumentos (5º = `p_payment_method_id uuid` desde `20261020000001`), y `rpc_reverse_payment_received`/`_made` desde `20261019000001`, que compensan cuenta corriente, caja, banco y asiento.
- **Infraestructura de avisos lista para replicar**: `_produce_plan_expiring_soon()` (barrido `pg_cron` `0 12 * * *`, una CTE encadenada que inserta en `email_logs` y, **sólo para las filas realmente insertadas**, en `public.events`), el Consumer 4 `_notification_from_event` con 8 tipos en-scope y `_notification_audience` con 4 targets, `notifications` con TTL de 30 días, la campana `NotificationBell` con su `TYPE_LABELS`, y `send-email` con ~17 plantillas.
- **Precedente de contacto directo al cliente final**: `buildWhatsAppUrl(phone, text)` en `frontend/lib/phone-utils.ts` (normalizador argentino `549…` + fallback al selector de contactos), usado hoy por el envío de comprobantes de venta. Tabla `sale_notifications` con `channel = 'whatsapp_link'` como bitácora.
- **Producción**: 5 tenants con cuentas corrientes, 11 deudores, $567.000 por cobrar, deuda más vieja de 13 días (el uso arrancó el 2026-08-20). Del lado proveedor, **una** cuenta con saldo 0.
- **Última migración viva**: `20261020000001`. `cobranzas-panel` reserva `20261021000001`.

Restricciones de plataforma que aplican: `api-standards` (RFC 7807, envelope `{items,total,page,pages}`, `Idempotency-Key` por header), `business-day-timezone` (`reporting_local_today()`, nunca `now()` ni el huso del servidor), `responsive-shell`, `soft-delete-policy`, el gate de integridad de función (toda reescritura parte del `pg_get_functiondef` vivo), el gate de ACLs con sus 5 chequeos, el invariante **D13** de `transactional-outbox` (11 `event_type` canónicos del Consumer 3, con gate real desde `cobranzas-reverso`), y la regla dura del proyecto de superficie frontend planificada en el propose.

**Governance por grupo:**

| Grupo | Nivel | Por qué |
|---|---|---|
| G1 — Columnas de plazo y de vencimiento | MEDIO | DDL aditivo nullable sobre tablas de dinero; sin backfill. |
| G2 — Helpers de cargo + 3 callers de alta | **ALTO** | Escriben dinero real; una regresión rompe venta a crédito, POS y compra a la vez. |
| G3 — Derivación FIFO y reportes | MEDIO | Sólo lectura, pero el número que produce dispara reclamos a clientes reales. |
| G4 — Barrido y avisos | BAJO | Lectura + `INSERT` en `email_logs`/`events`; no toca ningún libro. |
| G5 — Superficie frontend y configuración | BAJO | Salvo el formulario de venta, que es superficie del tramo alto. |

## Goals / Non-Goals

**Goals:**

- Que cada cargo a cuenta corriente nazca sabiendo **cuándo vence**, con el plazo resuelto de la política del negocio y editable en la venta puntual.
- Que "vencido" sea un dato derivable y auditable, no una etiqueta: imputación FIFO explícita, y el importe abierto de cada cargo visible en el historial.
- Que la deuda vencida **busque al usuario** una vez por día, en vez de esperar a que abra la pantalla.
- Que el reclamo esté a un click: recordatorio de WhatsApp con el mensaje ya escrito.
- Simetría cliente/proveedor sin duplicar lógica: un mecanismo, dos partes.
- **No convertir a nadie en moroso por defecto**: sin plazo configurado, no hay vencimiento.

**Non-Goals:**

- `clients.credit_limit` (firmado), backfill de vencimientos históricos, materialización de la imputación, intereses/punitorios, asiento de previsión por incobrabilidad, y edición del vencimiento de un cargo ya posteado (ver OQ-1).
- Cambiar el saldo materializado o la naturaleza append-only del ledger.
- Tocar el conjunto canónico de 11 `event_type` del Consumer 3 (`transactional-outbox` D13): un vencimiento no mueve plata.
- Pasada de tablet 768–1024 px más allá de lo que ya cubre `responsive-shell` — sigue vigente el residuo `tablet-filtros-cta` de `qa-integral-modulos`, que este change no agrava ni resuelve.

## Decisions

### D1 — El vencimiento vive en la **fila de cargo del ledger**, congelado al postearlo

`customer_account_movements.due_date date NULL` y su espejo en `supplier_account_movements`. Se escribe **una sola vez**, en el `INSERT` que crea el movimiento; nunca se actualiza. La tabla sigue siendo append-only en el sentido que importa: ninguna fila se modifica después de nacer.

*Alternativas consideradas:*

- **Tabla de open-items** (`receivable_open_items`, una fila por cargo con su saldo abierto y su vencimiento, actualizada por cada cobro). Se descarta: duplica el saldo —que ya está materializado y ya tiene su invariante— y crea un tercer lugar donde la plata puede divergir del ledger. Todo el módulo de cobranzas se construyó sobre "el ledger es la verdad y el balance es su materialización"; agregar una tercera fuente es el camino a que el panel y la cuenta corriente digan cosas distintas.
- **Derivar el vencimiento al leer**, como `fecha del cargo + plazo actual del cliente`, sin persistir nada. Es tentador porque **no exigiría tocar ninguna RPC de dinero** — el tramo caro de este change. Se descarta por dos razones independientes y ambas fatales: (a) el PO pidió explícitamente que la fecha sea **editable por venta puntual**, y un override no tiene dónde vivir; (b) cambiar el plazo del cliente reescribiría retroactivamente el vencimiento de toda su deuda pasada, lo que en un módulo de cobranza no es una preferencia sino un error — el vencimiento es un hecho pactado el día de la venta, no una función del presente.
- **Columna en el documento** (`sales.due_date`). Se descarta: la deuda vive en el ledger de la cuenta corriente y no todo cargo tiene documento propio (un `adjustment` no lo tiene). Poniéndola en el documento, la derivación FIFO tendría que hacer un `JOIN` opcional a dos tablas distintas según el origen.

El punto (b) es además el argumento positivo: congelar el vencimiento en la fila es exactamente el **patrón snapshot** que el proyecto ya adoptó en `document-snapshots` (nombre, SKU, costo, IVA e identidad fiscal congelados en la línea). Este change no inventa un patrón; aplica el que ya rige.

### D2 — El plazo se resuelve en cascada de tres niveles, y **`NULL` significa "sin vencimiento"**

```
plazo_efectivo := COALESCE(<parte>.payment_terms_days, accounts.default_payment_terms_days)
due_date       := CASE WHEN plazo_efectivo IS NULL THEN NULL
                       ELSE <fecha local del cargo> + plazo_efectivo END
```

Las tres columnas (`accounts.default_payment_terms_days`, `clients.payment_terms_days`, `suppliers.payment_terms_days`) son `smallint NULL` con `CHECK (>= 0)`. **Ninguna tiene `DEFAULT 0`.**

Esto es deliberado y es la decisión de producto más importante del change. Un `DEFAULT 0` significaría "vence el día de la venta": mañana a la mañana, las cinco cuentas de producción amanecerían con toda su deuda nueva marcada como vencida y una notificación de mora que nadie pactó. Con `NULL`, la funcionalidad es **opt-in**: hasta que el dueño configure un plazo, los cargos nacen sin vencimiento, el panel los muestra en un tramo propio y el barrido no avisa nada. El `0` explícito sigue siendo válido y significa lo que dice —*contado a la vista*— pero es una elección, no una herencia.

*Alternativa considerada*: plazo obligatorio con default de 30 días. Se descarta por lo mismo: instalaría una política comercial que ningún tenant eligió, sobre deuda real.

### D3 — La cascada se resuelve **dentro de `_pay_register_party_charge`**, y el override la atraviesa

El parámetro `p_due_date date` es **trailing y opcional** en toda la cadena. Si viene con valor, **es** el vencimiento; si viene `NULL`, el helper compartido resuelve la cascada de D2 leyendo el plazo de la parte y el de la cuenta. No existe forma de decir "esta venta no vence" cuando el cliente tiene plazo configurado.

El punto importante es **dónde** se resuelve: en el helper, no en los tres callers. `_pay_register_party_charge` ya recibe la cuenta, el tipo de parte y el identificador de la parte —tiene todo lo que la cascada necesita— y ya es el único autor del cargo por requirement vigente. Resolverla en cada caller la duplicaría por triplicado y abriría la puerta a que la misma venta venza distinto según se cargue desde el mostrador o desde el formulario, que es exactamente la clase de divergencia silenciosa que este helper existe para impedir (y que ya ocurrió en este proyecto: el bloque `credit` de C-30 borrado en silencio del POS durante meses).

Consecuencia práctica sobre el tramo de riesgo alto: el diff de los tres callers se reduce a **transportar un parámetro**, sin lógica nueva en ninguno. Toda la lógica de vencimiento vive en un solo cuerpo de función.

Como el parámetro es trailing y opcional, un caller que quedara sin migrar sigue compilando y postea un cargo válido **sin vencimiento** en vez de fallar — degradación segura, no silenciosa: la task de verificación mide que los tres caminos produzcan vencimiento cuando hay plazo configurado.

*Alternativa considerada*: un booleano `p_override_due_date` o una fecha centinela, para distinguir "no vino" de "vino vacío". Se descarta como sobre-ingeniería: el plazo configurado **es** la política del negocio, y "vendo a crédito a este cliente sin fecha de pago" no es un caso que el PO haya pedido ni que tenga sentido operativo. Si aparece, el parámetro extra se agrega después sin romper nada.

Guard: `p_due_date` anterior a la fecha del cargo se rechaza con `P0400` (`due_date_before_charge`). Un vencimiento **en el pasado pero posterior al cargo** se acepta: registrar hoy una venta de la semana pasada con vencimiento ya cumplido es legítimo y ocurre.

### D4 — La imputación FIFO es una **derivación pura por línea de flotación**, no un estado

No hay tabla de imputaciones ni columna `applied_amount`. Por cuenta corriente:

1. **Cargos** (los que pueden estar abiertos): las filas de tipo `sale` (o `purchase`) y las de `adjustment` con importe positivo. Se ordenan por `(COALESCE(due_date, created_at AT TIME ZONE 'America/Argentina/Mendoza'::date), created_at, id)` ascendente.
2. **Crédito disponible**: la suma, **con su propio signo y negada**, de *todas las demás* filas del ledger. Cobros y notas de crédito son negativos, así que suman crédito; un `payment_received_reversal` es positivo, así que **resta** crédito.
3. **Línea de flotación**: se acumulan los cargos en orden; el crédito los cancela hasta agotarse. El cargo donde cae la línea queda parcialmente abierto; los posteriores, enteros.

De aquí salen tres propiedades que sostienen todo lo demás:

- **Invariante de cierre**: `SUM(importe abierto) = customer_accounts.balance`, por construcción — `balance = Σcargos − Σcréditos` es la misma resta que la línea de flotación reparte. El panel, los buckets y el saldo no pueden discrepar.
- **El reverso se resuelve solo.** Anular un cobro inserta un movimiento positivo que reduce el crédito disponible: la línea baja y los cargos vuelven a abrirse **en orden exactamente inverso** al que se cerraron. Con imputación materializada habría que localizar y desandar cada aplicación de ese cobro; acá no hay nada que desandar. Esta es la razón principal por la que la imputación no se materializa.
- **Es total y a prueba de vocabulario nuevo.** Un `movement_type` futuro que no esté en la lista de cargos simplemente entra al pozo de crédito con su signo: el invariante de cierre sigue valiendo, aunque ese tipo no genere un ítem abierto propio. Nada queda sin contabilizar en silencio.

*Alternativa considerada*: clasificar por **signo** (`amount > 0` = cargo). Se descarta por un caso concreto: `payment_received_reversal` es positivo, y tratarlo como cargo crearía un ítem abierto **fechado hoy y sin vencimiento** cada vez que se anula un cobro, en vez de reabrir la deuda original. Anular un cobro rejuvenecería la mora — el mismo defecto que la Etapa A ya evitó en su D4 para la antigüedad.

### D5 — Orden de imputación y clasificación por tramo son **dos reglas distintas**

Se separan a propósito:

- **Para imputar** (qué cancela cada cobro): orden cronológico por `COALESCE(due_date, fecha local del cargo)`. Los cargos históricos sin vencimiento —los más viejos, de agosto— se cancelan **primero**, que es lo que de hecho ocurre en el mostrador.
- **Para clasificar** (en qué tramo cae lo abierto): sólo un cargo **con** `due_date` puede estar vencido. `due_date IS NULL` cae siempre en el tramo **sin vencimiento**, por viejo que sea.

Mezclarlas produciría una de dos mentiras: o los cargos sin fecha nunca se cobran (si se los manda al final de la cola), o la deuda de agosto aparece vencida sin que nadie haya pactado un plazo.

Tramos, con `hoy = reporting_local_today()` y `dias_vencido = hoy − due_date`:

| Tramo | Condición |
|---|---|
| Al día | `due_date >= hoy` (incluye el que vence hoy) |
| Vencido 1-30 | `1 ≤ dias_vencido ≤ 30` |
| Vencido 31-60 | `31 ≤ dias_vencido ≤ 60` |
| Vencido +60 | `dias_vencido > 60` |
| Sin vencimiento | `due_date IS NULL` |

**Sin vencimiento es un tramo propio, no se pliega a "al día".** Plegarlo diría "este cliente está al día" sobre deuda de la que no sabemos nada — exactamente el tipo de afirmación que el requirement *"El panel no promete mora"* de la Etapa A existía para impedir. Los cinco tramos suman el saldo.

### D6 — El read-model de la Etapa A **se extiende**; no nace un segundo RPC

`rpc_receivables_report(p_account_id uuid)` gana `overdue_total`, los cinco tramos, `oldest_due_date` y `days_overdue_max`. Cambia el tipo de retorno, así que va por `DROP FUNCTION` + `CREATE` (un `CREATE OR REPLACE` con `RETURNS TABLE` distinto falla con `42P13`), con las ACLs re-emitidas en el mismo archivo.

Es la aplicación directa del D2 de la Etapa A: *"el predicado de quién es deudor existe una sola vez"*. Un `rpc_receivables_aging` aparte tendría su propio `WHERE balance > 0 AND deleted_at IS NULL`, y el día que uno de los dos cambiara, el total de la cabecera dejaría de cerrar contra los buckets de la tabla que tiene al lado.

El espejo `rpc_payables_report(p_account_id uuid)` **sí** es una función nueva: no existe ninguna del lado proveedor. Es el molde textual del de clientes con `supplier` en lugar de `client`.

### D7 — El aging por documento viaja en las **dos** consultas de listado de movimientos

`due_date`, `is_overdue`, `days_overdue` y `open_amount` se agregan a `list_movements()` **y** a `list_movements_page()` de `customer_account_repository.py`, y a sus espejos de proveedor.

No es una precaución teórica: `cobranzas-reverso` ya se comió exactamente este bug. Sus derivados de anulabilidad se sumaron primero sólo al endpoint paginado, y las pantallas reales de cuenta corriente usan `get_account()` → `list_movements()`, una query distinta — el botón "Anular" no habría aparecido nunca pese a los tests unitarios en verde. El bloque de cuatro `EXISTS` está duplicado literal entre ambas; los derivados nuevos entran en las dos, y una task del apply lo verifica sobre la pantalla, no sobre el test.

*Deuda declarada*: la duplicación de ese bloque es un defecto conocido y este change lo **agranda** en vez de arreglarlo. Extraerlo a una CTE compartida es un refactor del hot path del historial, ajeno al alcance firmado; queda como candidato con la razón escrita.

### D8 — El barrido produce **un aviso por cuenta y por día**, no uno por deudor

`_produce_receivables_overdue_digest()`, molde textual de `_produce_plan_expiring_soon()`: una CTE encadenada que (1) agrega por cuenta los deudores con importe vencido > 0, (2) inserta en `email_logs`, y (3) inserta en `public.events` **sólo para las filas que el `INSERT` de email realmente insertó** — un solo dedup para los dos canales. `pg_cron` diario a las `0 12 * * *` (~09:00 Mendoza, franja user-facing, misma que el precedente).

Un aviso por deudor convertiría 11 deudores en 11 campanas y 11 emails el mismo día; a la tercera mañana el usuario silencia la campana y el mecanismo deja de existir. El resumen es lo que el PO pidió textualmente: *"N clientes vencidos por $X"*.

**Deduplicación por día calendario argentino**, con dos capas: la `metadata` lleva `{account_id, as_of, debtor_count, overdue_total}` y el `ON CONFLICT (user_id, event_type, metadata) DO NOTHING` del precedente, **más** un predicado explícito `NOT EXISTS (... WHERE metadata->>'as_of' = <hoy local>)` en la CTE de candidatos. La segunda capa existe porque los importes viajan dentro de la `metadata` para que la plantilla de email pueda renderizarlos: sin ella, una segunda corrida el mismo día después de un cobro produciría una `metadata` distinta y, por lo tanto, un segundo aviso. Con ella, el día es la unidad de deduplicación, que es lo que el usuario percibe.

*Alternativa considerada*: dejar los importes fuera de la `metadata` (sólo en el `subject`) para que el dedup del precedente alcance solo. Se descarta: la plantilla de `send-email` renderiza el cuerpo desde `metadata`, y un email que dice "tenés deuda vencida" sin decir cuánta obliga a entrar a la aplicación para saber si vale la pena.

El evento es `ReceivablesOverdueDigest`, **9º tipo en-scope del Consumer 4** (`_notification_from_event`, `CREATE OR REPLACE` sobre la **misma firma** `public.events` — patrón ya usado dos veces), target `ADMIN` (→ owners, vía `_notification_audience`, precedente `PlanLimitExceeded`), severidad `warning`, `branch_id` nulo. El espejo de proveedores (`PayablesOverdueDigest`) sale del **mismo barrido**, como una segunda rama de la misma función: dos consultas, un job, un tipo de evento por lado.

**Ninguno de los dos entra en el filtro del Consumer 3.** El conjunto canónico de 11 `event_type` del invariante D13 de `transactional-outbox` no cambia: un vencimiento no mueve plata y no tiene contrapartida contable. La task correspondiente verifica que el gate de D13 siga verde y que el conteo siga siendo 11.

### D9 — Sólo se avisa lo **vencido**, no lo que está por vencer

El barrido dispara con `overdue_total > 0`. Un aviso preventivo ("vence en 3 días") es otro producto: cambia el destinatario natural (el cliente, no el dueño), el canal y el tono. El PO pidió el de vencidos.

### D10 — El plazo por defecto vive en `accounts`, con superficie en una pestaña nueva de `/configuracion`

No existe hoy ninguna tabla de configuración por cuenta: `SystemForm` guarda **preferencias del usuario** (moneda, huso, formato de fecha) en el perfil, y `AccountForm` es email y contraseña. `accounts` es la raíz del tenant y ya carga política de negocio (`billing_*`), así que la columna va ahí.

La superficie es una **9ª pestaña "Cobranzas"** en `/configuracion` (la `TabsList` pasa de `lg:grid-cols-8` a `lg:grid-cols-9`), siguiendo el precedente de Centros de costo y Formas de pago, que se montaron ahí. La escritura va por `rpc_set_default_payment_terms(p_days smallint)` `SECURITY DEFINER` con guard `is_account_writer` (`P0401`): es política de la cuenta y no la cambia cualquiera.

*Alternativa considerada*: un popover de configuración dentro de `/cobranzas`, para no sumar una pestaña. Más descubrible desde donde se mira la deuda, pero rompe con que Configuración es el hogar canónico de los ajustes de cuenta, y dejaría el ajuste invisible para quien nunca abre el panel. Se compensa con un enlace a Configuración desde el estado "sin vencimientos configurados" de `/cobranzas`.

### D11 — El POS no edita el vencimiento; el formulario de venta sí

El POS resuelve el vencimiento por la cascada y no muestra ningún campo. Es la superficie de mostrador: cada campo extra es tiempo con un cliente esperando, y el plazo del cliente **es** la política pactada — el caso "esta venta vence distinto" es de trastienda, no de caja. Además el POS tiene su propio `friendlyError` sin conectar a `operation-errors.ts` (hallazgo de `sucursal-guard-vaciado-auditoria`), así que toda superficie nueva ahí cuesta el doble.

El formulario de venta muestra el vencimiento resuelto **dentro del bloque de cuenta corriente que ya existe** —el que hoy muestra saldo actual y proyectado cuando el `kind` es `credit`— con un `Input type="date"` editable. Cero bloques nuevos.

### D12 — El recordatorio de WhatsApp es un deep-link, sin API paga y sin bitácora nueva

Botón por fila en `/cobranzas` que abre `buildWhatsAppUrl(cliente.phone, mensaje)` en una pestaña nueva. El mensaje se arma en un helper puro de `lib/` (nombre del negocio, saldo, importe vencido, tramo más viejo) para que sea testeable sin DOM. Si el teléfono no normaliza, `buildWhatsAppUrl` ya cae al selector de contactos de WhatsApp en vez de fallar: el botón nunca queda muerto.

Se reutiliza el helper existente en `lib/phone-utils.ts` tal cual — es el mismo que usa el envío de comprobantes. **No** se registra el envío: `sale_notifications` está keyed por `operation_id` y por `auth.uid()`, no por deuda, y forzarla acá exigiría un `operation_id` inventado. El PO pidió el botón, no la bitácora; si más adelante hace falta trazar los reclamos, es una tabla propia y un change propio.

### D13 — Sin índice nuevo, con la medición declarada

La derivación recorre los movimientos de cada deudor filtrando por `customer_account_id`, cubierto por el índice existente `(customer_account_id, created_at DESC)`. El barrido diario los recorre para todos los tenants: hoy son 5 cuentas y unos cientos de filas. Un índice por `due_date` sería optimización sin medición. Se declara para que la ausencia sea decisión; si el padrón crece un orden de magnitud, se mide con `EXPLAIN ANALYZE` antes de agregarlo. Misma postura que el D12 de la Etapa A.

### D14 — Los formularios de cliente y de proveedor conservan el plazo al editar

`ClientUpdate` y su espejo de proveedor tienen todos los campos opcionales; el `PATCH`/`PUT` que omita `payment_terms_days` **no** debe ponerlo en `NULL`. Es exactamente el bug que `metodos-pago-operaciones` resolvió con la preservación por `model_fields_set`, y el mismo que `edicion-preserva-contexto` encontró en cinco campos que se perdían en silencio al editar una operación. Una task del apply lo fija con un test antes de tocar el schema.

Del mismo modo, **un cargo ya posteado nunca cambia de vencimiento**: la operación con cargo en cuenta corriente es inmutable (`P0423`, vigente desde `pagos-cableados-restantes`), así que no hay camino de edición que pueda hacer derivar la fecha. Es una garantía que ya existe, no una que este change tenga que construir — pero deja el hueco de la OQ-1.

### D15 — Estética: tokens semánticos y nada de rojo como único canal

Los tramos se comunican con **texto** ("Vencido hace 45 días", "Vence en 3 días", "Sin vencimiento") y con tokens semánticos (`text-destructive`, `text-warning`, `text-muted-foreground`), nunca sólo por color: el requirement de la Etapa A ya lo exige para el saldo y acá el dato es más cargado. Se hereda el hallazgo D14 de la Etapa A —`CustomerAccountBalance` usa `text-yellow-400`/`text-emerald-400` hardcodeados— y **no** se replica: la superficie nueva nace en tokens. Cuatro combinaciones verificadas (claro/oscuro × móvil/escritorio) con capturas, y la tabla desplazándose en su propio contenedor sin desbordar el documento.

## Risks / Trade-offs

- **[El tramo alto rompe la venta a crédito, el POS y la compra a la vez]** → Es el riesgo dominante: los tres callers de alta pasan por el mismo helper. Mitigación en cuatro capas: (a) toda reescritura parte del `pg_get_functiondef` **vivo de prod** y se hashea antes de tocar nada — la regla existe porque `compras-proveedor-cuenta-corriente` encontró un cuerpo vivo divergido del archivo de migración; (b) el parámetro nuevo es **trailing y opcional**, de modo que un caller no migrado sigue compilando y postea sin vencimiento en vez de fallar; (c) safety net de TDD estricto sobre los tests existentes de los tres caminos antes de tocarlos, con el mismo verde exigido después; (d) gate SQL que verifica **una sola definición** de cada función reescrita (`42725`) y las ACLs exactas.
- **[`DROP FUNCTION` + `CREATE` resetea las ACLs]** → Gotcha ya cobrado en este proyecto. Los `REVOKE`/`GRANT` van en el **mismo archivo** de migración, inmediatamente después de cada `CREATE`, y el gate de ACLs los verifica. Ojo particular con `_pay_register_party_charge`, cuya ACL correcta hoy es **sin `authenticated`** (hotfix `20261010000001`): recrearla con el `GRANT ... TO authenticated` que trae su archivo original de `20261001000001` reabriría una escritura cross-tenant ya cerrada.
- **[Un `NULL` mal interpretado declara moroso a todo el padrón]** → D2 lo evita por construcción (sin plazo no hay vencimiento) y un gate SQL lo fija: con `default_payment_terms_days IS NULL` y sin plazo por cliente, un cargo nuevo nace con `due_date IS NULL` y el barrido no produce ninguna fila. Se mide además en la verificación post-merge sobre producción, donde hoy las 5 cuentas están en ese estado.
- **[La derivación FIFO no cierra contra el saldo]** → Sería el defecto más caro: dos números contradictorios en la misma pantalla. Se cubre con un test de propiedad —`SUM(open) = balance` sobre secuencias generadas de cargos, cobros, notas y reversos— y con un gate SQL que lo verifica sobre los datos vivos de la cuenta sintética.
- **[Anular un cobro deja la imputación inconsistente]** → Estructuralmente imposible con D4: no hay imputación almacenada que pueda quedar inconsistente. El test lo fija igual, porque la propiedad es el argumento central del diseño y tiene que estar defendida por algo más que un párrafo.
- **[El aviso diario se vuelve ruido y el usuario silencia la campana]** → D8 (uno por cuenta y por día) + D9 (sólo vencidos). El riesgo residual es la cuenta con deuda vencida crónica que recibe el mismo aviso todas las mañanas; queda anotado como OQ-3.
- **[El barrido escala mal cuando haya cientos de tenants]** → Hoy son 5. El barrido es `O(movimientos)` sin índice dedicado (D13). Se declara el umbral: si el conteo de movimientos crece un orden de magnitud, se mide antes de que sea un problema de producción.
- **[Sumar derivados a `list_movements` duplicado agranda una duplicación conocida]** → Declarado en D7 con la razón por la que no se arregla acá. La mitigación es que las dos copias se tocan en la misma task y que la verificación es sobre la pantalla real, no sobre el test.
- **[La 9ª pestaña de `/configuracion` aprieta el layout]** → `lg:grid-cols-9` con las etiquetas ya truncadas a `text-xs sm:text-sm`; se verifica en las cuatro combinaciones. Si no entra, la alternativa declarada en D10 (popover en `/cobranzas`) sigue disponible sin cambiar nada del backend.
- **[El mensaje de WhatsApp expone datos del cliente en una app de terceros]** → Es un deep-link que el usuario dispara conscientemente y cuyo texto ve antes de enviar, igual que el comprobante de venta que ya existe. El mensaje no lleva más que nombre, importe y vencimiento.

## Migration Plan

0. **Precondición**: `cobranzas-panel` mergeado y su migración `20261021000001` viva en producción. Si no lo está, este change no arranca — su RPC es el que se extiende.
1. **Checkpoints previos** (antes de escribir SQL): `MAX(version)` real de `supabase_migrations.schema_migrations`, `pg_get_functiondef` vivo y hasheado de las **siete** funciones que se reescriben, y ACLs vigentes de `_pay_register_party_charge` (esperado: sin `authenticated`). Renumerar si otro PR se llevó `20261022000001` — hay precedente de doble renumerado.
2. **Migración `20261022000001_cobranzas_vencimientos.sql`**, en este orden: columnas nuevas (`ADD COLUMN IF NOT EXISTS`, todas nullable) → `DROP`+`CREATE` de los dos `c30_register_*_account_movement` y de `_pay_register_party_charge` con sus ACLs → `CREATE OR REPLACE` de los tres callers de alta → `DROP`+`CREATE` de `rpc_receivables_report` → `CREATE` de `rpc_payables_report` y `rpc_set_default_payment_terms` → `CREATE OR REPLACE` de `_notification_from_event` (misma firma) → `CREATE` del barrido + `cron.unschedule`/`cron.schedule` → bloque de gates. Idempotente ante reaplicación: el auto-apply de Supabase GitHub la corre dos veces.
3. **Backend** → **Edge Function** (`send-email`) → **Frontend**.
4. **Deploy**: el merge dispara build + deploy + `supabase db push` automáticos. Nada manual, nunca el MCP `apply_migration`.
5. **Verificación post-merge en producción**: `MAX(version)`; una sola definición de cada función reescrita; ACLs exactas (incluida la ausencia de `authenticated` en el helper de cargo); el job de `pg_cron` programado; conteo de cargos con `due_date` no nulo (esperado **0** hasta que alguien configure un plazo); el barrido devolviendo **0** filas; y el total por cobrar del panel cerrando contra la suma de los cinco tramos.
6. **Rollback**: `DROP` del job de cron y del barrido; restaurar `_notification_from_event` a sus 8 tipos; `DROP`+`CREATE` de las funciones de cargo a su aridad anterior con sus ACLs; `DROP` de `rpc_payables_report` y `rpc_set_default_payment_terms`; restaurar `rpc_receivables_report` a la firma de la Etapa A. Las **columnas se dejan** (aditivas, nullable, sin lectores tras el rollback): dropearlas perdería los vencimientos ya cargados y no gana nada.

## Open Questions

- **OQ-1 — ¿Cómo se corrige un vencimiento mal cargado?** Hoy no se puede: la operación con cargo posteado es inmutable (`P0423`), así que la única salida es borrar la venta y rehacerla. *Recomendación: dejarlo así en este change y abrir un candidato propio* — una acción "cambiar vencimiento" sobre un cargo abierto es una escritura sobre el ledger que merece su propia RPC, su propio guard y su propia entrada de auditoría, y meterla acá mezclaría el tramo alto con una superficie que el sign-off no cubre. El sign-off del PO no habla de corrección.
- **OQ-2 — ¿El aviso debe incluir a los clientes dados de baja con deuda vencida?** La Etapa A los excluye del panel (su D5) y declara la consecuencia: esa deuda queda oculta. *Recomendación: mantener la exclusión también en el barrido*, para que el aviso no nombre clientes que la aplicación no lista. Se mide el conteo en producción durante la verificación (esperado 0) y, si aparece, se reporta al PO en vez de resolverse en silencio.
- **OQ-3 — ¿El aviso debe repetirse todos los días mientras la deuda siga vencida?** El diseño actual sí lo hace (dedup por día). *Recomendación: dejarlo así y observar*: con 11 deudores es una línea por mañana, no una avalancha. Si el PO reporta fatiga, la variante barata es avisar sólo cuando el importe vencido **cambia** respecto del último aviso — un ajuste del predicado del barrido, sin migración.
- **OQ-4 — ¿El tramo "sin vencimiento" debería desaparecer una vez configurado el plazo?** Los 11 deudores actuales quedan ahí para siempre (Non-Goal: sin backfill). *Recomendación: sí mostrarlo siempre, con su leyenda*, y dejar que se vacíe solo a medida que esa deuda se cobre. Un tramo que aparece y desaparece según el estado de configuración es más confuso que uno que a veces está en cero.
- **OQ-5 — ¿El plazo de pago debería poder configurarse por forma de pago además de por cliente?** Un `kind='credit'` a 30 días y otro a 60 sería representable con el catálogo `payment_methods` que ya existe. *Recomendación: no en este change* — el sign-off define la cascada en dos niveles (cuenta → parte) y sumar un tercero antes de que alguien lo pida es política inventada.
- **OQ-6 — ¿La deuda del lado proveedor merece su propia entrada de menú en vez de una pestaña?** *Recomendación: pestaña*, como está diseñado: `/cobranzas` es la pantalla de "estado de cuentas con terceros" y el dueño de un microemprendimiento mira las dos caras en la misma sesión. Una ruta aparte duplicaría cabecera, filtros y navegación para el mismo mecanismo.
