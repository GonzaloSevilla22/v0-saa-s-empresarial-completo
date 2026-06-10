## ADDED Requirements

### Requirement: Persistencia de identidad fiscal del cliente
La tabla `clients` SHALL incluir tres columnas opcionales (nullable): `tax_id TEXT` (CUIT o DNI), `iva_condition TEXT` y `legal_name TEXT` (razón social). `iva_condition` MUST estar restringida por CHECK constraint a los valores `'responsable_inscripto'`, `'monotributista'`, `'exento'`, `'consumidor_final'`.

#### Scenario: Cliente sin datos fiscales sigue siendo válido
- **WHEN** se crea un cliente solo con `name`
- **THEN** la fila se persiste con `tax_id`, `iva_condition` y `legal_name` en NULL

#### Scenario: Condición IVA inválida es rechazada por la DB
- **WHEN** se intenta insertar un cliente con `iva_condition = 'inscripto_raro'`
- **THEN** el INSERT falla por violación del CHECK constraint

### Requirement: API de clientes acepta y devuelve identidad fiscal
Los schemas Pydantic `ClientCreate` y `ClientUpdate` SHALL aceptar `tax_id`, `iva_condition` y `legal_name` como campos opcionales, y `ClientOut` SHALL devolverlos. `iva_condition` MUST validarse en el endpoint (Pydantic `Literal` de los 4 valores permitidos) antes de tocar la DB.

#### Scenario: Crear cliente con identidad fiscal completa
- **WHEN** se hace POST `/clients` con `{"name": "ACME SRL", "tax_id": "30-71234567-1", "iva_condition": "responsable_inscripto", "legal_name": "ACME S.R.L."}`
- **THEN** la respuesta 201 incluye los tres campos fiscales persistidos

#### Scenario: Crear cliente sin identidad fiscal
- **WHEN** se hace POST `/clients` con `{"name": "Juan Pérez"}`
- **THEN** la respuesta 201 devuelve `tax_id`, `iva_condition` y `legal_name` en `null`

#### Scenario: Condición IVA inválida rechazada en el endpoint
- **WHEN** se hace POST `/clients` con `iva_condition = "otro"`
- **THEN** la API responde 422 sin tocar la DB

#### Scenario: Actualizar solo los datos fiscales
- **WHEN** se hace PUT `/clients/{id}` con `{"tax_id": "20-12345678-6", "iva_condition": "monotributista"}`
- **THEN** la respuesta 200 refleja los campos fiscales actualizados y `name`/`email`/`phone` quedan intactos

### Requirement: Validación de CUIT en el frontend
El frontend SHALL validar el formato de CUIT con la expresión `^\d{2}-\d{8}-\d{1}$` y verificar el dígito verificador con el algoritmo módulo 11 (pesos `5,4,3,2,7,6,5,4,3,2`; dígito = `11 - (suma mod 11)`, con `11 → 0` y `10 → 9`). Un `tax_id` que no matchee el formato CUIT (p. ej. un DNI de 7-8 dígitos) SHALL aceptarse sin verificación de dígito, pero un CUIT con formato correcto y dígito verificador inválido MUST bloquear el submit.

#### Scenario: CUIT válido
- **WHEN** el usuario ingresa `30-71234567-1` (dígito verificador correcto para ese prefijo)
- **THEN** `isValidCuit` devuelve `true` y el formulario permite guardar

#### Scenario: CUIT con dígito verificador incorrecto
- **WHEN** el usuario ingresa `20-12345678-9` (el dígito correcto es 6)
- **THEN** `isValidCuit` devuelve `false`, el formulario muestra error y no envía la mutación

#### Scenario: DNI aceptado sin verificación
- **WHEN** el usuario ingresa `12345678` como CUIT/DNI
- **THEN** el formulario lo acepta como identificador sin verificación de dígito

### Requirement: Captura de datos fiscales en el formulario de cliente
El formulario de cliente SHALL ofrecer una sección "Datos fiscales" con los campos opcionales CUIT/DNI, Condición IVA (select con las 4 opciones + vacío) y Razón social, tanto en alta como en edición. El hook `use-clients` SHALL mapear los tres campos entre la API y el tipo `Client`.

#### Scenario: Alta de cliente con datos fiscales
- **WHEN** el usuario completa nombre + CUIT válido + condición IVA y guarda
- **THEN** la mutación envía `tax_id`, `iva_condition` y `legal_name` a la API y el cliente listado refleja los datos

#### Scenario: Edición preserva datos fiscales existentes
- **WHEN** el usuario abre un cliente con identidad fiscal cargada
- **THEN** la sección "Datos fiscales" muestra los valores persistidos
