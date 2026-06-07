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
    let htmlContent = `<h1>Notificación de ALIADATA</h1><p>Has recibido un nuevo aviso: ${event_type}</p>`;

    if (event_type === "welcome") {
      htmlContent = `
        <div style="font-family: Arial, sans-serif; color: #333;">
          <h2>¡Bienvenido a ALIADATA Emprendedores! 🚀</h2>
          <p>Nos alegra tenerte en nuestra comunidad. Estás a un paso de optimizar la gestión de tu negocio.</p>
          <a href="https://aliadata.com/dashboard" style="background-color: #10b981; color: white; padding: 10px 20px; text-decoration: none; border-radius: 5px;">Ir a mi Dashboard</a>
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
          <a href="https://aliadata.com/pools/${metadata.pool_id}" style="background-color: #8b5cf6; color: white; padding: 10px 20px; text-decoration: none; border-radius: 5px;">Ver Pool</a>
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
    } else if (event_type === "trial_expiring_soon") {
      // metadata.umbral: '7d' | '1d'
      const umbral = metadata?.umbral ?? "7d";
      const diasLabel = umbral === "1d" ? "1 día" : "7 días";
      const urgenciaColor = umbral === "1d" ? "#ef4444" : "#f59e0b";
      htmlContent = `
        <div style="font-family: Arial, sans-serif; color: #333; max-width: 600px; margin: 0 auto;">
          <div style="background-color: ${urgenciaColor}; padding: 20px; border-radius: 8px 8px 0 0; text-align: center;">
            <h2 style="color: white; margin: 0;">⏰ Te quedan ${diasLabel} de prueba</h2>
          </div>
          <div style="background-color: #f9fafb; padding: 24px; border-radius: 0 0 8px 8px; border: 1px solid #e5e7eb; border-top: none;">
            <p style="font-size: 16px;">Hola,</p>
            <p>Tu período de prueba del plan <strong>Avanzado</strong> en EmprendeSmart está por terminar.</p>
            <p>Cuando venza, vas a seguir usando EmprendeSmart con el <strong>plan Gratis</strong>. Si querés mantener todas las funciones avanzadas, podés elegir un plan pago.</p>
            <div style="text-align: center; margin: 24px 0;">
              <a href="https://emprende-smart.vercel.app/planes"
                 style="background-color: #10b981; color: white; padding: 12px 28px; text-decoration: none; border-radius: 6px; font-weight: bold; font-size: 16px; display: inline-block;">
                Ver planes y precios
              </a>
            </div>
            <p style="color: #6b7280; font-size: 14px;">Si ya elegiste un plan, podés ignorar este mensaje.</p>
            <hr style="border: none; border-top: 1px solid #e5e7eb; margin: 20px 0;">
            <p style="color: #9ca3af; font-size: 12px; text-align: center;">EmprendeSmart — Gestión financiera para microemprendedores de Mendoza</p>
          </div>
        </div>
      `;
    } else if (event_type === "plan_upgraded") {
      // C-10: MercadoPago payment approved → plan activated
      const planName = (metadata?.plan as string | undefined) ?? "pago"
      const planDisplay = planName.charAt(0).toUpperCase() + planName.slice(1)
      const amountDisplay = metadata?.amount != null ? `$${Number(metadata.amount).toLocaleString("es-AR")}` : ""
      const activatedAt = metadata?.activated_at ? new Date(metadata.activated_at as string).toLocaleDateString("es-AR") : new Date().toLocaleDateString("es-AR")
      htmlContent = `
        <div style="font-family: Arial, sans-serif; color: #333; max-width: 600px; margin: 0 auto;">
          <div style="background-color: #10b981; padding: 20px; border-radius: 8px 8px 0 0; text-align: center;">
            <h2 style="color: white; margin: 0;">¡Tu plan ${planDisplay} ya está activo!</h2>
          </div>
          <div style="background-color: #f9fafb; padding: 24px; border-radius: 0 0 8px 8px; border: 1px solid #e5e7eb; border-top: none;">
            <p style="font-size: 16px;">¡Hola!</p>
            <p>Tu pago fue procesado correctamente y el plan <strong>${planDisplay}</strong> está activo en tu cuenta de EmprendeSmart.</p>
            ${amountDisplay ? `<p><strong>Monto abonado:</strong> ${amountDisplay}</p>` : ""}
            <p><strong>Fecha de activación:</strong> ${activatedAt}</p>
            <div style="text-align: center; margin: 24px 0;">
              <a href="https://emprende-smart.vercel.app/dashboard"
                 style="background-color: #10b981; color: white; padding: 12px 28px; text-decoration: none; border-radius: 6px; font-weight: bold; font-size: 16px; display: inline-block;">
                Ir a mi Dashboard
              </a>
            </div>
            <p style="color: #6b7280; font-size: 14px;">Podés ver tu historial de pagos en <a href="https://emprende-smart.vercel.app/facturacion">Facturación</a>.</p>
            <hr style="border: none; border-top: 1px solid #e5e7eb; margin: 20px 0;">
            <p style="color: #9ca3af; font-size: 12px; text-align: center;">EmprendeSmart — Gestión financiera para microemprendedores de Mendoza</p>
          </div>
        </div>
      `
    } else if (event_type === "plan_downgraded") {
      // C-10: subscription cancelled or expired — plan reverted to gratis
      const planDisplay = (() => {
        const p = (metadata?.plan as string | undefined) ?? ""
        return p.charAt(0).toUpperCase() + p.slice(1)
      })()
      const expiresAt = metadata?.plan_expires_at
        ? new Date(metadata.plan_expires_at as string).toLocaleDateString("es-AR")
        : ""
      const reason = (metadata?.reason as string | undefined) ?? "user_requested"
      const isUserRequested = reason === "user_requested"
      htmlContent = `
        <div style="font-family: Arial, sans-serif; color: #333; max-width: 600px; margin: 0 auto;">
          <div style="background-color: #6b7280; padding: 20px; border-radius: 8px 8px 0 0; text-align: center;">
            <h2 style="color: white; margin: 0;">Tu suscripción fue ${isUserRequested ? "cancelada" : "vencida"}</h2>
          </div>
          <div style="background-color: #f9fafb; padding: 24px; border-radius: 0 0 8px 8px; border: 1px solid #e5e7eb; border-top: none;">
            <p style="font-size: 16px;">Hola,</p>
            ${isUserRequested
              ? `<p>Tu solicitud de cancelación del plan <strong>${planDisplay}</strong> fue registrada correctamente.</p>
                 ${expiresAt ? `<p>Tu plan permanecerá activo hasta el <strong>${expiresAt}</strong>, después vas a seguir usando EmprendeSmart con el plan <strong>Gratis</strong>.</p>` : ""}
                 <p>Si fue un error, podés reactivar tu suscripción en cualquier momento.</p>`
              : `<p>Tu plan <strong>${planDisplay}</strong> venció y tu cuenta fue ajustada al plan <strong>Gratis</strong>.</p>
                 <p>Si querés seguir con las funciones avanzadas, podés elegir un nuevo plan.</p>`
            }
            <div style="text-align: center; margin: 24px 0;">
              <a href="https://emprende-smart.vercel.app/planes"
                 style="background-color: #10b981; color: white; padding: 12px 28px; text-decoration: none; border-radius: 6px; font-weight: bold; font-size: 16px; display: inline-block;">
                Ver planes y precios
              </a>
            </div>
            <p style="color: #6b7280; font-size: 14px;">¿Necesitás ayuda? Escribinos por <a href="https://wa.me/5492615000000">WhatsApp</a>.</p>
            <hr style="border: none; border-top: 1px solid #e5e7eb; margin: 20px 0;">
            <p style="color: #9ca3af; font-size: 12px; text-align: center;">EmprendeSmart — Gestión financiera para microemprendedores de Mendoza</p>
          </div>
        </div>
      `
    } else if (event_type === "trial_expired") {
      htmlContent = `
        <div style="font-family: Arial, sans-serif; color: #333; max-width: 600px; margin: 0 auto;">
          <div style="background-color: #6b7280; padding: 20px; border-radius: 8px 8px 0 0; text-align: center;">
            <h2 style="color: white; margin: 0;">Tu período de prueba terminó</h2>
          </div>
          <div style="background-color: #f9fafb; padding: 24px; border-radius: 0 0 8px 8px; border: 1px solid #e5e7eb; border-top: none;">
            <p style="font-size: 16px;">Hola,</p>
            <p>Tu prueba del plan <strong>Avanzado</strong> en EmprendeSmart terminó. A partir de ahora estás usando el <strong>plan Gratis</strong>.</p>
            <p>Con el plan Gratis podés seguir registrando ventas, compras y gastos. Si necesitás funciones avanzadas como reportes comparativos, inteligencia artificial ilimitada o más usuarios, elegí el plan que mejor se adapte a tu negocio.</p>
            <div style="text-align: center; margin: 24px 0;">
              <a href="https://emprende-smart.vercel.app/planes"
                 style="background-color: #10b981; color: white; padding: 12px 28px; text-decoration: none; border-radius: 6px; font-weight: bold; font-size: 16px; display: inline-block;">
                Ver planes y precios
              </a>
            </div>
            <p style="color: #6b7280; font-size: 14px;">Gracias por probar EmprendeSmart. Esperamos verte de nuevo en un plan pago.</p>
            <hr style="border: none; border-top: 1px solid #e5e7eb; margin: 20px 0;">
            <p style="color: #9ca3af; font-size: 12px; text-align: center;">EmprendeSmart — Gestión financiera para microemprendedores de Mendoza</p>
          </div>
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
        toAddresses = ["test@aliadata.com"]; // Fallback if no users or error
      }
    } else {
      toAddresses = [recipient];
    }

    // Dispatch
    console.log(`Sending emails to ${toAddresses.length} recipients for event: ${event_type}`);

    // Batch or loop setup (using Promise.all for simple MVP chunking)
    const emailPromises = toAddresses.map((email) =>
      resend.emails.send({
        from: "ALIADATA Emprendedores <onboarding@resend.dev>",
        to: email,
        subject: subject || "Notificación de ALIADATA",
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
