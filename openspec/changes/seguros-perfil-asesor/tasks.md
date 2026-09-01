> **Modo TDD estricto activo.** Todo grupo que escriba código de aplicación sigue el ciclo RED → GREEN → TRIANGULATE → REFACTOR, con la red de seguridad medida ANTES de tocar archivos existentes. Las tasks marcadas `[checkpoint]` requieren detenerse y verificar contra el estado vivo antes de continuar.
>
> **Governance MEDIO** — implementar en pasos, con las decisiones no obvias visibles para el PO. No requiere sign-off previo para escribir código; sí lo requiere **publicar** (grupo 10).

## 1. Preparación y red de seguridad

- [x] 1.1 Crear rama nueva desde `main` actualizado (`git fetch origin && git checkout -b opsx/seguros-perfil-asesor-apply origin/main`). Nunca commitear a `main`: todo va por PR, incluidos los fixes triviales de seguimiento.
- [x] 1.2 **[safety net]** Correr `pnpm vitest run __tests__/seguros-click-tracking.test.tsx` y registrar el baseline exacto (se esperan 7 casos en verde). Si alguno falla ANTES de tocar nada, detenerse y reportarlo como fallo pre-existente — no arreglarlo dentro de este change. **Baseline: 7/7 verdes.**
- [x] 1.3 **[safety net]** Correr la suite completa del frontend y registrar el conteo baseline (`N passed / M failed`), para poder distinguir después una regresión propia de un fallo ajeno pre-existente. **Baseline: 210 archivos / 1655 tests, 0 fallos.**
- [x] 1.4 **[checkpoint]** Re-verificar contra prod, en el momento del apply, que `community.seguros` sigue con 0 filas y que `MAX(version)` de migraciones sigue siendo `20261016000001`. Si cambió cualquiera de los dos, recalcular el número de migración correlativo antes de escribir SQL. (El puntero del brief original ya estaba desactualizado en dos migraciones una vez.) **Confirmado: 0 filas, MAX(version)=20261016000001 tanto en origin/main como en prod → `20261017000001` es correcta.**
- [x] 1.5 Releer `docs/Julian_Dupas_PAS_v5_260814_174911.pdf` y fijar el contenido exacto a sembrar: 3 líneas de servicio con su bajada, frase ancla, párrafo de apertura, 4 pilares, 14 ciudades, teléfono, mail, web y matrícula. No parafrasear el material del partner: se transcribe. **Contenido íntegro extraído (ver `julian_pas.txt`, 3.137 caracteres); usado textual en el seed (task 8).**

## 2. Migración: modelo de datos

- [x] 2.1 Crear `supabase/migrations/20261017000001_seguros_perfil_asesor.sql` (número confirmado en 1.4), con cabecera que explique el porqué del change, como es costumbre en las migraciones de este repo.
- [x] 2.2 Agregar las columnas nuevas con `ADD COLUMN IF NOT EXISTS`, todas nullable o con default, sin tocar las 4 columnas existentes: `entry_type`, `slug`, `advisor_name`, `advisor_role`, `license_number`, `license_authority`, `headline`, `bio`, `photo_url`, `contact_phone`, `contact_whatsapp`, `contact_email`, `service_lines`, `pillars`, `coverage_areas`, `disclaimer`, `contact_clicks`, `is_featured`, `sort_order`.
- [x] 2.3 Agregar el CHECK del conjunto cerrado de `entry_type` (`'offer'`, `'advisor'`) con default `'offer'`, de forma guardada para poder reaplicar la migración.
- [x] 2.4 Agregar el CHECK condicional `entry_type <> 'advisor' OR slug IS NOT NULL` (invariante de datos, no de formulario).
- [x] 2.5 Agregar los CHECK de `jsonb_typeof(...) = 'array'` sobre `service_lines` y `pillars`. Dejar comentado en el SQL por qué no se valida la forma de cada elemento en la DB (un CHECK no admite subconsulta) y dónde sí se valida (Zod, task 3.3).
- [x] 2.6 Crear el índice único parcial sobre `slug` (`WHERE slug IS NOT NULL`).
- [x] 2.7 **[checkpoint]** Verificar que la migración es idempotente aplicándola dos veces seguidas contra una base local, y que no altera ninguna policy ni el trigger `update_seguros_updated_at`. **Hallazgo real (no cosmético): `ON CONFLICT (slug) DO UPDATE` fallaba con `42P10` (no unique/exclusion constraint matching) porque el índice único es PARCIAL (`WHERE slug IS NOT NULL`) — Postgres exige que el `ON CONFLICT` repita el mismo predicado para poder inferir el arbiter. Corregido a `ON CONFLICT (slug) WHERE slug IS NOT NULL DO UPDATE`. Verificado con `npx supabase migration up --local` + reaplicación directa por `psql`: 1 fila, sin duplicar; los 4 CHECK vivos; `anon`=false/`authenticated`=true en la función nueva; trigger `update_seguros_updated_at` y las 2 policies (`Public items are viewable by everyone`, `seguros_admin_all`) intactos.

## 3. Capa canónica: tipos y servicio

- [x] 3.1 **RED** — Escribir tests de la extensión de `insuranceService` en un archivo nuevo (`frontend/__tests__/seguros-advisor-profile.test.tsx`), sin tocar el de click-tracking: obtener un asesor por slug, listar asesores visibles, distinguir `offer` de `advisor`. Los tests referencian funciones que todavía no existen. **12/12 rojos confirmados antes de implementar** (imports inexistentes: `getAdvisorBySlug`, `isAdvisorEntry`, `serviceLinesSchema`, `pillarsSchema`).
- [x] 3.2 **GREEN** — Extender `frontend/lib/services/insuranceService.ts` con lo mínimo para pasar. **Extender, nunca duplicar**: no crear un servicio ni un cliente Supabase paralelo (regla de reutilización antes que repetición). `getAdvisorBySlug` usa `.maybeSingle()` (no `.single()`): "no encontrado" es resultado válido, no excepción; se apoya en RLS (no filtra `is_visible` explícito) para que oculto y no-existe converjan al mismo resultado.
- [x] 3.3 **GREEN** — Definir los tipos del perfil en la capa canónica (interfaz de la entrada extendida, `ServiceLine`, `Pillar`, vía de contacto como unión cerrada de strings) y el esquema Zod que valida la forma de las listas jsonb en el borde. **Prohibido `any`**, incluido el `any` que ya existe alrededor si se toca esa línea. `EntryType`, `ContactChannel`, `CONTACT_CHANNELS`, `serviceLineSchema`/`serviceLinesSchema`, `pillarSchema`/`pillarsSchema` agregados junto a `Insurance` en `insuranceService.ts` (mismo archivo que ya alojaba `Insurance`, no `lib/types.ts` — sigue el patrón de otros servicios del repo con interfaz propia).
- [x] 3.4 **TRIANGULATE** — Sumar casos con entradas de ambos tipos mezcladas, listas vacías, campos de contacto ausentes y un slug inexistente. Verificar que las consultas usan `.schema("community")` (el gate `check_frontend_table_refs.py` lo exige). **13/13 verdes**: found/not-found/error de `getAdvisorBySlug`, advisor/offer/`entry_type` ausente de `isAdvisorEntry` (ausente ⇒ `offer`, backward-compat con los mocks de la red de seguridad), Zod válido/vacío/elemento incompleto/tipo incorrecto ×2 (service_lines y pillars), vías de contacto opcionales ausentes.
- [x] 3.5 **REFACTOR** — Limpiar duplicación entre las consultas nuevas y las existentes del servicio; tests verdes después de cada paso. Sin duplicación nueva: `getAdvisorBySlug` reutiliza el mismo patrón `.schema("community").from("seguros")` que el resto del servicio. 13/13 (advisor-profile) + 7/7 (click-tracking, red de seguridad) verdes tras el refactor.

## 4. Tracking por vía de contacto

- [ ] 4.1 Escribir en la migración la función `public.increment_seguros_contact_click(row_id uuid, channel text)`: `SECURITY DEFINER`, `SET search_path = ''`, referencia calificada `community.seguros`, un único UPDATE atómico que incrementa `clicks_count` y la clave de la vía dentro de `contact_clicks`, con el conjunto de vías validado dentro de la función.
- [ ] 4.2 Agregar `REVOKE EXECUTE ON FUNCTION ... FROM PUBLIC, anon;` y `GRANT EXECUTE ... TO authenticated;` inmediatamente después del `CREATE`. Revocar sólo de `PUBLIC` no alcanza: un `CREATE` fresco le regala `EXECUTE` a `anon` por privilegios por defecto, y el gate de ACLs corta el CI.
- [ ] 4.3 **RED** — Tests del método nuevo del servicio: llama al RPC con `row_id` y `channel` correctos, y ante error **loguea sin re-lanzar** (mismo contrato fire-and-forget que el contador existente).
- [ ] 4.4 **GREEN** — Implementar el método en `insuranceService.ts`, junto al `incrementClicks` existente y sin modificarlo.
- [ ] 4.5 **TRIANGULATE** — Casos con vía desconocida, con error de red (rechazo de la promesa) y con error del RPC; verificar que en ningún caso se cae en una escritura directa a la tabla.
- [ ] 4.6 **[safety net]** Re-correr `seguros-click-tracking.test.tsx` **sin editarlo**: los 7 casos deben seguir verdes. Si alguno se pone rojo, el contrato legacy se rompió — revertir y rediseñar, no ajustar el test.
- [ ] 4.7 Verificar en base local que `has_function_privilege` da falso para `anon` y verdadero para `authenticated` sobre la función nueva.

## 5. Ruta de perfil `/seguros/[slug]`

- [ ] 5.1 **RED** — Tests del perfil: renderiza identidad, rol y matrícula; lista servicios y pilares en orden; muestra zonas; ofrece sólo las vías de contacto cargadas.
- [ ] 5.2 **GREEN** — Crear `frontend/app/(dashboard)/seguros/[slug]/page.tsx` y los componentes del perfil en PascalCase, con tokens semánticos del design system (nada de colores cableados).
- [ ] 5.3 **GREEN** — Componente de avatar con degradación a iniciales derivadas del nombre, ocupando las mismas dimensiones que la foto (sin salto de layout).
- [ ] 5.4 **GREEN** — Bloque de contacto: WhatsApp a `https://wa.me/<E.164 sin +>` y web en pestaña nueva con `rel="noopener noreferrer"`; `mailto:` y `tel:` para correo y teléfono. Cada control se renderiza **sólo** si su dato existe — sin botones inertes ni deshabilitados. Cada uno dispara el tracking de su vía, fire-and-forget, sin bloquear la navegación.
- [ ] 5.5 **GREEN** — Bloque regulatorio: matrícula junto a identidad y rol; leyenda del organismo sólo si está cargada (sin etiqueta huérfana ni texto de relleno); deslinde de Aliadata desde el campo editable, no desde una constante.
- [ ] 5.6 **TRIANGULATE** — Casos con listas vacías, sin foto, sin WhatsApp, sin leyenda de organismo, y slug inexistente (pantalla de no encontrado, sin error no controlado).
- [ ] 5.7 **REFACTOR** — Extraer los subcomponentes repetidos del perfil; tests verdes tras cada paso.

## 6. Índice `/seguros` adaptativo

- [ ] 6.1 **RED** — Tests del índice: con 1 asesor visible y 0 ofertas lleva al perfil sin grilla de tres columnas; con 2+ asesores renderiza una card por asesor enlazando a su slug; las ofertas legacy siguen renderizando con su link saliente; sin entradas visibles se conserva el estado vacío actual.
- [ ] 6.2 **GREEN** — Modificar `frontend/app/(dashboard)/seguros/page.tsx` para decidir por **el conteo real de filas visibles**, nunca por una constante ni por un flag cableado a "hay un solo partner".
- [ ] 6.3 **TRIANGULATE** — Caso mixto (asesores + ofertas visibles a la vez) y caso de 3 asesores; verificar que el layout no deja huecos en ninguno.
- [ ] 6.4 **[safety net]** Re-correr `seguros-click-tracking.test.tsx`: los casos que renderizan `SegurosPage` con ofertas deben seguir verdes sin editarse.
- [ ] 6.5 **REFACTOR** — Unificar la card de asesor con los componentes base ya existentes en vez de crear variantes nuevas.

## 7. Panel de administración

- [ ] 7.1 **RED** — Tests del formulario de admin: alta completa de un asesor con todos los campos; edición de una oferta legacy sin que el formulario exija campos de asesor; alta/baja/reordenamiento de líneas de servicio y pilares se persisten.
- [ ] 7.2 **GREEN** — Extender `frontend/app/(dashboard)/admin/seguros/page.tsx` con el selector de tipo de entrada y los campos condicionados al tipo.
- [ ] 7.3 **GREEN** — Editor de listas ordenadas (servicios y pilares): agregar, borrar y reordenar elementos, con la validación Zod de 3.3 aplicada antes de guardar.
- [ ] 7.4 **GREEN** — Campos de identidad, matrícula, leyenda, contacto (los cuatro), zonas de cobertura, foto, deslinde, slug, destacado y orden. **Ningún campo del modelo puede quedar sin superficie de edición**: contenido que nadie puede cargar es contenido que no existe.
- [ ] 7.5 **GREEN** — Mostrar el desglose de clicks por vía junto al total en las métricas del panel.
- [ ] 7.6 **TRIANGULATE** — Guardar un asesor sin slug (debe fallar con mensaje claro, no con un error crudo de Postgres); guardar un slug duplicado (idem); guardar una lista vacía.
- [ ] 7.7 **REFACTOR** — Reemplazar el `useState<any>` de `stats` y el `KpiSummaryCard({...}: any)` que se toquen por tipos explícitos. No dejar `any` nuevo ni conservar el que quede en las líneas modificadas.

## 8. Seed del partner

- [ ] 8.1 Agregar a la migración el `INSERT ... ON CONFLICT (slug) DO UPDATE` con el contenido transcripto en 1.5, con `is_visible = false`.
- [ ] 8.2 Sembrar `contact_whatsapp`, `license_authority` y `disclaimer` **vacíos**: dependen de OQ-1, OQ-3 y OQ-4. Deben quedar completables desde el panel sin migración nueva.
- [ ] 8.3 Sembrar `contact_url` con la web del partner hallada en el PDF (`www.argbroker.com.ar`) y `license_number` con la matrícula declarada en el material (`98506`), ambos **a confirmar** por el PO en OQ-3 antes de publicar.
- [ ] 8.4 **[checkpoint]** Aplicar dos veces en base local y verificar que existe exactamente una fila con ese slug y que la segunda aplicación no pisa con vacíos lo editado a mano.

## 9. Verificación

- [ ] 9.1 Aplicar la migración con `npx supabase db push` vía CLI. **Nunca** con el MCP `apply_migration` (desincroniza el historial de migraciones).
- [ ] 9.2 Correr la suite completa del frontend y comparar contra el baseline de 1.3: cero regresiones propias.
- [ ] 9.3 Correr `tsc` y verificar que no aparecen errores nuevos.
- [ ] 9.4 Correr los gates de CI que aplican: ACLs de funciones (`supabase/tests/test_function_acl_gate.sql`) y referencias de tablas del frontend (`scripts/ci/check_frontend_table_refs.py`).
- [ ] 9.5 **Verificación visual — desktop, tema claro**: perfil e índice, con foto y sin foto.
- [ ] 9.6 **Verificación visual — desktop, tema oscuro**: idem.
- [ ] 9.7 **Verificación visual — mobile, tema claro**: una sola columna, sin desbordes horizontales, vías de contacto alcanzables con el pulgar.
- [ ] 9.8 **Verificación visual — mobile, tema oscuro**: idem.
- [ ] 9.9 Verificación de accesibilidad del perfil y del formulario nuevo: labels asociados, foco visible, orden de tabulación, contraste según los tokens, y nombre accesible en los controles de contacto (que no queden como iconos sin texto).
- [ ] 9.10 Probar a mano las cuatro vías de contacto con datos cargados y verificar que el desglose de clicks sube en la vía correcta y el total en 1 por click.
- [ ] 9.11 Verificar como usuario no admin que una entrada con `is_visible = false` no es accesible ni desde el índice ni por URL directa al slug.

## 10. Cierre

- [ ] 10.1 Actualizar `CHANGES.md` con la entrada del change: qué se hizo, hallazgos y OQs pendientes.
- [ ] 10.2 Si se tocó `CLAUDE.md`, correr `python scripts/ci/check_docs_sync.py --fix` en el **mismo** PR (el gate `Docs Sync` lo verifica).
- [ ] 10.3 Abrir el PR con el detalle de las decisiones de diseño y las 6 OQs con su recomendación. Esperar los checks en verde y mergear.
- [ ] 10.4 **[checkpoint post-merge]** Verificar en prod: `MAX(version) = 20261017000001`, las columnas y CHECKs vivos, las ACLs de la función nueva (`anon` sin `EXECUTE`), y la fila del partner presente con `is_visible = false`.
- [ ] 10.5 **[requiere PO]** Presentar el perfil al PO para revisión del contenido y firma de las 6 OQs — en particular OQ-3 (matrícula y leyenda regulatoria) y OQ-4 (texto del deslinde), que son las que tienen consecuencia hacia afuera.
- [ ] 10.6 **[requiere PO]** Publicar: completar desde el panel los campos que dependían de las OQs y activar la visibilidad con el toggle existente. La publicación es acción explícita del PO, nunca un efecto del deploy.
- [ ] 10.7 Guardar en engram el resultado del apply con `topic_key: "opsx/seguros-perfil-asesor/apply"`, incluyendo los hallazgos y qué quedó pendiente del PO.
