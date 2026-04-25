import { Resend } from "npm:resend";
import { createClient } from "jsr:@supabase/supabase-js@2";

const resend = new Resend(Deno.env.get("RESEND_API_KEY"));
const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const supabase = createClient(supabaseUrl, supabaseServiceKey);

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

    // Template logic
    let htmlContent = `<h1>Notificación de ALIADA</h1><p>Has recibido un nuevo aviso: ${event_type}</p>`;

    if (event_type === "welcome") {
      htmlContent = `
        <div style="font-family: Arial, sans-serif; color: #333;">
          <h2>¡Bienvenido a ALIADA Emprendedores! 🚀</h2>
          <p>Nos alegra tenerte en nuestra comunidad. Estás a un paso de optimizar la gestión de tu negocio.</p>
          <a href="https://aliada.com/dashboard" style="background-color: #10b981; color: white; padding: 10px 20px; text-decoration: none; border-radius: 5px;">Ir a mi Dashboard</a>
        </div>
      `;
    } else if (event_type === "meeting_notice") {
      htmlContent = `
        <div style="font-family: Arial, sans-serif; color: #333;">
          <h2>📅 Nueva Reunión Programada</h2>
          <p>Se ha agendado una nueva reunión en la comunidad: <strong>${metadata.title}</strong></p>
          <p><strong>Fecha/Hora (UTC):</strong> ${new Date(metadata.start_time).toLocaleString()}</p>
          <a href="${metadata.url}" style="background-color: #3b82f6; color: white; padding: 10px 20px; text-decoration: none; border-radius: 5px;">Unirse a la Reunión</a>
        </div>
      `;
    } else if (event_type === "pool_notice") {
      htmlContent = `
        <div style="font-family: Arial, sans-serif; color: #333;">
          <h2>🛒 Nuevo Pool de Compra Abierto</h2>
          <p>Un nuevo pool de compra está disponible: <strong>${metadata.title}</strong></p>
          <p><strong>Cierra el:</strong> ${new Date(metadata.closes_at).toLocaleDateString()}</p>
          <a href="https://aliada.com/pools/${metadata.pool_id}" style="background-color: #8b5cf6; color: white; padding: 10px 20px; text-decoration: none; border-radius: 5px;">Ver Pool</a>
        </div>
      `;
    } else if (event_type === "low_stock_alert") {
      htmlContent = `
        <div style="font-family: Arial, sans-serif; color: #333;">
          <h2>⚠️ Alerta de Stock Bajo (AI)</h2>
          <p>El producto <strong>${metadata.product_name}</strong> tiene bajo inventario.</p>
          <p><strong>Stock actual:</strong> <span style="color: #ef4444; font-weight: bold;">${metadata.current_stock}</span> unidades.</p>
          <p><em>Te recomendamos reabastecer pronto para no perder ventas.</em></p>
        </div>
      `;
    } else if (event_type === "low_margin_alert") {
      htmlContent = `
        <div style="font-family: Arial, sans-serif; color: #333;">
          <h2>📉 Alerta de Margen Crítico (AI)</h2>
          <p>Se ha registrado una venta con un margen de ganancia inferior al 15%.</p>
          <ul>
            <li><strong>Producto:</strong> ${metadata.product_name}</li>
            <li><strong>Monto Venta:</strong> $${metadata.amount}</li>
            <li><strong>Costo Base:</strong> $${metadata.cost_basis}</li>
            <li><strong>Margen de Ganancia:</strong> <span style="color: #ef4444; font-weight: bold;">${metadata.margin_percentage}%</span></li>
          </ul>
          <p><em>Por favor, revisa tus costos o ajusta el precio para mantener la rentabilidad.</em></p>
        </div>
      `;
    }

    // Recipient logic
    let toAddresses: string[] = [];
    if (recipient === "all_users") {
      const { data: usersData, error: usersError } = await supabase.auth.admin.listUsers();
      if (!usersError && usersData?.users) {
        toAddresses = usersData.users.map((u: any) => u.email).filter(Boolean) as string[];
      }
      if (toAddresses.length === 0) {
        toAddresses = ["test@aliada.com"]; // Fallback if no users or error
      }
    } else {
      toAddresses = [recipient];
    }

    // Dispatch
    console.log(`Sending emails to ${toAddresses.length} recipients for event: ${event_type}`);

    // Batch or loop setup (using Promise.all for simple MVP chunking)
    const emailPromises = toAddresses.map((email) =>
      resend.emails.send({
        from: "ALIADA Emprendedores <onboarding@resend.dev>",
        to: email,
        subject: subject || "Notificación de ALIADA",
        html: htmlContent,
      })
    );

    const results = await Promise.allSettled(emailPromises);

    // Evaluate ALL results, not just the first one
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

    // Partial or full success
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
