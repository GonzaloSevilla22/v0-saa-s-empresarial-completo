import { Resend } from "npm:resend";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { verifyWebhookSecret } from "../_shared/webhook-auth.ts";
import { isAllUsersFanoutAllowed } from "../_shared/email-fanout-policy.ts";
import { receiptAttachmentFilename, renderEmailHtml } from "../_shared/email-templates.ts";

const resend = new Resend(Deno.env.get("RESEND_API_KEY"));
const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const supabase = createClient(supabaseUrl, supabaseServiceKey);

Deno.serve(async (req: Request) => {
  try {
    // send-email-webhook-hardening (D3/D4): the FIRST operation of the
    // handler authenticates the caller, before parsing the body and before
    // any use of Resend. Only the production trigger (via pg_net) knows the
    // secret it reads from Supabase Vault; verify_jwt cannot be used here
    // (design.md §Restricción central). A rejection returns immediately —
    // no `email_logs` row is read or written, closing the "UPDATE with an
    // attacker-chosen id" vector (design.md §Context).
    const providedSecret = req.headers.get("x-webhook-secret");
    const expectedSecret = Deno.env.get("SEND_EMAIL_WEBHOOK_SECRET");
    const authResult = verifyWebhookSecret(providedSecret, expectedSecret);
    if (!authResult.ok) {
      // Log the cause (401 vs 503) for observability, WITHOUT ever logging
      // the provided or expected secret values.
      console.error(`[send-email] webhook auth rejected: ${authResult.reason} (HTTP ${authResult.status})`);
      return new Response(JSON.stringify({ error: authResult.reason }), {
        status: authResult.status,
        headers: { "Content-Type": "application/json" },
      });
    }

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
    // El armado vive en el módulo puro _shared/email-templates.ts (testeado desde
    // frontend/__tests__/send-email-templates.test.ts): escapa todo dato de
    // `metadata` y NUNCA toma un enlace de ella (email-logs-cierre-insert, OQ-7).
    const htmlContent = renderEmailHtml(event_type, metadata);

    // ── Adjunto del recibo (si viene en metadata) ─────────────────────────────
    // El backend genera el PDF (build_receipt_pdf) y lo deja en
    // metadata.receipt_pdf_base64 para plan_upgraded / payment_receipt.
    const attachments = metadata?.receipt_pdf_base64
      ? [{
          filename: receiptAttachmentFilename(metadata?.receipt_number),
          content: metadata.receipt_pdf_base64 as string,
        }]
      : undefined;

    // Recipient logic
    let toAddresses: string[] = [];
    if (recipient === "all_users") {
      // send-email-webhook-hardening group 6 (ACTIVO, sign-off PO 2026-07-31,
      // OQ3 = sí): tras la autenticación del webhook, el fan-out masivo deja
      // de ser alcanzable desde afuera pero sigue siendo un riesgo de
      // accidente interno — un INSERT equivocado en email_logs dispararía un
      // envío a TODOS los usuarios reales sin confirmación. Se restringe a
      // los event_type pensados para llegar a todos (avisos de comunidad).
      if (!isAllUsersFanoutAllowed(event_type)) {
        console.error(`[send-email] all_users fan-out rejected for disallowed event_type: ${event_type}`);
        await supabase.from("email_logs").update({
          status: "failed",
          error_details: JSON.stringify({
            error: "all_users fan-out not allowed for this event_type",
            event_type,
          }),
        }).eq("id", id);

        return new Response(
          JSON.stringify({ error: "all_users fan-out not allowed for this event_type" }),
          { status: 403, headers: { "Content-Type": "application/json" } },
        );
      }

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
