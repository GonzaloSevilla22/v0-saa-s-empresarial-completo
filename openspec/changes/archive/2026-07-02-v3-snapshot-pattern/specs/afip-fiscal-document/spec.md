## ADDED Requirements

### Requirement: FiscalIdentitySnapshot del receptor en el comprobante

El comprobante SHALL persistir, además de `receptor_doc_tipo`/`receptor_doc_nro` ya definidos, la identidad fiscal del receptor vigente al emitir: `receptor_legal_name TEXT` (razón social) y `receptor_iva_condition TEXT` (condición de IVA), ambos NULLABLE. Estos campos SHALL congelarse al insertar el `pending_cae` (RPC `rpc_emit_pending_cae` y `rpc_emit_subscription_payment_cae`), derivándolos de la identidad fiscal del cliente (`client-fiscal-identity`) cuando existe, de modo que el comprobante conserve la condición que justifica el tipo (A/B) ante una inspección, aun si el cliente cambia de condición después. Los valores históricos NULL SHALL interpretarse como "consumidor final sin identificar" (comportamiento actual). Este requisito NO SHALL volver obligatoria la identificación del receptor bajo el umbral de ARCA (la regla de opcionalidad existente se mantiene).

#### Scenario: La emisión congela la razón social y condición IVA del receptor

- **GIVEN** una venta a un cliente con identidad fiscal cargada (razón social "ACME SA", condición "Responsable Inscripto")
- **WHEN** se emite el comprobante
- **THEN** la fila `fiscal_documents` queda con `receptor_legal_name = 'ACME SA'` y `receptor_iva_condition = 'Responsable Inscripto'`, congelados en el `pending_cae`

#### Scenario: Cambiar la condición del cliente luego de emitir no altera el comprobante

- **GIVEN** un comprobante emitido con `receptor_iva_condition = 'Monotributo'`
- **WHEN** el cliente pasa a "Responsable Inscripto" en su ficha
- **THEN** el comprobante ya emitido conserva `receptor_iva_condition = 'Monotributo'`

#### Scenario: Consumidor final sin identificar mantiene el comportamiento previo

- **GIVEN** una venta a consumidor final sin identidad fiscal, bajo el umbral de ARCA
- **WHEN** se emite el comprobante
- **THEN** `receptor_legal_name` y `receptor_iva_condition` quedan en NULL y la emisión completa como `DocTipo = 99`, sin exigir identificación

### Requirement: Datos del emisor vigentes congelados en el comprobante

El comprobante SHALL conservar los datos del emisor vigentes al emitir suficientes para reconstruir la fotografía fiscal: el número de punto de venta (ya congelado en `punto_de_venta`) y la condición de IVA propia del emisor aplicada. Cuando estos datos ya estén disponibles en la fila (p. ej. `punto_de_venta`), el requisito SHALL considerarse cubierto por los campos existentes; cualquier dato del emisor no persistido y necesario para la reconstrucción SHALL agregarse de forma aditiva y NULLABLE.

#### Scenario: El punto de venta queda congelado en el comprobante

- **WHEN** se emite un comprobante desde un punto de venta cuyo número podría reasignarse después
- **THEN** la fila `fiscal_documents` conserva `punto_de_venta` con el número vigente al emitir, independiente de cambios posteriores en la configuración del PV
