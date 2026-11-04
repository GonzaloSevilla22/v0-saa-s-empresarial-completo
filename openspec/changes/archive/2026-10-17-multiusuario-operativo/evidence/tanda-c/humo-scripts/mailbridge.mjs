// Puente de correo del humo LOCAL. En producción el trigger on_email_log_insert invoca a la Edge Function `send-email`,
// que renderiza `renderEmailHtml` y manda por Resend. Localmente el trigger se salta (sin secretos en Vault) y Resend no
// alcanza a Mailpit, así que este puente hace lo MISMO que la función con lo único local que cambia el transporte:
// toma las filas `pending` de `email_logs`, las renderiza con la plantilla REAL (supabase/functions/_shared/email-templates.ts)
// y las entrega al Mailpit del stack por su API de envío (el puerto SMTP del contenedor no se publica en el host).
// NO ejercita Resend (externo): sí la fila real y la plantilla real.
// Uso: node mailbridge.mjs   (imprime cuántos correos entregó)
import { pathToFileURL } from "node:url"
import { psql, WT, MAILPIT } from "./common.mjs"

const { renderEmailHtml } = await import(pathToFileURL(`${WT}/supabase/functions/_shared/email-templates.ts`).href)

const rows = JSON.parse(
  psql(`select coalesce(json_agg(t), '[]'::json) from (
          select id, recipient, subject, event_type, metadata
          from public.email_logs where status = 'pending' and event_type = 'org_invite' order by created_at
        ) t`).trim(),
)
let delivered = 0
for (const r of rows) {
  const html = renderEmailHtml(r.event_type, r.metadata)
  const res = await fetch(`${MAILPIT}/api/v1/send`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      From: { Email: "no-reply@aliadata.com.ar", Name: "ALIADATA" },
      To: [{ Email: r.recipient }],
      Subject: r.subject,
      HTML: html,
    }),
  })
  if (!res.ok) throw new Error(`Mailpit /send ${res.status}: ${await res.text()}`)
  psql(`update public.email_logs set status = 'sent', sent_at = now() where id = '${r.id}'`)
  delivered++
}
console.log(`mailbridge: ${delivered} correo(s) entregados a Mailpit`)
