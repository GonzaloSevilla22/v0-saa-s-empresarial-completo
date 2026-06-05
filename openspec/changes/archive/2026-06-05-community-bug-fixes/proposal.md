# Proposal — community-bug-fixes

> Change `C-09` del roadmap (`CHANGES.md`). Fase 1 — independiente (bug fix paralelo).
> Governance: **MEDIO** (módulo de foro comunitario — lógica de negocio, sin impacto en billing ni auth).
> Dependencias: **ninguna**. Puede correr en paralelo con C-01.

## Why

El módulo de comunidad (`/comunidad`) fue marcado como "⚠️ Funcional con bugs conocidos" en el estado del MVP (`06_funcionalidades.md`). La auditoría del código (`app/(dashboard)/comunidad/page.tsx` + `contexts/data-context.tsx`) revela seis categorías de bugs concretos:

1. **Plan-gating inconsistente en replies:** `isPro` bloquea crear posts pero no bloquea crear replies. Cualquier usuario `free` puede llamar `addReply` directamente (el botón de respuesta no tiene guard).
2. **`addPost` no es async en el handler del form:** `handleSubmit` llama `addPost(...)` sin `await`, por lo que errores de DB (RLS, permisos) son silenciados y el modal se cierra aunque el POST haya fallado.
3. **RLS de `replies` no verifica plan:** la política de INSERT en `replies` solo comprueba `auth.uid() = user_id`; no valida que el usuario tenga `plan = 'pro'`. Un usuario free puede bypassar la UI y escribir directo a la tabla.
4. **Estado stale de replies al expandir un post por segunda vez:** `handleExpandReplies` solo carga replies si `!replies[postId]`; si alguien responde mientras la vista está cerrada, al reabrir se muestra la lista vieja sin el nuevo reply.
5. **`replies_count` en la tarjeta de post no se actualiza cuando el realtime subscription dispara:** el realtime subscription de `posts` llama `refreshPosts()`, lo que recarga desde DB correctamente, pero el contador local en `addReply` también hace `setPosts(prev => ...)` en un optimistic update — si la UI ya leyó el post del realtime antes del `setPosts`, el contador se duplica.
6. **CTA de upgrade para usuarios free es un `Tooltip` invisible en mobile:** `TooltipProvider` con `Tooltip` no funciona en touch screens (los tooltips solo se activan con hover). Un usuario mobile en plan free no puede descubrir por qué el botón está deshabilitado.

Resolver estos bugs es urgente porque la comunidad es un vector de retención clave del producto (KPI: "interacciones comunitarias") y bugs visibles erosionan la confianza en el MVP.

## What Changes

**Lógica de plan-gating (frontend + RLS):**
- Agregar guard de plan `isPro` al textarea de reply (mostrar CTA en lugar de form para usuarios free).
- Agregar política RLS `INSERT` en `replies` que valide `plan = 'pro'` en `profiles` (igual que posts).
- Agregar política RLS `INSERT` en `posts` que valide `plan = 'pro'` (verificar que está implementada; si solo existe en el código, añadirla a nivel DB).

**Bug `handleSubmit` no async:**
- Convertir `handleSubmit` a `async function`, agregar `await addPost(...)`, mover el `toast.success` y el cierre del modal al bloque de éxito, y agregar catch para mostrar error al usuario.

**Estado stale de replies:**
- Cambiar `handleExpandReplies` para que recargue siempre (no solo cuando `!replies[postId]`), o bien añadir una key de versión que se invalide cuando el realtime dispare en `posts`.

**Double-count de `replies_count`:**
- Eliminar el optimistic update manual de `replies_count` en `addReply` (el trigger de DB ya lo incrementa, y `refreshPosts()` cargará el valor correcto vía realtime). El optimistic update era necesario solo porque antes no había realtime para `replies`; ahora que hay subscription en `posts`, el contador se auto-actualiza.

**CTA mobile:**
- Reemplazar el `Tooltip` por un componente visible: usar un `Sheet` o un banner inline que explique la restricción y ofrezca un CTA de upgrade, activable tanto en hover como en tap.

**PA-03 (documentación):**
- Documentar la respuesta definitiva a PA-03 en `knowledge-base/10_preguntas_abiertas.md`: usuarios free pueden leer posts y replies pero no crear ni responder; CTA de upgrade visible.

## Impact

- **Affected code:**
  - `app/(dashboard)/comunidad/page.tsx` — fixes de UI: guard de reply, handleSubmit async, CTA mobile, fix double-count.
  - `contexts/data-context.tsx` — eliminar optimistic update de `replies_count` en `addReply`.
  - `supabase/migrations/` — nueva migración con política RLS para `replies` INSERT + verificación de la policy de `posts`.
  - `knowledge-base/10_preguntas_abiertas.md` — resolver PA-03.
- **No rompe:** ningún cambio destructivo. Las RLS policies son `DROP IF EXISTS` + `CREATE POLICY` idempotentes. El comportamiento para usuarios `pro` es idéntico.
- **Riesgo:** bajo. El único cambio de DB es una política RLS adicional, no un schema change.
