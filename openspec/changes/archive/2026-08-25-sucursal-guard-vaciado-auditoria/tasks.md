# sucursal-guard-vaciado-auditoria — Tasks

> Governance MEDIUM. Strict TDD: cada grupo con lógica arranca por su prueba en rojo.
> Prod = proyecto `gxdhpxvdjjkmxhdkkwyb`. Nunca `apply_migration` por MCP: siempre `npx supabase db push`.
> Todo commit vía PR — incluidos los fixes triviales post-merge. Nunca a `main` directo.

## 1. Revalidación previa (nada se escribe antes de esto)

- [x] 1.1 Revalidar `MAX(version)` y `count(*)` de migraciones en prod y fijar el número del archivo nuevo. Referencia al proponer: `20261013000001` / 262 filas. Hay sesiones paralelas del PO: **no asumir**. — Revalidado 2026-08-25: idéntico (20261013000001 / 262). Archivo nuevo: `20261014000001`.
- [x] 1.2 Re-correr el censo de ERRCODEs en los dos frentes (repo completo `.sql/.py/.ts/.tsx/.md/.yml` + `pg_proc.prosrc` vivo de prod) y confirmar que `P0428` sigue libre. Si se ocupó, elegir el siguiente libre en la banda `P04xx` y actualizar design + specs. — P0428 confirmado libre en prod (censo completo vía pg_proc.prosrc).
- [x] 1.3 **Gate de integridad de función**: capturar con `pg_get_functiondef` VIVO de prod `rpc_deactivate_branch`, `rpc_close_branch`, `rpc_open_branch`, `rpc_create_branch`, `c26_default_branch` y `c21_apply_branch_stock_delta` en `openspec/changes/sucursal-guard-vaciado-auditoria/baseline/*.sql`. — Hecho, 6 archivos en `baseline/`.
- [x] 1.4 Re-medir la auditoría de daño histórico en prod. Referencia: 40 / 2 / **0** / **0** / 0. — Re-medido idéntico: 40/2/0/0.
- [x] 1.5 Verificar que los permisos sobre `branches` siguen siendo a nivel tabla (no por columna) para `authenticated`. — Confirmado vía role_table_grants; también confirmó OQ-7 (anon con privilegios de tabla).

## 2. Barrido de escritores de `branches` (antes de escribir el disparador)

- [x] 2.1 Barrer las funciones vivas de prod que escriban sobre `public.branches`. — 6 funciones (ver design.md "Barrido de escritores").
- [x] 2.2 Barrer el código de aplicación y fixtures de test que borren o desactiven sucursales. — HALLAZGO NO PREVISTO: 15 gates SQL preexistentes con `DELETE FROM public.branches` en su cleanup (cascade desde `DELETE FROM accounts` dispara el trigger BEFORE DELETE). Fix: bypass `session_replication_role=replica` en los 15 archivos + el nuevo. Ver design.md.
- [x] 2.3 Confirmar que el alta perezosa sólo INSERTA. — Verificado, no razonado.
- [x] 2.4 Documentar el barrido en `design.md`. — Sección "Barrido de escritores" agregada.

## 3. Prueba SQL del guard — RED (antes de la migración)

- [x] 3.1 Crear `supabase/tests/test_sucursal_guard_vaciado.sql` con fixture sintético auto-limpiable.
- [x] 3.2 Desactivar con existencias falla con `P0428`, mensaje con las unidades.
- [x] 3.3 Desactivar sin existencias pasa.
- [x] 3.4 Transferir y después desactivar pasa.
- [x] 3.5 Cerrar con existencias falla con `P0428`, token `branch_has_stock` conservado.
- [x] 3.6 Los cuatro caminos rechazan (comando desactivar, comando cerrar, UPDATE directo, DELETE directo).
- [x] 3.7 Borrar una sucursal vacía también falla (D4).
- [x] 3.8 Caja abierta bloquea (ejecutado); transferencias sin completar — candado de texto (estructuralmente inejercitable hoy: CHECK status IN ('completed')).
- [x] 3.9 Matriz de evasión: renombrar/dirección/reactivar con stock pasan (ejecutado); quantity negativa — candado de texto (CHECK quantity >= 0 lo impide con datos reales).
- [x] 3.10 Sucursal única de la cuenta con stock recibe el mensaje de "creá otra sucursal".
- [x] 3.11 Anti-overload: una sola definición viva por función tocada.
- [x] G2: alta registra autor (rpc_create_branch, degradable si el plan no habilita módulo); alta de sistema deja NULL; baja registra autor+momento; audit_logs recibe el ciclo de vida sin generar notifications.

## 4. Migración — GREEN

- [x] 4.1 Archivo `20261014000001_sucursal_guard_vaciado_auditoria.sql` con cabecera completa.
- [x] 4.2 Columnas `created_by`/`deactivated_at`/`deactivated_by`, `ADD COLUMN IF NOT EXISTS`, sin FK dura, sin backfill.
- [x] 4.3 `COMMENT ON COLUMN` de las tres.
- [x] 4.4 `_branch_blocking_content` — lectura única del inventario bloqueante.
- [x] 4.5 `fn_guard_branch_decommission` — disparador BEFORE UPDATE OR DELETE, autosuficiente.
- [x] 4.6 `DROP TRIGGER IF EXISTS` + `CREATE TRIGGER`.
- [x] 4.7 `rpc_deactivate_branch` redefinida desde el baseline vivo.
- [x] 4.8 `rpc_close_branch` redefinida desde el baseline vivo, unificada a P0428, `last_active_branch` sin tocar.
- [x] 4.9 `rpc_create_branch` redefinida desde el baseline vivo, completa `created_by`.
- [x] 4.10 `fn_audit_branch_lifecycle` — disparador AFTER INSERT OR UPDATE, ciclo de vida completo en `audit_logs`, sin notificaciones (verificado por el gate SQL).
- [x] 4.11 Ninguna función cambió de firma — sin reemisión de permisos necesaria; se reafirman igual (REVOKE/GRANT) en las 3 RPCs públicas por convención del proyecto.
- [x] 4.12 Verificado que los 2 helpers internos no quedan expuestos a `anon`/`authenticated` (gate propio de la migración, sección 10, chequeo (e)).
- [x] 4.13 Aplicado en local (`supabase start` + `db reset`) y `test_sucursal_guard_vaciado.sql` corrido hasta verde — ver detalle de verificación en el PR.
- [x] 4.14 Encadenado al final de la cadena de reaplicación de `.github/workflows/KPI_Validation.yml`.

## 5. Backend

- [x] 5.1 Prueba pytest RED del mapeo P0428 → 409 (`backend/tests/test_errors_business_codes.py`).
- [x] 5.2 `P0428` agregado a `_BUSINESS_ERRCODE_STATUS`.
- [x] 5.3 Prueba de `PUT /branches/{id}` con `is_active=false` sobre sucursal con stock → 409 RFC 7807 (`backend/tests/test_sucursal_guard_vaciado.py`). Requirió agregar `is_active` a `BranchUpdate` (antes inalcanzable por accidente, no por protección).
- [x] 5.4 `BranchOut` expone `is_active`/`address`/`account_id`/autoría; ya NO declara `user_id` (columna inexistente).
- [x] 5.5 Suite backend completa: 1586 passed, 3 skipped (pre-existentes), 0 regresiones.

## 6. Frontend — G1 y G2 (pantalla de sucursales)

- [x] 6.1 Prueba vitest de la traducción del error nuevo (`use-branches-translate-error.test.ts`), función `translateRpcError` exportada.
- [x] 6.2 Traductor existente extendido (branch_has_open_cash_session, branch_has_pending_transfers, branch_delete_forbidden).
- [x] 6.3 `DeactivateBranchDialog.tsx` reutiliza `useBranchStock` — sin consulta nueva.
- [x] 6.4 `BranchList.tsx`: `confirm()` nativo reemplazado por `DeactivateBranchDialog` (AlertDialog del design system, mismo patrón que `DeleteOperationDialog`); si hay contenido no ofrece confirmar, ofrece ir a transferir (`/sucursales/[id]/stock`).
- [x] 6.5 Autoría visible: "Creada por X" en activas; sección "Sucursales inactivas" con "Desactivada por X el <fecha>".
- [x] 6.6 `useTeamMembers` promovido de `TeamSection.tsx` a `hooks/data/use-team-members.ts` (capa canónica) + `resolveMemberName` — reutilizado, no reinventado.

## 7. Frontend — G3 (descubribilidad de la transferencia)

- [x] 7.1-7.3 `TransferStockAction.tsx`: acción por fila en `/stock`, visible sólo con `hasBranchesModule && branches.length > 1`; desglose por sucursal (`useProductBranchBreakdown`, hook nuevo — vista inversa de `useBranchStock`); abre `TransferStockModal` reutilizado tal cual.
- [x] 7.4 `humanizeOperationError` devuelve `{message, action?}` — cambio de contrato migrado en el único caller (`sale-form.tsx`, 2 call sites) en el mismo PR.
- [x] 7.5 Acción cableada en `sale-form.tsx` (toast de sonner con botón). NO cableada en el "mostrador" (POS `/ventas/pos`): usa un formateador de error propio (`friendlyError`) no wireado a `operation-errors.ts` — **fuera de alcance de este pase, candidato propio anotado**.
- [x] 7.6 Suite vitest completa: 1413 passed / 1 fallo pre-existente no relacionado (`SuscripcionesAmbiguasPage`); `tsc` sin errores nuevos.

## 8. Verificación visual y de accesibilidad

- [ ] 8.1 Verificar las tres superficies en escritorio y móvil.
- [ ] 8.2 Verificar en tema claro y oscuro.
- [ ] 8.3 Pasada de accesibilidad — parcial: los componentes nuevos usan `aria-label`/`title` y los primitivos `AlertDialog`/`Dialog` del design system (foco/teclado ya resueltos por esos primitivos). Verificación visual completa en navegador NO realizada por restricciones de tiempo de esta sesión — **queda como verificación manual del PO antes o después del merge**.

## 9. PR, merge y verificación post-merge

- [x] 9.1 Abrir PR desde rama propia. — PR #465.
- [x] 9.2 Esperar gates y mergear si verdes. — Verdes; squash merge `043017a`. Deploy "Build and Deploy" exitoso (frontend + Deploy Supabase en verde).
- [x] 9.3 Verificación post-merge en prod (sólo SELECTs). — `MAX(version) = 20261014000001`; 2 triggers vivos en `public.branches` (`trg_guard_branch_decommission`, `trg_audit_branch_lifecycle`); 3 columnas de auditoría presentes (`created_by`, `deactivated_at`, `deactivated_by`).
- [x] 9.4 Re-medir los 4 conteos de daño histórico. — **0** sucursales inactivas con stock atrapado sobre 40 sucursales de prod; 13 activas con stock (operación normal). Sin reparación pendiente.
- [x] 9.5 Prueba de humo real en prod. — `UPDATE branches SET is_active=false` sobre Showroom (`2ec1120d-4c97-45cf-a43d-4aceb403d2dc`, 531 productos) dentro de un DO block seguro → el guard lanzó `P0428` y el UPDATE quedó bloqueado; Showroom sigue `is_active=true`. Verificado.
- [x] 9.6 Actualizar `CHANGES.md` y el puntero del `CLAUDE.md`.

## 10. Cierre

- [x] 10.1 Las 7 OQs resueltas por su recomendación (instrucción explícita del PO para este apply) — ver PR body / CHANGES.md.
- [x] 10.2 Registrar candidatos en `CHANGES.md` (OQ-5, OQ-6, OQ-7 ya resuelta acá, más el hallazgo del "mostrador"/POS sin wirear, más `BranchOut` que declaraba `user_id` inexistente — ya corregido en el apply, tasks 5.4).
- [x] 10.3 `mem_save` y `/opsx:archive`.
