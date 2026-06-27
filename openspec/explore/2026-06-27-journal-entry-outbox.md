# Exploración: journal-entry-outbox — Contabilidad de partida doble vía outbox

> **Tipo:** Exploración (modo thinking — sin implementación)
> **Fecha:** 2026-06-27
> **Proyecto:** EmprendeSmart (EIE) — Supabase project `gxdhpxvdjjkmxhdkkwyb`
> **Contexto:** V2.5 Finanzas, 2do change (prereq: `cost-center-dimension` ✅ live)
> **Scope:** Mapear el espacio de diseño completo de `journal-entry-outbox`, con recomendaciones por decisión y preguntas abiertas para el PO.

---

## 1. Contexto: qué existe y qué falta

### Estado del outbox (C-25, live)

El relay está activo en pg_cron (`relay-process-outbox`, cada minuto) invocando `rpc_process_outbox_dispatch(100)`. Dos consumers:

```
events (processed_at IS NULL)
    │
    ├─► AuditLog  → INSERT audit_logs         (todo tipo de evento)
    └─► Email     → INSERT email_logs          (solo 3 tipos: sale_created, stock_adjusted, plan_changed)
```

**Patrón clave**: el dispatch es **pure-SQL plpgsql** dentro de una función `SECURITY DEFINER`. Sin HTTP, sin Render, sin cold starts. Cada evento tiene sub-bloque `BEGIN/EXCEPTION/END` (aislamiento por evento). Idempotencia por `(event_id, consumer_type)` en `operation_idempotency`.

### Eventos ya emitidos al outbox (producers live)

| Evento | Emitido en | aggregate_type |
|--------|-----------|----------------|
| `SaleConfirmed` | `_c29_confirm_order_core` (migr. C-29) | `SalesOrder` |
| `PurchaseCreated` | `rpc_create_purchase_operation` (C-25 backend) | `Purchase` |
| `StockAdjusted` | `rpc_apply_product_stock_delta` (C-25 backend) | `BranchStock` |
| `PaymentReceived` | `rpc_register_payment_received` (C-30) | `CustomerAccount` |
| `SupplierPaymentMade` | `rpc_register_payment_made` (C-30) | `SupplierAccount` |
| `SupplierCharge` | `rpc_register_supplier_charge` (C-30) | `SupplierAccount` |

Pendientes (no emitidos aún):
- `FiscalDocumentIssued` — C-27 emite el CAE, pero no insertan en `events`
- `CashSessionOpened`, `CashSessionClosed` — C-28 no emite aún
- `CreditNoteIssued` — no existe producer

### Lo que agrega `cost-center-dimension` (prereq ✅)

- Tabla `cost_centers` (id, account_id, name, code, is_active)
- Columnas `cost_center_id` nullable en `expenses` y `purchases`
- `rpc_create_purchase_operation` ya la acepta y propaga a todas las líneas

Esto es exactamente el `CostCenterId` que `JournalLine.costCenter` necesita.

---

## 2. El modelo de dominio que hay que construir

Del `modelo-dominio-aliadata-v2.md` §5.6:

```
JournalEntry (root)
│   id, postedAt, source=DocumentRef, post(), reverse()
└── *-- JournalLine (value objects, partida doble)
        account: AccountCode       ← FK a un plan de cuentas
        costCenter: CostCenterId   ← nullable FK a cost_centers
        side: Debit | Credit
        amount: Money
```

**Invariante de oro**: toda entrada debe balancear — `SUM(amount WHERE side=Debit) = SUM(amount WHERE side=Credit)`.

---

## 3. Espacio de diseño — Análisis por tema

### 3.1 Plan de cuentas (chart of accounts)

Este es el corazón del problema. Tres opciones:

```
OPCIÓN A — Hardcoded (sin tabla)
══════════════════════════════════════════════════════

  "1100" → "Caja"          (ASSET)
  "1200" → "Banco"         (ASSET)
  "1300" → "Deudores"      (ASSET)
  "2100" → "Proveedores"   (LIABILITY)
  "4100" → "Ventas"        (INCOME)
  "4200" → "IVA Débito"    (LIABILITY)
  "5100" → "Compras/COGS"  (EXPENSE)
  "5200" → "IVA Crédito"   (ASSET)
  "5300" → "Gastos"        (EXPENSE)
  "5400" → "Sueldos"       (EXPENSE)

  Ventajas:
  ✓ Cero migración adicional
  ✓ Cero UI para gestionar cuentas
  ✓ Las reglas de mapping son simples (CASE estático)
  
  Desventajas:
  ✗ El PO no puede personalizar sin un change nuevo
  ✗ No cumple con un plan de cuentas argentino "real"
    (FACPCE, resolución técnica 19 o variante PYME)
  ✗ Fija el código en el payload de cada JournalLine —
    si cambia hay que reescribir entradas históricas

OPCIÓN B — Tabla seeded por cuenta (config editable)
══════════════════════════════════════════════════════

  CREATE TABLE chart_of_accounts (
    id         uuid PK,
    account_id uuid FK accounts,  ← RLS por cuenta
    code       text NOT NULL,
    name       text NOT NULL,
    type       text CHECK(type IN ('asset','liability','equity','income','expense')),
    is_active  boolean DEFAULT true,
    UNIQUE(account_id, code)
  );

  Al crear la cuenta (onboarding) → seed de un plan
  mínimo argentino (50-80 cuentas).
  
  Ventajas:
  ✓ El contador puede personalizar
  ✓ Exportable a software contable externo (Tango, Bejerman)
  ✓ Extensible: agregar cuentas sin un change
  
  Desventajas:
  ✗ Requiere seed en el onboarding
  ✗ Requiere UI básica de CRUD (o al menos lectura)
  ✗ La tabla FK desde journal_lines puede desincronizarse

OPCIÓN C — AccountCode como texto (sin tabla FK)
══════════════════════════════════════════════════════

  journal_lines.account_code text NOT NULL
  (sin FK, sin tabla maestra por ahora)

  Las cuentas son "convención de código": 1100, 4100, etc.
  Se documenta en una tabla de referencia (no FK).
  
  Ventajas:
  ✓ Máxima flexibilidad: permite que el PO defina los
    códigos sin migrar la tabla FK
  ✓ Los reportes hacen GROUP BY account_code
  
  Desventajas:
  ✗ Sin integridad referencial
  ✗ Errores de tipeo pasan sin control
```

**Recomendación para V1**: **Opción A + Opción C** combinadas. El mapping de eventos a cuentas usa un conjunto fijo de `~10 códigos` hardcodeados en la función plpgsql (CASE). `journal_lines` almacena `account_code TEXT` sin FK. Si en V2 se quiere la tabla maestra, se migra la FK sin tocar los datos. Esto es lo que ERP medianos llaman "libro diario simplificado para PYME".

La Opción B tiene futuro pero su UI/seed es scope de V2.6 o un change dedicado `chart-of-accounts-ui`.

---

### 3.2 Reglas de mapping evento → asiento (el núcleo)

Para Argentina: Factura A/B divide neto + IVA. Factura C va a precio total (no discrimina IVA). El campo `fiscal_documents.neto` / `iva_amount` ya existe (agregado por `fiscal-receptor-iva-relay`).

```
╔══════════════════════════════════════════════════════════════════╗
║  EVENTO: SaleConfirmed (pago cash)                               ║
║                                                                  ║
║  Factura C (Monotributista):                                     ║
║    DÉBITO  1100 Caja           total                             ║
║    CRÉDITO 4100 Ventas         total                             ║
║                                                                  ║
║  Factura A/B (Responsable Inscripto):                            ║
║    DÉBITO  1100 Caja           total                             ║
║    CRÉDITO 4100 Ventas         neto                              ║
║    CRÉDITO 4200 IVA Débito     iva_amount                        ║
║                                                                  ║
║  Pago en cuenta corriente (payment_method='credit'):             ║
║    DÉBITO  1300 Deudores ctes  total                             ║
║    CRÉDITO 4100 Ventas         neto  (+ 4200 IVA si A/B)         ║
╚══════════════════════════════════════════════════════════════════╝

╔══════════════════════════════════════════════════════════════════╗
║  EVENTO: FiscalDocumentIssued                                    ║
║  (si la venta ya generó asiento en SaleConfirmed, este          ║
║   evento puede ser un no-op o registrar solo el CAE)             ║
║                                                                  ║
║  PROBLEMA: ¿duplicación con SaleConfirmed?                       ║
║  Ver decisión 3.3 para la resolución.                            ║
╚══════════════════════════════════════════════════════════════════╝

╔══════════════════════════════════════════════════════════════════╗
║  EVENTO: PurchaseReceived                                        ║
║                                                                  ║
║  DÉBITO  5100 Compras/COGS     neto  (o total si no hay IVA CF)  ║
║  DÉBITO  5200 IVA Crédito      iva_amount (si corresponde)       ║
║  CRÉDITO 2100 Proveedores      total                             ║
╚══════════════════════════════════════════════════════════════════╝

╔══════════════════════════════════════════════════════════════════╗
║  EVENTO: PaymentReceived                                         ║
║  (cliente paga su cuenta corriente)                              ║
║                                                                  ║
║  DÉBITO  1100 Caja             amount                            ║
║  CRÉDITO 1300 Deudores ctes    amount                            ║
╚══════════════════════════════════════════════════════════════════╝

╔══════════════════════════════════════════════════════════════════╗
║  EVENTO: SupplierPaymentMade                                     ║
║  (pago al proveedor)                                             ║
║                                                                  ║
║  DÉBITO  2100 Proveedores      amount                            ║
║  CRÉDITO 1100 Caja             amount                            ║
╚══════════════════════════════════════════════════════════════════╝

╔══════════════════════════════════════════════════════════════════╗
║  EVENTO: CashSessionClosed                                       ║
║  (cierre Z de caja — diferencia de arqueo)                       ║
║                                                                  ║
║  Si diferencia > 0 (sobrante):                                   ║
║    DÉBITO  1100 Caja             diferencia                      ║
║    CRÉDITO 5999 Diferencias caja diferencia                      ║
║                                                                  ║
║  Si diferencia < 0 (faltante):                                   ║
║    DÉBITO  5999 Diferencias caja ABS(diferencia)                 ║
║    CRÉDITO 1100 Caja             ABS(diferencia)                 ║
║                                                                  ║
║  Nota: el "cierre" de caja mueve el total a un resultado.        ║
║  En realidad la mayoría de las PYMEs no registran el cierre Z    ║
║  contablemente — es un control operativo.                        ║
╚══════════════════════════════════════════════════════════════════╝

╔══════════════════════════════════════════════════════════════════╗
║  EVENTO: CreditNoteIssued (reversión)                            ║
║                                                                  ║
║  Espejo del asiento de la venta original (reverse()).            ║
║  journal_entries.reversal_of = id_del_asiento_original           ║
╚══════════════════════════════════════════════════════════════════╝
```

**Dónde viven las reglas**: En V1 recomiendo mantenerlas **en la función plpgsql** (`rpc_process_journal_entries` o como extensión a `rpc_process_outbox_dispatch`). Hay 6-8 tipos de evento × 3-4 líneas cada uno ≈ 30-40 CASE branches — manejable en SQL. Si llega a 15+ tipos diferentes con lógica compleja (percepciones, etc.), mover a Python backend. El momento de escape natural es cuando el mapping necesita consultar tablas externas (tipo de IVA por producto, exenciones, etc.).

---

### 3.3 Eventos que generan asiento en V1 vs deferred

**Problema clave**: `SaleConfirmed` y `FiscalDocumentIssued` pueden dispararse en la misma transacción (venta con factura inmediata) o secuencialmente (venta `pending_cae` → CAE async → emisión). Si ambos generan asiento, se duplica el ingreso.

```
FLUJO VENTA+FACTURA:
                                    
  _c29_confirm_order_core()
  ├── stock δ (sync)
  ├── cash_movement (sync)
  ├── rpc_emit_pending_cae (sync, si el PV tiene AFIP configurado)
  │     → INSERT fiscal_documents (status: pending_cae)
  │     → relay-process-pending-cae → WSFE → fiscal_documents(status: issued)
  │     → Acá debería emitirse FiscalDocumentIssued al outbox
  └── INSERT events (SaleConfirmed)
  
  DECISIÓN de mapping en V1:
  
  Opción A (recomendada):
    SaleConfirmed → genera el asiento contable SIEMPRE
    FiscalDocumentIssued → NO genera asiento (solo audit)
    Razón: la venta ocurrió aunque el CAE tarde; la contabilidad
    refleja el hecho económico, no el trámite fiscal.
  
  Opción B:
    FiscalDocumentIssued → genera el asiento (con neto+IVA exactos)
    SaleConfirmed → NO genera asiento
    Riesgo: ventas sin CAE (monotributistas) nunca tendrían asiento.
```

**Scope de V1 recomendado**:

| Evento | V1 | Razón |
|--------|-----|-------|
| `SaleConfirmed` | ✅ | El más importante — toda venta genera asiento |
| `PurchaseReceived`/`PurchaseCreated` | ✅ | Simétrico; IVA Crédito Fiscal |
| `PaymentReceived` | ✅ | Cancela deudor contra caja |
| `SupplierPaymentMade` | ✅ | Cancela proveedor contra caja |
| `FiscalDocumentIssued` | ⚠️ | Depende de DEC-PO-1 (ver abajo) — recomiendo NO en V1 |
| `CreditNoteIssued` | ✅ | Reversión automática — sin ella el libro queda incompleto |
| `CashSessionClosed` | ❌ defer | Diferencias de arqueo son operativas; no todos los contadores las asientan |
| `SupplierCharge` | ❌ defer | Cargo manual al proveedor; cubre menos del 5% de casos |
| `StockAdjusted` | ❌ defer | Los ajustes de inventario requieren cuenta "Variación de Inventario" que muchas PYMEs no usa |

---

### 3.4 Consumer: pure-SQL plpgsql vs Python backend

```
CRITERIO DE DECISIÓN:
══════════════════════════════════════════════════════════════

¿El consumer puede hacer su trabajo con solo:
  (a) El payload de events,
  (b) UNAs pocas queries simples, y
  (c) INSERTs en journal_entries + journal_lines?

Si SÍ → pure-SQL plpgsql (como AuditLog en C-25).
Si NO → Python backend.

ANÁLISIS para JournalEntry:

  ✓ El payload de SaleConfirmed ya tiene: total, payment_method,
    client_id, branch_id. Falta: neto + iva_amount.
    → Requiere JOIN a fiscal_documents para obtener neto/iva.
    → UNA query de lookup: manejable en plpgsql.
  
  ✓ PurchaseReceived payload tiene: total, branch_id, cost_center_id.
    Falta: neto + iva para determinar IVA CF.
    → Requiere JOIN a purchases para el desglose.
    
  ✓ El mapping es un CASE estático (6-8 ramas) en plpgsql.
  
  ✓ El balanceo (SUM debit = SUM credit) se puede verificar
    con un CHECK o con un ASSERT en la función.
  
  ✓ Los INSERTs finales son en journal_entries + journal_lines.
  
VEREDICTO: Pure-SQL plpgsql es viable para V1.

El umbral de escape a Python sería:
  - Más de 15 tipos de evento con lógica distinta
  - Necesidad de llamar APIs externas durante el posting
  - Lógica de distribución de costos porcentual (jerarquía de CC)
  - Tests de lógica de mapping que son más fáciles en pytest que en SQL

CONSIDERACIÓN PRÁCTICA:
  Pure-SQL significa el mapping de cuentas vive dentro de
  rpc_process_outbox_dispatch (o un helper que llama).
  Puede crecer y volverse difícil de mantener.
  
  ALTERNATIVA: consumer separado en la misma función SQL.
  rpc_process_outbox_dispatch ya tiene el patrón:
    Consumer 1: AuditLog
    Consumer 2: EmailNotification
    Consumer 3: JournalEntry  ← NUEVO
    ...
  
  O una función dedicada rpc_post_journal_entries que el
  relay llama como un tercero, manteniendo separación.
```

**Recomendación**: Pure-SQL con una función helper dedicada `rpc_post_journal_entry(event)` llamada desde `rpc_process_outbox_dispatch` como Consumer 3. La función helper puede vivir en la misma migración. Cuando el mapping supere 10 eventos, migrarlo a Python.

---

### 3.5 Schema propuesto

```sql
-- Tabla principal de asientos
CREATE TABLE journal_entries (
  id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id     uuid        NOT NULL REFERENCES accounts(id),
  posted_at      timestamptz NOT NULL DEFAULT now(),
  source_event_id uuid       NULL REFERENCES events(id),  -- idempotencia
  source_doc_ref  jsonb      NULL,  -- {'type':'SalesOrder','id':'...'}
  status         text        NOT NULL DEFAULT 'posted'
                             CHECK (status IN ('posted','reversed')),
  reversal_of    uuid        NULL REFERENCES journal_entries(id),
  created_at     timestamptz NOT NULL DEFAULT now()
);

-- Líneas de asiento (partida doble)
CREATE TABLE journal_lines (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  entry_id         uuid        NOT NULL REFERENCES journal_entries(id)
                               ON DELETE CASCADE,
  account_code     text        NOT NULL,  -- '1100', '4100', etc. (sin FK en V1)
  cost_center_id   uuid        NULL REFERENCES cost_centers(id) ON DELETE SET NULL,
  side             text        NOT NULL CHECK (side IN ('debit','credit')),
  amount           numeric(15,2) NOT NULL CHECK (amount > 0),
  description      text        NULL
);

-- Invariante de balance (CHECK a nivel entrada)
-- Implementado como un ASSERT en la función de posting,
-- NO como CHECK en la tabla (porque el CHECK no puede
-- hacer subqueries en Postgres).
-- La función verifica SUM(debit) = SUM(credit) antes de commitear.

-- Índices
CREATE INDEX journal_entries_account_id_posted_at ON journal_entries (account_id, posted_at DESC);
CREATE INDEX journal_entries_source_event_id ON journal_entries (source_event_id) WHERE source_event_id IS NOT NULL;
CREATE INDEX journal_lines_entry_id ON journal_lines (entry_id);
CREATE INDEX journal_lines_account_code ON journal_lines (account_code, entry_id);
```

**Idempotencia**: `source_event_id` con `UNIQUE(source_event_id)` (parcial `WHERE source_event_id IS NOT NULL`) garantiza que un evento genera a lo sumo un asiento. Compatible con el patrón `(event_id, consumer_type)` de C-25.

**RLS**: `journal_entries` con SELECT by `account_id`. Sin INSERT/UPDATE policy para `authenticated` — escritura solo por la función SECURITY DEFINER (idéntico a `audit_logs`).

---

### 3.6 Propagación de cost_center_id

```
FUENTE → JournalLine.cost_center_id

SaleConfirmed:
  payload.branch_id existe → pero branch no es cost_center.
  La venta no tiene cost_center_id actualmente.
  Opciones:
  (a) NULL siempre en V1 para ventas → las líneas de ingreso
      no tienen CC, lo cual es correcto (el CC es de gastos).
  (b) Agregar cost_center_id al payload de SaleConfirmed
      (futuro — cuando el PO quiera imputar ingresos por CC).
  RECOMENDACIÓN: (a) — NULL para líneas de ingreso en V1.

PurchaseReceived:
  purchases.cost_center_id ya existe (cost-center-dimension).
  El payload de PurchaseCreated debería incluirlo.
  Si no está en el payload actual → la función puede hacer
  un SELECT a purchases para obtenerlo.
  RECOMENDACIÓN: agregar cost_center_id al payload del
  productor PurchaseCreated (mínimo cambio en el INSERT del evento).

Gastos (expenses):
  No tienen producer de evento aún. Para incluirlos en V1
  habría que agregar un evento GastoRegistrado al outbox.
  COMPLEJIDAD: moderada. ¿Está en scope de V1?
```

---

### 3.7 Reversión y notas de crédito

```
FLUJO DE REVERSIÓN:

  CreditNoteIssued
  ↓
  Consumer JournalEntry
  ↓
  1. Busca el JournalEntry original (source_event = SaleConfirmed del mismo sale)
  2. Crea un JournalEntry nuevo con:
     - reversal_of = id_del_asiento_original
     - status = 'posted' (la reversión también queda posted)
     - Líneas con debits/credits invertidos
  3. Marca el asiento original con status = 'reversed'

PROBLEMA: ¿Cómo relacionar CreditNoteIssued → SaleConfirmed original?
  El evento CreditNoteIssued debería incluir el sales_order_id original.
  La función puede consultar journal_entries.source_doc_ref
  para encontrar el asiento original.

COMPLEJIDAD: Media. Requiere que el producer de CreditNoteIssued
  sea diseñado correctamente con la referencia al documento original.
  El productor de CreditNoteIssued no existe aún.
```

---

### 3.8 Governance y señales de riesgo

```
ASSESSMENT:
  ✓ Los asientos se generan a partir de hechos ya commitados.
    No hay dinero que se mueva en este change.
  ✓ Si el consumer falla, el evento queda pending y se reintenta.
    El ERP no se ve afectado (outbox es asíncrono).
  
  ⚠ Los contadores pueden basarse en estos registros para declaraciones
    fiscales. Un asiento mal generado puede crear discrepancias.
  ⚠ La lógica de IVA (Factura A/B vs C) es fiscalmente sensible.
  ⚠ La reversión mal implementada puede crear descuadres en el libro.
  
GOVERNANCE RECOMENDADO: HIGH
  Razón: el libro diario generado puede ser utilizado por contadores
  y usarse como base para declaraciones impositivas. Aunque no mueve
  dinero, genera registros de auditoría con implicancias fiscales.
  Los asientos de IVA (DF/CF) son sensibles bajo RG AFIP.
  
  Requiere:
  - Sign-off del PO antes de cada etapa de implementación
  - Revisión de la lógica de mapping por alguien con conocimiento
    contable (al menos el PO validar los CASE de cuentas)
  - Tests que verifiquen SUM(debit) = SUM(credit) para cada tipo
```

---

### 3.9 Nuevas preguntas abiertas (PA-24 a PA-27)

**PA-24 — IVA en ventas: ¿Factura A/B discrimina IVA en el asiento?**
La tabla `fiscal_documents` ya tiene `neto` y `iva_amount` (desde `fiscal-receptor-iva-relay`). ¿Usamos esos campos cuando existen para generar un asiento con IVA discriminado, o en V1 simplificamos a una sola línea de ingreso?

**PA-25 — ¿Expenses genera asiento en V1?**
Los gastos (`expenses`) tienen `cost_center_id` desde `cost-center-dimension`. Un gasto debería generar:
- `DÉBITO 5300 Gastos / cost_center_id`
- `CRÉDITO 2100 Proveedores` (o `1100 Caja` si es pago inmediato)
¿Queremos un evento `ExpenseRegistered` en el outbox, o deferimos expenses al V1.5?

**PA-26 — Plan de cuentas mínimo argentino vs plan simplificado**
¿El PO quiere un plan de cuentas con códigos tipo FACPCE (1.1.01.01...) o alcanza con un plan simplificado de ~10 cuentas (1100 Caja, 4100 Ventas, etc.)? Impacta directamente si necesitamos una tabla `chart_of_accounts` o hardcodeamos los códigos.

**PA-27 — ¿Exportación a software contable en V1 o V2.6?**
Si el contador usa Tango/Bejerman/Colppy, ¿necesitan un export de journal_entries en formato Siiga/TXT en V1? Si sí, la tabla de cuentas necesita los códigos en el formato del software destino. Si es para V2.6, podemos usar códigos propios.

---

## 4. Decisiones para el PO (9 puntos, con recomendación)

### DEC-PO-1 — SaleConfirmed vs FiscalDocumentIssued como fuente del asiento

**Contexto**: La venta genera `SaleConfirmed` en el outbox. Si el org tiene AFIP configurado, luego (async, minutos después) se emite el CAE y se podría emitir `FiscalDocumentIssued`. ¿Cuál de los dos genera el asiento de venta?

**Recomendación**: `SaleConfirmed` genera el asiento. `FiscalDocumentIssued` puede actualizarlo (agregar neto/IVA discriminados) si el org es Responsable Inscripto, pero no es el trigger principal. Evita que ventas de monotributistas queden sin asiento.

**Alternativa**: `FiscalDocumentIssued` para todas las ventas (más completo pero bloquea el asiento hasta tener el CAE).

---

### DEC-PO-2 — Plan de cuentas en V1

**Opciones**:
- **(A) Hardcoded** (~10 códigos, sin tabla): rápido, cero UI.
- **(B) Tabla chart_of_accounts seeded**: personalizable, requiere seed en onboarding + UI básica.
- **(C) AccountCode como text libre en journal_lines**: sin FK, máxima flexibilidad.

**Recomendación**: **(A)** para V1 con schema que soporta **(C)** (`account_code text NOT NULL` sin FK). Si el PO quiere personalización: V2.6 agrega la tabla FK. El plan de ~10 cuentas suficiente para un libro diario de PYME:
- 1100 Caja, 1200 Banco, 1300 Deudores ctes
- 2100 Proveedores
- 4100 Ventas, 4200 IVA Débito Fiscal
- 5100 Compras/COGS, 5200 IVA Crédito Fiscal, 5300 Gastos

---

### DEC-PO-3 — ¿IVA discriminado en asientos?

Si el org emite Factura A o B (Responsable Inscripto), `fiscal_documents.neto` y `iva_amount` ya están disponibles. ¿Queremos:
- **(A) Líneas separadas** para neto + IVA DF en ventas, e IVA CF en compras → necesario para libro de IVA AFIP.
- **(B) Total único** sin discriminar IVA → más simple, menos útil fiscalmente.

**Recomendación**: **(A)** si el segmento objetivo incluye Responsables Inscriptos (que sí lo incluye según el modelo V2). El campo ya existe en `fiscal_documents`. Costo: 1-2 líneas más por asiento y una query de lookup.

---

### DEC-PO-4 — Consumer: pure-SQL plpgsql vs Python backend

**Contexto**: C-25 usa pure-SQL (`rpc_process_outbox_dispatch`). El mapping de cuentas tiene ~6-8 tipos de evento × 3-4 CASE branches.

**Recomendación**: **pure-SQL** como Consumer 3 en `rpc_process_outbox_dispatch`, con una función helper `_journal_post_from_event(event)` separada para mantener el código legible. Si el número de tipos de evento sube a 12+, migrar a Python.

---

### DEC-PO-5 — Eventos incluidos en scope V1

**Recomendación mínima**:
- ✅ `SaleConfirmed` (venta al contado y crédito)
- ✅ `PurchaseCreated` (compra/recepción mercadería)
- ✅ `PaymentReceived` (cobro de cta cte cliente)
- ✅ `SupplierPaymentMade` (pago a proveedor)
- ✅ `CreditNoteIssued` (nota de crédito → reversal)

**Defer a V2.6**:
- ❌ `CashSessionClosed` (diferencias de arqueo)
- ❌ `StockAdjusted` (variación de inventario)
- ❌ `SupplierCharge` (cargo manual)
- ❌ `ExpenseRegistered` (nuevo producer necesario)

Decisión del PO: ¿incluir `expenses` en V1 o deferirlos?

---

### DEC-PO-6 — CreditNoteIssued: ¿producer existe o hay que crearlo?

El evento `CreditNoteIssued` no está en el outbox. Para el consumer de reversión necesitamos el producer. C-27/`fiscal-receptor-iva-relay` emite el CAE pero no inserta en `events`.

**Pregunta al PO**: ¿la nota de crédito se registra en V1 o se defiere?

**Recomendación**: incluirla — un libro sin notas de crédito está incompleto. El producer es una adición al `rpc_emit_pending_cae` cuando `type='NC'`.

---

### DEC-PO-7 — cost_center_id en las líneas de ingreso (ventas)

Las ventas actualmente no llevan `cost_center_id`. ¿Queremos que las líneas de ingreso (`4100 Ventas`) tengan el CC de la sucursal, o NULL?

**Recomendación**: NULL para líneas de ingreso en V1. El CC es más relevante para gastos/compras (análisis de costos). Fácil de agregar después.

---

### DEC-PO-8 — Governance sign-off

El mapping de IVA es fiscalmente sensible. ¿Quién valida los CASE de cuentas antes de ir a producción?

**Recomendación**: El PO revisa el mapping propuesto (en el documento de design del change) antes del apply, y lo valida contra 3-5 casos reales de ventas de la DB.

---

### DEC-PO-9 — ¿Expenses en scope V1?

Si `expenses` va en V1, necesita:
- Un nuevo evento `ExpenseRegistered` (producer en el backend)
- Mapping: Débito 5300 Gastos + CC / Crédito 2100 Proveedores o 1100 Caja

**Recomendación**: **Defer**. Agrega complejidad y un nuevo producer. El libro diario sin gastos directos sigue siendo útil para ventas+compras. Agregar en V2.6 junto con el plan de cuentas completo.

---

## 5. Scope recomendado para el propose

### IN (V1 del change)

1. **Schema**: `journal_entries` + `journal_lines` (con RLS, índices, idempotencia por `source_event_id`)
2. **Consumer 3 en el relay**: `_journal_post_from_event()` plpgsql SECURITY DEFINER
3. **Producers nuevos**: `FiscalDocumentIssued` (en el relay CAE) y `CreditNoteIssued` (en la RPC de nota de crédito)
4. **Eventos mapeados**: SaleConfirmed, PurchaseCreated, PaymentReceived, SupplierPaymentMade, CreditNoteIssued
5. **Balanceo**: ASSERT en la función helper (error si SUM(debit) ≠ SUM(credit) → evento queda pending)
6. **cost_center_id**: propagado en las líneas de compras/gastos desde el payload del evento
7. **Cuentas hardcodeadas**: ~10 códigos documentados

### OUT (deferidos a V2.6)

- UI de plan de cuentas (chart_of_accounts tabla editable)
- Asientos de ajuste de inventario (StockAdjusted)
- Asientos de cierre de caja (CashSessionClosed)
- Asientos de gastos directos (expenses, sin producer)
- Export a software contable externo (Tango/Bejerman/Colppy)
- Percepciones, retenciones, diferencias de cambio

---

## 6. Diagrama de flujo completo del consumer

```
pg_cron (cada 1 min)
  → rpc_process_outbox_dispatch(100)
        │
        FOR EACH event (FOR UPDATE SKIP LOCKED):
        │
        ├── Consumer 1: AuditLog
        │     INSERT audit_logs  (siempre)
        │
        ├── Consumer 2: EmailNotification
        │     INSERT email_logs  (solo 3 tipos)
        │
        └── Consumer 3: JournalEntry (NUEVO)
              │
              ├─ event_type IN (SaleConfirmed, PurchaseCreated,
              │                 PaymentReceived, SupplierPaymentMade,
              │                 CreditNoteIssued)?
              │    NO → skip (idempotent noop)
              │    SÍ ↓
              │
              ├─ Ya existe journal_entries.source_event_id = event.id?
              │    SÍ  → skip (idempotente)
              │    NO  ↓
              │
              ├─ lookup: obtener neto/iva_amount si aplica
              │    (JOIN fiscal_documents o purchases según tipo)
              │
              ├─ calcular líneas (CASE por event_type + fiscal_type)
              │
              ├─ ASSERT SUM(debit) = SUM(credit)
              │    FALLA → RAISE → evento queda pending, retry
              │
              ├─ INSERT journal_entries (source_event_id = event.id)
              └─ INSERT journal_lines (N filas)
              
        → UPDATE events SET processed_at = now()
          (solo si los 3 consumers activos tuvieron éxito)
```

---

## 7. Análisis de riesgos específicos del change

| Riesgo | Probabilidad | Mitigación |
|--------|-------------|------------|
| IVA discriminado incorrecto (A/B vs C) | Media | Test con 3 casos: monotrib, RI factura A, RI factura B |
| Asiento duplicado (SaleConfirmed + FiscalDocumentIssued) | Alta si no se decide DEC-PO-1 | Único: fuente elegida en DEC-PO-1, idempotencia por source_event_id |
| Balance desequilibrado (SUM debit ≠ SUM credit) | Baja | ASSERT en la función → evento queda pending para debugging |
| Producer de FiscalDocumentIssued faltante | Alta | Debe crearse como parte de este change |
| CreditNoteIssued sin referencia al asiento original | Media | Diseñar payload con sales_order_id original |
| journal_entries crece sin retención | Baja (largo plazo) | El partial index por processed_at de events no aplica aquí; agregar índice compuesto account_id + posted_at. Retención V2.x. |

---

## 8. Preguntas abiertas (summary)

| ID | Pregunta | Bloquea proposal |
|----|----------|-----------------|
| DEC-PO-1 | SaleConfirmed vs FiscalDocumentIssued | Sí |
| DEC-PO-2 | Plan de cuentas: hardcoded vs tabla | Sí |
| DEC-PO-3 | IVA discriminado en asientos (A/B vs C) | Sí |
| DEC-PO-5 | Lista exacta de eventos V1 | Sí |
| DEC-PO-9 | Expenses en scope V1 | Sí |
| PA-24 | Factura A/B discrimina IVA en asiento | (mismo que DEC-PO-3) |
| PA-25 | Expenses genera asiento en V1 | (mismo que DEC-PO-9) |
| PA-26 | Plan de cuentas: FACPCE vs simplificado | Sí |
| PA-27 | Export a software contable en V1 | Sí |
| DEC-PO-4 | pure-SQL vs Python (consumer) | No — recomendación clara |
| DEC-PO-6 | CreditNoteIssued producer | No — recomendación clara |
| DEC-PO-7 | cost_center_id en líneas de ingreso | No — recomendación clara |
| DEC-PO-8 | Governance sign-off quién valida | No — procedural |

**Las 5 que bloquean el propose** son DEC-PO-1, DEC-PO-2, DEC-PO-3, DEC-PO-5, y PA-26. Con esas resueltas el agente de propose puede arrancar.

---

## 9. ¿Está listo para proponer?

**Casi**. Pending del PO:
1. Confirmar fuente del asiento de venta (DEC-PO-1)
2. Confirmar plan de cuentas simplificado vs FACPCE (PA-26 / DEC-PO-2)
3. Confirmar si IVA discriminado va en V1 o no (DEC-PO-3)
4. Confirmar si expenses van en V1 (DEC-PO-9)
5. Confirmar la lista de eventos V1 (DEC-PO-5)

Con estas 5 respuestas: `/opsx:propose journal-entry-outbox` puede arrancar. El change es de governance HIGH, no CRÍTICO — no mueve dinero pero genera registros con implicancias contables. El PO debe revisar el design.md del propose antes del apply.

---

*Exploración completada 2026-06-27. Siguiente paso: resolución de las 5 DEC-PO por el PO → propose.*
