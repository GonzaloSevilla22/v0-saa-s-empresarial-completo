## Context

El módulo de clientes es hoy CRUD puro. Su lista (`frontend/app/(dashboard)/clientes/page.tsx`) lee **PostgREST en directo** vía `usePaginatedQuery({table:"clients"})`, mientras que las mutaciones van por FastAPI (`useClients()` → `pythonClient`). El `status` que muestra el badge actual es la columna `clients.status`, escrita a mano y sin ningún proceso que la mantenga.

Relevamiento previo al diseño (regla de reutilización, 2026-08-02):

| Ya existe | Estado | Qué hacemos |
|---|---|---|
| `/clientes/[id]/cuenta/page.tsx` (C-30) | **Huérfana**: ningún archivo de la app enlaza a esa ruta | Se convierte en pestaña del detalle; la fila de la lista le da entrada |
| `CustomerAccountBalance` / `CustomerAccountHistory` / `RegisterPaymentForm` | Funcionan | Se reutilizan sin tocar |
| `useCustomerAccount` (`GET /clientes/{id}/cuenta`) | Funciona | Se reutiliza sin tocar |
| `SalesRepository.list_paginated_by_operation` | Agrupa ventas por `COALESCE(operation_id, id)` | **Se copia el patrón de `op_key`**, no la función (filtra por org, no por cliente) |
| `lib/reporting/revenue-canon.ts` (`lineRevenue`, `sumLineRevenue`) | Canon RN-D | Se reutiliza en el frontend para cualquier suma de líneas |
| `BaseRepository.paginate()` | Envelope `{items,total,page,pages}` | Se reutiliza en los dos endpoints nuevos |
| `PageOut[T]` (`backend/schemas/common.py`) | Envelope v3-api-standards | Se reutiliza |
| `PaginationBar` + `usePaginatedQuery` | Genéricos de UI | `PaginationBar` se reutiliza; `usePaginatedQuery` se abandona en esta pantalla (ver §4) |
| `client_addresses` (v3-catalog-masters) | Tabla creada, **UI diferida** | Fuera de alcance; el layout de detalle deja lugar para una futura pestaña |

**Volúmenes reales de producción** (proyecto `gxdhpxvdjjkmxhdkkwyb`, SELECTs agregados, 2026-08-14):

- 1.150 clientes vivos (`deleted_at IS NULL`) en 12 cuentas.
- 585 filas en `sales`; 426 con `client_id`; **127 clientes distintos con al menos una venta** → **1.023 clientes (89%) nunca compraron nada**.
- `sales.total` no es NULL en ninguna fila; 18 filas (16 con cliente) no tienen `operation_id`.
- `customer_accounts` y `customer_account_movements`: **0 filas**. La cuenta corriente de C-30 no tiene uso real todavía.

## Goals / Non-Goals

**Goals**
- Que la lista de clientes responda "¿quién me compra seguido?" y "¿a quién dejé de ver?" sin que el usuario configure nada.
- Que un click en el cliente muestre sus compras y el total acumulado.
- Que los agregados se calculen en la base, en una sola consulta por página — nunca iterando ventas en el cliente.
- Rescatar la pantalla de cuenta corriente de C-30 dándole puerta de entrada.

**Non-Goals**
- Segmentación RFM, scoring, predicción de churn o campañas automáticas.
- Migrar o retirar la columna `clients.status` (OQ-3).
- Implementar notas de crédito (no existen datos).
- UI de `client_addresses`.

## Decisions

### 1. Definiciones de "frecuente" e "inactivo", calibradas contra producción

Distribución real de operaciones de venta por cliente (127 clientes con compras):

| Compras (lifetime) | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|
| Clientes | 86 | 17 | 8 | 6 | 8 | 1 | 1 |

Recencia y frecuencia evaluadas en día calendario argentino:

| Candidato de umbral | Clientes que califican | % de los 127 |
|---|---|---|
| ≥2 compras en 90 días | 28 | 22,0% |
| **≥3 compras en 90 días** | **16** | **12,6%** |
| ≥4 compras en 90 días | 11 | 8,7% |
| Última compra hace ≥30 días | 75 | 59,1% |
| **Última compra hace ≥60 días** | **44** | **34,6%** |
| Última compra hace ≥90 días | 20 | 15,7% |

**Decisión — `FRECUENTE_MIN_OPS = 3` en `FRECUENTE_WINDOW_DAYS = 90`.** Con ≥2 el badge marcaría casi un cuarto del padrón y dejaría de ser una señal; con ≥4 baja a 11 clientes y varias cuentas quedarían sin ningún frecuente. Con ≥3 el tenant principal marca 14 de sus 86 clientes con compras y el segundo marca 2 de 21 — discrimina en ambos.

**Decisión — `INACTIVO_MIN_DAYS = 60`.** A 30 días marcaría al 59% (el ciclo de compra normal del negocio ya supera el mes: el promedio es 1,74 compras por cliente en ~4,5 meses de historia); a 90 días sólo 20 clientes, y como la historia arranca el 2026-03-26 el umbral quedaría casi sin población. 60 días deja un bucket accionable de 44.

**Decisión — `SIN_COMPRAS` es un estado propio, no "inactivo".** Es el hallazgo de calibración más importante: 1.023 de 1.150 clientes (89%) nunca compraron. Si "sin compras" cayera dentro de "inactivo", el badge de inactivo lo llevaría el 92% del padrón y la pantalla no comunicaría nada. Un cliente cargado ayer que todavía no compró no es un cliente perdido.

Estados resultantes: `frecuente` · `activo` · `inactivo` · `sin_compras`.

**Precedencia — `inactivo` gana sobre `frecuente`.** Un cliente puede cumplir ambos (3 compras concentradas hace 60-90 días). Se resuelve a `inactivo` porque es el estado accionable: un cliente que compraba seguido y se calló es la señal más valiosa de la pantalla, y perderla bajo un badge de "frecuente" sería el peor error posible. Hoy el solapamiento afecta a **1 cliente de 127**, así que la regla es barata; se define igual para que no quede al azar del orden del `CASE`. Los campos crudos (`purchase_count_90d`, `days_since_last_purchase`) viajan igual en la respuesta, así la UI puede matizar sin recalcular.

**Orden de evaluación canónico**: `sin_compras` → `inactivo` → `frecuente` → `activo`.

### 2. Los umbrales viven en el backend, y sólo ahí

`backend/core/client_activity.py` es la única fuente de verdad:

```python
FRECUENTE_MIN_OPS     = 3
FRECUENTE_WINDOW_DAYS = 90
INACTIVO_MIN_DAYS     = 60
```

Se pasan a SQL **como parámetros de la consulta**, nunca interpolados en el string, y el estado llega ya resuelto al frontend en `activity_status`.

*Alternativa descartada*: constantes espejadas en `frontend/lib/clients/` para clasificar en el cliente. Es exactamente la duplicación que la regla de reutilización prohíbe (el caso de la criticidad de stock rehecha en 5 lugares): dos definiciones en dos lenguajes divergen en el primer ajuste del PO. El frontend sólo mapea `activity_status` → etiqueta y color, y para los textos usa el dato por cliente que ya recibe ("Última compra hace 73 días"), sin necesitar el umbral.

### 3. El total del historial es **bruto**, y las notas de crédito quedan en la cuenta corriente

`customer_account_movements` tiene **0 filas** en producción: no hay ni una nota de crédito emitida. El historial de compras muestra la suma canónica de las ventas, sin descontar NC, rotulado sin ambigüedad como **"Total comprado"** con la aclaración *"no descuenta notas de crédito"*; el saldo real y sus ajustes siguen viviendo en la pestaña **Cuenta corriente**, que ya existe y es el lugar correcto para eso.

Es la opción honesta: "cuánto me compró este cliente" (volumen comercial) y "cuánto me debe / cuánto le devolví" (posición financiera) son dos preguntas distintas, y el producto ya tiene una pantalla para cada una. Descontar NC obligaría a unir contra una tabla vacía para un efecto hoy nulo, y mezclaría ambas semánticas en un número que no respondería bien ninguna de las dos. Queda como **OQ-2** por si el PO prefiere el neto.

### 4. Los agregados se calculan en el repository, en una consulta por página

`GET /clients/activity` resuelve todo en una sola SQL: página de clientes + `LEFT JOIN LATERAL` contra el agregado de ventas de cada uno. Nada de N+1, nada de traer ventas al frontend.

```
clients (filtrado, ordenado, paginado)
   └── LEFT JOIN LATERAL (
         SELECT COUNT(*) ops_total,
                COUNT(*) FILTER (WHERE op_day >= $today - ($window - 1)) ops_window,
                MAX(op_day) last_op_day,
                SUM(op_total) total_spent
         FROM ( -- una fila por OPERACIÓN
                SELECT COALESCE(s.operation_id::text, s.id::text) op_key,
                       MAX((s.date AT TIME ZONE 'America/Argentina/Mendoza')::date) op_day,
                       SUM(COALESCE(si.subtotal, s.total, s.amount)) op_total
                FROM sales s
                LEFT JOIN sale_items si ON si.sale_id = s.id
                WHERE s.account_id = clients.account_id AND s.client_id = clients.id
                GROUP BY 1
              ) ops
       ) agg ON TRUE
```

**La unidad de "compra" es la operación, no la fila de `sales`.** `sales` es tabla de líneas: una venta de 3 productos son 3 filas. Contar filas inflaría la frecuencia de cualquiera que compre carrito grande. Se agrupa por `COALESCE(operation_id::text, id::text)` — el mismo `op_key` que ya usa `SalesRepository.list_paginated_by_operation`, y el `COALESCE` es obligatorio porque 16 filas con cliente no tienen `operation_id`.

**Monto por línea = `COALESCE(si.subtotal, s.total, s.amount)`** (RN-D / `reporting-invariants`). En `sales`, `amount` es el **precio unitario** y `total` el subtotal de línea: sumar `amount` subvalúa toda venta con `quantity > 1` — es exactamente la regresión del 17,53% que encontró `v3-reporting-invariants`. Se prefiere `sale_items.subtotal` cuando existe (fuente de verdad desde C-20) y se cae al header plano por RN-97.

*Alternativa descartada — vista materializada / columnas denormalizadas en `clients`*: con 585 ventas y 1.150 clientes el LATERAL es trivial, y una copia denormalizada exige invalidación en cada alta, edición y borrado de venta (tres caminos de escritura distintos, incluido POS). Se revisa si el volumen crece dos órdenes de magnitud.

### 5. Endpoints nuevos; `GET /clients` no se toca

| Endpoint | Respuesta | Consumidor |
|---|---|---|
| `GET /clients` *(existente, intacto)* | `list[ClientOut]` | 6 pantallas que lo usan como origen de selectores |
| `GET /clients/activity` *(nuevo)* | `PageOut[ClientActivityOut]` | Lista de clientes |
| `GET /clients/{client_id}/purchases` *(nuevo)* | `PageOut[ClientPurchaseOut]` | Detalle del cliente |

*Alternativa descartada — cambiar `GET /clients` al envelope paginado con agregados*: rompe `ventas`, `pos`, `configuración`, `sale-form`, `client-form` y `client-import-dialog`, que sólo necesitan `[{id, name}]` para un `<select>`. Cargarles el costo de los agregados y una migración de shape para no beneficiarlos en nada es un mal negocio. Son dos modelos de lectura distintos —selector vs. pantalla de gestión— y merecen dos endpoints.

El **resumen del detalle** (cantidad de compras, total, última compra) **reutiliza el mismo método del repository** que alimenta la lista, filtrado a un `client_id`: una sola definición de los agregados para las dos pantallas.

Búsqueda, orden y paginación se mueven al backend: `search` (nombre/email, `ILIKE`), `activity_status` (filtro), `sort` ∈ {`name`, `last_purchase`, `total_spent`, `purchase_count`} con dirección, `page`/`size` 0-based. Errores en RFC 7807 y envelope estándar, por `v3-api-standards`.

### 6. Ruta real con pestañas, no dialog

```
/clientes                      lista con badges (fila clickeable)
/clientes/[id]/layout.tsx      cabecera del cliente + nav de pestañas   (nuevo)
/clientes/[id]                 «Historial de compras»                   (nuevo)
/clientes/[id]/cuenta          «Cuenta corriente»            (existente, deja de ser huérfana)
```

El módulo **ya eligió ruta**: `/clientes/[id]/cuenta` existe desde C-30. Meter el historial en un dialog crearía dos patrones de detalle conviviendo, y dejaría a la cuenta corriente tan inalcanzable como está. Con `layout.tsx` la cabecera y las pestañas se comparten, cada pestaña es enlazable y compartible, el back del navegador funciona, y el historial paginado no pelea con el scroll de un modal en mobile.

El layout hace el fetch del cliente (`GET /clients/{id}`, ya existe) para el nombre de la cabecera; cada pestaña pide sólo lo suyo.

### 7. Timezone: día calendario argentino

Toda aritmética de días usa el canon `business-day-timezone`:

- `days_since_last_purchase = reporting_local_today() - (MAX(date) AT TIME ZONE 'America/Argentina/Mendoza')::date`
- Ventana de frecuencia: `op_day >= reporting_local_today() - (FRECUENTE_WINDOW_DAYS - 1)` — 90 días calendario **inclusive** del día de hoy.

Prohibido `now() - interval '90 days'` a secas: corre un día toda operación cargada entre las 21:00 y las 24:00 ART. La diferencia no es teórica — recalculando con ART el conteo de frecuentes pasó de 17 a 16.

### 8. Estética y accesibilidad

Badges con `cva` sobre tokens semánticos (`--color-success`, `--color-warning`, `--color-muted`), nunca colores literales — el `statusColors` actual de la página usa `emerald-500`/`yellow-500`/`red-500` hardcodeados y **no** se replica. El estado nunca se comunica sólo por color: cada badge lleva su texto. La fila clickeable es un elemento accionable real con foco visible y navegable por teclado, y los botones de editar/borrar que ya viven en la fila **detienen la propagación** para no disparar la navegación.

## Risks / Trade-offs

- **Los umbrales pueden no encajarle al PO** → viven en una sola constante del backend; cambiarlos es una línea y un test. OQ-1 los pone a firmar.
- **La lista deja de leer PostgREST y pasa por Render (cold start ~50s)** → la pantalla ya depende de FastAPI para todas sus mutaciones, así que no agrega un punto de falla nuevo; se mantienen los estados de carga y error que la página ya tiene.
- **El LATERAL corre sobre todos los clientes de la página** → acotado a `size` clientes por request. Sin índice compuesto, cada agregado usa `idx_sales_client_id`. Con 585 ventas es irrelevante; se agrega `sales(account_id, client_id, date DESC)` como índice de soporte, barato y alineado con el patrón de acceso.
- **"Total comprado" bruto puede leerse como "lo que me debe"** → se rotula explícitamente y la pestaña de cuenta corriente queda a un click.
- **Clientes con ventas pero `deleted_at` no nulo** → quedan fuera por `not_deleted_clause()`, consistente con `v3-soft-delete-policy`.
- **Ventas sin `client_id` (159 de 585) no se atribuyen a nadie** → correcto: son ventas mostrador. No se inventa atribución.

## Migration Plan

Cambio puramente aditivo del lado de lectura. Sin cambios de esquema ni de datos; el único artefacto SQL es un índice `CREATE INDEX CONCURRENTLY IF NOT EXISTS` (idempotente, obligatorio por la integración GitHub de Supabase que auto-aplica al mergear). Rollback = revertir el PR; ninguna estructura queda huérfana.

## Open Questions

- **OQ-1 (umbrales)**: ¿el PO confirma `≥3 compras en 90 días` = frecuente y `≥60 días` = inactivo? Datos de calibración en §1. No bloquea el apply — son constantes de una línea.
- **OQ-2 (bruto vs. neto)**: ¿"Total comprado" queda bruto (recomendado, §3) o debe descontar notas de crédito cuando existan?
- **OQ-3 (`clients.status`)**: la columna manual (`activo`/`inactivo`/`perdido`) queda conviviendo con el estado calculado. ¿Se retira en un change posterior o tiene un uso que no detectamos? Mostrar dos nociones de "estado" en la misma fila es confuso y este change las deja juntas a propósito, para no borrar datos sin sign-off.
- **OQ-4 (orden por defecto de la lista)**: hoy es alfabético por nombre. ¿Se mantiene, o conviene "última compra, más reciente primero" ahora que el dato existe? Se implementa alfabético (sin cambio de comportamiento) salvo indicación contraria.
