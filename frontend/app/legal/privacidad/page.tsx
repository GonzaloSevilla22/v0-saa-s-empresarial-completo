import type { Metadata } from "next"
import { LegalShell } from "@/components/legal/LegalShell"

export const metadata: Metadata = {
  title: "Política de Privacidad — ALIADATA",
  description: "Cómo ALIADATA recopila, usa y protege tus datos personales y fiscales.",
}

export default function PrivacidadPage() {
  return (
    <LegalShell title="Política de Privacidad">
      <p>
        En ALIADATA respetamos tu privacidad. Esta Política explica qué datos personales y fiscales
        recopilamos, con qué finalidad, cuál es la base legal del tratamiento y qué derechos tenés,
        de acuerdo con la Ley Nacional de Protección de Datos Personales N.º 25.326 y su normativa
        complementaria.
      </p>

      <h2>1. Responsable del tratamiento</h2>
      <p>
        El responsable de la base de datos es ALIADATA. Para ejercer tus derechos o realizar
        consultas sobre tus datos, escribinos a{" "}
        <a href="mailto:soporte@alia-data.com">soporte@alia-data.com</a>.
      </p>

      <h2>2. Qué datos recopilamos</h2>
      <ul>
        <li><strong>Datos de registro:</strong> nombre, apellido, email, teléfono y localidad.</li>
        <li><strong>Datos de tu negocio:</strong> nombre comercial, productos, ventas, compras, gastos, stock y clientes que cargás en la plataforma.</li>
        <li><strong>Datos fiscales:</strong> CUIT/CUIL, condición frente al IVA y datos necesarios para la emisión de comprobantes electrónicos ante AFIP/ARCA.</li>
        <li><strong>Datos de uso:</strong> información técnica de acceso (logs, dispositivo, navegador) para seguridad y mejora del Servicio.</li>
        <li><strong>Preferencias de comunicación:</strong> tu opt-in para recibir notificaciones por email sobre novedades y cambios.</li>
      </ul>

      <h2>3. Para qué usamos tus datos (finalidad)</h2>
      <ul>
        <li>Prestar el Servicio: gestión financiera, comercial, de stock y de clientes.</li>
        <li>Emitir comprobantes fiscales electrónicos a través de la integración con AFIP/ARCA.</li>
        <li>Generar análisis, sugerencias y resúmenes mediante funciones de inteligencia artificial sobre tus propios datos.</li>
        <li>Enviarte comunicaciones operativas (cuenta, seguridad, facturación) y —solo si lo aceptaste— novedades del producto.</li>
        <li>Cumplir obligaciones legales, fiscales y contables.</li>
      </ul>

      <h2>4. Base legal del tratamiento</h2>
      <p>
        Tratamos tus datos sobre la base de tu consentimiento (que prestás al registrarte y aceptar
        estos documentos), de la ejecución de la relación contractual del Servicio, y del
        cumplimiento de obligaciones legales aplicables. El opt-in de comunicaciones de marketing es
        opcional y revocable en cualquier momento.
      </p>

      <h2>5. Inteligencia artificial</h2>
      <p>
        Para las funciones de IA podemos procesar tus datos con proveedores de modelos de lenguaje.
        El procesamiento se limita a generar las salidas que solicitás dentro del Servicio. Las
        sugerencias de IA son orientativas y no constituyen asesoramiento profesional.
      </p>

      <h2>6. Con quién compartimos datos</h2>
      <p>
        Compartimos datos únicamente con proveedores que nos ayudan a prestar el Servicio
        (infraestructura y base de datos, envío de emails, procesamiento de pagos, proveedores de
        IA) y con organismos públicos cuando una norma lo exige (por ejemplo, AFIP/ARCA para la
        emisión de comprobantes). No vendemos tus datos personales.
      </p>

      <h2>7. Transferencias internacionales</h2>
      <p>
        Algunos proveedores pueden alojar o procesar datos fuera de Argentina. En esos casos
        adoptamos resguardos razonables para proteger tu información conforme a la Ley 25.326.
      </p>

      <h2>8. Conservación</h2>
      <p>
        Conservamos tus datos mientras tu cuenta esté activa y durante los plazos que exijan las
        obligaciones legales, fiscales y contables. Registramos la versión de los Términos que
        aceptaste y la fecha de aceptación para fines de auditoría del consentimiento.
      </p>

      <h2>9. Seguridad</h2>
      <p>
        Aplicamos medidas técnicas y organizativas para proteger tus datos (control de acceso por
        organización, cifrado en tránsito y prácticas de seguridad). Ningún sistema es
        infalible; te pedimos cuidar tu contraseña y avisarnos ante cualquier uso no autorizado.
      </p>

      <h2>10. Tus derechos</h2>
      <p>
        Tenés derecho a acceder, rectificar, actualizar y suprimir tus datos personales, y a retirar
        tu consentimiento para comunicaciones de marketing. Para ejercerlos, escribinos a{" "}
        <a href="mailto:soporte@alia-data.com">soporte@alia-data.com</a>. La AGENCIA DE ACCESO A LA
        INFORMACIÓN PÚBLICA, órgano de control de la Ley 25.326, tiene la atribución de atender
        denuncias y reclamos relativos al incumplimiento de las normas de protección de datos
        personales.
      </p>

      <h2>11. Cambios en esta Política</h2>
      <p>
        Podemos actualizar esta Política. Cuando el cambio sea relevante, te lo notificaremos y
        actualizaremos el identificador de versión. Consultá también los{" "}
        <a href="/legal/terminos">Términos y Condiciones</a>.
      </p>
    </LegalShell>
  )
}
