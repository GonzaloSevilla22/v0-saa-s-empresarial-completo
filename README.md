# Entrega Final: Documentación del Producto 

## 1. Resumen Ejecutivo

**Nombre del Proyecto:** *EmprendeSmart*  (MVP del **Ecosistema Inteligente para Emprendedores (EIE)**)

Dado que se trata de un proyecto real que estoy poniendo en marcha en este momento, cada sugerencia incluida en su devolución constituye un aporte de gran valor para su desarrollo.

**Problema que resuelve:** La app resuelve la falta de información financiera clara en microemprendedores, transformando registros simples en insights accionables para tomar decisiones basadas en datos. 

**Usuario target:** Emprendedor o microemprendedora de Mendoza que inició su negocio por necesidad o autoempleo, maneja ventas diarias (feria, comercio pequeño, servicios locales), registra ingresos y gastos de forma informal o mental, utiliza WhatsApp como herramienta principal y no cuenta con formación financiera formal. Tiene motivación y voluntad de crecer, pero carece de herramientas simples que le permitan entender si realmente gana dinero, cuánto margen tiene y qué decisiones debería tomar para mejorar su rentabilidad.

**Unidad mínima de valor:** La acción concreta que representa que el sistema entregó valor es:
"Que el emprendedor realice un registro financiero (Venta, Compra o Gasto) y el sistema le devuelva un Insight accionable". Esto confirma que el usuario pasó de la gestión por instinto a la toma de decisiones basada en información técnica. 

---

## 2. Integración de Servicios (Requisito: 2 de 3)

### Servicio: Email / Analytics

**Servicios elegidos:** Resend / Analytics

---

### Servicio 1: Email (Resend)

#### Acción de usuario asociada

1. El usuario se registra y confirma su cuenta.
2. El usuario participa en funcionalidades de Comunidad (eventos, reuniones, pools de compra).
3. El usuario genera actividad relacionada con IA (insights, reportes, alertas).

---

#### Implementación

##### Descripción breve de cómo se integró

- Se integró **Resend** como proveedor de email transaccional.
- La API Key se maneja como variable de entorno segura (no expuesta en frontend).
- Los envíos se ejecutan mediante Supabase (Auth hooks, Edge Functions y/o jobs programados).
- Se implementó sistema de logs y control de duplicación para evitar spam.

##### Flujo que habilita

1. Ocurre un evento del sistema (registro confirmado, bienvenida, recordatorio, alerta).
2. Se registra el evento de envío.
3. Una función backend ejecuta el envío vía Resend.
4. Se guarda el estado del envío (éxito / error).

##### Beneficio para el producto / usuario

- Mejora el onboarding (confirmación + bienvenida personalizada).
- Aumenta retención mediante recordatorios.
- Refuerza el valor del módulo IA mediante reportes automáticos.

---

### Servicio 2: Analytics (Supabase + Dashboard Admin + D3)

#### Acción de usuario asociada

Eventos medibles generados por el usuario:

- Registro y finalización de onboarding.
- Creación de operaciones.
- Generación de insights IA.
- Participación en comunidad (posts y respuestas).

---

#### Implementación

##### Descripción breve de cómo se integró

- Se utiliza la tabla `analytics_events` para registrar eventos clave.
- Se desarrollaron vistas y funciones RPC en Supabase para agregaciones eficientes.
- Se implementó un dashboard ADMIN en Next.js.
- Visualización mediante D3.js puro.
- Seguridad mediante RLS y control de rol `admin`.

##### Flujo que habilita

1. El usuario realiza acciones dentro de la app.
2. Se registran eventos en `analytics_events`.
3. El administrador accede a `/admin/analytics`.
4. El frontend consulta métricas agregadas.
5. D3 renderiza gráficos y cohortes.

##### Métricas incluidas en el MVP

- Activación profunda (primera operación).
- Unidad Mínima de Valor (operación + insight IA).
- Retención a 30 días.
- Frecuencia de uso semanal.
- Uso del módulo IA (insights por tipo).
- Actividad en comunidad.

##### Beneficio para el producto / usuario

- Permite validar hipótesis del MVP con datos reales.
- Facilita decisiones de roadmap basadas en evidencia.
- Mejora continua orientada a valor y retención.

---

## 3. Métricas y Aprendizaje (Modelo AARRR)
> Acquisition, Activation, Retention, Referral, Revenue: 
> [Referencia](https://www.obsbusiness.school/blog/el-modelo-de-analisis-aarrr)

### 3.1 Definición de la unidad mínima de valor

*Que el emprendedor realice un registro financiero (Venta, Compra o Gasto) y el sistema le devuelva un Insight accionable*.

### 3.2 KPIs por etapa del embudo AARRR

### 3.3 Métricas priorizadas y postergadas

#### 3.3.1 Metricas incluídas en el MVP

| Etapa | KPI | Definición operativa | Por qué es relevante |
|-------|-----|----------------------|----------------------|
| Activación | % que registra la primera operación | Usuarios que registran al menos una Venta, Compra o Gasto luego del registro. | Confirma que el usuario entendió la utilidad básica del sistema. |
| Activación | % que alcanza la Unidad Mínima de Valor (UMV) | Usuario que registra una operación financiera y recibe al menos un Insight posterior. | Valida que el sistema entrega profesionalización real basada en datos. |
| Retención | Retención a 30 días | Usuarios que vuelven a registrar operaciones ≥ 30 días después de su primera operación. | Indica si la herramienta se convierte en hábito operativo. |
| Retención | Frecuencia semanal de uso | Promedio de días por semana con al menos una operación registrada. | Mide consistencia y adopción real del sistema. |
| Activación / Uso IA | Insights generados por usuario | Cantidad de insights generados por usuario en un período dado. | Evalúa adopción de la capa inteligente diferencial del producto. |
| Referral (interno) | Participación en comunidad | Usuarios que crean posts o responden dentro de la plataforma. | Mide sentido de pertenencia y compromiso dentro del ecosistema. |
------------------------------------------------------------------------

#### 3.3.2 Metricas postergadas en el MVP

| Etapa | KPI | Definición operativa | Por qué no es crítica en esta etapa |
|-------|-----|----------------------|--------------------------------------|
| Adquisición | CAC (Costo de Adquisición por Usuario) | Inversión total en marketing dividida por nuevos registros. | El foco actual es validar activación profunda antes de optimizar adquisición. |
| Adquisición | % provenientes de comunidad física | Usuarios cuyo canal de adquisición fue feria o evento presencial. | Requiere instrumentación adicional; el aprendizaje principal hoy es de uso, no de canal. |
| Retención / IA | % que abre alertas de IA | Usuarios que interactúan activamente con alertas generadas. | Aún no está instrumentado el tracking de apertura; primero validar generación de valor. |
| Referral | Net Promoter Score (NPS) | Encuesta de disposición a recomendar la app. | En fase temprana se prioriza aprendizaje cualitativo directo. |
| Ingresos | MRR (Monthly Recurring Revenue) | Ingreso mensual recurrente por suscripciones premium. | Monetización aún no activada; escalar ingresos sin validación profunda sería prematuro. |
| Ingresos | ARPU | Ingreso promedio por usuario activo. | Depende de modelo de suscripción aún no implementado. |

------------------------------------------------------------------------

---

## 4. Estrategia de Distribución (Deck de 5 slides)

*El link se adjunta en el punto 6 (Anexo)*

## 5. Conciencia Técnica (Hacks y Límites del Vibe Coding)


### 5.1 Hacks implementados (mínimo 3)


| Nº | Hack | Tipo | Descripción | Riesgo que mitiga |
|----|------|------|----------------------|------------------|
| 1 | **Supabase como BaaS (Backend-as-a-Service)** | Arquitectura | Delegación total del backend (Auth, DB, RLS, Edge Functions, RPC, Scheduler) en Supabase. | Reduce time-to-market y evita construir infraestructura compleja prematuramente. |
| 2 | **Freemium con gating server-side sin billing real** | Monetización | Plan `free/pro` validado en Edge Functions sin integración real con proveedor de pagos. | Permite validar conversión sin asumir complejidad fiscal y técnica de facturación. |
| 3 | **IA operativa sin modelo predictivo propio** | IA / Producto | Edge Functions generan insights y predicciones heurísticas sin ML entrenado con datos propios. | Permite validar percepción de valor IA sin inversión en ciencia de datos avanzada. |
| 4 | **Frontend generado con V0 (Vercel) antes del backend formal** | Proceso / UX | UI creada con IA generativa antes de definir arquitectura backend. | Permite validar experiencia y narrativa antes de invertir en lógica compleja. |
| 5 | **Desarrollo evolutivo desacoplado (V0 → GitHub → Antigravity)** | Proceso / Arquitectura | El proyecto no nació full-stack planificado; evolucionó por etapas hasta consolidarse en Supabase + Edge Functions. | Evita sobrearquitectura temprana y permite iteración incremental. |

---
#### Deuda técnica futura

El proyecto esta funcional, pero presenta algunos errores que necesitan de mas depuracion en algunos modulos. Asumiendo que estos bugs se pueden solucionar relativamente facil, presento una evaluación de deuda tecnica futura, basandome en el desarrollo alcanzado:

| Hack | Nivel de deuda futura | Justificación |
|------|----------------------|---------------|
| Supabase como BaaS | 🟡 Media | Escalable en MVP, pero podría requerir separación OLTP/OLAP o microservicios si crece a gran escala. |
| Freemium sin billing | 🟠 Alta | Deberá migrar a integración real (Stripe/MercadoPago) con lógica de suscripciones robusta. |
| IA sin modelo propio | 🟡 Media | Necesitará evolución hacia modelos calibrados si se quiere ventaja competitiva real. |
| Frontend V0 | 🟢 Baja | Puede refactorizarse progresivamente sin romper backend. |
| Desarrollo evolutivo | 🟢 Baja | Es natural en Lean; no implica deuda estructural grave si se documenta bien. |

### 5.2 Riesgos detectados y decisiones postergadas

#### Riesgos identificados:

- **Riesgo 1: Dependencia fuerte del proveedor (vendor lock-in)**  
  *Descripción:* El uso intensivo de Supabase centraliza la infraestructura en un único proveedor.  
  *Plan de monitoreo:* Documentación técnica completa + exportación periódica de esquemas + control estricto en Git.

- **Riesgo 2: Complejidad creciente del sistema (RLS + RPC + Edge + Email + Analytics)**  
  *Descripción:* A medida que se agregan módulos (IA, Resend, Admin Analytics), aumenta la superficie de debugging.  
  *Plan de monitoreo:* Tests incrementales por módulo + validación estricta de RLS + checklist de debugging.

---

#### Decisiones postergadas conscientemente:

- **Decisión 1: No implementar pasarela de pagos en el MVP**  
  *Por qué no ahora:* Se prioriza validar activación profunda (UMV) y retención antes de monetización formal.  
  *Cuándo revisarla:* Cuando la tasa de conversión free→pro supere un umbral consistente durante 2–3 meses.

- **Decisión 2: No desarrollar infraestructura analítica separada (Data Warehouse / OLAP)**  
  *Por qué no ahora:* El volumen de usuarios aún no justifica separación OLTP/OLAP.  
  *Cuándo revisarla:* Cuando el volumen de datos afecte rendimiento o se requieran cohortes complejas multi-anuales.

---

### 5.3 Supuestos asumidos

| Supuesto | Implicancia si es falso | Señal que nos hará revisarlo |
|----------|------------------------|------------------------------|
| Los emprendedores priorizan simplicidad sobre sofisticación técnica | El producto podría percibirse como demasiado básico y perder retención | Retención a 30 días baja y feedback solicitando funciones avanzadas |
| El modelo freemium es viable en Mendoza | La conversión podría no cubrir costos de infraestructura | Tasa de upgrade < 3% sostenida + baja disposición a pagar en entrevistas |
| La IA genera percepción de valor suficiente | Podría no influir en activación ni en retención | Baja interacción con `ai_alert_opened` y bajo porcentaje de UMV alcanzado |


El MVP está diseñado para **aprender primero y escalar después**.

## 6. Anexo: Enlaces y Evidencias

- **URL del producto desplegado:** [Link del producto desplegado en el readme.md del repo.](https://v0-saa-s-empresarial-completo-eie.vercel.app/)  
- **Repositorio:** [\[link a repo\]](https://github.com/GonzaloSevilla22/v0-saa-s-empresarial-completo)
- **Slides - Estrategias de Distribucion (punto 4):** [\[link a  slides\]](https://docs.google.com/presentation/d/1r9s9fe2ZOvat7VNVWF1TEO_mLo3zzo-B/edit?usp=sharing&ouid=114501808713988604223&rtpof=true&sd=true)  
- **Capturas de integraciones funcionando:** Algunas capturas [\[link a imágenes\]  ](https://drive.google.com/file/d/1lEx5KqpnTXbTVlwJRmKQn-ijpinjHsUo/view?usp=sharing)
- **Dashboard de métricas:** [\[link a capturas metricas\]](https://drive.google.com/file/d/1ST3ncQe0xUvpQwM872IP2WT4OuRQez9t/view?usp=sharing)

---

## Checklist de cumplimiento

- [*] Integración de al menos 2 servicios (email/analytics)  
- [*] Cada integración asociada a acción concreta de usuario  
- [*] Unidad mínima de valor definida  
- [*] 5 KPIs AARRR definidos  
- [*] Métricas priorizadas y postergadas justificadas  
- [*] Deck de 5 slides completo  
- [*] + de 3 hacks de límites de vibe coding implementados  
- [*] Riesgos y decisiones postergadas documentados  
