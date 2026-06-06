## MODIFIED Requirements

### Requirement: Cuota IA aplica a todas las Edge Functions de IA

El sistema SHALL verificar la cuota IA **antes** de llamar a OpenAI y SHALL incrementar el contador **después** de una llamada exitosa, en **todas** las Edge Functions de IA del proyecto: `ai-insights`, `ai-prediccion`, `ai-resumen`, `ai-simulador` (counter `'queries'`) y `fair-advisor` (counter `'advice'`).

El incremento SHALL realizarse mediante el RPC atómico `rpc_increment_ai_usage` (no read-modify-write desde el cliente).

#### Scenario: fair-advisor bloqueado al exceder cuota de advice

- **GIVEN** un usuario `gratis` con `ai_advice_used = 3` (límite = 3)
- **WHEN** llama a `fair-advisor`
- **THEN** la función retorna HTTP 429 con `{ ok: false, error: 'quota_exceeded' }`

#### Scenario: fair-advisor procede cuando hay cuota disponible

- **GIVEN** un usuario `avanzado` con `ai_advice_used = 1` (límite = 10)
- **WHEN** llama a `fair-advisor`
- **THEN** la función procesa la solicitud y retorna resultado de IA, `ai_advice_used` queda en 2

#### Scenario: ai-insights bloqueado al exceder cuota de queries

- **GIVEN** un usuario `gratis` con `ai_queries_used = 5` (límite = 5)
- **WHEN** llama a `ai-insights`
- **THEN** la función retorna HTTP 429 con `{ ok: false, error: 'quota_exceeded' }`
