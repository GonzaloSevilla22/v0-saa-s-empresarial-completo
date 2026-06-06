## ADDED Requirements

### Requirement: Límite de sucursales por plan

El sistema SHALL leer `plan_limits.max_branches` para cada plan y rechazar la creación de sucursales que supere el cupo. El límite SHALL ser 0 para `gratis`, `inicial` y `avanzado`; 3 para `pro`.

#### Scenario: `usePlanLimits()` expone `maxBranches`

- **GIVEN** un usuario con plan efectivo 'pro'
- **WHEN** el componente llama a `usePlanLimits()`
- **THEN** el objeto retornado incluye `maxBranches: 3`

#### Scenario: `usePlanLimits()` retorna `maxBranches: 0` para planes sin sucursales

- **GIVEN** un usuario con plan efectivo 'avanzado'
- **WHEN** el componente llama a `usePlanLimits()`
- **THEN** el objeto retornado incluye `maxBranches: 0`

#### Scenario: Seed de `plan_limits` incluye `max_branches`

- **GIVEN** la tabla `plan_limits` correctamente seedeada
- **WHEN** se consulta `SELECT max_branches FROM plan_limits WHERE plan = 'pro'`
- **THEN** retorna 3

#### Scenario: UI oculta módulo de sucursales para planes sin cupo

- **GIVEN** un usuario con plan 'avanzado' (max_branches = 0)
- **WHEN** navega al sidebar principal
- **THEN** el item de menú "Sucursales" no está presente en el DOM (no solo oculto con CSS)
