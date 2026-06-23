## Context

La facturación electrónica AFIP funciona **end-to-end en homologación** desde C-31 (`v21-wsfe-homologacion-wiring`, archivado 2026-06-23): CAE real `86250464989491` obtenido contra ARCA `wswhomo` el 2026-06-23. El `WSFEAdapter` autentica vía WSAA (`zeep` + parseo del TA XML), arma `FECAESolicitar` y procesa la respuesta. El relay (`pg_cron` + 3 puntos de entrada) y la factory real/stub (C-27) ya están en producción.

Sin embargo, ese E2E real destapó que la solicitud de CAE **no es válida para producción**. Estado actual del código (no re-derivar):

- `backend/services/fiscal/wsfe_adapter.py` → `_call_wsfe` construye `request_body["FeCAEReq"]["FeDetReq"]["FECAEDetRequest"][0]` con `Concepto=1, DocTipo=99, DocNro, CbteDesde=CbteHasta=invoice_data.number, CbteFch, ImpTotal=total, ImpTotConc=0, ImpNeto=total, ImpOpEx=0, ImpIVA=0, ImpTrib=0, MonId="PES", MonCotiz=1`. **No hay `CondicionIVAReceptorId` ni array `Iva`.** `_get_wsaa_token` ejecuta `loginCms` **siempre** (sin caché de TA). `_COMPROBANTE_AFIP_CODE`: `factura_a=1, factura_b=6, factura_c=11`.
- `backend/services/fiscal/fiscal_document_port.py` → `CAERequest(account_id, fiscal_document_id, comprobante_type, punto_de_venta, number, total, cuit_emisor, ambiente, cuit_receptor=None, fecha_comprobante=None)`. `CAEResponse(cae, cae_due_date, is_approved, error_code, error_detail)`.
- `backend/services/fiscal/adapter_factory.py` → `build_cae_adapter(*, has_cert, service_client=None)`.
- `backend/routers/fiscal.py` → 3 puntos de relay: `process-pending` (user JWT), `process-pending-cron` (cron Bearer secret, cross-account), `process_doc_by_id_background` (fire-and-forget post-emisión vía `background_tasks.add_task`).
- `backend/requirements.txt` y `backend/pyproject.toml` → tienen `zeep>=4.2,<5` y `redis>=5.0`; **falta `supabase`**.

Constraint dura: el dominio se mantiene SOAP-free (frontera ACL). Governance **CRÍTICO** (fiscal, dinero real, clave privada): este documento propone; el apply espera sign-off del PO.

## Goals / Non-Goals

**Goals:**
- Producir solicitudes de CAE **autorizables en producción**: `CondicionIVAReceptorId` (RG 5616), array `Iva`/`AlicIva`, numeración autoritativa vía `FECompUltimoAutorizado`.
- Cachear el TA de WSAA de forma que sobreviva entre las 3 invocaciones del relay, evitando el cooldown ~10 min de WSAA.
- Declarar `supabase-py` para que el cert-read del bucket `afip-certs` funcione en prod.
- Mantener la frontera del ACL: los nuevos datos fiscales viajan como campos de dominio en `CAERequest`; el SOAP queda en el adapter.

**Non-Goals:**
- NO se toca la transacción de emisión ni la de venta (C-29). Todo el cambio vive en el camino relay/adapter.
- NO se implementa la tabla completa RG 5616 de `CondicionIVAReceptorId` para todos los casos: se cubre el set necesario (consumidor final + las condiciones que el proyecto ya maneja) y se deja la tabla completa para confirmación del PO.
- NO se corta a producción en este change: el corte/runbook es una Open Question (defer probable).
- NO se escribe código de producción hasta el sign-off del PO (Gate 0 en tasks.md).

## Decisions

### D1 — Nuevos campos de dominio en `CAERequest` (no filtrar SOAP)

Para construir `CondicionIVAReceptorId` y el array `Iva` sin que el dominio conozca SOAP, se agregan campos de dominio a `CAERequest`:
- `receptor_iva_condition` (la condición IVA del receptor, ya modelada en el dominio fiscal: `consumidor_final` / `responsable_inscripto` / `monotributista` / `exento`).
- Un desglove de IVA: o bien `neto` + `iva_amount` (caso simple, una sola alícuota 21%), o bien una lista de alícuotas `[(alicuota_id, base, importe)]` para soportar múltiples alícuotas a futuro. **Decisión**: empezar con `neto` + `iva_amount` + `iva_alicuota_id` (suficiente para 21% único) y dejar la lista como evolución; el adapter traduce a `AlicIva`. El mapeo SOAP (nombres `BaseImp`, `Importe`, `Id`) vive 100% en el adapter.

*Alternativa descartada*: pasar la condición/IVA ya como dict SOAP desde el service → rompe el ACL (el service conocería el formato AFIP). Rechazada por la regla dura del proyecto.

### D2 — Mapeo `CondicionIVAReceptorId` (RG 5616/2024)

Tabla de mapeo en el adapter `receptor_iva_condition → CondicionIVAReceptorId`:

| receptor_iva_condition | CondicionIVAReceptorId |
|---|---|
| `consumidor_final` | 5 |
| `responsable_inscripto` | 1 |
| `monotributista` | 6 |
| `exento` | 4 |

`consumidor_final = 5` está confirmado por el E2E (Code 10246 al omitirlo). El resto de la tabla RG 5616 **debe confirmarlo el PO** antes de facturar tipos A a RI reales (ver Open Questions). El adapter falla de forma explícita (error normalizado) si recibe una condición sin mapeo, en vez de omitir el campo y arriesgar Code 10246.

### D3 — Construcción del array `Iva` vs. rama tipo C

- **Tipo A/B** (IVA discriminado): el adapter arma `Iva = [{Id: 5, BaseImp: neto, Importe: iva_amount}]` (Id=5 = 21%), con `ImpNeto = neto`, `ImpIVA = iva_amount`, `ImpTotal = total`, garantizando `ImpNeto + ImpIVA = ImpTotal` (caso sin otros tributos/exentos).
- **Tipo C** (monotributo, `CbteTipo=11`): **sin** array `Iva`, `ImpIVA=0`, `ImpNeto=ImpTotal`. La rama se decide por `comprobante_type`/`CbteTipo` (el tipo C no discrimina IVA por definición).

El adapter es la única capa que conoce `AlicIva` Id=5 ↔ 21%.

### D4 — Numeración autoritativa `FECompUltimoAutorizado` + reconciliación con la reserva local

El adapter consulta `FECompUltimoAutorizado(PtoVta, CbteTipo)` antes de `FECAESolicitar` y usa `último + 1`. Esto convive con la reserva local de `rpc_next_document_number` (que ya reserva `number` en la emisión). Dos estrategias para reconciliar:

- **(A) Validate-and-align**: confiar en la reserva local como número esperado; consultar ARCA solo para validar que `local == último+1`. Si difieren → registrar desync (Code 10016 esperado), alinear al número de ARCA o marcar el documento para revisión.
- **(B) ARCA-as-source-of-truth at CAE time**: ignorar el `number` local al momento del CAE y usar siempre `FECompUltimoAutorizado + 1`; el `number` local queda como reserva/orden interno, reconciliado a posteriori.

**Decisión del PO (2026-06-23)**: **(B) ARCA-as-source-of-truth** — usar siempre `FECompUltimoAutorizado + 1`; el `number` local es la reserva interna. Ante mismatch detectado (Code 10016), el adapter lo maneja explícitamente sin persistir CAE contra número incorrecto.

### D5 — Store de caché del TA

El TA dura ~12h; WSAA rechaza re-`loginCms` dentro de ~10 min. La caché **debe sobrevivir entre invocaciones** porque cron + background = procesos separados (in-process no alcanza). Opciones:

- **Redis (Upstash)** — `redis>=5.0` ya es dependencia. Key `ta:{cuit}:{service=wsfe}:{ambiente}`, value `{token, sign, expiration}`, TTL ≈ tiempo hasta `expiration` menos un margen de refresco (p.ej. 30 min). Pro: TTL nativo, sin migración. Con: depende de que Upstash esté provisionado en prod.
- **Tabla Postgres** (p.ej. `wsaa_tickets(cuit, service, ambiente, token, sign, expiration)` con RLS/service-role) — Pro: ya hay Postgres, durable, auditable. Con: requiere migración + lógica de expiración manual.

**Decisión del PO (2026-06-23)**: **Postgres** — tabla `wsaa_access_tickets` keyed por `(account_id, cuit, ambiente)`, columnas `token`, `sign`, `expires_at`. RLS por `account_id`; escrito/leído server-side en el path aislado del adapter (service_role ya autorizado para el bucket de certs, D7). Migración incluida en este change. **Inyección**: el store se inyecta en `build_cae_adapter`/`WSFEAdapter` como un puerto pequeño (`TicketCache.get(key)/set(key, ta, ttl)`), así los 3 puntos de relay comparten la misma implementación y los tests usan un fake in-memory.

### D6 — Dependencia `supabase-py`

Agregar `supabase` a `backend/requirements.txt` y a `dependencies` de `backend/pyproject.toml`. Sin esto, `self._service_client.storage.from_("afip-certs").download(path)` no tiene la librería en prod → cert-upload 503 → fallback a stub. `zeep` ya está en ambos archivos: no se re-agrega.

### D7 — TDD con mocks (sin red)

Todos los tests del gate de CI mockean `zeep`/WSAA/Storage (no tocan ARCA). El E2E real contra ARCA es `@pytest.mark.integration` (manual, fuera del gate). Path de tests: `backend/tests/test_*.py` (existe `backend/tests/test_c27_wsfe_adapter.py`). Arquitectura 3 capas y ACL se mantienen; el TA cache es un puerto inyectado (composición, no herencia).

## Risks / Trade-offs

- **[Mapeo RG 5616 incompleto]** → Solo `consumidor_final=5` está validado por el E2E; un mapeo incorrecto para otras condiciones genera Code 10246 en prod. **Mitigación**: el adapter falla explícito ante condición sin mapeo; PO confirma la tabla completa antes del corte.
- **[Estrategia de numeración cambia la UX del `number`]** → Si se adopta D4(B), el número fiscal autoritativo puede diferir del reservado mostrado. **Mitigación**: decisión del PO; el spec solo exige manejar el mismatch (Code 10016).
- **[Caché TA stale o compartida mal entre cuentas]** → Una key mal formada podría cruzar TAs entre CUITs/ambientes. **Mitigación**: key `{cuit}:{service}:{ambiente}` estricta; margen de refresco antes de `expiration`; tests de expiración y de aislamiento por key.
- **[Upstash no provisionado en prod]** → Si se elige Redis y no está disponible, el TA cache falla. **Mitigación**: fallback a re-`loginCms` (degradado pero correcto) o elegir el store DB; Open Question del PO.
- **[Totales inconsistentes]** → `ImpNeto + ImpIVA ≠ ImpTotal` provoca rechazo de ARCA. **Mitigación**: el desglose viaja validado desde el dominio; tests de consistencia de totales (A/B y C).
- **[Governance CRÍTICO]** → cambios sobre facturación real con clave privada. **Mitigación**: Gate 0 (sign-off PO) antes de cualquier apply; E2E contra ARCA fuera del gate de CI.

## Migration Plan

1. **Sign-off del PO** (Gate 0) antes de escribir código.
2. Resolver Open Questions (store del TA, estrategia de numeración).
3. Implementar TDD por hueco (RED→GREEN→TRIANGULATE) con todo mockeado.
4. Agregar `supabase` a ambos archivos de dependencias; verificar build del backend.
5. E2E `@pytest.mark.integration` manual contra ARCA homologación con cert del PO (fuera del gate de CI), reusando el flujo que ya obtuvo CAE `86250464989491`.
6. Corte a producción y runbook: **fuera de alcance de este change** salvo que el PO lo incluya (Open Question).
- **Rollback**: el camino relay/adapter es aditivo; si una solicitud falla en prod, el comprobante queda `pending_cae`/`rejected` con `last_error` (la máquina de estados existente lo cubre) y se puede revertir el adapter a la versión homologación-only.

## Open Questions — RESOLVED (PO sign-off 2026-06-23)

> Todas las preguntas abiertas fueron respondidas por el PO antes del apply (Gate 0). Las decisiones se bajan a las secciones D2, D4, D5 correspondientes.

1. ~~**Store de la caché del TA**~~ → **RESOLVED: Postgres** (`wsaa_access_tickets`). Ver D5 actualizado.
2. ~~**Estrategia de numeración**~~ → **RESOLVED: ARCA-as-source-of-truth** (`FECompUltimoAutorizado + 1`). Ver D4 actualizado.
3. ~~**Tabla completa RG 5616 de `CondicionIVAReceptorId`**~~ → **RESOLVED: 4 condiciones mapeadas** (`consumidor_final=5, responsable_inscripto=1, monotributista=6, exento=4`). Ver D2 (sin cambios — ya incluye la tabla completa).
4. ~~**Alcance del corte a producción / runbook**~~ → **RESOLVED: DIFERIDO**. El runbook de corte es out-of-scope de este change; se trackea en un change dedicado.
