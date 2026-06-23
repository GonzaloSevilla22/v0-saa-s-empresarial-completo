## 0. Gate de governance — sign-off del PO (BLOQUEANTE)

> Governance **CRÍTICO**: facturación AFIP real, dinero real, clave privada. **No se escribe NINGUNA línea de código de producción hasta que el PO apruebe explícitamente** la estrategia de numeración (D4), el store de la caché del TA (D5) y la tabla `CondicionIVAReceptorId` RG 5616 (D2). El apply de las tareas 1+ queda bloqueado por este gate.

- [x] 0.1 Presentar al PO las 4 Open Questions de `design.md` y obtener decisión escrita: (a) store del TA → **Postgres** (`wsaa_access_tickets`), (b) numeración → **ARCA-as-source-of-truth** (`FECompUltimoAutorizado + 1`), (c) tabla RG 5616 → **4 condiciones** (`consumidor_final=5, responsable_inscripto=1, monotributista=6, exento=4`), (d) runbook → **DIFERIDO** (out-of-scope de este change).
- [x] 0.2 Sign-off del PO registrado en `design.md` (2026-06-23). Gate 0 satisfecho — tareas 1-6 habilitadas.

## 1. Hueco 5 — Dependencia supabase-py (sin red, mecánico)

- [x] 1.1 RED: test que parsea `backend/requirements.txt` y `backend/pyproject.toml` y asume que `supabase` está declarado en ambos (falla hoy) — `backend/tests/test_wsfe_prod_dependencies.py`
- [x] 1.2 GREEN: agregar `supabase` a `backend/requirements.txt` y a `dependencies` de `backend/pyproject.toml` (mínimo para pasar el test)
- [x] 1.3 TRIANGULATE: segundo caso asserta que `zeep` sigue declarado exactamente una vez en cada archivo (no se duplicó) y que `supabase` no quedó duplicado

## 2. Hueco 1 — CondicionIVAReceptorId (RG 5616, prioridad máxima)

- [x] 2.1 RED: test (zeep/WSAA/Storage mockeados) que captura el `FECAEDetRequest` construido por `_call_wsfe` para un receptor consumidor final y asume `CondicionIVAReceptorId == 5` (falla: hoy la key no existe) — `backend/tests/test_wsfe_condicion_iva_receptor.py`
- [x] 2.2 GREEN: agregar `receptor_iva_condition` a `CAERequest` (`fiscal_document_port.py`) y, en `wsfe_adapter._call_wsfe`, mapear → `CondicionIVAReceptorId` (consumidor_final=5) e incluirlo en el dict; sin filtrar SOAP al dominio
- [x] 2.3 TRIANGULATE: segundo caso (responsable_inscripto → id según tabla D2) + caso de borde: condición sin mapeo SHALL fallar con error normalizado (no omitir el campo y arriesgar Code 10246)

## 3. Hueco 2 — Array Iva (AlicIva) + rama tipo C

- [x] 3.1 RED: test (mocks) que captura el `FECAEDetRequest` de un comprobante tipo B con neto+IVA 21% y asume array `Iva = [{Id:5, BaseImp, Importe}]` con `ImpNeto+ImpIVA == ImpTotal` (falla: hoy `ImpIVA=0`, sin array) — `backend/tests/test_wsfe_iva_array.py`
- [x] 3.2 GREEN: agregar el desglose de IVA (`neto`, `iva_amount`, `iva_alicuota_id`) a `CAERequest`; en `_call_wsfe` construir el array `Iva` y los totales consistentes para A/B
- [x] 3.3 TRIANGULATE: caso de borde tipo C (CbteTipo=11) → SIN array `Iva`, `ImpIVA=0`, `ImpNeto=ImpTotal`; verificar la consistencia de totales en ambas ramas

## 4. Hueco 3 — Numeración autoritativa FECompUltimoAutorizado

> Implementar la estrategia que el PO eligió en 0.1(b).

- [x] 4.1 RED: test (mock del cliente WSFEv1) donde `FECompUltimoAutorizado(PtoVta, CbteTipo)` devuelve `41` y se asume que `_call_wsfe` pide `CbteDesde == CbteHasta == 42` (falla: hoy usa `invoice_data.number`) — `backend/tests/test_wsfe_numeracion.py`
- [x] 4.2 GREEN: consultar `FECompUltimoAutorizado(PtoVta, CbteTipo)` antes de `FECAESolicitar` y usar `último + 1`
- [x] 4.3 TRIANGULATE: caso de borde mismatch entre el `number` local reservado (`rpc_next_document_number`) y el último de ARCA → se detecta/maneja (Code 10016) sin persistir CAE contra número fuera de secuencia, según la estrategia aprobada (D4)

## 5. Hueco 4 — Caché del Ticket de Acceso WSAA

> Usar el store que el PO eligió en 0.1(a). Tests con un fake in-memory del `TicketCache` (no Redis/DB real, no red).

- [x] 5.1 RED: test donde un TA vigente está en el `TicketCache` fake y se asume que `_get_wsaa_token` lo reusa SIN llamar a `loginCms` (falla: hoy `loginCms` siempre) — `backend/tests/test_wsfe_ta_cache.py`
- [x] 5.2 GREEN: introducir el puerto `TicketCache` (get/set por key `{cuit}:wsfe:{ambiente}`), inyectarlo vía `build_cae_adapter`/`WSFEAdapter`, y reusar el TA vigente en `_get_wsaa_token`
- [x] 5.3 TRIANGULATE: caso TA expirado (o dentro del margen de refresco) → fuerza nuevo `loginCms` y actualiza la caché; caso "persistencia entre invocaciones" → un segundo adapter construido con el mismo store reusa el TA (la caché no es in-process)
- [x] 5.4 Verificar que los 3 puntos de relay (`process-pending`, `process-pending-cron`, `process_doc_by_id_background` en `backend/routers/fiscal.py`) comparten la misma instancia/implementación del store

## 6. Cierre — gate de tests

- [x] 6.1 Ejecutar `python -m pytest backend/tests -m "not integration"` desde la raíz del repo y confirmar verde (gate de CI) — **529/529 PASSED**
- [ ] 6.2 (Manual, FUERA del gate) E2E `@pytest.mark.integration` contra ARCA homologación con el cert del PO, reusando el flujo que obtuvo CAE `86250464989491` — confirmar que la solicitud de producción (CondicionIVAReceptorId + Iva + numeración) es aceptada
