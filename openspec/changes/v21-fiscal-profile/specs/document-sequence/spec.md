## ADDED Requirements

### Requirement: Persistencia de la secuencia de numeración por punto de venta y tipo
El sistema SHALL persistir la numeración de comprobantes en la tabla `document_sequences` (`id` UUID PK, `fiscal_profile_id` UUID FK `fiscal_profiles`, `punto_de_venta` INTEGER NOT NULL, `comprobante_type` TEXT NOT NULL, `last_number` BIGINT NOT NULL DEFAULT 0, `created_at` TIMESTAMPTZ), con UNIQUE `(fiscal_profile_id, punto_de_venta, comprobante_type)`. Cada combinación de perfil fiscal, punto de venta y tipo de comprobante SHALL tener una única fila de secuencia.

#### Scenario: La combinación PV + tipo es única
- **GIVEN** una secuencia para `(perfil X, PV 1, 'factura_b')`
- **WHEN** se intenta insertar otra fila con la misma combinación
- **THEN** el INSERT falla por violación del UNIQUE constraint

#### Scenario: Distintos tipos de comprobante tienen secuencias independientes
- **GIVEN** un perfil fiscal con PV 1
- **WHEN** se numeran comprobantes `'factura_a'` y `'factura_b'`
- **THEN** cada tipo lleva su propia `last_number`, independiente del otro

### Requirement: Numeración sin huecos con lock corto serializado
El sistema SHALL entregar el siguiente número de comprobante únicamente a través de `rpc_next_document_number(p_fiscal_profile_id, p_punto_de_venta, p_comprobante_type)`, que SHALL tomar un lock serializado con `SELECT … FOR UPDATE` sobre la fila de `document_sequences`, incrementar `last_number` en 1 y devolver el nuevo valor. Si la fila no existe, la RPC SHALL crearla con `UPDATE-then-INSERT` (NUNCA upsert acumulativo `INSERT … ON CONFLICT DO UPDATE`, que dispara el gotcha de validación de CHECK del proyecto). La RPC SHALL tomar y soltar el lock en su propio alcance corto, JAMÁS dentro de la transacción larga de la venta.

#### Scenario: Numeración secuencial sin huecos
- **GIVEN** una secuencia con `last_number = 5`
- **WHEN** se llama `rpc_next_document_number` tres veces seguidas
- **THEN** devuelve 6, 7, 8 y `last_number` queda en 8

#### Scenario: Primera numeración crea la fila de secuencia
- **GIVEN** no existe fila de secuencia para `(perfil X, PV 1, 'factura_c')`
- **WHEN** se llama `rpc_next_document_number` por primera vez
- **THEN** se crea la fila vía UPDATE-then-INSERT y devuelve 1

#### Scenario: Dos perfiles en paralelo no producen números duplicados
- **GIVEN** dos perfiles fiscales distintos numerando concurrentemente
- **WHEN** ambos llaman `rpc_next_document_number` al mismo tiempo
- **THEN** cada perfil obtiene su propia secuencia sin duplicados ni interferencia (los locks son por fila, independientes)

#### Scenario: 100 llamadas concurrentes sobre la misma secuencia no dejan huecos
- **GIVEN** una secuencia con `last_number = 0`
- **WHEN** 100 transacciones concurrentes llaman `rpc_next_document_number` sobre la misma combinación
- **THEN** se entregan exactamente los números 1..100 sin huecos ni repetidos (serialización por el `FOR UPDATE`)

### Requirement: Acceso a la secuencia restringido a la RPC con guard
El sistema SHALL impedir la escritura directa de `document_sequences` desde el cliente: la tabla SHALL tener RLS por `account_id` (SELECT a miembros de la cuenta del perfil) y la única vía de incremento SHALL ser `rpc_next_document_number` (SECURITY DEFINER con guard `is_account_writer`). El backend Python SHALL invocar la RPC vía repository (JWT-passthrough), nunca con `service_role`.

#### Scenario: Cliente no puede actualizar last_number directamente
- **WHEN** un usuario intenta `UPDATE document_sequences SET last_number = 999`
- **THEN** la RLS rechaza la operación (escritura solo vía RPC definer)

#### Scenario: Member sin rol de escritura no puede numerar
- **GIVEN** un usuario con rol `member` en la cuenta
- **WHEN** invoca `rpc_next_document_number`
- **THEN** la RPC retorna error `P0401` (guard `is_account_writer`)
