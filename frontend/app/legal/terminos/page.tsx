import type { Metadata } from "next"
import { LegalShell } from "@/components/legal/LegalShell"

export const metadata: Metadata = {
  title: "Términos y Condiciones — ALIADATA",
  description: "Términos y Condiciones de uso de la plataforma ALIADATA.",
}

export default function TerminosPage() {
  return (
    <LegalShell title="Términos y Condiciones">
      <p>
        Estos Términos y Condiciones (los &quot;Términos&quot;) regulan el acceso y uso de la
        plataforma ALIADATA (el &quot;Servicio&quot;), operada para microemprendedores y pequeños
        comercios de la provincia de Mendoza, Argentina. Al crear una cuenta y usar el Servicio,
        aceptás estos Términos.
      </p>

      <h2>1. Qué es ALIADATA</h2>
      <p>
        ALIADATA es un servicio de software como servicio (SaaS) para la gestión financiera y
        comercial de tu emprendimiento: ventas, compras, gastos, stock, clientes, emisión de
        comprobantes fiscales y asistencia con inteligencia artificial. El Servicio es una
        herramienta de apoyo a la gestión y no reemplaza el asesoramiento contable, impositivo o
        legal profesional.
      </p>

      <h2>2. Registro y cuenta</h2>
      <ul>
        <li>Debés proporcionar datos veraces y mantenerlos actualizados (nombre, apellido, email, teléfono y localidad).</li>
        <li>Sos responsable de la confidencialidad de tu contraseña y de toda la actividad de tu cuenta.</li>
        <li>Debés ser mayor de edad y tener capacidad legal para contratar.</li>
        <li>Una cuenta corresponde a un titular; podés invitar a otros usuarios a tu organización según el plan contratado.</li>
      </ul>

      <h2>3. Planes y facturación</h2>
      <p>
        El Servicio ofrece un plan gratuito y planes pagos con funcionalidades adicionales. Los
        precios, límites y condiciones de cada plan se informan en la plataforma. La contratación
        de planes pagos y los pagos se procesan a través de los medios habilitados en el Servicio.
      </p>

      <h2>4. Datos fiscales y emisión de comprobantes</h2>
      <p>
        Si usás las funciones de facturación, el Servicio se integra con AFIP/ARCA para emitir
        comprobantes electrónicos. Sos el único responsable de la veracidad y la corrección de los
        datos fiscales que cargás (CUIT/CUIL, condición frente al IVA, datos del receptor) y del
        cumplimiento de tus obligaciones tributarias. ALIADATA actúa como herramienta de emisión y
        no asume responsabilidad por declaraciones o comprobantes incorrectos derivados de datos
        provistos por vos.
      </p>

      <h2>5. Asistencia con inteligencia artificial</h2>
      <p>
        El Servicio incluye funciones de IA que generan sugerencias, resúmenes y análisis a partir
        de tus datos. Estas salidas son orientativas, pueden contener errores y no constituyen
        asesoramiento profesional. Las decisiones que tomes en base a ellas son de tu exclusiva
        responsabilidad.
      </p>

      <h2>6. Uso aceptable</h2>
      <ul>
        <li>No usar el Servicio para fines ilícitos ni para cargar contenido o datos de terceros sin autorización.</li>
        <li>No intentar vulnerar la seguridad, automatizar el acceso de forma abusiva ni interferir con el funcionamiento del Servicio.</li>
        <li>No revender ni ceder el acceso sin autorización.</li>
      </ul>

      <h2>7. Disponibilidad y cambios</h2>
      <p>
        Procuramos mantener el Servicio disponible, pero puede haber interrupciones por
        mantenimiento, causas técnicas o de fuerza mayor. Podemos modificar, agregar o discontinuar
        funcionalidades, notificándote cuando el cambio sea relevante.
      </p>

      <h2>8. Tus datos</h2>
      <p>
        El tratamiento de tus datos personales se rige por nuestra{" "}
        <a href="/legal/privacidad">Política de Privacidad</a>, conforme a la Ley Nacional de
        Protección de Datos Personales 25.326.
      </p>

      <h2>9. Limitación de responsabilidad</h2>
      <p>
        En la medida permitida por la ley, ALIADATA no será responsable por daños indirectos,
        lucro cesante o pérdida de datos derivados del uso o la imposibilidad de uso del Servicio.
        Es tu responsabilidad mantener copias de la información que consideres crítica.
      </p>

      <h2>10. Baja de la cuenta</h2>
      <p>
        Podés solicitar la baja de tu cuenta en cualquier momento. Conservaremos cierta información
        cuando una obligación legal o fiscal así lo requiera, según se detalla en la Política de
        Privacidad.
      </p>

      <h2>11. Ley aplicable y jurisdicción</h2>
      <p>
        Estos Términos se rigen por las leyes de la República Argentina. Ante cualquier
        controversia, las partes se someten a los tribunales ordinarios de la Provincia de Mendoza,
        salvo normas de orden público que dispongan otra cosa.
      </p>

      <h2>12. Contacto</h2>
      <p>
        Para consultas sobre estos Términos, escribinos a{" "}
        <a href="mailto:soporte@alia-data.com">soporte@alia-data.com</a>.
      </p>
    </LegalShell>
  )
}
