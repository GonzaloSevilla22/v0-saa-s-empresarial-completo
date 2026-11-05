## MODIFIED Requirements

### Requirement: Cuota IA aplica a todas las Edge Functions de IA (C-04)

El sistema SHALL verificar la cuota IA **antes** de llamar a OpenAI y SHALL incrementar el contador **después** de una llamada exitosa, en **todas** las Edge Functions de IA del proyecto: `ai-insights`, `ai-comparativo`, `ai-precio`, `ai-prediccion`, `ai-rentabilidad`, `ai-resumen`, `ai-simulador` (counter `'queries'`) y `fair-advisor` (counter `'advice'`). La Edge Function `invoice-ocr` SHALL quedar gobernada por la cuota de lecturas de factura (counter `'ocr'`, capability `invoice-ocr-budget`): en lugar del par verificar-antes / incrementar-después, SHALL **reservar** el cupo de forma atómica con `rpc_reserve_ai_usage('ocr')` antes de llamar a OpenAI.

El incremento SHALL realizarse mediante el RPC atómico `rpc_increment_ai_usage` (no read-modify-write desde el cliente), salvo para `invoice-ocr`, cuyo incremento ocurre dentro de la reserva atómica.

El límite contra el que se compara el contador SHALL corresponder al **plan efectivo de la cuenta**, resuelto según la definición normativa de la base de datos. La verificación de cuota NOT SHALL derivar el plan de `public.profiles`.

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

#### Scenario: El límite de la cuenta que pagó corresponde a su plan pagado

- **GIVEN** una cuenta con `accounts.billing_plan = 'pro'` cuyo registro en `profiles` conserva `'gratis'`, y un miembro con `ai_queries_used = 10`
- **WHEN** ese miembro llama a una Edge Function de IA
- **THEN** la llamada es procesada, porque el contador se compara contra el límite de `'pro'` (300) y no contra el de `'gratis'` (5)

#### Scenario: invoice-ocr reserva antes de llamar a OpenAI

- **GIVEN** un usuario `gratis` con `ai_ocr_used = 5` (límite = 5)
- **WHEN** llama a `invoice-ocr`
- **THEN** la función retorna HTTP 429 con `{ ok: false, error: 'quota_exceeded' }` sin llamar a OpenAI, y `ai_queries_used` no cambia
