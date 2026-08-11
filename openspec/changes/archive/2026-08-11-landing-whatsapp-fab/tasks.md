## 1. Preparación

- [x] 1.1 Crear rama `feat/landing-whatsapp-fab` desde `main` actualizado (nunca commitear a `main`).
- [x] 1.2 **Red de seguridad**: correr la suite de frontend completa (`pnpm vitest run` en `frontend/`) y anotar el baseline de tests en verde. Si algo ya falla, reportarlo como falla pre-existente y NO intentar arreglarlo en este change. → **Baseline: 97 archivos / 729 tests, todo verde.**
- [x] 1.3 Confirmar en `frontend/lib/phone-utils.ts` que `normalizeWhatsAppPhone` y `buildWhatsAppUrl` siguen exportadas con la firma que asume `design.md` (reutilización, no reescritura).

## 2. Componente `WhatsAppFab` — ciclo TDD

- [x] 2.1 **RED**: crear `frontend/__tests__/components/WhatsAppFab.test.tsx` con el primer caso — dado el número real `+54 9 2617 63-5174`, el componente renderiza un enlace cuyo `href` es `https://wa.me/5492617635174?text=…`. El test debe fallar porque `WhatsAppFab` todavía no existe.
- [x] 2.2 **GREEN**: crear `frontend/components/landing/WhatsAppFab.tsx` (Server Component, sin `"use client"`) con lo mínimo para pasar: prop `phone`, normalización vía `normalizeWhatsAppPhone`, URL vía `buildWhatsAppUrl` y un `<a>`. Ejecutar y confirmar verde.
- [x] 2.3 **TRIANGULATE — degradación**: agregar casos para `phone` ausente (`undefined`), vacío (`"   "`) e inválido (`"123"`); en los tres el componente no renderiza nada y **no** emite ningún `href` que contenga `wa.me`. Generalizar la implementación hasta que pasen. → El RED confirmó el riesgo de D3: emitía `https://wa.me/?text=…` (selector de contactos).
- [x] 2.4 **TRIANGULATE — normalización**: agregar un caso con formato local (`0261 763-5174`) que debe producir el mismo `href` canónico con prefijo `549`.
- [x] 2.5 **TRIANGULATE — mensaje pre-cargado**: asertar que el `href` incluye el parámetro `text` con el mensaje inicial codificado para URL (espacios y caracteres no ASCII codificados, URL no rota).
- [x] 2.6 **TRIANGULATE — seguridad del enlace**: asertar `target="_blank"` y que `rel` contiene `noopener` y `noreferrer`.
- [x] 2.7 **TRIANGULATE — accesibilidad**: asertar el nombre accesible (menciona WhatsApp e indica que abre pestaña nueva) y que el SVG del glifo está marcado como decorativo (`aria-hidden`).
- [x] 2.8 Implementar el estilado del botón: `fixed bottom-5 right-5 sm:bottom-6 sm:right-6`, `z-40`, `h-14 w-14` (≥ 44 px táctiles), verde de marca `#25D366`, `shadow-elevation-*`, `focus-visible:ring-2 ring-offset-2`, hover `scale-105` con `transition-transform duration-fast ease-standard` y degradación `motion-reduce:transition-none motion-reduce:hover:scale-100` (design.md D5-D8).
- [x] 2.9 Embeber el glifo oficial de WhatsApp como SVG inline con `aria-hidden="true"` y `focusable="false"` (lucide-react no trae marcas — design.md D4).
- [x] 2.10 **REFACTOR**: extraer el mensaje inicial a una constante nombrada del módulo, revisar nombres y comentarios (por qué la validación va antes de `buildWhatsAppUrl` — design.md D3). Suite verde después de cada paso. → 12/12 tests del componente en verde.

## 3. Montaje en la home

- [x] 3.1 **RED**: agregar a la suite un test que verifique que `app/page.tsx` monta `WhatsAppFab` pasándole el valor de `process.env.ALIADATA_WHATSAPP_PHONE`. → `frontend/__tests__/HomePageWhatsAppFab.test.tsx`.
- [x] 3.2 **GREEN**: montar `<WhatsAppFab phone={process.env.ALIADATA_WHATSAPP_PHONE} />` en `frontend/app/page.tsx` como hermano de `<LandingPageFull />` — NO dentro de `LandingPageFull`, NO en un layout (design.md D2, requisito de alcance exclusivo).
- [x] 3.3 Verificar por inspección de código que ningún layout, `/landing`, ruta de auth ni pantalla del dashboard importa `WhatsAppFab` (grep del identificador en `frontend/` — debe aparecer solo en el componente, su test y `app/page.tsx`). → 4 coincidencias exactas: componente, `app/page.tsx` y los 2 tests.
- [x] 3.4 Correr la suite completa de frontend y confirmar que sigue verde, incluidos los tests de CSP y de la landing. → **99 archivos / 744 tests verdes** (baseline 97/729 + 2 archivos y 15 tests nuevos), 0 regresiones.

## 4. Configuración

- [x] 4.1 Documentar `ALIADATA_WHATSAPP_PHONE` en `frontend/.env.example`, con el formato esperado y la nota de que sin ella el botón simplemente no aparece.
- [x] 4.2 Cargar `ALIADATA_WHATSAPP_PHONE` con el número real en `frontend/.env.local` para poder verificar en local. → Confirmado que `.env.local` está gitignoreado: el número real no viaja al repo.
- [x] 4.3 **[PO]** Cargar la variable en Vercel para Production y Preview. Puede hacerse antes del merge: sin el código desplegado, la variable no tiene efecto. → Cargada por el PO 2026-08-05; verificado en producción que el `href` emite el número real.

## 5. Verificación visual y de accesibilidad

- [x] 5.1 Levantar el dev server y verificar en desktop (1280 px): el botón está visible al cargar, acompaña el scroll hasta el footer, y al tocarlo abre `wa.me` con el número y el mensaje correctos. → `position: fixed`, 56×56 px, `#25D366` (`rgb(37,211,102)`), sigue en su lugar tras 8562 px de scroll y `elementFromPoint` sobre su centro devuelve el botón (no está tapado). `href` emitido: `https://wa.me/5492617635174?text=Hola%20ALIADATA%20%F0%9F%91%8B%20…`. **No se navegó al destino externo**: la verificación es sobre el `href` exacto.
- [x] 5.2 Verificar en mobile (375 px) recorriendo **hasta el final de la página**: el botón no tapa el CTA final "Empezar Gratis" ni el contenido del footer (riesgo declarado en `design.md`). → A 375×812, con 20 px de margen: **0 solapamientos** contra links/párrafos/títulos del footer y del área del CTA final (test de intersección de rectángulos al fondo de la página y 900 px antes).
- [x] 5.3 Verificar que el botón queda por debajo del Navbar fijo y del menú mobile abierto (jerarquía `z-40` vs `z-50`). → FAB `z-40` vs header `z-50`; con el menú mobile abierto (header de 342 px) no hay intersección de rectángulos.
- [x] 5.4 Verificar accesibilidad: alcanzable por tabulación con foco visible sobre el fondo oscuro, activable con Enter, y nombre accesible correcto en el árbol de accesibilidad. → El árbol de accesibilidad lo expone como `link "Escribinos por WhatsApp (se abre en una pestaña nueva)"`; `focus()` lo deja como `activeElement`; el SVG queda `aria-hidden="true"`.
- [x] 5.5 Verificar con movimiento reducido activado que la transición de escala no se aplica. → Verificadas las reglas CSS reales dentro de `@media (prefers-reduced-motion)`: `.motion-reduce\:transition-none { transition-property: none }` y `.motion-reduce\:hover\:scale-100:hover` (scale 1). Además la transición normal resuelve los tokens: `transform 0.12s cubic-bezier(0.4,0,0.2,1)` = `duration-fast` + `ease-standard`.
- [x] 5.6 Verificar en la consola del navegador que **no hay violaciones de CSP** al cargar la landing y al navegar al enlace (lección de `tutorial-videos`: todo lo de terceros se verifica contra el CSP antes del merge). → 0 violaciones de CSP en consola. Los únicos errores son `Error fetching landing sections: fetch failed` (backend local caído, pre-existente y ajeno a este change: la landing cae a sus secciones por defecto).
- [x] 5.7 Confirmar que la escena 3D del hero y el resto de la landing siguen funcionando igual (sin regresiones de render). → El contenedor del `HeroSceneMount` renderiza su póster de fallback porque este browser reporta `hardwareConcurrency: 4` y `LOW_END_HARDWARE_CONCURRENCY_MAX = 4` clasifica el equipo como gama baja: es la degradación diseñada del gate, no una regresión. El h1 y el resto de la landing renderizan normal.

## 6. Documentación

- [x] 6.1 Actualizar la fila `/` de `frontend/docs/surface-matrix.md` anotando que la home lleva el FAB de contacto por WhatsApp en `z-40`, esquina inferior derecha — para que un futuro elemento flotante sepa que este existe.

## 7. Entrega

- [x] 7.1 Commit con conventional commits (`feat(landing): boton flotante de WhatsApp en la home`) y co-autoría del agente. → `9813e91` en `feat/landing-whatsapp-fab`.
- [x] 7.2 Abrir PR contra `main` describiendo alcance, decisión de la env var y capturas desktop + mobile. → PR #360. Sin capturas (el pane no componía frames): verificación por geometría/estilos computados, declarado en el PR.
- [x] 7.3 Esperar checks verdes (incluido `validate-kpis`, no solo Vercel) y mergear. → `validate-kpis` pass (1m49s) + Vercel pass; squash-merge `c0f8eac` 2026-08-05.
- [x] 7.4 **Verificación post-deploy en producción**: confirmar que el botón aparece en la home real y que el enlace abre la conversación con el número correcto. Es la contraparte necesaria de la degradación silenciosa: si la variable quedó mal cargada, el botón no aparece y nadie se entera. → Verificado 2026-08-05 en browser (`https://wa.me/5492617635174?text=…`, fixed, z-40, 56×56, sin solapamientos al fondo) y re-verificado 2026-08-07 por HTML server-rendered: `/` contiene el enlace con el número real; `/auth/login` y `/landing` NO contienen `wa.me` (alcance exclusivo confirmado en prod).
