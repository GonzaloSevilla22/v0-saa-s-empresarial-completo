# document-sequence — Spec (v21-fiscal-profile C-27)

## Purpose

Numeracion de comprobantes fiscales sin huecos, serializada por punto de venta y tipo de comprobante. Provee la RPC `rpc_next_document_number` con lock corto `SELECT … FOR UPDATE` para garantizar secuencias sin huecos ni repetidos bajo concurrencia. Depende de `fiscal-profile` (points_of_sale). Consumida por `afip-fiscal-document` en la emisión de cada comprobante.

## Requirements

### Requirement: Persistencia de la secuencia de numeracion por punto de venta y tipo

El sistema SHALL persistir la numeracion de comprobantes en la tabla `document_sequences` (`id` UUID PK, `point_of_sale_id` UUID FK NOT NULL `points_of_sale`, `comprobante_type` TEXT NOT NULL, `last_number` BIGINT NOT NULL DEFAULT 0, `created_at` TIMESTAMPTZ), con UNIQUE `(point_of_sale_id, comprobante_type)`. La numeracion es **por punto de venta y tipo de comprobante**: cada combinacion de punto de venta y tipo de comprobante SHALL tener una unica fila de secuencia.

#### Scenario: La combinacion PV + tipo es unica

- **GIVEN** una secuencia para `(point_of_sale P1, 'factura_b')`
- **WHEN** se intenta insertar otra fila con la misma combinacion
- **THEN** el INSERT falla por violacion del UNIQUE constraint

#### Scenario: Distintos tipos de comprobante tienen secuencias independientes

- **GIVEN** un punto de venta P1
- **WHEN** se numeran comprobantes `'factura_a'` y `'factura_b'`
- **THEN** cada tipo lleva su propia `last_number`, independiente del otro

#### Scenario: Distintos puntos de venta tienen secuencias independientes

- **GIVEN** dos puntos de venta P1 y P2 del mismo perfil fiscal
- **WHEN** se numera `'factura_b'` en P1 y en P2
- **THEN** cada punto de venta lleva su propia `last_number` para ese tipo, sin compartir la secuencia

---

### Requirement: Numeracion sin huecos con lock corto serializado

El sistema SHALL entregar el siguiente numero de comprobante unicamente a traves de `rpc_next_document_number(p_point_of_sale_id, p_comprobante_type)`, que SHALL tomar un lock serializado con `SELECT … FOR UPDATE` sobre la fila de `document_sequences`, incrementar `last_number` en 1 y devolver el nuevo valor. Si la fila no existe, la RPC SHALL crearla con `UPDATE-then-INSERT` (NUNCA upsert acumulativo `INSERT … ON CONFLICT DO UPDATE`, que dispara el gotcha de validacion de CHECK del proyecto). La RPC SHALL tomar y soltar el lock en su propio alcance corto, JAMAS dentro de la transaccion larga de la venta.

#### Scenario: Numeracion secuencial sin huecos

- **GIVEN** una secuencia con `last_number = 5`
- **WHEN** se llama `rpc_next_document_number` tres veces seguidas
- **THEN** devuelve 6, 7, 8 y `last_number` queda en 8

#### Scenario: Primera numeracion crea la fila de secuencia

- **GIVEN** no existe fila de secuencia para `(point_of_sale P1, 'factura_c')`
- **WHEN** se llama `rpc_next_document_number` por primera vez
- **THEN** se crea la fila via UPDATE-then-INSERT y devuelve 1

#### Scenario: Dos puntos de venta en paralelo no producen numeros duplicados

- **GIVEN** dos puntos de venta distintos numerando concurrentemente el mismo tipo
- **WHEN** ambos llaman `rpc_next_document_number` al mismo tiempo
- **THEN** cada punto de venta obtiene su propia secuencia sin duplicados ni interferencia (los locks son por fila, independientes)

#### Scenario: 100 llamadas concurrentes sobre la misma secuencia no dejan huecos

- **GIVEN** una secuencia con `last_number = 0`
- **WHEN** 100 transacciones concurrentes llaman `rpc_next_document_number` sobre la misma combinacion
- **THEN** se entregan exactamente los numeros 1..100 sin huecos ni repetidos (serializacion por el `FOR UPDATE`)

---

### Requirement: Acceso a la secuencia restringido a la RPC con guard

El sistema SHALL impedir la escritura directa de `document_sequences` desde el cliente: la tabla SHALL tener RLS por `account_id` (SELECT a miembros de la cuenta duena del punto de venta, resuelta via `points_of_sale`) y la unica via de incremento SHALL ser `rpc_next_document_number` (SECURITY DEFINER con guard `is_account_writer` sobre el `account_id` del punto de venta). El backend Python SHALL invocar la RPC via repository (JWT-passthrough), nunca con `service_role`.

#### Scenario: Cliente no puede actualizar last_number directamente

- **WHEN** un usuario intenta `UPDATE document_sequences SET last_number = 999`
- **THEN** la RLS rechaza la operacion (escritura solo via RPC definer)

#### Scenario: Member sin rol de escritura no puede numerar

- **GIVEN** un usuario con rol `member` en la cuenta
- **WHEN** invoca `rpc_next_document_number`
- **THEN** la RPC retorna error `P0401` (guard `is_account_writer`)
