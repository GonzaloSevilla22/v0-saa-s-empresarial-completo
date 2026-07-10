# units-of-measure

## Purpose

Catálogo de unidades de medida tipadas (Modelo V3 §7.1), mixto global (`is_system = true`, visible a todo tenant) + per-tenant (`account_id`), con factor de conversión relativo a la unidad base del mismo `type`. Este capability formaliza como contrato un invariante que ya está garantizado físicamente en la base de datos (`units_of_measure.type NOT NULL` + `CHECK`) — no introduce DDL nuevo. Habilita la futura conversión entre unidades del mismo tipo (capability V3.5, p. ej. comprar por kg / vender por unidad) sin requerir una migración adicional.

## Requirements

### Requirement: Toda unidad de medida porta un tipo semántico

El sistema SHALL exigir que cada fila de `units_of_measure` tenga un `type` no nulo perteneciente al conjunto cerrado vigente (`unit`, `weight`, `volume`, `length`, `custom`), donde `weight` representa peso, `volume` representa volumen y `unit` representa conteo/contable. Este contrato ya está garantizado por la restricción `NOT NULL` + `CHECK` sobre la columna `type`; este cambio lo formaliza sin modificar el esquema.

#### Scenario: Alta de unidad sin tipo es rechazada

- **WHEN** se intenta insertar una unidad de medida sin `type` (o con un valor fuera del conjunto permitido)
- **THEN** la base de datos rechaza la operación por violación de `NOT NULL` o del `CHECK` de `type`

#### Scenario: Toda unidad del sistema ya está tipada

- **WHEN** se listan las unidades con `is_system = true`
- **THEN** todas tienen un `type` no nulo dentro del conjunto permitido (invariante ya vigente en producción: 10 unidades del sistema tipadas)

### Requirement: Catálogo mixto global y por tenant

El sistema SHALL exponer un catálogo de unidades **mixto**: las unidades del sistema (`is_system = true`) son globales y visibles para todo tenant, mientras que las unidades creadas por un tenant (`is_system = false`, con `account_id`) son visibles y editables solo dentro de ese tenant. La visibilidad y la escritura SHALL respetar la RLS org-based ya vigente (`is_system = true OR account_id IN current_account_ids()` para lectura; `is_system = false AND account_id IN current_account_ids()` para escritura).

#### Scenario: Un tenant ve las unidades del sistema

- **WHEN** un usuario autenticado de cualquier cuenta lista las unidades de medida
- **THEN** recibe todas las unidades del sistema (`is_system = true`) más las propias de su cuenta

#### Scenario: Un tenant no puede modificar unidades del sistema ni de otra cuenta

- **WHEN** un usuario intenta actualizar o borrar una unidad con `is_system = true`, o una unidad de otra cuenta
- **THEN** la operación es rechazada por RLS (no afecta ninguna fila)

### Requirement: El factor de conversión es relativo a la unidad base del mismo tipo

El sistema SHALL interpretar `factor` como el múltiplo de la unidad base del **mismo** `type` (referenciada por `base_unit_id`). La conversión entre unidades (capability V3.5) SHALL operar únicamente entre unidades que comparten `type`; convertir entre tipos distintos (p. ej. peso ↔ volumen) NO está definido y no debe intentarse sin una densidad u otra relación fuera de este catálogo.

#### Scenario: Conversión solo dentro del mismo tipo

- **WHEN** una futura conversión (V3.5) recibe dos unidades de `type` distinto
- **THEN** la conversión no está definida y el sistema no debe producir un resultado silencioso (rechaza o exige una relación explícita fuera del catálogo)

#### Scenario: Factor relativo a la base

- **WHEN** una unidad no base declara `base_unit_id` y `factor`
- **THEN** `factor` expresa cuántas unidades base equivalen a una de esta unidad, y ambas comparten `type`
