## Why

Aliadata cerró un **acuerdo comercial** con Julián Dupás, Productor Asesor de Seguros: no es un beneficio suelto ni un favor a un cliente, es un partner del ecosistema. El módulo `/seguros` ya existe en producción, tiene entrada de sidebar, CRUD de admin y tracking de clicks — pero está **vacío** (0 filas en `community.seguros`, verificado en prod el 2026-09-01) y hoy le muestra a todo usuario el empty state "Próximamente seguros para emprendedores".

El problema no es que falte el módulo: es que **el modelo de datos actual no puede contar lo que el acuerdo realmente es**. `community.seguros` tiene 4 campos de texto plano (`title`, `description`, `coverage`, `price`) más un link saliente. El material del partner tiene estructura: 3 líneas de servicio, 4 pilares de asesoramiento desarrollados, 14 ciudades de alcance, matrícula de PAS, y contacto por teléfono y mail. Publicarlo en la ficha actual perdería más de la mitad del contenido y forzaría un badge `price` que un PAS no puede dar: cotiza caso por caso. Además, con **un solo partner** la grilla de 3 columnas de `/seguros` se ve rota (1 card y 2 huecos).

El PO firmó la **Opción B: perfil de asesor** (2026-09-01), sobre ficha simple y sobre destacado+grilla.

## What Changes

- **Nueva ruta `/seguros/[slug]`**: página de perfil del asesor con el material completo — identidad + matrícula, frase ancla, líneas de servicio, pilares, zonas de cobertura y vías de contacto. Con un partner es el destino principal; con 2+ es el detalle al que linkea la grilla.
- **`/seguros` (índice) se adapta al conteo**: con un único asesor visible, la página lleva al perfil sin simular un catálogo; con 2+, vuelve a ser grilla y cada card linkea a su perfil. La grilla legacy de ofertas se conserva.
- **`community.seguros` se extiende** con los campos que hoy no tiene: discriminador de tipo de entrada, `slug` para la URL del perfil, identidad y matrícula del asesor, contacto estructurado (teléfono / WhatsApp / mail), líneas de servicio y pilares como listas ordenadas, zonas de cobertura, foto opcional y flag de destacado. **Sin BREAKING**: todas las columnas nuevas son nullable o tienen default, y las 4 existentes quedan intactas.
- **Tracking por vía de contacto**: hoy `increment_seguros_clicks` cuenta un click de salida agregado. Se agrega el registro de **qué vía** eligió el usuario (WhatsApp / mail / teléfono / web) **sin romper** el contador actual, su RPC ni su test — el total sigue siendo el mismo número que hoy.
- **`/admin/seguros` edita todos los campos nuevos**: sin esto el contenido no lo puede cargar nadie y el change queda incompleto (regla de superficie frontend).
- **Identificación regulatoria y disclaimer**: el perfil publica la matrícula del PAS y una línea que aclara el rol de Aliadata en la relación.
- **Degradación limpia sin foto**: el perfil rinde con iniciales cuando no hay imagen; no se bloquea la publicación por un asset que no tenemos.

## Capabilities

### New Capabilities
- `insurance-advisor-profile`: el perfil público de un Productor Asesor de Seguros dentro del ecosistema — modelo de contenido estructurado sobre `community.seguros`, ruta de perfil por slug, comportamiento del índice según el conteo de asesores visibles, identificación regulatoria y disclaimer, tracking por vía de contacto, y edición completa desde el panel de admin.

### Modified Capabilities

Ninguna. `community-schema` describe el **movimiento** de las 16 tablas al schema `community` y la exigencia de que los objetos SQL del servidor califiquen el schema; agregarle columnas a `community.seguros` y crear una función nueva **no cambia ninguno de sus requirements** — sí los obedece (la migración y el RPC nuevo referencian `community.seguros` con schema calificado, y el RPC nuevo lleva su `REVOKE` explícito como exige el gate de ACLs). No existe hoy ninguna spec de seguros/insurance que quede desactualizada por este change (verificado: `grep` sobre `openspec/specs/` sólo devuelve la mención de `seguros` en la lista de tablas de `community-schema`).

## Impact

**Governance: MEDIO.** Es contenido público de un tercero con acuerdo comercial de por medio. No toca dinero, ni auth, ni datos sensibles, ni multi-tenancy: `community.seguros` es una tabla de catálogo global sin `account_id`, con lectura pública de filas visibles y escritura admin-only. Lo que sí tiene es **marca y responsabilidad**: publicamos la identidad profesional y la matrícula de una persona real bajo el nombre de Aliadata, y una leyenda regulatoria mal puesta es un problema del partner, no nuestro. De ahí que la identificación del PAS y el disclaimer queden como decisiones a firmar por el PO, no a improvisar por el agente. Implementación en pasos con checkpoints; sin sign-off previo requerido para escribir código.

**Base de datos** (Supabase, proyecto `gxdhpxvdjjkmxhdkkwyb`):
- 1 migración nueva. **Numeración: `20261017000001`** — verificado contra `origin/main` (última: `20261016000001_qa_integral_fixes.sql`) y contra prod (`MAX(version) = 20261016000001`). Ojo: el brief de esta tarea decía `20261014000001`; ese puntero estaba **desactualizado en dos migraciones**.
- `ALTER TABLE community.seguros ADD COLUMN IF NOT EXISTS ...` (idempotente, aditivo), 1 índice único parcial sobre `slug`, 1 CHECK sobre el discriminador de tipo.
- 1 función nueva para el tracking por vía de contacto, con `REVOKE ... FROM PUBLIC, anon` explícito y `GRANT` sólo a `authenticated`, siguiendo el patrón de `20260831000001` (el gate `supabase/tests/test_function_acl_gate.sql` corta el CI si falta).
- RLS: **sin cambios**. Las dos policies vivas (`Public items are viewable by everyone` FOR SELECT sobre `is_visible`, y `seguros_admin_all` FOR ALL) ya cubren exactamente lo que el perfil necesita.
- **Sin backfill**: la tabla está vacía. La carga del partner es un seed idempotente, no una reparación de datos.

**Frontend** (superficie obligatoria, declarada acá y con tasks propias):
| Ruta | Estado | Cómo se llega |
|---|---|---|
| `/seguros` | modificada | Sidebar → grupo **Ecosistema** → **Seguros** (ya existe, `app-sidebar.tsx:89`, sin gating de plan) |
| `/seguros/[slug]` | **nueva** | Desde `/seguros`; con un solo asesor, es el destino directo |
| `/admin/seguros` | modificada | Sidebar de admin → **Gestionar Seguros** (ya existe, `app-sidebar.tsx:273`) |

- `frontend/lib/services/insuranceService.ts` — **se extiende, no se duplica** (capa canónica; la regla de reutilización lo exige explícitamente).
- `frontend/app/(dashboard)/seguros/page.tsx`, `frontend/app/(dashboard)/admin/seguros/page.tsx` — se modifican.
- Componentes nuevos del perfil, en PascalCase, con tokens semánticos del design system. Verificación obligatoria en **desktop y mobile** y en **tema claro y oscuro**.

**Tests**:
- `frontend/__tests__/seguros-click-tracking.test.tsx` (7 casos) es la **red de seguridad**: debe seguir verde sin editarlo. Cubre el contrato "el tracking nunca rompe la UX" y el `href`/`target`/`rel` del link de contacto.
- Tests nuevos para el perfil, el ruteo por slug, el comportamiento del índice según conteo y el tracking por vía.

**Fuera de alcance**: la landing pública (el perfil vive dentro de la app autenticada), cualquier cobro o intermediación (Aliadata no interviene en la contratación), y la serie temporal de clicks por evento (el agregado por vía alcanza para la decisión de negocio de hoy).

**Datos que faltan para poder publicar** — detallados con recomendación en `design.md`: confirmación de la matrícula y de la leyenda regulatoria que corresponde, si el teléfono del partner recibe WhatsApp, el texto final del disclaimer de Aliadata, y la foto o logo (opcional: degrada a iniciales).
