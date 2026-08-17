## ADDED Requirements

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

## MODIFIED Requirements

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
