## 0. Gate 0 — Sign-off del PO (✅ RESUELTO 2026-06-26, PO GonzaloSevilla22)

- [x] 0.1 Confirmar decisiones D1–D5 del design con el PO (fiscal, dinero real)
- [x] 0.2 OQ-1 → auto del cliente (C-22) cuando esté; receptor **NUNCA obligatorio** bajo el umbral (ni al cargar cliente ni al emitir)
- [x] 0.3 OQ-2 → desglose neto/IVA lo provee la venta (no auto-computar)
- [x] 0.4 OQ-3 → umbral como constante de config (`settings.afip_consumidor_final_threshold`)
- [x] 0.5 Sign-off obtenido → habilitado para apply (PR para review del PO; NUNCA auto-merge de código fiscal)

## 1. Safety net (baseline antes de tocar nada)

- [x] 1.1 Baseline: suite fiscal corrida — detectadas 3 fallas en `test_wsfe_numeracion.py`
- [x] 1.2 Verificado pre-existente (fallan idéntico en la base por mocks stale `Nro`→`CbteNro` del PR #225); reparados los mocks

## 2. DB — migración aditiva (20260800000006_fiscal_receptor_iva_relay.sql)

- [x] 2.3 Migración aditiva: `ALTER TABLE fiscal_documents ADD COLUMN` (5 columnas NULLABLE)
- [x] 2.4 `rpc_emit_pending_cae`: DROP firma vieja (4 args) + CREATE con 5 params nuevos, persistidos en el INSERT
- [x] 2.5 `rpc_emit_subscription_payment_cae`: persiste `receptor_doc_tipo/nro` (NULLIF 99) — cierra el bug latente
- [x] 2.7 Invariante de rollback documentada en el header del `.sql` (DROP COLUMN + restaurar RPC)
- [ ] 2.1/2.2/2.6 Verificación DB-level (RPC persiste receptor/IVA, NULL=actual) → cubierta por el test de service (params fluyen) + task 8.3 (integración con DB real, manual). Sin DB local en este entorno.

## 3. Port — CAERequest (✅ verde)

- [x] 3.1/3.2/3.3 `receptor_doc_tipo`/`receptor_doc_nro` agregados a `CAERequest`; default None preserva construcción legacy

## 4. Repository — claim_pending RETURNING (✅ verde)

- [x] 4.1/4.2/4.3/4.4 `claim_pending` devuelve las 5 columnas nuevas; `list_pending`/`list_pending_all` ya las exponen vía `fd.*`

## 5. Relay — CAERelayProcessor threading (✅ verde, test_cae_relay_receptor_iva.py)

- [x] 5.1/5.2 `process_document` propaga receptor + IVA al `CAERequest` desde el doc
- [x] 5.3 TRIANGULATE: doc histórico sin esos campos (NULL) → defaults (comportamiento actual)

## 6. Adapter — DocTipo derivado + AlicIva real + guards (✅ verde, test_wsfe_receptor_doctipo.py)

- [x] 6.1/6.2/6.3 `DocTipo` derivado (80=CUIT, 96=DNI, 99/DocNro=0) reemplaza el hardcode
- [x] 6.4/6.5 Array `AlicIva` real desde el desglose; tipo C sin array (sin cambios)
- [x] 6.6/6.7 Guard del umbral (`settings.afip_consumidor_final_threshold`, default 10_000_000)
- [x] 6.8/6.9 Guard D5: Factura A/B sin desglose falla explícito (no IVA=0 silencioso)
- [x] 6.10 TRIANGULATE: Factura C consumidor final < umbral = idéntico a hoy (regresión verde)

## 7. Schema/Service — propagar receptor en la emisión (✅ verde, test_emit_pending_cae_receptor.py)

- [x] 7.1/7.2 `EmitPendingCAERequest` (+neto/iva_amount/iva_alicuota_id) y `emit_pending_cae` pasan receptor + IVA a la RPC
- [x] 7.3 TRIANGULATE: emisión sin receptor sigue funcionando (consumidor final)

## 8. Regresión + integración

- [x] 8.1 Suite completa fiscal `-m "not integration"` verde (617 passed desde la raíz; flujo admin de suscripción intacto)
- [x] 8.2 Baseline de la sección 1 intacto (mocks reparados)
- [ ] 8.3 (Manual, PO) E2E homologación con DB real: Factura B con CUIT + Factura ≥ umbral con un CUIT representado, tras `npx supabase db push` de la migración
- [x] 8.4 Memoria engram actualizada con el resultado del apply (topic `opsx/fiscal-receptor-iva-relay/apply`)
