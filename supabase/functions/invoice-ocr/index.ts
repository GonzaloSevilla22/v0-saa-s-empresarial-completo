import { createClient } from 'jsr:@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

// GPT-4o vision can take up to 40s on a high-res invoice image.
const AI_TIMEOUT_MS = 55_000

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    status,
  })
}

// ── Prompt ─────────────────────────────────────────────────────────────────────
const SYSTEM_PROMPT = `Sos un sistema experto en análisis de facturas comerciales argentinas.
Extraé TODA la información de la imagen con máxima precisión.

CONTEXTO ARGENTINA:
- Facturas tipo A (entre responsables inscriptos), B (a consumidor final), C (monotributista)
- CUIT formato: XX-XXXXXXXX-X
- IVA: 21% estándar, 10.5% reducido, 0% exento
- Moneda principal: ARS. También USD, EUR.
- Fechas: podés ver DD/MM/YYYY, MM/DD/YYYY o YYYY-MM-DD — siempre devolvé YYYY-MM-DD.

INSTRUCCIONES:
1. Extraé EXACTAMENTE lo que ves — nunca inventes datos.
2. Si un campo no está legible, devolvé null.
3. Para la lista de ítems: extraé CADA línea de producto/servicio.
4. Interpretá unidades: kg, g, lt, ml, m, cm, u, doc, cj, paq, un.
5. Si hay descuentos por línea o globales, capturálos por separado.
6. Para product description: normalizá el texto (sin abreviaciones raras, mayúsculas correctas).
7. Si el documento está rotado, borroso o incompleto, igual intentá extraer lo que puedas y reportalo en warnings.

FORMATO DE RESPUESTA — devolvé SOLO este JSON sin texto adicional:
{
  "supplier": {
    "name": "string o null",
    "cuit": "string o null",
    "address": "string o null",
    "invoice_type": "A|B|C|otro|null"
  },
  "invoice": {
    "number": "string o null",
    "date": "YYYY-MM-DD o null",
    "currency": "ARS|USD|EUR|null"
  },
  "totals": {
    "subtotal": number_or_null,
    "vat_amount": number_or_null,
    "vat_rate": number_or_null,
    "other_taxes": number_or_null,
    "discount": number_or_null,
    "total": number_or_null
  },
  "items": [
    {
      "raw_description": "texto OCR original",
      "description": "nombre normalizado del producto",
      "quantity": number,
      "unit": "kg|g|L|mL|m|cm|u|doc|cj|null",
      "unit_price": number_or_null,
      "discount_pct": number_or_null,
      "subtotal": number_or_null
    }
  ],
  "confidence": 0.95,
  "warnings": ["string array de alertas sobre calidad o dudas"]
}`

// ── Main handler ───────────────────────────────────────────────────────────────

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })

  const startMs = Date.now()
  console.log('[invoice-ocr] Request received')

  try {
    // ── Auth ────────────────────────────────────────────────────────────────────
    const authHeader = req.headers.get('Authorization')
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_ANON_KEY') ?? '',
      { global: { headers: { Authorization: authHeader! } } }
    )
    const adminClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    )

    const { data: { user }, error: userError } = await supabase.auth.getUser()
    if (userError || !user) {
      return jsonResponse({ ok: false, error: 'No autorizado' }, 401)
    }

    // ── Parse body ──────────────────────────────────────────────────────────────
    const { document_id, storage_path } = await req.json()
    if (!document_id || !storage_path) {
      return jsonResponse({ ok: false, error: 'Faltan document_id o storage_path' }, 400)
    }

    // Verify document belongs to this user
    const { data: doc, error: docErr } = await supabase
      .from('invoice_documents')
      .select('id, mime_type, status')
      .eq('id', document_id)
      .eq('user_id', user.id)
      .single()

    if (docErr || !doc) {
      return jsonResponse({ ok: false, error: 'Documento no encontrado' }, 404)
    }
    if (doc.status === 'completed') {
      return jsonResponse({ ok: false, error: 'Documento ya fue procesado' }, 409)
    }

    // Mark as processing
    await supabase
      .from('invoice_documents')
      .update({ status: 'processing' })
      .eq('id', document_id)

    // ── Download file from storage ──────────────────────────────────────────────
    console.log('[invoice-ocr] Downloading:', storage_path)
    const { data: fileData, error: downloadErr } = await adminClient
      .storage
      .from('invoices')
      .download(storage_path)

    if (downloadErr || !fileData) {
      await supabase.from('invoice_documents').update({
        status: 'failed',
        error_message: `Storage download error: ${downloadErr?.message}`,
        processing_ms: Date.now() - startMs,
      }).eq('id', document_id)
      return jsonResponse({ ok: false, error: 'No se pudo descargar el archivo' }, 500)
    }

    // ── Convert to base64 ───────────────────────────────────────────────────────
    const arrayBuffer = await fileData.arrayBuffer()
    const uint8Array  = new Uint8Array(arrayBuffer)
    const base64      = btoa(String.fromCharCode(...uint8Array))
    const mimeType    = doc.mime_type || 'image/jpeg'

    if (!mimeType.startsWith('image/')) {
      await supabase.from('invoice_documents').update({
        status: 'failed',
        error_message: 'Solo se soportan imágenes (JPEG, PNG, WEBP, HEIC). Para PDFs, tomá una foto o captura de pantalla.',
        processing_ms: Date.now() - startMs,
      }).eq('id', document_id)
      return jsonResponse({
        ok: false,
        error: 'Formato no soportado. Subí una foto de la factura (JPEG, PNG o WEBP).'
      }, 422)
    }

    // ── Call GPT-4o Vision ──────────────────────────────────────────────────────
    const openAiKey = Deno.env.get('OPENAI_API_KEY')
    if (!openAiKey) return jsonResponse({ ok: false, error: 'OpenAI no configurado' }, 500)

    console.log('[invoice-ocr] Calling GPT-4o vision, image size:', uint8Array.length, 'bytes')

    const controller = new AbortController()
    const timer = setTimeout(() => controller.abort(), AI_TIMEOUT_MS)

    let aiResponse: Response
    try {
      aiResponse = await fetch('https://api.openai.com/v1/chat/completions', {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${openAiKey}`,
          'Content-Type': 'application/json',
        },
        signal: controller.signal,
        body: JSON.stringify({
          model: 'gpt-4o',
          messages: [
            { role: 'system', content: SYSTEM_PROMPT },
            {
              role: 'user',
              content: [
                {
                  type: 'image_url',
                  image_url: {
                    url: `data:${mimeType};base64,${base64}`,
                    detail: 'high',
                  },
                },
                {
                  type: 'text',
                  text: 'Analizá esta factura y devolvé el JSON según el formato indicado.',
                },
              ],
            },
          ],
          response_format: { type: 'json_object' },
          max_tokens: 2000,
          temperature: 0.1,
        }),
      })
    } catch (fetchErr: unknown) {
      clearTimeout(timer)
      const isAbort = fetchErr instanceof DOMException && fetchErr.name === 'AbortError'
      const errMsg = isAbort ? 'Timeout al procesar la imagen. Intentá con una imagen más pequeña.' : String(fetchErr)
      await supabase.from('invoice_documents').update({
        status: 'failed', error_message: errMsg, processing_ms: Date.now() - startMs,
      }).eq('id', document_id)
      return jsonResponse({ ok: false, error: errMsg }, 504)
    }
    clearTimeout(timer)

    if (!aiResponse.ok) {
      const errText = await aiResponse.text().catch(() => 'unknown')
      let errMsg = `OpenAI error ${aiResponse.status}`
      try { errMsg = JSON.parse(errText)?.error?.message || errMsg } catch (_) {}
      console.error('[invoice-ocr] OpenAI error:', errMsg)
      await supabase.from('invoice_documents').update({
        status: 'failed', error_message: errMsg, processing_ms: Date.now() - startMs,
      }).eq('id', document_id)
      return jsonResponse({ ok: false, error: errMsg }, 502)
    }

    // ── Parse AI response ───────────────────────────────────────────────────────
    const aiData    = await aiResponse.json()
    const rawContent = aiData?.choices?.[0]?.message?.content ?? ''
    console.log('[invoice-ocr] Raw AI response length:', rawContent.length)

    let parsed: Record<string, unknown>
    try {
      const cleaned = rawContent.replace(/^```(?:json)?\s*/i, '').replace(/\s*```$/, '').trim()
      parsed = JSON.parse(cleaned)
    } catch (_) {
      const errMsg = 'No se pudo parsear la respuesta de IA'
      await supabase.from('invoice_documents').update({
        status: 'failed', error_message: errMsg, processing_ms: Date.now() - startMs,
      }).eq('id', document_id)
      return jsonResponse({ ok: false, error: errMsg }, 500)
    }

    const processingMs = Date.now() - startMs
    const invoice  = parsed.invoice  as Record<string, unknown> ?? {}
    const supplier = parsed.supplier as Record<string, unknown> ?? {}
    const totals   = parsed.totals   as Record<string, unknown> ?? {}

    // ── Persist result ──────────────────────────────────────────────────────────
    const { error: updateErr } = await supabase
      .from('invoice_documents')
      .update({
        status:           'completed',
        ai_model:         'gpt-4o',
        ai_raw_response:  parsed,
        ai_confidence:    typeof parsed.confidence === 'number' ? Math.min(1, Math.max(0, parsed.confidence)) : null,
        ai_warnings:      Array.isArray(parsed.warnings) ? parsed.warnings : [],
        parsed_items:     Array.isArray(parsed.items) ? parsed.items : [],
        supplier_name:    typeof supplier.name   === 'string' ? supplier.name   : null,
        supplier_cuit:    typeof supplier.cuit   === 'string' ? supplier.cuit   : null,
        invoice_number:   typeof invoice.number  === 'string' ? invoice.number  : null,
        invoice_date:     typeof invoice.date    === 'string' ? invoice.date    : null,
        invoice_type:     typeof supplier.invoice_type === 'string' ? supplier.invoice_type : null,
        invoice_currency: typeof invoice.currency === 'string' ? invoice.currency : 'ARS',
        invoice_total:    typeof totals.total    === 'number' ? totals.total    : null,
        processing_ms:    processingMs,
      })
      .eq('id', document_id)

    if (updateErr) console.error('[invoice-ocr] DB update error:', updateErr.message)

    console.log('[invoice-ocr] Done in', processingMs, 'ms. Items:', (parsed.items as unknown[])?.length ?? 0)

    return jsonResponse({
      ok: true,
      document_id,
      processing_ms: processingMs,
      result: parsed,
    })

  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err)
    console.error('[invoice-ocr] Unhandled error:', msg)
    return jsonResponse({ ok: false, error: msg }, 500)
  }
})