# Tasks — community-bug-fixes

> Change `C-09`. Governance: MEDIO. Sin dependencias — puede implementarse en cualquier orden relativo a C-01.
> Archivos clave: `app/(dashboard)/comunidad/page.tsx`, `contexts/data-context.tsx`, nueva migration SQL, `knowledge-base/10_preguntas_abiertas.md`.

---

## Bloque 1 — RLS: cerrar gap de seguridad en DB

### Tarea 1.1 — Crear migration RLS para `posts` INSERT con verificación de plan

**Archivo:** `supabase/migrations/YYYYMMDD000001_community_rls_plan_check.sql` (usar timestamp actual)

**Qué hacer:**
1. Eliminar la policy de INSERT en `posts` si existe sin chequeo de plan.
2. Crear policy `"Pro users can insert posts"` con `WITH CHECK` que verifica `plan = 'pro'` en `profiles`.
3. Verificar también la policy de INSERT en `replies` y crearla con el mismo guard.
4. Verificar que las policies de SELECT, DELETE permanezcan inalteradas.

**SQL esperado:**
```sql
-- Posts INSERT: solo plan pro
DROP POLICY IF EXISTS "Pro users can insert posts" ON public.posts;
CREATE POLICY "Pro users can insert posts"
ON public.posts FOR INSERT
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = (SELECT auth.uid())
      AND plan = 'pro'
  )
);

-- Replies INSERT: solo plan pro
DROP POLICY IF EXISTS "Pro users can insert replies" ON public.replies;
CREATE POLICY "Pro users can insert replies"
ON public.replies FOR INSERT
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = (SELECT auth.uid())
      AND plan = 'pro'
  )
);
```

**Acceptance criteria:**
- [x] La migration corre sin errores en Supabase.
- [x] Un usuario con `plan = 'free'` recibe error `42501` al intentar INSERT en `posts` o `replies`.
- [x] Un usuario con `plan = 'pro'` puede insertar normalmente.

---

## Bloque 2 — `data-context.tsx`: eliminar optimistic update de `replies_count`

### Tarea 2.1 — Quitar el `setPosts` que incrementa manualmente `replies_count` en `addReply`

**Archivo:** `contexts/data-context.tsx`

**Localizar:** función `addReply` (línea ~711). Al final de la función, hay:
```tsx
// Update replies_count in posts state without re-fetching all 8 tables
setPosts(prev => prev.map(p =>
  p.id === postId ? { ...p, replies: p.replies + 1 } : p,
))
```

**Qué hacer:** eliminar ese bloque `setPosts`. El trigger de DB (`on_post_reply_change`) ya incrementa `posts.replies_count`, y el realtime subscription `rt-posts` dispara `refreshPosts()` que lee el valor correcto. El optimistic manual produce un doble-increment.

**Mantener inalterado:**
- `toast.success("Respuesta enviada")` en `handleSubmitReply` (en la page, no en el context).
- El `setReplyContent("")` en `handleSubmitReply`.
- El insert en `replies` y su error handling.

**Acceptance criteria:**
- [x] Al responder un post, el contador de respuestas en la tarjeta se incrementa exactamente en 1 (no 2).
- [x] No hay `setPosts` con `replies_count` manual en `addReply`.

---

## Bloque 3 — `comunidad/page.tsx`: bugs de UI

### Tarea 3.1 — Convertir `handleSubmit` a async con error handling completo

**Archivo:** `app/(dashboard)/comunidad/page.tsx`

**Estado actual:**
```tsx
function handleSubmit(e: React.FormEvent) {
  e.preventDefault()
  if (!title || !content) {
    toast.error("Completá todos los campos")
    return
  }
  addPost({ userId: user?.id || "", author: user?.name || "Anónimo", title, content, category, date: ..., replies: 0, likes: 0 })
  toast.success("Post publicado")
  setOpen(false)
  setTitle("")
  setContent("")
}
```

**Qué hacer:**
1. Agregar `const [submitting, setSubmitting] = useState(false)` al estado del componente.
2. Convertir `handleSubmit` a `async function`.
3. Agregar `try/catch` con `setSubmitting(true/false)`.
4. Mover `toast.success`, `setOpen(false)`, reset de campos al bloque `try` tras el `await`.
5. En el `catch`, mostrar `toast.error`.
6. Deshabilitar el botón de submit mientras `submitting === true` y mostrar texto "Publicando...".

**Resultado esperado:**
```tsx
const [submitting, setSubmitting] = useState(false)

async function handleSubmit(e: React.FormEvent) {
  e.preventDefault()
  if (!title || !content) {
    toast.error("Completá todos los campos")
    return
  }
  setSubmitting(true)
  try {
    await addPost({ userId: user?.id || "", author: user?.name || "Anónimo", title, content, category, date: new Date().toISOString().split("T")[0], replies: 0, likes: 0 })
    toast.success("Post publicado")
    setOpen(false)
    setTitle("")
    setContent("")
  } catch (err: any) {
    toast.error(err.message || "Error al publicar el post")
  } finally {
    setSubmitting(false)
  }
}
```

**Button de submit actualizado:**
```tsx
<Button type="submit" className="w-full" disabled={submitting}>
  {submitting ? "Publicando..." : "Publicar"}
</Button>
```

**Acceptance criteria:**
- [x] Si la RLS rechaza el insert (usuario free), el toast muestra el error correctamente.
- [x] El modal NO se cierra si `addPost` lanza.
- [x] El botón de submit está deshabilitado mientras `submitting === true`.

---

### Tarea 3.2 — Corregir stale replies: siempre recargar al expandir

**Archivo:** `app/(dashboard)/comunidad/page.tsx`

**Localizar:** función `handleExpandReplies`.

**Estado actual:**
```tsx
if (!replies[postId]) {
  setLoadingReplies(prev => ({ ...prev, [postId]: true }))
  try {
    const data = await getReplies(postId)
    setReplies(prev => ({ ...prev, [postId]: data }))
  } catch (err) {
    toast.error("Error al cargar respuestas")
  } finally {
    setLoadingReplies(prev => ({ ...prev, [postId]: false }))
  }
}
```

**Qué hacer:** eliminar la condición `if (!replies[postId])`. Cargar siempre al abrir.

**Resultado esperado:**
```tsx
async function handleExpandReplies(postId: string) {
  if (expandedPost === postId) {
    setExpandedPost(null)
    return
  }
  setExpandedPost(postId)
  setLoadingReplies(prev => ({ ...prev, [postId]: true }))
  try {
    const data = await getReplies(postId)
    setReplies(prev => ({ ...prev, [postId]: data }))
  } catch (err) {
    toast.error("Error al cargar respuestas")
  } finally {
    setLoadingReplies(prev => ({ ...prev, [postId]: false }))
  }
}
```

**Acceptance criteria:**
- [x] Al cerrar y reabrir la sección de replies de un post, la lista se recarga desde DB.
- [x] No se muestra la lista vieja mientras carga (se muestra el spinner).

---

### Tarea 3.3 — Agregar guard de plan `isPro` al área de reply

**Archivo:** `app/(dashboard)/comunidad/page.tsx`

**Localizar:** el bloque de reply dentro de `{expandedPost === post.id && (...)}` — específicamente la sección del form de respuesta (Textarea + Button "Enviar").

**Qué hacer:** wrappear el form de reply con `{isPro ? (...form...) : (...CTA...)}`.

**Resultado esperado:**
```tsx
{isPro ? (
  <div className="flex gap-2 items-end">
    <Textarea
      placeholder="Escribir una respuesta..."
      value={replyContent}
      onChange={(e) => setReplyContent(e.target.value)}
      className="min-h-[60px] text-xs bg-background"
    />
    <Button
      size="sm"
      className="h-8 px-3"
      disabled={!replyContent.trim()}
      onClick={() => handleSubmitReply(post.id)}
    >
      Enviar
    </Button>
  </div>
) : (
  <div className="flex items-center gap-2 text-xs text-muted-foreground bg-muted/30 rounded-md px-3 py-2">
    <Crown className="h-3 w-3 text-yellow-500 shrink-0" />
    <span>Actualizá a Pro para responder.</span>
    <Button variant="link" size="sm" className="h-auto p-0 text-xs text-primary" asChild>
      <Link href="/planes">Ver planes</Link>
    </Button>
  </div>
)}
```

**Añadir import:** `import Link from "next/link"` (si no está).

**Acceptance criteria:**
- [x] Usuario `free`: ve el CTA de upgrade en lugar del form de reply.
- [x] Usuario `pro`: ve el Textarea y puede enviar.

---

### Tarea 3.4 — Reemplazar Tooltip del botón "Nuevo post" por banner inline accesible en mobile

**Archivo:** `app/(dashboard)/comunidad/page.tsx`

**Localizar:** el bloque del header con el botón "Nuevo post" para `!isPro`:
```tsx
<TooltipProvider>
  <Tooltip>
    <TooltipTrigger asChild>
      <Button size="sm" disabled className="opacity-60">
        <Crown className="h-4 w-4 mr-1 text-yellow-500" />
        Nuevo post
      </Button>
    </TooltipTrigger>
    <TooltipContent className="bg-popover border-border">
      <p className="text-xs">Solo disponible en plan Pro</p>
    </TooltipContent>
  </Tooltip>
</TooltipProvider>
```

**Qué hacer:** reemplazar por un banner inline visible en todas las pantallas.

**Resultado esperado:**
```tsx
<div className="flex items-center gap-2 text-xs text-muted-foreground bg-muted/40 border border-border rounded-md px-3 py-1.5">
  <Crown className="h-3.5 w-3.5 text-yellow-500 shrink-0" />
  <span className="hidden sm:inline">Solo plan Pro puede publicar.</span>
  <Button variant="link" size="sm" className="h-auto p-0 text-xs text-primary" asChild>
    <Link href="/planes">Actualizar</Link>
  </Button>
</div>
```

**Acceptance criteria:**
- [x] En mobile (touch), el usuario free ve claramente la restricción y el link de upgrade.
- [x] No hay imports de `Tooltip`, `TooltipContent`, `TooltipProvider`, `TooltipTrigger` si ya no se usan en otro lugar de la página.
- [x] En desktop, el banner también es visible.

---

## Bloque 4 — Documentación: resolver PA-03

### Tarea 4.1 — Documentar PA-03 en knowledge-base

**Archivo:** `knowledge-base/10_preguntas_abiertas.md`

**Localizar:** sección `### PA-03 — Rol de comunidad: ¿qué features son exactamente "solo lectura" para free?`

**Qué hacer:** marcar como resuelta y documentar la respuesta definitiva.

**Resultado esperado:**
```markdown
### ~~PA-03 — Rol de comunidad: ¿qué features son exactamente "solo lectura" para free?~~ ✅ RESUELTA (C-09)
**Resuelto**: 2026-06-04 — community-bug-fixes.  
**Respuesta canónica:**
- Usuarios `free`: pueden **leer** todos los posts y replies (SELECT sin restricción de plan — RN-60).
- Usuarios `free`: **no pueden crear posts ni responder** — bloqueado tanto en UI (guard `isPro`) como en DB (RLS WITH CHECK verifica `plan = 'pro'`).
- Usuarios `free`: **pueden dar like** a posts (la acción de like no tiene restricción de plan — es engagement, no contenido).
- **CTA visible**: al intentar postear o responder, los usuarios free ven un banner inline con link a `/planes` (no un tooltip que requiere hover).
- Cursos básicos: se definen por `courses.is_pro = false` — sin criterio adicional (RN-70).
```

**Acceptance criteria:**
- [x] PA-03 queda marcada como RESUELTA con fecha y change.
- [x] Las 3 sub-preguntas de PA-03 están respondidas.

---

## Orden de implementación recomendado

1. **Tarea 1.1** — Migration RLS (base de seguridad; el resto depende de que la DB esté correcta).
2. **Tarea 2.1** — Eliminar optimistic update (una línea, bajo riesgo).
3. **Tarea 3.1** → **3.2** → **3.3** → **3.4** — fixes de UI en orden de impacto.
4. **Tarea 4.1** — Documentación (puede hacerse en cualquier momento).

---

## Tests E2E a validar manualmente tras implementar

- [ ] Usuario `pro`: crea post → aparece en la lista → puede responder → contador de replies sube en 1 (no 2).
- [ ] Usuario `free`: ve posts y replies → botón "Nuevo post" muestra banner de upgrade → al expandir un post ve el CTA de reply en lugar del form.
- [ ] Usuario `free` vía curl/Supabase client: INSERT directo en `posts` o `replies` → error 403 (RLS policy).
- [ ] Usuario `pro`: borra su propio post → desaparece. Intenta borrar post ajeno → falla.
- [ ] Expandir y cerrar replies de un post → al reabrir, la lista está fresca (no stale).
