## MODIFIED Requirements

### Requirement: Página `/rentabilidad` con tabla, gráfico y análisis IA

El sistema SHALL proveer la página `/rentabilidad` con:
- Tabla de productos ordenada por `gross_margin_pct` (desc), mostrando nombre, revenue, costo, margen %, unidades vendidas
- Bar chart horizontal (Recharts) con los top 10 productos por margen
- Panel con el último insight IA (type=`'margen'`) y botón "Analizar con IA"
- **Botón "Sugerir precio IA" en cada fila de la tabla**, que abre el `PriceSuggestionModal` para ese producto
- Gating: solo accesible para `'avanzado'` y `'pro'`; para planes inferiores muestra `<PlanGate requiredPlan="avanzado" />`

#### Scenario: Usuario avanzado ve la tabla de rentabilidad completa con botón de precio

- **GIVEN** un usuario con plan efectivo `'avanzado'`
- **WHEN** navega a `/rentabilidad`
- **THEN** ve la tabla con sus productos ordenados por margen, el gráfico de barras, el panel de análisis IA y el botón "Sugerir precio IA" en cada fila

#### Scenario: Usuario gratis ve el componente de upgrade en lugar del contenido

- **GIVEN** un usuario con plan efectivo `'gratis'`
- **WHEN** navega a `/rentabilidad`
- **THEN** ve el componente `PlanGate` con el mensaje de upgrade y un CTA al plan Avanzado; el contenido real no se renderiza

#### Scenario: Botón "Analizar con IA" llama a la Edge Function y muestra el insight

- **GIVEN** un usuario avanzado con cuota disponible en la página `/rentabilidad`
- **WHEN** hace clic en "Analizar con IA"
- **THEN** se llama a `ai-rentabilidad`, el botón muestra estado de carga, y al completarse aparece el análisis en el panel

#### Scenario: Período de análisis respeta el historial máximo del plan

- **GIVEN** un usuario con plan `'inicial'` (12 meses de historial)
- **WHEN** carga `/rentabilidad` con el período por defecto
- **THEN** el RPC solo incluye ventas dentro del rango permitido por el plan

#### Scenario: Botón "Sugerir precio IA" abre el modal con el producto correcto

- **GIVEN** un usuario avanzado en la tabla de `/rentabilidad`
- **WHEN** hace clic en "Sugerir precio IA" en la fila del producto "Medialunas"
- **THEN** se abre el `PriceSuggestionModal` con `productName = "Medialunas"` y comienza a cargar la sugerencia
