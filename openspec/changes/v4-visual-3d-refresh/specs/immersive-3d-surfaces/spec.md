## ADDED Requirements

### Requirement: Escenas 3D decorativas solo en superficies de alto impacto
El sistema SHALL renderizar escenas 3D (React Three Fiber + drei) únicamente en superficies de alto impacto — landing/hero, login/registro, onboarding, empty states destacados y momentos de celebración ("venta cerrada", "meta alcanzada"). El sistema SHALL NOT montar escenas 3D en superficies operativas densas (POS/venta rápida, tablas de datos, listados). El 3D SHALL ser puramente decorativo.

#### Scenario: Alto impacto lleva 3D
- **WHEN** el usuario visita la landing, el login/registro o un momento de celebración y su dispositivo califica (ver gate de capacidad)
- **THEN** se monta la escena 3D correspondiente

#### Scenario: Operativa densa nunca lleva 3D
- **WHEN** el usuario abre el POS, una tabla de datos o un listado
- **THEN** no se carga el bundle 3D ni se monta ningún `<Canvas>` en esa superficie

### Requirement: Carga fuera del critical path
Toda escena 3D SHALL cargarse vía `next/dynamic` con `ssr:false` y SHALL NOT formar parte del first-load JS de rutas no-3D. El `<Canvas>` SHALL montarse solo cuando su superficie entra en viewport (IntersectionObserver) y SHALL pausar o desmontar su render loop cuando sale del viewport. Un `<Suspense>` con fallback estático SHALL cubrir la carga de assets.

#### Scenario: No entra al critical path
- **WHEN** se analiza el first-load JS de una ruta que no tiene superficie 3D
- **THEN** el bundle de R3F/drei/escena no aparece en ese first-load (verificado con el analyzer de `v4-frontend-07`)

#### Scenario: Montaje por viewport
- **WHEN** una superficie 3D todavía no está visible en el viewport
- **THEN** su `<Canvas>` no está montado; al entrar en viewport se monta, y al salir se pausa/desmonta el loop de render

#### Scenario: Fallback durante la carga de assets
- **WHEN** la escena 3D se está montando y sus assets glTF aún no cargaron
- **THEN** se muestra el poster/fallback estático hasta que la escena esté lista

### Requirement: Gate de capacidad con fallback estático
Antes de montar el `<Canvas>`, el sistema SHALL evaluar un gate de capacidad y servir un fallback estático (imagen/gradiente) — sin costo de WebGL — cuando se cumpla cualquiera de: `prefers-reduced-motion: reduce`; dispositivo mobile o de gama baja según los umbrales documentados; ausencia de contexto WebGL; o `navigator.connection.saveData` / conexión lenta. La experiencia SHALL ser 100% usable con el fallback.

#### Scenario: Reduced-motion sirve poster
- **WHEN** el usuario tiene `prefers-reduced-motion: reduce`
- **THEN** la superficie muestra el poster estático y no monta la escena 3D

#### Scenario: Mobile / gama baja sirve poster
- **WHEN** el dispositivo es mobile o de gama baja según los umbrales documentados (viewport + `hardwareConcurrency`/`deviceMemory` + `pointer: coarse`)
- **THEN** la superficie muestra el poster estático y no monta la escena 3D

#### Scenario: Sin WebGL sirve poster
- **WHEN** el navegador no puede crear un contexto `webgl2`/`webgl`
- **THEN** la superficie muestra el poster estático y la app sigue funcionando sin errores

#### Scenario: Save-Data sirve poster
- **WHEN** `navigator.connection.saveData` es verdadero o la conexión es lenta
- **THEN** la superficie muestra el poster estático y no descarga los assets 3D

### Requirement: Presupuesto de performance
El chunk 3D (R3F + drei + escena) SHALL ir 100% detrás de `next/dynamic` con un presupuesto de bundle explícito, y los assets glTF/Draco SHALL respetar un presupuesto de peso por escena, ambos documentados y verificables. El LCP de las rutas con 3D SHALL NOT regresionar respecto de la baseline 2D, y el 3D SHALL usar degradación de calidad (p. ej. `AdaptiveDpr`) antes que caer el frame-rate.

#### Scenario: Presupuesto de bundle respetado
- **WHEN** se mide el tamaño del chunk lazy de una escena 3D
- **THEN** está dentro del presupuesto documentado y no se incluye en rutas sin 3D

#### Scenario: LCP no regresiona
- **WHEN** se mide el LCP de la landing/auth con la escena 3D activa contra la baseline sin 3D
- **THEN** el LCP no empeora, porque el 3D carga después del elemento LCP (poster/contenido) y detrás del gate

#### Scenario: Degradación de calidad antes que de FPS
- **WHEN** el dispositivo no sostiene el frame-rate objetivo
- **THEN** la escena baja la resolución/DPR (AdaptiveDpr) en vez de dejar caer los FPS

### Requirement: Accesibilidad del contenido 3D
La superficie 3D SHALL ser tratada como decorativa: su contenedor SHALL llevar `aria-hidden="true"`, SHALL NOT ser enfocable por teclado, y toda la información y las acciones SHALL existir en el DOM accesible fuera del canvas. El gate de axe de `v4-frontend-04` SHALL permanecer en 0 violaciones críticas/serias con o sin 3D.

#### Scenario: Canvas oculto a tecnologías de asistencia
- **WHEN** un lector de pantalla recorre una superficie con 3D
- **THEN** el contenedor del canvas está `aria-hidden` y no se anuncia; el contenido y las acciones siguen disponibles fuera del canvas

#### Scenario: Usable sin 3D
- **WHEN** la escena 3D no se monta (por gate o por fallo)
- **THEN** el usuario puede completar la misma tarea (navegar, iniciar sesión, registrarse, operar) sin degradación funcional

### Requirement: Assets self-hosted compatibles con el CSP
Los assets 3D (glTF con geometría Draco, texturas KTX2/Basis si aplica) y los decoders correspondientes SHALL servirse desde el propio origen (`frontend/public/`), no desde CDNs de terceros. El CSP del middleware SHALL permitir los Web Workers de los decoders mediante `worker-src 'self' blob:` sin habilitar ningún host de terceros.

#### Scenario: Assets y decoders del propio origen
- **WHEN** una escena carga un modelo glTF/Draco
- **THEN** tanto el modelo como el decoder se descargan del propio origin, sin peticiones a hosts de terceros

#### Scenario: CSP permite los workers de decode
- **WHEN** el decoder de Draco/KTX2 instancia su Web Worker desde un blob URL en producción
- **THEN** el CSP (`worker-src 'self' blob:`) lo permite y la escena decodifica sin ser bloqueada

### Requirement: Resiliencia ante fallo de escena
Una escena 3D que falle en tiempo de ejecución SHALL degradar a su poster estático mediante un error boundary, y NUNCA SHALL dejar la superficie en pantalla en blanco ni propagar el error al resto de la app.

#### Scenario: Fallo de render cae al poster
- **WHEN** una escena 3D lanza un error durante el render (p. ej. asset corrupto o contexto WebGL perdido)
- **THEN** el error boundary de la superficie muestra el poster estático y el resto de la página sigue funcionando
