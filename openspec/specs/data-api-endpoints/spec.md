# data-api-endpoints Specification

> Synced from change `compras-proveedor-cuenta-corriente` — 2026-08-23

## Purpose

Endpoints REST del backend FastAPI para proveedores (ABM), con arquitectura de tres capas, validación Pydantic v2, guard de rol en el service, JWT-passthrough para RLS, y traducción de errores de negocio a respuestas HTTP estándar.

## Requirements

### Requirement: Endpoints REST de proveedores

El sistema SHALL exponer el ABM de proveedores como un router FastAPI por dominio (`/suppliers`) con las operaciones de listado, obtención por identificador, creación, edición y baja, siguiendo la arquitectura de tres capas del backend: el router valida el payload con schemas Pydantic v2 y resuelve dependencias, el service aplica el guard de rol de escritura, y el repository accede a los datos con JWT-passthrough para que la RLS por cuenta permanezca activa. El listado plano SHALL devolver los proveedores vivos de la cuenta ordenados por nombre, sin envelope de paginación, porque se consume como selector desde el formulario de compra y desde la pantalla de proveedores.

#### Scenario: Listado plano de proveedores como selector

- **WHEN** un usuario autenticado consulta `GET /suppliers`
- **THEN** recibe una lista plana de los proveedores vivos de su cuenta ordenados por nombre, apta para poblar un selector

#### Scenario: Alta de proveedor devuelve el recurso creado

- **WHEN** un usuario con rol de escritura crea un proveedor
- **THEN** la respuesta es 201 con el proveedor creado, incluyendo su identificador y sus atributos fiscales

#### Scenario: El guard de rol vive en el service

- **WHEN** un usuario sin rol de escritura invoca la creación, edición o baja de un proveedor
- **THEN** la solicitud es rechazada por el guard del service, y el router no contiene lógica de autorización propia

### Requirement: Los errores de negocio del guard de plan llegan traducidos

El sistema SHALL traducir los códigos de error de negocio emitidos por los guards de base de datos —incluido el guard de límite de proveedores por plan— a respuestas HTTP con el estado correcto y el formato de error estándar de la plataforma, en lugar de degradarlos a un error genérico de servidor. Un código de error de negocio sin mapeo SHALL considerarse un defecto.

#### Scenario: Alcanzar el límite de proveedores responde 403

- **GIVEN** una cuenta que ya alcanzó el límite de proveedores de su plan efectivo
- **WHEN** intenta crear un proveedor por la API
- **THEN** la respuesta es 403 con el formato de error estándar, y el mensaje del guard llega al cliente

#### Scenario: El mapeo cubre el código antes de que exista superficie que lo dispara

- **WHEN** se inspecciona la tabla de mapeo de códigos de negocio a estados HTTP
- **THEN** el código del guard de límite de proveedores está presente, con una prueba que lo verifica
