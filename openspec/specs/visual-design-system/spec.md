# visual-design-system Specification

## Purpose
TBD - created by archiving change v4-visual-3d-refresh. Update Purpose after archive.
## Requirements
### Requirement: Lenguaje visual con tokens semánticos extendidos
El sistema SHALL definir el lenguaje visual de ALIADATA mediante tokens semánticos de segundo nivel (escala tipográfica, ritmo de spacing, radios, elevación/sombras y tokens de motion) construidos sobre los tokens base de color de `v4-frontend-01`, expuestos como CSS variables en `app/globals.css` y como utilities en `tailwind.config.ts theme.extend`. El sistema SHALL NOT introducir una segunda fuente de tokens ni reintroducir literales `#hex` o clases de color de escala Tailwind fuera de la allowlist documentada.

#### Scenario: Los tokens semánticos compilan como utilities
- **WHEN** un componente usa una utility de token semántico del refresh (p. ej. una sombra de elevación o una duración de motion tokenizada)
- **THEN** Tailwind la compila desde `theme.extend` (no como arbitrary value) y resuelve al CSS variable correspondiente

#### Scenario: No se reintroducen colores hardcodeados
- **WHEN** se aplica el refresh a una superficie que tenía clases de color hardcodeadas (`emerald-*`/`green-*`/`amber-*`/`red-*`/`slate-*`) o `#hex`
- **THEN** esas ocurrencias se reemplazan por tokens semánticos (`primary`/`success`/`warning`/`destructive`/`muted`/`foreground`) y el lint de color de `v4-frontend-01` pasa sin nuevas violaciones

### Requirement: Estilos de componente unificados sobre shadcn/Radix
El sistema SHALL aplicar el refresh estilizando los componentes shadcn/Radix existentes a través de la API `cva` en `components/ui/*` y de los tokens, sin bifurcar ni reescribir la librería de componentes. El resultado visual SHALL ser coherente entre superficies (cards, botones, inputs, tablas, badges, diálogos).

#### Scenario: Refresh sin fork de componentes
- **WHEN** se refresca un componente base (p. ej. Button o Card)
- **THEN** el cambio se expresa vía variantes `cva` y tokens, y no crea un componente paralelo que duplique el de `components/ui/`

#### Scenario: Coherencia entre superficies
- **WHEN** el mismo tipo de componente aparece en dos superficies distintas (dashboard y ventas)
- **THEN** presenta el mismo tratamiento visual (radio, elevación, color semántico) derivado de los tokens

### Requirement: Sistema de micro-animaciones 2D con respeto de reduced-motion
El sistema SHALL proveer un conjunto reutilizable de micro-animaciones 2D (Framer Motion) en `components/motion/*` para entrada de listas/cards, feedback de estado (éxito/error/carga) y estados hover/press, leyendo los tokens de motion compartidos. Todas las animaciones SHALL respetar `prefers-reduced-motion: reduce` degradando a una transición mínima o nula.

#### Scenario: Animación de entrada estándar
- **WHEN** una lista o card entra en pantalla y el usuario no pidió reducir movimiento
- **THEN** se anima con la duración y curva de los tokens de motion compartidos, sin reimplementar timings ad hoc por componente

#### Scenario: Respeto de prefers-reduced-motion
- **WHEN** el sistema operativo del usuario tiene `prefers-reduced-motion: reduce`
- **THEN** las micro-animaciones 2D degradan a un fundido mínimo o a ninguna animación, y no hay movimiento de desplazamiento/escala

### Requirement: Tema claro y oscuro coherente
El refresh SHALL cubrir los temas claro y oscuro (ya soportados por `next-themes`), garantizando que todos los tokens semánticos introducidos tengan valor válido en ambos temas. Tener valor en ambos temas SHALL NOT considerarse suficiente: el valor de cada tema SHALL además cumplir el umbral de contraste del rol que cumple en ese tema, verificado por el test de contraste, porque una luminosidad elegida para leerse sobre fondo oscuro no se lee sobre un tinte claro. El sistema SHALL NOT declarar el mismo valor HSL en `:root` y en `.dark` para un token que pinta texto, salvo que el test demuestre que ese valor único cumple el umbral en los dos temas.

#### Scenario: Tokens definidos en ambos temas
- **WHEN** se introduce un token semántico nuevo del refresh
- **THEN** existe su valor tanto en `:root` (claro) como en `.dark` (oscuro)

#### Scenario: Cambio de tema sin artefactos
- **WHEN** el usuario alterna entre tema claro y oscuro con el toggle existente
- **THEN** las superficies refrescadas cambian de tema sin colores hardcodeados que queden fuera de tema

#### Scenario: Valor compartido entre temas para un token de texto
- **WHEN** un token que pinta texto declara el mismo valor HSL en `:root` y en `.dark`
- **THEN** el test de contraste lo evalúa en ambos temas y falla si el valor no alcanza 4,5:1 en alguno de los dos

### Requirement: Matriz de clasificación de superficies
El sistema SHALL mantener una matriz que clasifica cada superficie en una de tres clases — `3d` (alto impacto), `2d-motion` (refresh + micro-animaciones) o `refresh-only` (solo tokens) — y esa clasificación SHALL gobernar el tratamiento aplicado. Las superficies operativas densas (POS/venta rápida, tablas de datos, listados) SHALL clasificarse como `2d-motion` o `refresh-only` y NUNCA como `3d`.

#### Scenario: Superficie operativa densa no lleva 3D
- **WHEN** se clasifica el POS, una tabla de datos o un listado
- **THEN** su clase es `2d-motion` o `refresh-only`, y no se monta ninguna escena 3D en ella

#### Scenario: Ante duda se degrada
- **WHEN** una superficie es ambigua entre dos clases
- **THEN** se asigna la clase de menor costo de render

### Requirement: Refresh no altera la lógica de negocio
El refresh visual SHALL limitarse a presentación (estilos, tokens, animaciones) y SHALL NOT modificar la lógica de negocio, los hooks de datos, las RPCs, la autenticación, la RLS ni los cálculos de dinero/fiscal.

#### Scenario: Solo cambian estilos y animación
- **WHEN** se refresca una pantalla con formularios o tablas de datos
- **THEN** el cambio afecta clases/tokens/animaciones y no toca los handlers de submit, las queries ni las mutaciones existentes

### Requirement: Contraste WCAG AA verificable de los tokens semánticos
El sistema SHALL garantizar que todo par canónico de tokens semánticos de color alcance el umbral de contraste WCAG 2.1 AA en ambos temas — 4,5:1 cuando el token pinta texto y 3:1 cuando pinta un indicador de interfaz no textual — y SHALL verificarlo con un test automático que lea `frontend/app/globals.css` como única fuente de verdad y calcule los ratios, en lugar de depender de una auditoría manual. Son pares canónicos: el token de texto sobre el tinte del token base (`bg-<rol>/5`, `/10`, `/15`), el token de texto sobre las superficies planas `--background` y `--card`, el token `--<rol>-foreground` sobre el sólido `--<rol>`, y `--ring` sobre esas mismas superficies planas.

#### Scenario: Un token que no alcanza el umbral falla el build
- **WHEN** se edita un valor HSL de un token semántico en `frontend/app/globals.css` y el par canónico resultante cae por debajo de su umbral
- **THEN** el test de contraste falla identificando el par, el tema y el ratio medido, y el PR no puede mergearse

#### Scenario: El tinte se evalúa en el peor caso
- **WHEN** el test evalúa un token de texto que se usa sobre tintes del token base con distintas opacidades
- **THEN** calcula el ratio componiendo el tinte sobre la superficie con la misma fórmula alpha del navegador, y exige el umbral en la opacidad más desfavorable, no en un promedio

#### Scenario: Ambos temas se verifican
- **WHEN** el test corre
- **THEN** evalúa los pares del bloque `:root` y los del bloque `.dark` por separado, y no da por válido un tema porque el otro pase

### Requirement: Separación entre token de superficie y token de texto
El sistema SHALL definir, para cada rol semántico de color (`primary`, `success`, `warning`, `destructive`), un token de superficie que pinta fondos, tintes, bordes e indicadores, y un token de texto independiente (`--<rol>-text`) que pinta texto e íconos sobre esas superficies, porque ambos usos tienen requisitos de luminosidad opuestos y un valor único no puede satisfacer los dos en un mismo tema. El token de texto SHALL exponerse remapeando la paleta de utilities de texto en `tailwind.config.ts`, de modo que las utilities existentes (`text-<rol>`) resuelvan al token accesible sin que los componentes consumidores cambien de clase.

#### Scenario: El color de marca de las superficies no se degrada
- **WHEN** se corrige el contraste de texto de un rol semántico
- **THEN** el token de superficie de ese rol conserva su valor, y los fondos, tintes, bordes y series de gráfico que lo consumen mantienen el color de marca

#### Scenario: Los componentes no se migran clase por clase
- **WHEN** un componente ya usa la utility de texto del rol semántico (`text-success`, `text-warning`, `text-destructive`, `text-primary`)
- **THEN** obtiene el token accesible por el remapeo de la configuración, sin editar su `className` ni introducir una utility paralela

#### Scenario: Un rol nuevo nace con los dos tokens
- **WHEN** se agrega un rol semántico de color al sistema
- **THEN** se declaran su token de superficie y su token de texto en `:root` y en `.dark`, y el test de contraste cubre sus pares canónicos

