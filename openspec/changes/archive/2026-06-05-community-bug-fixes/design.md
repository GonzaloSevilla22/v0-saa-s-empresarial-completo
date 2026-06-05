# Design — community-bug-fixes

## Context

- **Stack:** Next.js 16 (App Router) + React 19 + TypeScript + Supabase (Postgres + RLS + Realtime) + Tailwind + shadcn/ui.
- **Archivos afectados principales:**
  - `app/(dashboard)/comunidad/page.tsx` — único componente de la página de comunidad (Client Component).
  - `contexts/data-context.tsx` — funciones `addPost`, `addReply`, `getReplies`, `toggleLike`, `refreshPosts`.
  - `supabase/migrations/20260309000007_refine_community_rls.sql` — última migration de RLS de comunidad (base a extender).
- **Estado actual de RLS (según migrations):**
  - `posts` INSERT: solo `auth.uid() = user_id` — **no verifica plan**. Gating real solo en la UI.
  - `posts` DELETE: `auth.uid() = user_id` — correcto (autor puede borrar).
  - `replies` INSERT: no existe una política de INSERT en las migrations auditadas — acceso implicitamente denegado por RLS habilitado, pero no hay evidencia de una policy pro-only.
  - `post_likes` INSERT: `auth.uid() = user_id` — correcto, likes no tienen restricción de plan (RN-60 solo menciona posts y replies).
- **Governance:** MEDIO. Se pueden implementar con checkpoints por sección. No requiere aprobación previa.

## Goals / Non-Goals

**Goals**
- Cerrar el gap de seguridad: plan-gating en RLS (no solo en UI) para INSERT en `posts` y `replies`.
- Corregir el bug de `handleSubmit` no-async que silencia errores de DB.
- Corregir stale replies al re-expandir un post.
- Eliminar el double-count de `replies_count`.
- Hacer el CTA de upgrade accesible en dispositivos touch (mobile).
- Documentar PA-03.

**Non-Goals**
- Implementar el sistema de 4 planes (eso es C-01/C-02). Los guards siguen usando `plan = 'pro'` del schema actual.
- Añadir moderación de contenido avanzada (solo borrado propio/admin — RN-61).
- Paginación de posts o replies (no está en scope del MVP).
- Notificaciones cuando alguien responde un post.

## Key Decisions

### D1 — RLS de plan en `posts` y `replies` via subquery a `profiles`

**Decisión:** usar `WITH CHECK (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND plan = 'pro'))` en las políticas INSERT de `posts` y `replies`.

**Por qué:** RN-60 define el gating de comunidad a nivel de negocio. Tener la restricción solo en UI es insuficiente: cualquier cliente (curl, Supabase client directo) puede bypassarla. La subquery a `profiles` es el patrón estándar del proyecto para verificar plan/role (ver otras migrations que usan `EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')`).

**Trade-off:** la subquery se ejecuta en cada INSERT. Con el volumen esperado (comunidad de microemprendedores de Mendoza) esto es insignificante. No se necesita `(select auth.uid())` wrapping aquí porque la subquery ya lo hace internamente.

**Pattern (best practice Supabase):**
```sql
CREATE POLICY "Pro users can insert posts"
ON public.posts FOR INSERT
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = (SELECT auth.uid())
      AND plan = 'pro'
  )
);
```

### D2 — `handleSubmit` como `async function` con error boundary completo

**Decisión:** convertir `handleSubmit` de sync a async, awaitar `addPost`, y mover el cierre del modal al bloque de éxito.

**Antes (buggy):**
```tsx
function handleSubmit(e: React.FormEvent) {
  e.preventDefault()
  // ...validations...
  addPost({ ... })           // fire-and-forget — errores silenciados
  toast.success("Post publicado")  // siempre se muestra
  setOpen(false)
}
```

**Después (correcto):**
```tsx
async function handleSubmit(e: React.FormEvent) {
  e.preventDefault()
  // ...validations...
  try {
    await addPost({ ... })
    toast.success("Post publicado")
    setOpen(false)
    setTitle("")
    setContent("")
  } catch (err: any) {
    toast.error(err.message || "Error al publicar el post")
  }
}
```

**Implicación:** el Button de submit necesita un estado `loading` para evitar doble submit.

### D3 — Siempre recargar replies al expandir (invalidar caché local)

**Decisión:** en `handleExpandReplies`, llamar siempre a `getReplies(postId)` al abrir, sin condición `!replies[postId]`.

**Antes (stale):**
```tsx
if (!replies[postId]) {   // stale si alguien respondió mientras estaba cerrado
  const data = await getReplies(postId)
  setReplies(prev => ({ ...prev, [postId]: data }))
}
```

**Después:**
```tsx
// Siempre recargar al abrir (cheap fetch, evita stale)
const data = await getReplies(postId)
setReplies(prev => ({ ...prev, [postId]: data }))
```

**Trade-off:** un fetch extra por apertura de sección. Aceptable dado el volumen de replies esperado. Alternativa desestimada: subscription realtime a `replies` (añade complejidad de canal y el volumen no lo justifica aún).

### D4 — Eliminar optimistic update de `replies_count` en `addReply`

**Decisión:** quitar el `setPosts(prev => prev.map(...))` que incrementa manualmente `replies_count` en `addReply`.

**Por qué:** el trigger `on_post_reply_change` (migration `20260309000006`) ya incrementa `posts.replies_count` en DB. El realtime subscription `rt-posts` (en `DataProvider`) dispara `refreshPosts()` que lee el valor correcto. El optimistic update manual produce un doble-increment cuando el realtime llega y el refresh sobreescribe con el valor ya-incrementado, pero si el componente ya renderizó el +1 local y luego llega el +1 del DB, el resultado muestra +2.

**Qué se mantiene:** el `toast.success("Respuesta enviada")` y el `setReplyContent("")`. Solo se quita la línea de `setPosts`.

**Alternativa desestimada:** mantener optimistic y cancelar el refresh. Esto rompería la consistencia con otros clientes conectados (si dos usuarios responden simultáneamente, cada uno vería solo su propio reply en el contador).

### D5 — CTA de upgrade para usuarios free: Banner inline reemplaza Tooltip

**Decisión:** para el botón "Nuevo post" y para el área de reply, reemplazar el `TooltipProvider/Tooltip` (solo hover) por un `Alert` de shadcn/ui visible de forma permanente + un botón de upgrade.

**Por qué:** `Tooltip` de Radix UI requiere hover, que no existe en touch. En mobile, el botón deshabilitado con tooltip es literalmente invisible para el usuario en cuanto a explicación.

**Diseño propuesto para el header:**
```tsx
{!isPro && (
  <div className="flex items-center gap-2 text-xs text-muted-foreground bg-muted/40 border border-border rounded-md px-3 py-2">
    <Crown className="h-3.5 w-3.5 text-yellow-500 shrink-0" />
    <span>Solo plan Pro puede publicar.</span>
    <Button variant="link" size="sm" className="h-auto p-0 text-xs text-primary" asChild>
      <Link href="/planes">Actualizar</Link>
    </Button>
  </div>
)}
```

**Diseño propuesto para el área de reply (en lugar del form):**
```tsx
{!isPro && (
  <div className="flex items-center gap-2 text-xs text-muted-foreground bg-muted/30 rounded-md px-3 py-2">
    <Crown className="h-3 w-3 text-yellow-500" />
    <span>Actualizá a Pro para responder.</span>
    <Button variant="link" size="sm" className="h-auto p-0 text-xs text-primary" asChild>
      <Link href="/planes">Ver planes</Link>
    </Button>
  </div>
)}
```

**Nota:** el enlace `/planes` corresponde a la página de upgrade que se implementará en C-10. Por ahora puede apuntar a `/planes` aunque la página no exista — mejor que un enlace vacío.

### D6 — Guard de reply en UI: no solo el Textarea, también el form

**Decisión:** wrappear todo el bloque de reply (Textarea + Button de enviar) con `{isPro ? (...form...) : (...CTA...)}`, no solo deshabilitar el Textarea.

**Por qué:** deshabilitar el Textarea sin ocultar el botón es confuso. El guard completo de sección evita ambigüedad.

## Estándares aplicados (skill-registry)

- **vercel-react-best-practices:** nunca definir componentes dentro de otros componentes — los CTAs son JSX inline, no sub-componentes.
- **nextjs-app-router-patterns:** la página de comunidad es ya un Client Component (`"use client"`); no se cambia la estrategia de rendering.
- **supabase best practices:** `TO authenticated` + ownership `USING` predicate juntos. Las nuevas policies usan `WITH CHECK` (INSERT) con subquery de plan.
- **Migrations idempotentes:** usar `DROP POLICY IF EXISTS` antes de `CREATE POLICY`.

## Risks / Trade-offs

- **R1 — `plan = 'pro'` hardcodeado en RLS.** En C-01 el campo pasará a llamarse `billing_plan` con 4 valores. La migration de RLS de C-01 deberá actualizar estas policies. Documentado en el campo `## Open Questions`.
- **R2 — Siempre-fetch de replies.** Si hay muchos replies, el fetch puede ser lento. Aceptable para MVP; paginación es Non-Goal.
- **R3 — `/planes` no existe todavía.** El CTA linkea a una ruta futura (C-10). En producción se verá un 404 hasta que C-10 se implemente. Alternativa: linkear a `/perfil` o a un modal de contacto — se decide en apply si se quiere cambiar.

## Open Questions

- Una vez aplicado C-01 (`billing-schema-migration`), las políticas RLS de `posts` y `replies` deben actualizarse para chequear `billing_plan IN ('inicial', 'avanzado', 'pro')` en lugar de `plan = 'pro'`. Crear una nueva migration en ese momento.
- ¿El CTA de upgrade debe linkar a `/planes` (C-10, futuro) o a `/perfil` (existente)? Se sugiere `/planes` para consistencia con el diseño final.
