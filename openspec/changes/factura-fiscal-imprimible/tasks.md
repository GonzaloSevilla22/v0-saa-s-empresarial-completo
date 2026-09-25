> **Governance**: MEDIA (lectura y render) con tramo **ALTO** por exactitud legal y porque toca `rpc_fiscal_document_authorize`. **No empezar el apply sin el sign-off del PO en OQ-1…OQ-9 de `design.md`.** TDD estricto: cada task de código arranca con un test en rojo. Ningún commit a `main`: rama `opsx/factura-fiscal-imprimible-apply` + PR.

## 0. Sign-off y verificación del estado vivo

- [ ] 0.1 Registrar en `design.md` las respuestas del PO a OQ-1…OQ-9; si OQ-7 se difiere, retirar el requirement "La fecha que se pide a ARCA es la fecha de Argentina" del delta `afip-fiscal-document` y el grupo 4.4
- [ ] 0.2 Medir en prod (sólo SELECT): `max(version)` de migraciones y elegir el número de la migración nueva (`≥ 20261064000001`, sin chocar con changes en curso); md5 vivo de `rpc_fiscal_document_authorize(uuid,text,date,bigint)` (esperado `c8bc224d6f2767c6eb8d28031488e1f7`); si difiere, partir del cuerpo nuevo y anotarlo
- [ ] 0.3 Confirmar que la zona horaria del proceso del backend en Render es UTC (log de `datetime.now().astimezone().tzinfo` o variable `TZ`) y anotarlo en `design.md` (D11)
- [ ] 0.4 Safety net: correr `pytest backend/tests/test_receipts.py backend/tests/test_fiscal_emision_segura.py backend/tests/test_c27_cae_relay_trigger.py` y los tests de Vitest de `sale-receipt-button`, `FiscalDocumentBadge`, `FiscalSettings`, `sale-operations-list`, `use-sales`; anotar el conteo base

## 1. Base de datos

- [ ] 1.1 Gate SQL nuevo `supabase/tests/test_factura_fiscal_imprimible.sql` (rojo): columnas nuevas de `fiscal_profiles` y `fiscal_documents`; `rpc_fiscal_document_authorize` con 5 parámetros, un solo overload, ACL sin `authenticated`/`anon`, `COMMENT` igual al vivo; **ejecuta** la RPC en los tres caminos (transición real escribe `fecha_comprobante` y `emisor_snapshot` y registra historial; idempotente devuelve `false` y no reescribe; llamada con 4 argumentos autoriza con fecha NULL); `rpc_fiscal_document_set_fecha_comprobante` sólo completa NULL sobre `authorized` y está revocada para roles de aplicación
- [ ] 1.2 Migración: `ADD COLUMN IF NOT EXISTS` `razon_social`, `nombre_fantasia`, `domicilio_comercial`, `iibb_numero` (text) e `inicio_actividades` (date) en `fiscal_profiles`; `fecha_comprobante date` y `emisor_snapshot jsonb` en `fiscal_documents`; todas NULLABLE, sin default
- [ ] 1.3 Misma migración: `DROP FUNCTION public.rpc_fiscal_document_authorize(uuid,text,date,bigint)` + `CREATE` desde el `pg_get_functiondef` vivo con `p_fecha_comprobante date DEFAULT NULL`, escribiendo `fecha_comprobante` y `emisor_snapshot` (JOIN `fiscal_profiles` por `fiscal_profile_id`) **sólo** en el `UPDATE … WHERE status = 'pending_cae'`; re-aplicar `REVOKE`/`GRANT` exactos y el `COMMENT` vivo (sumándole una línea de este change); diff línea a línea contra el cuerpo vivo (normalizando CRLF) para demostrar que sólo cambian las líneas nuevas
- [ ] 1.4 Misma migración: `rpc_fiscal_document_set_fecha_comprobante(p_doc_id uuid, p_fecha date)` `SECURITY DEFINER`, `search_path` fijo, `REVOKE ALL … FROM PUBLIC, anon, authenticated`; bloque `DO` de introspección (un overload, ACLs)
- [ ] 1.5 Cablear el gate en `KPI_Validation.yml`; aplicar la migración dos veces seguidas contra una base local propia (no el stack compartido si otro workflow lo usa) y verificar md5/ACL/COMMENT idénticos; gate en verde

## 2. Relay: fecha confirmada por ARCA

- [ ] 2.1 Tests (rojo) en `backend/tests/test_factura_fiscal_fecha.py`: `WSFEAdapter._call_wsfe` devuelve `CAEResponse.fecha_comprobante` desde `FeDetResp…CbteFch`, y la fecha enviada si ARCA no la trae; `reconcile_submitted` la devuelve desde `ResultGet.CbteFch`; `CAERelayProcessor` la pasa a `update_authorized` en ambos caminos; `FiscalDocumentRepository.update_authorized` la manda como 5º argumento
- [ ] 2.2 Implementar: campo `fecha_comprobante` en `CAEResponse` y `ReconcileResponse` (`fiscal_document_port.py`), parseo en `wsfe_adapter.py`, propagación en `cae_relay_processor.py`, parámetro en `update_authorized`; el stub (`wsfe_stub_adapter.py`) devuelve la fecha que recibió
- [ ] 2.3 Triangular: respuesta con `CbteFch` vacía/deforme no rompe la autorización (fecha NULL, se loguea) y nunca convierte un `A` en error
- [ ] 2.4 (Sólo si OQ-7 = sí) Test con reloj fijo en 2026-09-26 02:30 UTC → `CbteFch = '20260925'`; el relay arma `CAERequest.fecha_comprobante` con la fecha de `America/Argentina/Buenos_Aires`

## 3. Perfil fiscal: datos del emisor

- [ ] 3.1 Tests (rojo) de schema y repositorio: `FiscalProfileCreate`/`Out` con los 5 campos; largos máximos e `inicio_actividades` futuro → 422; upsert tri-estado (ausente conserva, `null` borra, valor reemplaza) para los 5 campos y `iibb_condition`; el test existente de `delegacion_autorizada` sigue verde
- [ ] 3.2 Implementar en `schemas/fiscal.py`, `fiscal_profile_repository.py` (upsert con `model_fields_set` desde el service) y `fiscal_profile_service.py`
- [ ] 3.3 Tests (rojo) de `FiscalSettings.tsx`: sección "Datos para imprimir la factura", aviso con la lista de faltantes, envío sólo de los campos tocados, `inicio_actividades` como fecha; `use-fiscal-profile.ts` mapea los campos nuevos (sin `any`, tipos en `lib/types.ts`)
- [ ] 3.4 Implementar la sección y el aviso; verificar desktop y móvil (360 px), tema claro y oscuro

## 4. Generador de la factura

- [ ] 4.1 Agregar `segno>=1.6` a `backend/requirements.txt` y `pyproject.toml`; `pypdf` a `[project.optional-dependencies].dev` y al `pip install` de `.github/workflows/Backend_Tests.yml`
- [ ] 4.2 Tests (rojo) de `build_qr_url`: round-trip byte a byte con el ejemplo oficial de ARCA; payload de Sumar (números como números, `importe` 32500 entero y 32500.5 con decimales, `tipoDocRec`/`nroDocRec` 99/0 y 80/CUIT, `tipoCmp` 11, `tipoCodAut` "E"); dominio según OQ-8
- [ ] 4.3 Implementar `build_qr_url` en `backend/services/fiscal/invoice_pdf.py`, reutilizando `_COMPROBANTE_AFIP_CODE` (moverlo a un módulo compartido si importarlo desde el adapter arrastra `zeep`; nunca copiarlo)
- [ ] 4.4 Tests (rojo) de `build_invoice_view` con el caso de Sumar (todos los textos del requirement), receptor CUIT con razón social y condición, condición de venta (credit → "Cuenta Corriente", resto y sin forma de pago → "Contado"), foto del emisor con fallback campo por campo al perfil, homologación, y cada `InvoiceNotPrintable` (`invoice_date_unknown`, `issuer_data_incomplete` con la lista, `invoice_lines_mismatch`, `invoice_type_not_printable`)
- [ ] 4.5 Implementar `InvoiceView` y `build_invoice_view` (puro), reutilizando `_format_amount`/`_latin1` de `receipts.py` sin duplicarlos; tabla letra/código lista para A/B
- [ ] 4.6 Tests (rojo) de `render_invoice_pdf`: `%PDF`/`%%EOF`; texto extraído con `pypdf` contiene los datos obligatorios, "ORIGINAL", el CAE y "Comprobante Autorizado"; `segno.make` recibe exactamente la URL de `build_qr_url`; con muchas líneas, más de una página con encabezado repetido; homologación contiene "SIN VALIDEZ FISCAL"
- [ ] 4.7 Implementar `render_invoice_pdf` (maqueta D8, QR como rectángulos desde la matriz de `segno`, fuentes core latin-1); si OQ-2 = sí, parámetro `copy_label` ("ORIGINAL"/"DUPLICADO")
- [ ] 4.8 Refactor con tests en verde; generar el PDF de Sumar con datos de prueba y revisarlo a ojo (captura adjunta al PR)

## 5. Endpoint

- [ ] 5.1 Tests (rojo) de `GET /fiscal/documents/{id}/pdf`: 200 `application/pdf` con `Content-Disposition` inline/attachment y nombre `factura-C-0003-00000501.pdf`; **404 idéntico** para uno de otra cuenta y para uno inexistente; 409 `fiscal_document_not_authorized` para `pending_cae`/`rejected`/`voided`; 409 `issuer_data_incomplete`/`invoice_date_unknown`/`invoice_lines_mismatch` en RFC 7807; 422 para id no-UUID; 401 sin sesión
- [ ] 5.2 Tests (rojo) del repositorio: `get_invoice_lines(doc_id, account_id)` filtra por `account_id`, trae `name_snapshot`/`quantity`/`price`/`subtotal` en orden y la forma de pago efectiva (orden, si no la operación de venta)
- [ ] 5.3 Implementar repositorio, `backend/services/fiscal/invoice_print_service.py` y la ruta en `routers/fiscal.py` (sólo DI + `Response`); actualizar el docstring de endpoints del router

## 6. Read models con el CAE

- [ ] 6.1 Tests (rojo): `SalesRepository` devuelve `fiscal_cae`, `fiscal_cae_due_date`, `fiscal_comprobante_type`; `SaleOut` los expone; `use-sales.ts` los mapea a `SaleFiscalState` (`cae`, `caeDueDate`, `comprobanteType`)
- [ ] 6.2 Implementar en `sales_repository.py`, `schemas/sales.py`, `lib/types.ts`, `hooks/data/use-sales.ts`
- [ ] 6.3 Tests (rojo): `SalesOrderRepository.list_orders` trae el estado real del comprobante (`status`, `punto_de_venta`, `number`, `cae`, `cae_due_date`, `comprobante_type`, `is_frozen` con la misma condición que `routers/fiscal.py`), filtrando por `account_id`
- [ ] 6.4 Implementar en `sales_order_repository.py` y su schema

## 7. Superficie

- [ ] 7.1 Tests (rojo) de `components/fiscal/FiscalInvoiceSummary.tsx`: autorizado muestra badge, "Factura C 0003-00000501", CAE, "vence 05/10/2026", botón copiar con `aria-label` y enlace "Verificar en ARCA" (`target="_blank"`, `rel="noopener noreferrer"`, URL de constatación); `pending_cae`/`voided`/congelado no muestran CAE ni enlace
- [ ] 7.2 Implementar el componente (tokens semánticos, `tabular-nums`, sin desborde a 360 px) y usarlo en `sale-operations-list.tsx` (reemplaza badge + label) y en `/ventas/ordenes` (con el estado real: test de que una orden autorizada muestra "Autorizado" al cargar)
- [ ] 7.3 Tests (rojo) de `lib/api/fiscal-invoice.ts`: `fetchFiscalInvoicePdf` usa `getAuthHeaders`, corta con `redirectedOnUnauthorized`, devuelve el blob y traduce 409 `issuer_data_incomplete`/`invoice_date_unknown` a errores tipados
- [ ] 7.4 Implementar el helper
- [ ] 7.5 Tests (rojo) de `SaleReceiptButton` con `fiscal` autorizado: menú "Factura" con "Ver / imprimir factura", "Descargar factura (PDF)", "Verificar en ARCA" y, separado, "Comprobante interno (sin validez fiscal)" + "Copiar texto"; WhatsApp comparte `factura-C-0003-00000501.pdf` y su texto nombra la factura; el aviso de datos incompletos lleva a `/configuracion/fiscal`; sin `fiscal` autorizado, el comportamiento actual intacto (tests existentes en verde)
- [ ] 7.6 Implementar en `sale-receipt-button.tsx` (reutilizar el flujo de share/descarga existente, extraído a una función común dentro del archivo o de `lib/`, sin duplicarlo) y pasar `fiscal` desde `sale-operations-list.tsx`
- [ ] 7.7 Verificación visual: `/ventas` (fila expandida y menú), `/ventas/ordenes` y `/configuracion/fiscal` en desktop (1280) y móvil (375), tema claro y oscuro — 12 capturas en el PR; contraste del bloque del CAE por el gate `token-contrast-aa`

## 8. Verificación y cierre del apply

- [ ] 8.1 Backend completo (`pytest` con coverage ≥ 87 %), frontend completo (Vitest), `tsc` sin errores nuevos, gates SQL en el orden de `KPI_Validation.yml`
- [ ] 8.2 Revisión adversarial del diff centrada en: exactitud del payload del QR, tenencia del endpoint (404 idéntico), que la RPC reescrita sólo cambia las líneas nuevas, y que ninguna rama del frontend imprime un comprobante no autorizado
- [ ] 8.3 PR del apply (conventional commits, trailer de co-autoría), CI en verde, merge

## 9. Post-merge (con el PO)

- [ ] 9.1 Verificar en prod (SELECT): `max(version)`, columnas nuevas, una sola `rpc_fiscal_document_authorize` de 5 parámetros con ACL y `COMMENT` correctos
- [ ] 9.2 Backfill de `fecha_comprobante` de los comprobantes autorizados sin fecha (los 3 medidos el 2026-09-25 más cualquiera autorizado durante el despliegue) con `FECompConsultar` + `rpc_fiscal_document_set_fecha_comprobante`, **con OK explícito del PO** (OQ-9); anotar cada fecha obtenida
- [ ] 9.3 El PO (y Sumar) completan sus datos en `/configuracion/fiscal`
- [ ] 9.4 Humo real: imprimir la Factura C 0003-00000501 de Sumar, escanear el QR con un celular y confirmar que ARCA muestra el comprobante; constatarla en `servicioscf.afip.gob.ar/publico/comprobantes/cae.aspx`; enviarla por WhatsApp desde el celular
- [ ] 9.5 Actualizar `CHANGES.md` (ficha del change; cerrar el candidato `comprobante-fiscal-visible`; anotar candidatos nuevos: `admin-pagos-factura-imprimible` si OQ-6 lo difiere, logo si OQ-4) y guardar el resultado en engram
