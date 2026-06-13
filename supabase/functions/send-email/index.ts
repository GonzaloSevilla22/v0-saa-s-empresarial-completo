import { Resend } from "npm:resend";
import { createClient } from "jsr:@supabase/supabase-js@2";

const resend = new Resend(Deno.env.get("RESEND_API_KEY"));
const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const supabase = createClient(supabaseUrl, supabaseServiceKey);

// ── Branding ──────────────────────────────────────────────────────────────────
const APP_URL = "https://www.aliadata.com.ar";
const LOGO_URL = "https://www.aliadata.com.ar/aliadata-logo.png";
const GREEN = "#10b981";
const DARK = "#0f172a";

/**
 * Envuelve el contenido en el layout de marca ALIADATA (logo + verde/negro).
 * HTML compatible con clientes de email (tablas + estilos inline).
 */
function layout(opts: {
  title: string;
  intro?: string;
  bodyHtml?: string;
  ctaText?: string;
  ctaUrl?: string;
  accent?: string;
}): string {
  const accent = opts.accent ?? GREEN;
  return `
  <div style="margin:0;padding:0;background:#f3f4f6;">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f3f4f6;padding:24px 0;font-family:Arial,Helvetica,sans-serif;">
      <tr><td align="center">
        <table role="presentation" width="600" cellpadding="0" cellspacing="0" style="max-width:600px;width:100%;background:#ffffff;border-radius:12px;overflow:hidden;box-shadow:0 1px 4px rgba(0,0,0,0.12);">
          <tr><td style="background:${DARK};padding:22px 32px;text-align:center;border-bottom:3px solid ${accent};">
            <img src="${LOGO_URL}" width="40" height="40" alt="ALIADATA" style="display:inline-block;vertical-align:middle;border:0;" />
            <span style="display:inline-block;vertical-align:middle;margin-left:10px;font-size:21px;font-weight:bold;letter-spacing:3px;color:#ffffff;">ALIADATA</span>
          </td></tr>
          <tr><td style="padding:32px;color:#334155;font-size:15px;line-height:1.6;">
            <h1 style="margin:0 0 16px;font-size:22px;color:${DARK};">${opts.title}</h1>
            ${opts.intro ? `<p style="margin:0 0 16px;">${opts.intro}</p>` : ""}
            ${opts.bodyHtml ?? ""}
            ${opts.ctaText && opts.ctaUrl ? `
            <table role="presentation" cellpadding="0" cellspacing="0" style="margin:26px 0 8px;"><tr>
              <td style="border-radius:8px;background:${accent};">
                <a href="${opts.ctaUrl}" style="display:inline-block;padding:13px 30px;font-size:15px;font-weight:bold;color:#ffffff;text-decoration:none;border-radius:8px;">${opts.ctaText}</a>
              </td></tr></table>` : ""}
          </td></tr>
          <tr><td style="background:${DARK};padding:22px 32px;text-align:center;">
            <p style="margin:0 0 4px;font-size:13px;font-weight:bold;letter-spacing:2px;color:${accent};">ALIADATA</p>
            <p style="margin:0;font-size:11px;color:#94a3b8;">Gestión inteligente para tu negocio</p>
            <p style="margin:10px 0 0;font-size:11px;color:#64748b;">© 2026 ALIADATA · Mendoza, Argentina</p>
          </td></tr>
        </table>
      </td></tr>
    </table>
  </div>`;
}

function infoRow(label: string, value: string): string {
  return `<tr>
    <td style="padding:7px 0;color:#64748b;width:130px;vertical-align:top;">${label}</td>
    <td style="padding:7px 0;color:${DARK};font-weight:bold;">${value}</td>
  </tr>`;
}

Deno.serve(async (req: Request) => {
  try {
    const rawBody = await req.text();
    console.log("Raw Webhook Payload:", rawBody);

    let payload;
    try {
      payload = JSON.parse(rawBody);
    } catch (parseError) {
      console.error("Failed to parse JSON:", parseError);
      return new Response("Invalid JSON payload", { status: 400 });
    }

    // Verify it's an insert to email_logs
    if (payload.type !== "INSERT" || payload.table !== "email_logs") {
      console.log("Ignored payload type/table:", payload.type, payload.table);
      return new Response("Not an email log insert", { status: 400 });
    }

    const record = payload.record;
    if (!record || !record.id || record.status !== "pending") {
      console.log("Ignored record status:", record?.status);
      return new Response("Invalid or already processed log", { status: 400 });
    }

    const { id, event_type, recipient, subject, metadata } = record;

    // ── Template por tipo de evento (todos con el layout de marca) ────────────
    let htmlContent = layout({
      title: "Notificación de ALIADATA",
      intro: `Recibiste un nuevo aviso: ${event_type}.`,
    });

    if (event_type === "welcome") {
      htmlContent = layout({
        title: "¡Te damos la bienvenida! 🚀",
        intro: `Hola ${metadata?.name ?? ""}, ¡gracias por sumarte a ALIADATA!`,
        bodyHtml: `<p style="margin:0 0 16px;">Ya podés empezar a ordenar tu negocio: registrá ventas, compras y stock, y dejá que la inteligencia artificial te dé información útil para crecer.</p>`,
        ctaText: "Ir a mi panel",
        ctaUrl: `${APP_URL}/dashboard`,
      });
    } else if (event_type === "new_user_admin_notice") {
      htmlContent = layout({
        title: "Nuevo registro en ALIADATA",
        intro: "Se registró un nuevo usuario en la app:",
        bodyHtml: `<table role="presentation" cellpadding="0" cellspacing="0" style="width:100%;font-size:15px;">
          ${infoRow("Nombre", metadata?.name ?? "-")}
          ${infoRow("Email", metadata?.email ?? "-")}
          ${infoRow("Teléfono", metadata?.phone ?? "-")}
          ${infoRow("Localidad", metadata?.locality ?? "-")}
        </table>`,
      });
    } else if (event_type === "meeting_notice") {
      htmlContent = layout({
        title: "📅 Nueva reunión programada",
        intro: `Se agendó una nueva reunión en la comunidad: <strong>${metadata.title}</strong>.`,
        bodyHtml: `<p style="margin:0;"><strong>Fecha/Hora (UTC):</strong> ${new Date(metadata.start_time).toLocaleString()}</p>`,
        ctaText: "Unirse a la reunión",
        ctaUrl: metadata.url,
      });
    } else if (event_type === "pool_notice") {
      htmlContent = layout({
        title: "🛒 Nuevo pool de compra abierto",
        intro: `Hay un nuevo pool de compra disponible: <strong>${metadata.title}</strong>.`,
        bodyHtml: `<p style="margin:0;"><strong>Cierra el:</strong> ${new Date(metadata.closes_at).toLocaleDateString()}</p>`,
        ctaText: "Ver pool",
        ctaUrl: `${APP_URL}/comunidad`,
      });
    } else if (event_type === "low_stock_alert") {
      htmlContent = layout({
        title: "⚠️ Alerta de stock bajo",
        intro: `El producto <strong>${metadata.product_name}</strong> tiene poco inventario.`,
        bodyHtml: `<p style="margin:0 0 8px;"><strong>Stock actual:</strong> <span style="color:#ef4444;font-weight:bold;">${metadata.current_stock}</span> unidades.</p>
          <p style="margin:0;color:#64748b;">Te recomendamos reabastecer pronto para no perder ventas.</p>`,
        ctaText: "Ver stock",
        ctaUrl: `${APP_URL}/stock`,
      });
    } else if (event_type === "low_margin_alert") {
      htmlContent = layout({
        title: "📉 Alerta de margen crítico",
        intro: "Se registró una venta con un margen de ganancia inferior al 15%.",
        bodyHtml: `<table role="presentation" cellpadding="0" cellspacing="0" style="width:100%;font-size:15px;">
          ${infoRow("Producto", String(metadata.product_name ?? "-"))}
          ${infoRow("Monto de venta", `$${metadata.amount}`)}
          ${infoRow("Costo base", `$${metadata.cost_basis}`)}
          ${infoRow("Margen", `<span style="color:#ef4444;">${metadata.margin_percentage}%</span>`)}
        </table>
        <p style="margin:16px 0 0;color:#64748b;">Revisá tus costos o ajustá el precio para mantener la rentabilidad.</p>`,
      });
    } else if (event_type === "trial_expiring_soon") {
      const umbral = metadata?.umbral ?? "7d";
      const diasLabel = umbral === "1d" ? "1 día" : "7 días";
      htmlContent = layout({
        title: `⏰ Te quedan ${diasLabel} de prueba`,
        intro: "Tu período de prueba del plan Avanzado está por terminar.",
        bodyHtml: `<p style="margin:0;">Cuando venza, vas a seguir usando ALIADATA con el plan Gratis. Si querés mantener todas las funciones avanzadas, elegí un plan pago.</p>`,
        ctaText: "Ver planes y precios",
        ctaUrl: `${APP_URL}/planes`,
      });
    } else if (event_type === "plan_upgraded") {
      const planName = (metadata?.plan as string | undefined) ?? "pago";
      const planDisplay = planName.charAt(0).toUpperCase() + planName.slice(1);
      const amountDisplay = metadata?.amount != null ? `$${Number(metadata.amount).toLocaleString("es-AR")}` : "";
      const activatedAt = metadata?.activated_at
        ? new Date(metadata.activated_at as string).toLocaleDateString("es-AR")
        : new Date().toLocaleDateString("es-AR");
      htmlContent = layout({
        title: `¡Tu plan ${planDisplay} ya está activo!`,
        intro: "¡Hola! Tu pago se procesó correctamente y tu plan ya está activo en ALIADATA.",
        bodyHtml: `<table role="presentation" cellpadding="0" cellspacing="0" style="width:100%;font-size:15px;">
          ${infoRow("Plan", planDisplay)}
          ${amountDisplay ? infoRow("Monto abonado", amountDisplay) : ""}
          ${infoRow("Fecha de activación", activatedAt)}
        </table>
        ${metadata?.receipt_pdf_base64 ? `<p style="margin:18px 0 0;color:#64748b;">Adjuntamos tu <strong>comprobante de pago</strong> en PDF.</p>` : ""}`,
        ctaText: "Ir a mi panel",
        ctaUrl: `${APP_URL}/dashboard`,
      });
    } else if (event_type === "payment_receipt") {
      const planName = (metadata?.plan as string | undefined) ?? "";
      const planDisplay = planName ? planName.charAt(0).toUpperCase() + planName.slice(1) : "";
      const amountDisplay = metadata?.amount != null ? `$${Number(metadata.amount).toLocaleString("es-AR")}` : "";
      htmlContent = layout({
        title: "Tu comprobante de pago",
        intro: "¡Gracias por tu pago! Adjuntamos el comprobante de tu suscripción a ALIADATA.",
        bodyHtml: `<table role="presentation" cellpadding="0" cellspacing="0" style="width:100%;font-size:15px;">
          ${metadata?.receipt_number ? infoRow("N° de recibo", String(metadata.receipt_number)) : ""}
          ${planDisplay ? infoRow("Plan", planDisplay) : ""}
          ${amountDisplay ? infoRow("Monto", amountDisplay) : ""}
        </table>
        <p style="margin:18px 0 0;color:#64748b;">El comprobante en PDF va adjunto a este correo. Es un comprobante de pago, no una factura.</p>`,
      });
    } else if (event_type === "plan_downgraded") {
      const p = (metadata?.plan as string | undefined) ?? "";
      const planDisplay = p ? p.charAt(0).toUpperCase() + p.slice(1) : "";
      const reason = (metadata?.reason as string | undefined) ?? "user_requested";
      const isUserRequested = reason === "user_requested";
      const expiresAt = metadata?.plan_expires_at
        ? new Date(metadata.plan_expires_at as string).toLocaleDateString("es-AR")
        : "";
      htmlContent = layout({
        title: `Tu suscripción fue ${isUserRequested ? "cancelada" : "dada de baja"}`,
        intro: isUserRequested
          ? `Registramos la cancelación de tu plan ${planDisplay}.`
          : `Tu plan ${planDisplay} venció y tu cuenta pasó al plan Gratis.`,
        bodyHtml: isUserRequested && expiresAt
          ? `<p style="margin:0;">Tu plan sigue activo hasta el <strong>${expiresAt}</strong>; después vas a usar ALIADATA con el plan Gratis. Si fue un error, podés reactivar cuando quieras.</p>`
          : `<p style="margin:0;">Si querés seguir con las funciones avanzadas, podés elegir un nuevo plan.</p>`,
        ctaText: "Ver planes y precios",
        ctaUrl: `${APP_URL}/planes`,
      });
    } else if (event_type === "trial_expired") {
      htmlContent = layout({
        title: "Tu período de prueba terminó",
        intro: "Tu prueba del plan Avanzado terminó. A partir de ahora usás el plan Gratis.",
        bodyHtml: `<p style="margin:0;">Con el plan Gratis seguís registrando ventas, compras y gastos. Si necesitás reportes comparativos, IA ilimitada o más usuarios, elegí el plan que mejor se adapte a tu negocio.</p>`,
        ctaText: "Ver planes y precios",
        ctaUrl: `${APP_URL}/planes`,
      });
    }

    // ── Adjunto del recibo (si viene en metadata) ─────────────────────────────
    // El backend genera el PDF (build_receipt_pdf) y lo deja en
    // metadata.receipt_pdf_base64 para plan_upgraded / payment_receipt.
    const attachments = metadata?.receipt_pdf_base64
      ? [{
          filename: `recibo-${metadata?.receipt_number ?? "aliadata"}.pdf`,
          content: metadata.receipt_pdf_base64 as string,
        }]
      : undefined;

    // Recipient logic
    let toAddresses: string[] = [];
    if (recipient === "all_users") {
      const { data: usersData, error: usersError } = await supabase.auth.admin.listUsers();
      if (!usersError && usersData?.users) {
        toAddresses = usersData.users.map((u: any) => u.email).filter(Boolean) as string[];
      }
      if (toAddresses.length === 0) {
        toAddresses = ["test@aliadata.com"]; // Fallback if no users or error
      }
    } else {
      toAddresses = [recipient];
    }

    // Dispatch
    console.log(`Sending emails to ${toAddresses.length} recipients for event: ${event_type}`);

    const emailPromises = toAddresses.map((email) =>
      resend.emails.send({
        from: "ALIADATA <no-reply@aliadata.com.ar>",
        to: email,
        subject: subject || "Notificación de ALIADATA",
        html: htmlContent,
        ...(attachments ? { attachments } : {}),
      })
    );

    const results = await Promise.allSettled(emailPromises);

    const successful = results.filter(
      (r): r is PromiseFulfilledResult<any> =>
        r.status === "fulfilled" && !r.value?.error
    );
    const failed = results.filter(
      (r) =>
        r.status === "rejected" ||
        (r.status === "fulfilled" && (r as PromiseFulfilledResult<any>).value?.error)
    );

    const errorMessages = failed.map((r) => {
      if (r.status === "rejected") {
        return (r as PromiseRejectedResult).reason?.message ?? String((r as PromiseRejectedResult).reason);
      }
      return (r as PromiseFulfilledResult<any>).value?.error?.message ??
        JSON.stringify((r as PromiseFulfilledResult<any>).value?.error);
    });

    console.log(`Email batch result — sent: ${successful.length}, failed: ${failed.length}, total: ${toAddresses.length}`);

    const allFailed = successful.length === 0;
    const partialFailed = failed.length > 0 && successful.length > 0;
    const firstSuccessId = successful[0]?.value?.data?.id ?? "batch-sent";

    if (allFailed) {
      console.error("All emails failed:", errorMessages);
      await supabase.from("email_logs").update({
        status: "failed",
        error_details: JSON.stringify({ errors: errorMessages, sent: 0, total: toAddresses.length }),
      }).eq("id", id);

      return new Response(JSON.stringify({ error: "All emails failed", details: errorMessages }), {
        status: 400,
        headers: { "Content-Type": "application/json" },
      });
    }

    await supabase.from("email_logs").update({
      status: partialFailed ? "partial" : "sent",
      provider_id: firstSuccessId,
      sent_at: new Date().toISOString(),
      error_details: partialFailed
        ? JSON.stringify({ errors: errorMessages, sent: successful.length, total: toAddresses.length })
        : null,
    }).eq("id", id);

    return new Response(
      JSON.stringify({ success: true, sent: successful.length, failed: failed.length, total: toAddresses.length }),
      { status: 200, headers: { "Content-Type": "application/json" } }
    );
  } catch (error: any) {
    console.error("Function Error:", error);
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
});
