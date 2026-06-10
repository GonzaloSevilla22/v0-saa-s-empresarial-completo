# Design: v20-fiscal-identity-clients (C-22)

## Context

`clients` hoy: `id, user_id, account_id, company_id, name, email, phone, created_at` (+ campos UX). El backend FastAPI ya opera con `account_id` como tenancy (post C-19) en las 3 capas (router → service → repository), y el frontend consume `/clients` vía `pythonClient` + React Query (`use-clients.ts`). El modelo V2 define `FiscalIdentity` como Value Object compartido entre Customer y Supplier (DEC-18); `suppliers` ya tiene un esquema fiscal de referencia. C-27 (AFIP, DEC-22) necesitará estos datos para emitir comprobantes.

## Goals / Non-Goals

**Goals**
- Persistir CUIT/DNI, condición IVA y razón social del cliente, opcionales de punta a punta (DB → API → UI).
- Validación de CUIT (dígito verificador módulo 11) en el frontend; validación de dominio (`Literal` de condiciones IVA) en el endpoint.
- Cero fricción agregada al alta rápida de clientes (los campos viven en una sección secundaria del form).

**Non-Goals**
- No se crea tabla/VO `fiscal_identities` separada (DEC-18: revisión solo si el solapamiento cliente/proveedor supera ~20%).
- No se valida CUIT contra el padrón AFIP (eso es C-27, WSFE).
- No se normaliza el esquema fiscal de `suppliers` ni se agrega `counterpartRef` (fuera de scope).
- No hay backfill: clientes históricos quedan NULL (= consumidor final sin identificar).

## Decisions

1. **Columnas inline en `clients`, no tabla aparte** — `FiscalIdentity` es un VO sin identidad propia; inline evita JOINs en el hot path de listado. Alternativa descartada: tabla `fiscal_identities` compartida — prematura per DEC-18.
2. **`tax_id` como TEXT libre con validación en frontend, no CHECK de formato en DB** — el campo acepta CUIT (`NN-NNNNNNNN-N`) o DNI (7-8 dígitos); un CHECK rígido en DB rompería el caso DNI y complicaría imports CSV. El CHECK de DB queda solo para `iva_condition` (dominio cerrado de 4 valores).
3. **Validación CUIT solo si el input matchea el patrón CUIT** — si el usuario carga un DNI, se acepta sin dígito verificador. Si carga algo con forma de CUIT, el módulo 11 es obligatorio. Pesos `5,4,3,2,7,6,5,4,3,2`, dígito `11 - (suma mod 11)` con `11→0`, `10→9`.
4. **`iva_condition` como `Literal` Pydantic en `ClientCreate`/`ClientUpdate`** — rechaza 422 antes de tocar la DB (regla dura del backend); el CHECK de DB es red de seguridad para escrituras que no pasan por la API (imports, SQL directo).
5. **`ClientUpdate.model_dump(exclude_none=True)` se mantiene** — consecuencia aceptada: no se puede *borrar* un dato fiscal vía PUT (NULL explícito se filtra). Aceptable en V2.0; si se necesita clearing, se resolverá con PATCH semántico en un change posterior.
6. **Migración aditiva idempotente** — `ADD COLUMN IF NOT EXISTS` para las 3 columnas (nullable, sin DEFAULT → sin rewrite de tabla ni lock significativo). El CHECK de `iva_condition` nace con la columna nueva (todas las filas existentes quedan NULL, que el CHECK permite), por lo que no requiere `NOT VALID`.

## Risks / Trade-offs

- [Drift entre `Literal` Pydantic y CHECK de DB] → ambos se definen en este change con la misma lista; test de integración cubre el rechazo en ambas capas.
- [El form ya tiene campos no persistidos (`status`, `category`)] → los campos fiscales nuevos SÍ viajan por la mutación; no se toca el comportamiento legacy de `status`/`category` (deuda preexistente, fuera de scope).
- [CSV import de clientes no incluye campos fiscales] → `client-import-dialog.tsx` no se toca; los imports siguen creando clientes sin identidad fiscal (válido por diseño).

## Migration Plan

1. Migración SQL aditiva (`npx supabase db push` al proyecto `gxdhpxvdjjkmxhdkkwyb` — nunca el MCP `apply_migration`).
2. Deploy backend (Render) — campos opcionales: compatible con frontend viejo.
3. Deploy frontend (Vercel) — el form nuevo escribe los campos; lecturas viejas ignoran claves extra.
4. Rollback: revertir deploys; las columnas pueden quedar (nullable, inofensivas) — no se dropea en rollback.

## Open Questions

Ninguna — PA no aplica a este change (BAJO, sin dependencias).
