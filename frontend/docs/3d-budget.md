# Presupuesto de peso/bundle — escenas 3D (`v4-visual-3d-refresh`)

> Documento vivo (task 2.8, actualizado en Fase D task 4.6). Complementa `frontend/docs/surface-matrix.md` y `frontend/docs/design-tokens.md`.

## Origen y assets

Sign-off del PO 2026-07-29 (design.md Open Question 5): **solo geometría procedural/low-poly generada por código**. No hay modelos glTF descargados ni encargados en este change. Esto simplifica D6/D8 del design:

- **No hay presupuesto de assets glTF/Draco** — no existen todavía. Si una fase futura introduce modelos reales, esta sección debe actualizarse con un presupuesto explícito por escena (el ~300 KB/escena de design.md D5 queda como referencia para ese caso, no verificado).
- **No hay decoders Draco/KTX2 self-hosted** — nada que decodificar. `worker-src 'self' blob:` (task 2.7) se agregó igual, de forma defensiva, porque la task de infraestructura lo pide explícitamente.
- Los posters de fallback son **SVG autoría propia** (`frontend/public/3d/hero-poster-{light,dark}.svg`, ~1–1.5 KB cada uno), no WebP/AVIF rasterizado — vectorial, más liviano, sin necesidad de herramientas de generación de imágenes; sirven vía `next/image` (`components/three/Poster.tsx`) con `unoptimized` para `.svg`.

## Presupuesto de bundle JS (chunk lazy R3F + three + drei)

**Medido, no especulativo** — build de producción (`pnpm build`, Next 16.1.6, Turbopack), chunk único que contiene `@react-three/fiber` + `three`: **~888 KB sin comprimir / ~233 KB gzip**.

Esto **supera** el objetivo especulativo de design.md D5 (~180 KB gz), documentado ahí *antes* de implementar. Motivo, no evitable con el uso actual: `@react-three/fiber` importa el namespace completo de `three` (`import * as THREE from 'three'`) porque su reconciler instancia clases de Three.js genéricamente a partir del nombre del tag JSX (`<mesh>` → `new THREE.Mesh()`), sin saber de antemano qué clases se van a usar — no es tree-shakeable por diseño. `@react-three/drei` está instalado (task 2.1) pero **no importado todavía** por ninguna escena (Fase B usa solo primitivas `@react-three/fiber`/`three`); si una escena futura importa algo de `drei`, este número sube y debe re-medirse.

**Presupuesto revisado (reemplaza el de D5, con la misma intención — nunca en el critical path):**
- Chunk compartido R3F+three: **~235 KB gz, una sola vez** — se cachea entre TODAS las escenas 3D del sitio (landing, login/registro, etc.), no es un costo por escena.
- Código propio por escena (ej. `HeroScene.tsx` + `heroSceneTheme.ts`): **< 5 KB gz** — geometría/materiales declarativos, sin lógica pesada.
- **Lo que SÍ es no-negociable y está verificado (no solo por construcción)**: este chunk **nunca** aparece en el first-load JS de una ruta sin 3D, y **nunca se descarga** para un dispositivo que el gate de capacidad descalifica. Ver "Verificación" abajo.

## Verificación realizada (task 2.9/2.10, Browser pane, build de producción)

1. **Aislamiento de rutas sin 3D**: se inspeccionó el contenido de los ~13 chunks que carga `/legal/privacidad` (ruta `refresh-only`, sin 3D) en el first-load — `grep` por `react-three|THREE\.|three/build` → **0 matches en los 13**. El chunk 3D no está.
2. **Gate de capacidad — no descarga para dispositivo descalificado**: el entorno de prueba real (browser headless de este sandbox) reporta `navigator.hardwareConcurrency = 4`, exactamente el umbral de gama baja (`LOW_END_HARDWARE_CONCURRENCY_MAX = 4`, ver `capabilityGate.ts`) → el gate descalifica correctamente. Se confirmó en `/` (ruta CON 3D) que, tras la carga inicial y 5s de espera, **cero requests** nuevos a chunks de R3F/three — el bug original (ver abajo) ya no ocurre.
3. **Bug encontrado y corregido en el camino**: la primera versión (`HeroSceneMount` renderizando directamente el componente envuelto en `next/dynamic`) SÍ descargaba el chunk de ~233 KB gz incluso con el gate descalificando — `next/dynamic` dispara el `import()` en cuanto su componente se renderiza, sin importar qué decida mostrar internamente. Fix: `components/three/GatedSceneMount.tsx` evalúa el gate (y el viewport) **antes** de renderizar el componente dinámico — confirmado tanto por tests (`GatedSceneMount.test.tsx`, el mock del importer nunca se llama en los casos descalificado/fuera-de-viewport) como en el browser real (arriba).
4. **No verificado en vivo (gap conocido)**: el camino "gate califica → se monta el `<Canvas>` real y las mallas de Three renderizan sin error" no se pudo confirmar en un browser real dentro de esta sesión — el hardware del sandbox reporta exactamente 4 cores (el umbral de descalificación) y no fue posible sobrescribir `navigator.hardwareConcurrency` de forma que el contexto real de la página lo viera (la herramienta de scripting corre en un world aislado). Cobertura de este camino: tests unitarios deterministas (`capabilityGate.test.ts` 12 casos, `useCapabilityGate.test.ts` 4 casos, `Lazy3DCanvas.test.tsx` 5 casos con `@react-three/fiber` mockeado, `GatedSceneMount.test.tsx` 4 casos) + `tsc --noEmit` limpio contra los tipos reales de `@react-three/fiber`/`three` (cualquier prop/elemento JSX inválido en `HeroScene.tsx` habría fallado la compilación). **Pendiente recomendado**: una verificación visual manual en un browser real de escritorio (fuera de este sandbox) antes o poco después de mergear a producción.

## Umbrales del gate de capacidad (referencia — fuente: `lib/three/capabilityGate.ts`)

| Señal | Umbral | Nota |
|---|---|---|
| `prefers-reduced-motion: reduce` | cualquier valor `true` | máxima prioridad |
| Mobile (viewport + puntero) | `innerWidth <= 767px` **Y** `pointer: coarse` | ambas señales juntas — evita falsos positivos de una ventana desktop angosta |
| Gama baja — cores | `hardwareConcurrency <= 4` | ausente (`undefined`, ej. Safari a veces) → NO descalifica por sí solo |
| Gama baja — memoria | `deviceMemory <= 4` (GB) | ausente (`undefined`, ej. Safari/Firefox, que no exponen la API) → NO descalifica por sí solo |
| Sin WebGL | no se puede crear contexto `webgl2` ni `webgl` | — |
| Save-Data / conexión lenta | `connection.saveData === true` o `effectiveType` en `{slow-2g, 2g}` | — |

Repetido de `capabilityGate.ts` a propósito: es el resumen de referencia rápida; la fuente de verdad y el detalle del razonamiento ("por qué esta combinación", "por qué ausente ≠ descalifica") vive en los comentarios del código y en `__tests__/lib/three/capabilityGate.test.ts`.

## Cierre — Fase D (2026-07-29)

### Degradación de calidad antes que FPS (D5 / spec "Degradación de calidad antes que de FPS")

`Lazy3DCanvas` monta `<AdaptiveDpr pixelated />` + `<AdaptiveEvents />` (drei) automáticamente en **toda** escena — no era así en el cierre de Fase B (`drei` estaba instalado pero sin ningún import real). Cuando R3F detecta frames lentos, baja el device-pixel-ratio (menos píxeles físicos por frame) y frena el raycasting de eventos de puntero, antes de que el frame-rate caiga. Aplicado en el wrapper compartido, no por escena — ninguna escena nueva puede "olvidarlo". Impacto en bundle: nulo medible (~233KB gz antes y después — `AdaptiveDpr`/`AdaptiveEvents` son componentes mínimos, la mayoría de `drei` sigue sin importarse).

### Verificación de aislamiento — 6 superficies operativas (task 3.8/4.4, ampliada Fase D)

Repetido con el build final de Fase D (tras agregar `AdaptiveDpr`/`AdaptiveEvents`): grep de contenido (`react-three|THREE\.|three/build`) sobre TODOS los chunks de los client-reference-manifest de `/ventas/pos`, `/dashboard`, `/stock`, `/clientes`, `/ventas/ordenes`, `/facturacion` — **0 matches**, sin regresión. `/legal/privacidad` (ruta pública sin 3D) también confirmada limpia.

### Accesibilidad de las superficies 3D (task 4.2 — sin gate axe formal, ver nota)

`v4-frontend-04` (el change dueño del gate axe/WCAG transversal) no existe todavía como código en este repo — no se reimplementa aquí (regla dura del change). Verificación hecha con las herramientas disponibles en esta Fase D:
- **Code review**: `grep` sobre `components/three/*.tsx` — 0 elementos focalizables/interactivos (`tabIndex`, `onClick`, `<button>`, `<input>`, `autoFocus`) dentro de ninguna escena/canvas; los 4 wrappers (`Lazy3DCanvas`, `Poster`, `GatedSceneMount`, `Celebration3D`) tienen `aria-hidden="true"` confirmado.
- **Browser real** (`/`, landing): 0 elementos focalizables dentro del contenedor 3D (`querySelectorAll('a, button, input, select, textarea, [tabindex]')` sobre el contenedor → longitud 0).
- **Contenido/acciones fuera del canvas**: por arquitectura — el texto, los CTAs, el formulario de login/registro y el feedback de "venta confirmada" son siempre hermanos del contenedor 3D en el DOM, nunca hijos (`Lazy3DCanvas` solo renderiza el `<Canvas>` o el poster, nada más).
- **Pendiente real**: una corrida de axe-core/Lighthouse contra las 6 superficies con y sin 3D, con puntaje 0 violaciones críticas/serias, queda para cuando `v4-frontend-04` se ejecute (o como verificación manual puntual fuera de esta sesión).

### Performance — FPS en gama media (task 4.3)

No se pudo benchmarkear FPS real en hardware de gama media dentro de esta sesión (sandbox sin GPU real accesible para profiling). Mitigado por diseño: las escenas son deliberadamente livianas (≤17 mallas low-poly por escena, sin texturas, sin post-procesado), `frameloop="demand"` evita renders desperdiciados, `AdaptiveDpr`/`AdaptiveEvents` degradan resolución antes que frame-rate (arriba). **Pendiente recomendado**: medición real en un dispositivo de gama media antes/después de exponer esto a usuarios reales.

### LCP (task 2.10/4.3)

No medido con Lighthouse/web-vitals real en esta sesión. Por diseño no debería regresionar: el poster (elemento `next/image`, candidato natural a LCP) se sirve inmediatamente; el 3D se monta después, vía `next/dynamic({ssr:false})` + gate + `IntersectionObserver`, fuera del critical path. **Pendiente recomendado**: medición real (Lighthouse CI o Vercel Analytics) en `/` y `/auth/login` antes/después de este change.

### Resumen de gaps conocidos (honesto, no resueltos en esta sesión)

1. Camino "gate qualifies=true → Canvas real monta y renderiza sin errores" no verificado en un browser real dentro de esta sesión (sandbox con `hardwareConcurrency=4` fijo, umbral de descalificación). Cubierto por 29+ tests unitarios deterministas + `tsc` limpio contra tipos reales de R3F.
2. FPS y LCP no medidos con herramientas de profiling reales (Lighthouse/DevTools Performance) — mitigado por diseño (escenas livianas, `AdaptiveDpr`, `frameloop="demand"`, gate de capacidad), no por medición.
3. Gate axe/WCAG formal no corrido (la infraestructura, `v4-frontend-04`, no existe todavía en este repo) — verificación manual/code-review hecha en su lugar.
4. Barrido de color transversal (883 clases de la auditoría original) sigue siendo alcance de `v4-frontend-01` — este change solo garantiza no haber introducido clases nuevas hardcodeadas en las superficies que tocó (ver `design-tokens.md`).
