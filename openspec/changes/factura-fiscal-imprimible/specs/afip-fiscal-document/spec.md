## MODIFIED Requirements

### Requirement: Datos del emisor vigentes congelados en el comprobante

El comprobante SHALL conservar los datos del emisor vigentes al emitir suficientes para reconstruir la fotografía fiscal: el número de punto de venta (ya congelado en `punto_de_venta`) y la condición de IVA propia del emisor aplicada. Cuando estos datos ya estén disponibles en la fila (p. ej. `punto_de_venta`), el requisito SHALL considerarse cubierto por los campos existentes; cualquier dato del emisor no persistido y necesario para la reconstrucción SHALL agregarse de forma aditiva y NULLABLE.

**Agregado por `factura-fiscal-imprimible`.** `fiscal_documents` SHALL tener la columna NULLABLE `emisor_snapshot JSONB` con `cuit`, `razon_social`, `nombre_fantasia`, `domicilio_comercial`, `iva_condition`, `iibb_condition`, `iibb_numero`, `inicio_actividades` y `ambiente` del perfil fiscal del documento, escrita por `rpc_fiscal_document_authorize` en la misma transición real `pending_cae → authorized` (el único punto por el que pasa todo comprobante autorizado, tanto desde el relay como desde la reconciliación). La foto NOT SHALL reescribirse después de autorizado: un cambio posterior del perfil fiscal no altera los datos del emisor de un comprobante ya autorizado. Los comprobantes autorizados antes de este change quedan con `emisor_snapshot` NULL.

#### Scenario: El punto de venta queda congelado en el comprobante

- **WHEN** se emite un comprobante desde un punto de venta cuyo número podría reasignarse después
- **THEN** la fila `fiscal_documents` conserva `punto_de_venta` con el número vigente al emitir, independiente de cambios posteriores en la configuración del PV

#### Scenario: La autorización congela los datos del emisor

- **GIVEN** un perfil fiscal con `razon_social = 'SUMAR'` y `domicilio_comercial = 'Calle 1, Mendoza'`, y un comprobante suyo en `pending_cae`
- **WHEN** el relay lo autoriza vía `rpc_fiscal_document_authorize`
- **THEN** `emisor_snapshot` contiene `razon_social = 'SUMAR'` y `domicilio_comercial = 'Calle 1, Mendoza'`

#### Scenario: Cambiar el perfil después no altera la foto

- **GIVEN** un comprobante autorizado con `emisor_snapshot.domicilio_comercial = 'Calle 1, Mendoza'`
- **WHEN** el owner cambia el domicilio comercial del perfil a 'Calle 2, Mendoza'
- **THEN** el comprobante conserva `emisor_snapshot.domicilio_comercial = 'Calle 1, Mendoza'`

#### Scenario: El camino idempotente no reescribe la foto

- **GIVEN** un comprobante ya autorizado
- **WHEN** se vuelve a invocar `rpc_fiscal_document_authorize` sobre él
- **THEN** la RPC devuelve `false` y `emisor_snapshot` no cambia

## ADDED Requirements

### Requirement: Fecha del comprobante confirmada por ARCA

`fiscal_documents` SHALL tener la columna NULLABLE `fecha_comprobante DATE` con la fecha de emisión (`CbteFch`) con la que ARCA autorizó el comprobante. El adapter WSFE SHALL devolverla en la respuesta normalizada: en `FECAESolicitar`, la `CbteFch` de la respuesta de detalle y, si ARCA no la informa, la fecha que el adapter envió; en la reconciliación por `FECompConsultar`, la `CbteFch` de `ResultGet`. El relay SHALL pasarla a `rpc_fiscal_document_authorize` mediante un parámetro nuevo `p_fecha_comprobante DATE DEFAULT NULL`, que la RPC SHALL persistir sólo en la transición real a `authorized`. La RPC SHALL reescribirse desde su definición viva con `DROP FUNCTION` + `CREATE` (sin dejar la firma de 4 parámetros como overload), conservando `SECURITY DEFINER`, su `COMMENT` y su ACL interna (sin `EXECUTE` para `authenticated` ni `anon`). Para completar comprobantes autorizados sin fecha, SHALL existir una RPC interna `rpc_fiscal_document_set_fecha_comprobante(p_doc_id uuid, p_fecha date)` que sólo escribe si `fecha_comprobante` es NULL y el documento está `authorized`, sin `EXECUTE` para roles de aplicación. Un gate SQL SHALL ejecutar ambas RPCs.

#### Scenario: La autorización guarda la fecha que devolvió ARCA

- **GIVEN** un comprobante en `pending_cae` y una respuesta de `FECAESolicitar` aprobada con `CbteFch = '20260925'`
- **WHEN** el relay lo autoriza
- **THEN** `fiscal_documents.fecha_comprobante = 2026-09-25`

#### Scenario: La reconciliación también guarda la fecha

- **GIVEN** un comprobante con marca de envío que el relay reconcilia y `FECompConsultar` devuelve `Resultado = 'A'` con `CbteFch = '20260925'`
- **WHEN** se adopta el CAE de ARCA
- **THEN** `fecha_comprobante = 2026-09-25`

#### Scenario: Un caller con la firma vieja sigue funcionando

- **WHEN** se invoca `rpc_fiscal_document_authorize` con 4 argumentos
- **THEN** el comprobante se autoriza igual que antes y `fecha_comprobante` queda NULL

#### Scenario: Completar la fecha no pisa una existente

- **GIVEN** un comprobante autorizado con `fecha_comprobante = 2026-09-25`
- **WHEN** se invoca `rpc_fiscal_document_set_fecha_comprobante` con otra fecha
- **THEN** la fecha no cambia

#### Scenario: Un usuario autenticado no puede invocar las RPCs

- **WHEN** el rol `authenticated` intenta ejecutar `rpc_fiscal_document_authorize` o `rpc_fiscal_document_set_fecha_comprobante`
- **THEN** la ejecución falla por falta de privilegio

---

### Requirement: La fecha que se pide a ARCA es la fecha de Argentina

El relay SHALL enviar a ARCA como `CbteFch` la fecha del día en la zona horaria `America/Argentina/Buenos_Aires` en el momento de armar el pedido, y NOT SHALL depender de la zona horaria del servidor. (Sujeto al sign-off de OQ-7 del design; si el PO lo difiere, este requirement se retira del change antes del apply.)

#### Scenario: Factura pedida de noche

- **GIVEN** el servidor en UTC y la hora 2026-09-26 02:30 UTC (2026-09-25 23:30 en Argentina)
- **WHEN** el relay arma el pedido de CAE
- **THEN** `CbteFch = '20260925'`
