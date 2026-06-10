# 01 — Visión y Objetivos

## Nombre del Producto
**EmprendeSmart** — MVP del **Ecosistema Inteligente para Emprendedores (EIE)**

## Nombre de la App en Branding
**ALIADATA Emprendedores** (usado en emails y comunicaciones oficiales)

## Problema que Resuelve
Los microemprendedores de Mendoza carecen de información financiera clara para tomar decisiones. Registran ingresos y gastos de forma mental o informal, no saben si realmente ganan dinero, ni cuál es su margen real. El sistema transforma registros simples en insights accionables para pasar de la gestión por instinto a la toma de decisiones basada en datos.

## Unidad Mínima de Valor (UMV)
> "El emprendedor registra una operación financiera (Venta, Compra o Gasto) y el sistema le devuelve un Insight accionable."

Este es el evento central que valida que el sistema entregó valor real.

## Usuario Target
- Emprendedor/microemprendedora de Mendoza, Argentina
- Inició su negocio por necesidad o autoempleo
- Opera en feria, comercio pequeño o servicios locales
- Registra ventas diarias de forma informal o mental
- Usa WhatsApp como herramienta principal
- Sin formación financiera formal
- Con motivación de crecer pero sin herramientas para entender su rentabilidad

## Objetivos por Actor

### Emprendedor (usuario final)
| Objetivo | Indicador de éxito |
|---|---|
| Registrar operaciones financieras de forma simple | Primera operación registrada < 3 min del registro |
| Entender su margen y rentabilidad real | % que alcanza la UMV en la primera sesión |
| Recibir insights accionables con datos reales | Tasa de generación de insights post-operación |
| Gestionar stock, clientes y compras desde un solo lugar | Frecuencia semanal de uso del dashboard |
| Acceder a recomendaciones de IA para eventos (ferias) | Uso del módulo Fair Advisor antes de una feria |

### Admin (operador de la plataforma)
| Objetivo | Indicador de éxito |
|---|---|
| Monitorear métricas de activación y retención | Dashboard admin con cohortes AARRR |
| Gestionar contenido educativo (cursos) | Cursos publicados y enrolados por usuarios |
| Administrar comunidad y eventos | Reuniones y pools publicados |
| Supervisar uso de IA y emails | Métricas de insights generados y emails enviados |

## KPIs AARRR del MVP

| Etapa | KPI | Definición |
|---|---|---|
| **Activación** | Primera operación registrada | % que registra ≥ 1 venta/compra/gasto luego del registro |
| **Activación** | Tasa de alcance de la UMV | % que registra operación + recibe insight posterior |
| **Retención** | Retención a 30 días | Usuarios que vuelven a registrar operaciones ≥ 30 días después |
| **Retención** | Frecuencia semanal | Promedio de días/semana con ≥ 1 operación registrada |
| **Activación / IA** | Insights generados/usuario | Cantidad de insights por usuario en un período dado |
| **Referral** | Participación en comunidad | Usuarios que crean posts o responden en la plataforma |

## Alcance del MVP

### Incluido en el MVP
- Registro de ventas, compras y gastos
- Gestión de productos con variantes y unidades de medida fraccionarias
- Control de stock con libro mayor inmutable (ledger)
- Gestión de clientes
- Módulo IA: insights, predicciones, resúmenes, simulador, fair advisor
- Comunidad (foro): posts y respuestas
- Cursos educativos básicos y pro
- Dashboard admin con métricas AARRR
- Sistema de email transaccional (bienvenida, alertas, eventos)
- OCR de facturas con auto-matching a productos
- Plan freemium (free/pro) con gating por feature — **billing real aún no integrado**
- Ferias / eventos: recomendaciones de productos para eventos de venta presencial

### Fuera de Alcance (MVP)
- Pasarela de pagos real (Stripe/MercadoPago)
- Data Warehouse / OLAP separado
- Modelos de ML entrenados con datos propios
- Facturación electrónica oficial (AFIP)
- App mobile nativa (iOS/Android)
- Multi-tenant empresarial con roles jerárquicos avanzados
- Módulo de logística/envíos

## Estado Actual (Junio 2026)
- **Deployado en producción**: Vercel + Supabase
- **Usuarios reales activos**: Sí
- **Plan activo durante beta**: todos los usuarios tienen plan `pro` (sin restricciones)
- **Próximo hito**: implementar el modelo de dominio V2 — Fase V2.0 retirada de deuda (billing, multi-tenant y backend Python ya completados en Fases 1-5 de CHANGES.md)
- **URL**: https://v0-saa-s-empresarial-completo-eie.vercel.app/
- **Repo**: https://github.com/GonzaloSevilla22/v0-saa-s-empresarial-completo

---

## Evolución V2 — Aliadata ERP (decidido 2026-06-09)

El PO adoptó el **modelo de dominio V2** (`modelo-dominio-aliadata-v2.md`, validado en `openspec/explore/2026-06-09-modelo-dominio-v2.md`), que reposiciona el producto:

- **Mercado objetivo ampliado**: de microemprendedores de Mendoza a **PyMEs argentinas** (referentes: Odoo, ERPNext, SAP Business One).
- **Core domain corregido**: el ERP operativo confiable (ventas, stock, compras, caja, fiscal AR) ES el core. La IA pasa a Supporting Domain — es la razón por la que el cliente *renueva*, no por la que *compra*.
- **Diferenciador**: "un ERP argentino que factura, no pierde stock y cierra la caja todos los días" — la facturación AFIP deja de estar fuera de alcance (va en V2.1, ver DEC-22).
- **Roadmap V2**: V2.0 retirada de deuda → V2.1 operación (Branch, AFIP, CashSession, Quote, ctas ctes) → V2.5 finanzas → V3 inteligencia. Ver CHANGES.md.

> Pendiente de definición explícita: naming (EmprendeSmart vs Aliadata) y si el reposicionamiento a PyMEs reemplaza o amplía el segmento original — ver PA-23 en `10_preguntas_abiertas.md`.
