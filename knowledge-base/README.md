# Knowledge Base — EmprendeSmart (EIE)

Base de conocimiento del proyecto **EmprendeSmart** (MVP del Ecosistema Inteligente para Emprendedores).

Generada con kb-creator el 2026-06-04. Fuente: exploración directa del codebase (Mode B — interactivo).

## Índice

| # | Archivo | Contenido | Estado |
|---|---|---|---|
| 01 | [01_vision_y_objetivos.md](01_vision_y_objetivos.md) | Propósito, UMV, usuario target, KPIs AARRR, alcance | ✅ Completo |
| 02 | [02_descripcion_general.md](02_descripcion_general.md) | Stack tecnológico, arquitectura, módulos, integraciones | ✅ Completo |
| 03 | [03_actores_y_roles.md](03_actores_y_roles.md) | Roles (user/admin), planes (free/pro), RBAC, RLS | ✅ Completo |
| 04 | [04_modelo_de_datos.md](04_modelo_de_datos.md) | 23+ tablas, tipos, relaciones, triggers, storage | ✅ Completo |
| 05 | [05_reglas_de_negocio.md](05_reglas_de_negocio.md) | Reglas por dominio (RN-XX): planes, operaciones, stock, IA, email, OCR | ✅ Completo |
| 06 | [06_funcionalidades.md](06_funcionalidades.md) | Historias de usuario por épica (10 épicas), estado por módulo | ✅ Completo |
| 07 | [07_flujos_principales.md](07_flujos_principales.md) | Flujos E2E: registro, venta, insight, OCR, fair advisor, email | ✅ Completo |
| 08 | [08_arquitectura_propuesta.md](08_arquitectura_propuesta.md) | BaaS pattern, Server/Client components, seguridad, deploy | ✅ Completo |
| 09 | [09_decisiones_y_supuestos.md](09_decisiones_y_supuestos.md) | 11 decisiones (DEC-XX), 7 supuestos (SUP-XX), decisiones postergadas | ✅ Completo |
| 10 | [10_preguntas_abiertas.md](10_preguntas_abiertas.md) | 15 preguntas abiertas + 4 inconsistencias detectadas | ✅ Completo |

## Resumen del Sistema

- **Producto**: SaaS para microemprendedores — gestión financiera + IA
- **Stack**: Next.js 16 + React 19 + TypeScript + Supabase + Tailwind + OpenAI
- **Deploy**: Vercel (frontend) + Supabase (backend completo)
- **Estado**: MVP en producción con usuarios reales (junio 2026)
- **Próximo hito**: estabilizar MVP + billing real + activar planes

## Cómo Usar Esta KB

- **Nuevo en el proyecto** → empezá por [01](01_vision_y_objetivos.md) y [02](02_descripcion_general.md)
- **Implementando una feature** → consultá [04](04_modelo_de_datos.md) + [05](05_reglas_de_negocio.md) + [07](07_flujos_principales.md)
- **Tomando una decisión arquitectural** → revisá [09](09_decisiones_y_supuestos.md) primero
- **Dudas sobre qué existe** → [10](10_preguntas_abiertas.md) lista las inconsistencias conocidas
- **Implementar billing** → bloqueado por [PA-01](10_preguntas_abiertas.md) (Word de planes pendiente)

## Actualización

Para actualizar esta KB después de cambios significativos:
```
/jr-orchestrator:kb
```
Para regenerar solo el CLAUDE.md/AGENTS.md:
```
/jr-orchestrator:rules
```
