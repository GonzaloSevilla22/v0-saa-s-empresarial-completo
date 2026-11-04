/**
 * email-logs-cierre-insert (OQ-7 de multiusuario-operativo, governance CRÍTICO) —
 * plantillas del Edge Function `send-email`.
 *
 * Antes de este hotfix las plantillas interpolaban `metadata.*` tal cual en el HTML
 * que se manda desde no-reply@aliadata.com.ar, y `meeting_notice` armaba su botón
 * con `metadata.url`. Con `metadata` escrita por un usuario (un nombre de negocio,
 * un título, o directamente una fila insertada a mano en `email_logs`) eso era HTML
 * y enlaces hostiles dentro de un correo con la marca de ALIADATA.
 *
 * Mismo patrón D5/D6 que send-email-fanout-policy.test.ts y
 * send-email-overdue-digest.test.ts: importa los módulos REALES
 * `supabase/functions/_shared/{html-escape,email-templates}.ts` (puros, sin
 * `Deno.*` a nivel módulo) por ruta relativa, en vez de re-declarar la regla.
 *
 * Lo que fijan estos tests:
 *   · `escapeHtml` / `safeFilenamePart`.
 *   · MATRIZ: con TODO campo de la metadata hostil, ninguna plantilla emite
 *     markup vivo (ni `<script>`, ni atributos con comillas sin escapar, ni un
 *     `href` que no apunte a la app).
 *   · `meeting_notice` NO toma el enlace de la metadata: el botón lleva a
 *     `${APP_URL}/comunidad` aunque `metadata.url` apunte a otro sitio.
 *   · `layout()` descarta un `ctaUrl` que no esté bajo `APP_URL` (incluidos los
 *     parecidos: subdominios del atacante, `@`, `javascript:`).
 *   · Control positivo: los correos legítimos conservan su contenido (nombres con
 *     `&` o `'` se leen bien; importes, planes y fechas siguen apareciendo).
 *
 * Run: pnpm vitest run __tests__/send-email-templates.test.ts
 */

import { describe, it, expect } from "vitest"
import { escapeHtml, safeFilenamePart } from "../../supabase/functions/_shared/html-escape"
import {
  APP_URL,
  infoRow,
  layout,
  receiptAttachmentFilename,
  renderEmailHtml,
} from "../../supabase/functions/_shared/email-templates"

const HOSTILE = `<script>alert(1)</script><img src=x onerror=alert(2)>"'><a href="https://evil.example/phish">Verificá tu cuenta</a>`

/** Todas las claves de metadata que alguna plantilla lee, con el valor hostil. */
const HOSTILE_METADATA: Record<string, unknown> = {
  name: HOSTILE,
  last_name: HOSTILE,
  email: HOSTILE,
  phone: HOSTILE,
  province: HOSTILE,
  locality: HOSTILE,
  title: HOSTILE,
  url: "https://evil.example/phish",
  start_time: HOSTILE,
  closes_at: HOSTILE,
  product_name: HOSTILE,
  current_stock: HOSTILE,
  amount: HOSTILE,
  cost_basis: HOSTILE,
  margin_percentage: HOSTILE,
  umbral: HOSTILE,
  plan: HOSTILE,
  activated_at: HOSTILE,
  plan_expires_at: HOSTILE,
  receipt_number: HOSTILE,
  receipt_pdf_base64: "AAAA",
  reason: HOSTILE,
  party_count: HOSTILE,
  overdue_total: HOSTILE,
  as_of: HOSTILE,
  // org_invite (multiusuario-operativo tanda C)
  account_name: HOSTILE,
  inviter_name: HOSTILE,
  role_labels: [HOSTILE, HOSTILE],
  roles: [HOSTILE],
  token: HOSTILE,
  expires_at: HOSTILE,
  invitation_id: HOSTILE,
  account_id: HOSTILE,
  link: "https://evil.example/phish",
  cta_url: "https://evil.example/phish",
}

const EVENT_TYPES = [
  "welcome",
  "new_user_admin_notice",
  "meeting_notice",
  "pool_notice",
  "low_stock_alert",
  "low_margin_alert",
  "trial_expiring_soon",
  "plan_upgraded",
  "payment_receipt",
  "plan_downgraded",
  "trial_expired",
  "subscription_payment_approved",
  "subscription_payment_failed",
  "subscription_expiring_soon",
  "receivables_overdue_digest",
  "payables_overdue_digest",
  "subscription_cancelled",
  "org_invite",
  "evento_desconocido",
] as const

function hrefsOf(html: string): string[] {
  return [...html.matchAll(/href="([^"]*)"/g)].map((m) => m[1])
}

function srcsOf(html: string): string[] {
  return [...html.matchAll(/src="([^"]*)"/g)].map((m) => m[1])
}

describe("escapeHtml / safeFilenamePart", () => {
  it("escapa los seis caracteres que abren markup o rompen un atributo", () => {
    expect(escapeHtml(`<a href="x" title='y'>&\`</a>`)).toBe(
      "&lt;a href=&quot;x&quot; title=&#39;y&#39;&gt;&amp;&#96;&lt;/a&gt;",
    )
  })

  it("no re-escapa de menos ni de más: texto común queda igual", () => {
    expect(escapeHtml("Hola María, ¡gracias! 🚀 $1.500,50")).toBe("Hola María, ¡gracias! 🚀 $1.500,50")
  })

  it("null/undefined → vacío; no-strings se convierten con String() antes de escapar", () => {
    expect(escapeHtml(null)).toBe("")
    expect(escapeHtml(undefined)).toBe("")
    expect(escapeHtml(42)).toBe("42")
    expect(escapeHtml(false)).toBe("false")
    expect(escapeHtml({ toString: () => "<b>" })).toBe("&lt;b&gt;")
  })

  it("safeFilenamePart deja sólo letras, dígitos, _ y -; usa el fallback si no queda nada", () => {
    expect(safeFilenamePart("RC-2026_0001", "aliadata")).toBe("RC-2026_0001")
    expect(safeFilenamePart("../../etc/passwd\".pdf", "aliadata")).toBe("etcpasswdpdf")
    expect(safeFilenamePart("<>/\\", "aliadata")).toBe("aliadata")
    expect(safeFilenamePart(undefined, "aliadata")).toBe("aliadata")
    expect(safeFilenamePart("A".repeat(100), "x")).toHaveLength(40)
  })

  it("receiptAttachmentFilename nunca arrastra caracteres de ruta ni comillas", () => {
    expect(receiptAttachmentFilename("RC-000123")).toBe("recibo-RC-000123.pdf")
    expect(receiptAttachmentFilename(undefined)).toBe("recibo-aliadata.pdf")
    expect(receiptAttachmentFilename('x/../"y')).toBe("recibo-xy.pdf")
  })
})

describe("matriz hostil — ninguna plantilla emite markup vivo desde la metadata", () => {
  for (const eventType of EVENT_TYPES) {
    it(`${eventType}: sin <script>, sin <img> inyectado, sin atributo roto, hrefs sólo hacia la app`, () => {
      const html = renderEmailHtml(eventType, HOSTILE_METADATA)

      expect(html).not.toContain("<script")
      expect(html).not.toMatch(/<[^>]*onerror[ \t]*=/i)
      expect(html).not.toContain("<img src=x")
      // El enlace hostil sembrado en los campos no aparece como <a> propio.
      expect(html).not.toContain('<a href="https://evil.example')
      for (const href of hrefsOf(html)) {
        expect(href === APP_URL || href.startsWith(`${APP_URL}/`)).toBe(true)
      }
      for (const src of srcsOf(html)) {
        expect(src.startsWith(`${APP_URL}/`)).toBe(true)
      }
    })
  }

  it("la metadata hostil sí se muestra, pero como texto escapado (control positivo)", () => {
    const html = renderEmailHtml("new_user_admin_notice", HOSTILE_METADATA)
    expect(html).toContain("&lt;script&gt;alert(1)&lt;/script&gt;")
    expect(html).toContain("&quot;&#39;&gt;&lt;a href=&quot;https://evil.example/phish&quot;&gt;")
  })

  it("metadata ausente, nula o de tipo inesperado no rompe el armado", () => {
    for (const eventType of EVENT_TYPES) {
      for (const metadata of [undefined, null, "texto", 7, [], {}]) {
        expect(() => renderEmailHtml(eventType, metadata)).not.toThrow()
      }
    }
  })
})

describe("enlaces: nunca salen de la metadata", () => {
  it("meeting_notice lleva a /comunidad aunque metadata.url apunte a otro sitio", () => {
    const html = renderEmailHtml("meeting_notice", {
      title: "Reunión mensual",
      start_time: "2026-11-05T15:00:00Z",
      url: "https://evil.example/phish",
    })
    expect(html).not.toContain("evil.example")
    expect(hrefsOf(html)).toEqual([`${APP_URL}/comunidad`])
    expect(html).toContain("Reunión mensual")
  })

  it("meeting_notice con url javascript: tampoco la usa", () => {
    const html = renderEmailHtml("meeting_notice", { title: "x", start_time: "2026-11-05T15:00:00Z", url: "javascript:alert(1)" })
    expect(html).not.toContain("javascript:")
    expect(hrefsOf(html)).toEqual([`${APP_URL}/comunidad`])
  })

  const ACEPTADOS = [`${APP_URL}`, `${APP_URL}/dashboard`, `${APP_URL}/planes?x=1`]
  const RECHAZADOS = [
    "https://evil.example/phish",
    "http://www.aliadata.com.ar/dashboard",
    "https://www.aliadata.com.ar.evil.example/dashboard",
    "https://www.aliadata.com.ar@evil.example/dashboard",
    "https://www.aliadata.com.arevil/dashboard",
    "javascript:alert(1)",
    "//evil.example",
    "/dashboard",
    "",
  ]

  for (const url of ACEPTADOS) {
    it(`layout() dibuja el botón para ${url}`, () => {
      const html = layout({ title: "T", ctaText: "Ir", ctaUrl: url })
      expect(hrefsOf(html)).toEqual([url])
    })
  }

  for (const url of RECHAZADOS) {
    it(`layout() descarta el botón para ${JSON.stringify(url)}`, () => {
      const html = layout({ title: "T", ctaText: "Ir", ctaUrl: url })
      expect(hrefsOf(html)).toEqual([])
      expect(html).not.toContain("evil.example")
    })
  }

  it("layout() escapa title y ctaText (slots de texto plano) y el href", () => {
    const html = layout({ title: HOSTILE, ctaText: HOSTILE, ctaUrl: `${APP_URL}/a?b="c"&d=<e>` })
    expect(html).not.toContain("<script")
    expect(html).not.toMatch(/<[^>]*onerror[ \t]*=/i)
    expect(hrefsOf(html)).toEqual([`${APP_URL}/a?b=&quot;c&quot;&amp;d=&lt;e&gt;`])
  })

  it("infoRow() escapa etiqueta y valor", () => {
    const html = infoRow(HOSTILE, HOSTILE)
    expect(html).not.toContain("<script")
    expect(html).not.toContain("<img")
  })
})

describe("correos legítimos: el contenido sigue ahí (control positivo)", () => {
  it("welcome saluda por el nombre, y un nombre con & o ' se lee bien", () => {
    const html = renderEmailHtml("welcome", { name: "Pérez & O'Brien" })
    expect(html).toContain("Hola Pérez &amp; O&#39;Brien, ¡gracias por sumarte a ALIADATA!")
    expect(hrefsOf(html)).toEqual([`${APP_URL}/dashboard`])
  })

  it("new_user_admin_notice muestra las seis filas", () => {
    const html = renderEmailHtml("new_user_admin_notice", {
      name: "Ana",
      last_name: "Gómez",
      email: "ana@example.com",
      phone: "+54 261 555 0000",
      province: "Mendoza",
      locality: "Godoy Cruz",
    })
    for (const text of ["Ana", "Gómez", "ana@example.com", "+54 261 555 0000", "Mendoza", "Godoy Cruz"]) {
      expect(html).toContain(text)
    }
  })

  it("low_stock_alert y low_margin_alert muestran producto, cifras y margen", () => {
    const stock = renderEmailHtml("low_stock_alert", { product_name: "Yerba 1kg", current_stock: 3 })
    expect(stock).toContain("<strong>Yerba 1kg</strong>")
    expect(stock).toContain(">3</span>")

    const margin = renderEmailHtml("low_margin_alert", {
      product_name: "Yerba 1kg",
      amount: 1200,
      cost_basis: 1100,
      margin_percentage: 8.33,
    })
    expect(margin).toContain("Yerba 1kg")
    expect(margin).toContain("$1200")
    expect(margin).toContain("$1100")
    expect(margin).toContain("8.33%")
  })

  it("plan_upgraded muestra plan capitalizado, monto en es-AR y fecha", () => {
    const html = renderEmailHtml("plan_upgraded", {
      plan: "pro",
      amount: 12000,
      activated_at: "2026-10-17T12:00:00Z",
      receipt_pdf_base64: "AAAA",
    })
    expect(html).toContain("¡Tu plan Pro ya está activo!")
    expect(html).toContain("$12.000")
    expect(html).toContain("17/10/2026")
    expect(html).toContain("comprobante de pago")
  })

  it("plan_downgraded (cancelación del usuario) conserva el texto y la fecha de vencimiento", () => {
    const html = renderEmailHtml("plan_downgraded", {
      plan: "pro",
      plan_expires_at: "2026-11-16T12:00:00+00:00",
      reason: "user_requested",
    })
    expect(html).toContain("Tu suscripción fue cancelada")
    expect(html).toContain("Registramos la cancelación de tu plan Pro.")
    expect(html).toContain("<strong>16/11/2026</strong>")
    expect(hrefsOf(html)).toEqual([`${APP_URL}/planes`])
  })

  it("plan_downgraded por vencimiento usa el otro texto", () => {
    const html = renderEmailHtml("plan_downgraded", { plan: "pro", reason: "expired" })
    expect(html).toContain("Tu suscripción fue dada de baja")
    expect(html).toContain("Tu plan Pro venció y tu cuenta pasó al plan Gratis.")
  })

  it("los digests de deuda vencida siguen mostrando cantidad e importe", () => {
    const html = renderEmailHtml("receivables_overdue_digest", { party_count: 3, overdue_total: 45000 })
    expect(html).toContain("<strong>3 clientes</strong>")
    expect(html).toContain("45.000")
    expect(hrefsOf(html)).toEqual([`${APP_URL}/cobranzas`])
  })

  it("pool_notice y meeting_notice muestran el título escapado", () => {
    const pool = renderEmailHtml("pool_notice", { title: "Pool <Verano> & más", closes_at: "2026-12-01T00:00:00Z" })
    expect(pool).toContain("<strong>Pool &lt;Verano&gt; &amp; más</strong>")
    expect(hrefsOf(pool)).toEqual([`${APP_URL}/comunidad`])
  })

  it("un event_type desconocido cae en el aviso genérico, con el nombre escapado", () => {
    const html = renderEmailHtml("<b>raro</b>", {})
    expect(html).toContain("Recibiste un nuevo aviso: &lt;b&gt;raro&lt;/b&gt;.")
  })
})

// ── org_invite (multiusuario-operativo tanda C, grupo 16) ────────────────────────────────────
//
// El email de invitación es el único que la app manda a una dirección que elige un usuario, y su
// botón lleva un token. Lo que fijan estos tests (specs transactional-email-delivery, «Plantilla de
// correo de invitación a una cuenta»):
//   · todo dato que el usuario controla (nombre del negocio, nombre de quien invita, etiquetas de
//     rol) sale ESCAPADO como texto;
//   · el botón es `APP_URL + /invitacion/ + encodeURIComponent(token)`, NUNCA una URL de la metadata;
//   · un token con forma inválida no dibuja el botón (no hay link a nada raro).

const TOKEN = "0123456789abcdef".repeat(4)

const INVITE_METADATA = {
  invitation_id: "11111111-1111-1111-1111-111111111111",
  account_id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
  token: TOKEN,
  account_name: "Panadería Sol",
  inviter_name: "Ana Gómez",
  roles: ["seller", "cashier"],
  role_labels: ["Vendedor", "Cajero"],
  expires_at: "2026-10-24T12:00:00+00:00",
}

describe("org_invite — el email de invitación a una cuenta", () => {
  it("nombra a quien invita, al negocio, los roles y el vencimiento", () => {
    const html = renderEmailHtml("org_invite", INVITE_METADATA)
    expect(html).toContain("<strong>Ana Gómez</strong> te invitó a sumarte a <strong>Panadería Sol</strong> en ALIADATA")
    expect(html).toContain("<strong>Vendedor, Cajero</strong>")
    expect(html).toContain("<strong>24/10/2026</strong>")
  })

  it("el botón es APP_URL + /invitacion/ + el token codificado, y es el único enlace", () => {
    const html = renderEmailHtml("org_invite", INVITE_METADATA)
    expect(hrefsOf(html)).toEqual([`${APP_URL}/invitacion/${TOKEN}`])
  })

  it("el token se codifica con encodeURIComponent (un carácter reservado no cambia la ruta)", () => {
    // Un token real es hex; uno con `-`/`_` sigue pasando. Lo reservado no pasa la validación de forma.
    const html = renderEmailHtml("org_invite", { ...INVITE_METADATA, token: "abc-DEF_0123456789abcdef" })
    expect(hrefsOf(html)).toEqual([`${APP_URL}/invitacion/${encodeURIComponent("abc-DEF_0123456789abcdef")}`])
  })

  it("el nombre del negocio con marcado se muestra como TEXTO, sin interpretar las etiquetas", () => {
    const html = renderEmailHtml("org_invite", { ...INVITE_METADATA, account_name: "<b>Sol</b> & <i>Hijos</i>" })
    expect(html).toContain("<strong>&lt;b&gt;Sol&lt;/b&gt; &amp; &lt;i&gt;Hijos&lt;/i&gt;</strong>")
    expect(html).not.toContain("<b>Sol</b>")
  })

  it("el nombre de quien invita y las etiquetas de rol también salen escapados", () => {
    const html = renderEmailHtml("org_invite", {
      ...INVITE_METADATA,
      inviter_name: HOSTILE,
      role_labels: [HOSTILE],
    })
    expect(html).not.toContain("<script")
    expect(html).not.toMatch(/<[^>]*onerror[ 	]*=/i)
    expect(html).not.toContain('<a href="https://evil.example')
    expect(html).toContain("&lt;script&gt;alert(1)&lt;/script&gt;")
  })

  it("una URL en la metadata NO aparece en el HTML y no cambia el botón", () => {
    const html = renderEmailHtml("org_invite", {
      ...INVITE_METADATA,
      url: "https://evil.example/phish",
      link: "https://evil.example/phish",
      cta_url: "https://evil.example/phish",
      invite_url: "https://evil.example/phish",
      account_url: "https://evil.example/phish",
    })
    expect(html).not.toContain("evil.example")
    expect(hrefsOf(html)).toEqual([`${APP_URL}/invitacion/${TOKEN}`])
  })

  it("un token hostil o con forma inválida no dibuja ningún botón", () => {
    for (const token of [HOSTILE, "", "corto", "../../etc/passwd", "a b".repeat(20), undefined, null, 42, { toString: () => TOKEN }]) {
      const html = renderEmailHtml("org_invite", { ...INVITE_METADATA, token })
      expect(hrefsOf(html)).toEqual([])
      expect(html).not.toContain("/invitacion/")
    }
  })

  it("sin etiquetas de rol cae a los códigos, y sin ninguno no inventa un rol", () => {
    const codes = renderEmailHtml("org_invite", { ...INVITE_METADATA, role_labels: undefined, roles: ["viewer"] })
    expect(codes).toContain("<strong>viewer</strong>")
    const none = renderEmailHtml("org_invite", { ...INVITE_METADATA, role_labels: [], roles: [] })
    expect(none).not.toContain("como <strong>")
  })

  it("un vencimiento ilegible no rompe el correo ni imprime «Invalid Date»", () => {
    const html = renderEmailHtml("org_invite", { ...INVITE_METADATA, expires_at: "no-es-una-fecha" })
    expect(html).not.toContain("Invalid Date")
    expect(hrefsOf(html)).toEqual([`${APP_URL}/invitacion/${TOKEN}`])
  })

  it("sin nombre de quien invita ni del negocio igual sale un correo legible", () => {
    const html = renderEmailHtml("org_invite", { token: TOKEN })
    expect(html).toContain("Alguien de tu equipo te invitó a sumarte a <strong>un negocio</strong>")
    expect(hrefsOf(html)).toEqual([`${APP_URL}/invitacion/${TOKEN}`])
  })

  it("org_invite NO está entre los eventos que admiten el envío masivo a todos los usuarios", async () => {
    const { isAllUsersFanoutAllowed } = await import("../../supabase/functions/_shared/email-fanout-policy")
    expect(isAllUsersFanoutAllowed("org_invite")).toBe(false)
  })
})
