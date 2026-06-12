// C-14 generate-export Edge Function
// Generates CSV or XLSX files from user data, enforces monthly export quota,
// uploads to Storage bucket `exports`, and returns a signed URL (1 hour).

import { createClient } from 'jsr:@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

type ExportType = 'sales_csv' | 'purchases_csv' | 'expenses_csv' | 'stock_csv' | 'full_report_xlsx'
type Plan = 'gratis' | 'inicial' | 'avanzado' | 'pro'

// ─── Helpers ──────────────────────────────────────────────────────────────────

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    status,
  })
}

function getEffectivePlan(profile: {
  billing_plan: string | null
  billing_status: string | null
  trial_plan: string | null
  trial_expires_at: string | null
}): Plan {
  const now = new Date()
  const trialActive =
    profile.billing_status === 'trialing' &&
    profile.trial_plan != null &&
    profile.trial_expires_at != null &&
    new Date(profile.trial_expires_at) > now
  return ((trialActive ? profile.trial_plan : profile.billing_plan) ?? 'gratis') as Plan
}

function historyDateFrom(historyDays: number): string {
  const d = new Date()
  d.setDate(d.getDate() - historyDays)
  return d.toISOString().split('T')[0]
}

// ─── CSV generators ───────────────────────────────────────────────────────────

function rowsToCsv(headers: string[], rows: Record<string, unknown>[]): string {
  const escape = (v: unknown) => {
    const s = v == null ? '' : String(v)
    return s.includes(',') || s.includes('"') || s.includes('\n')
      ? `"${s.replace(/"/g, '""')}"`
      : s
  }
  const lines = [headers.join(',')]
  for (const row of rows) {
    lines.push(headers.map(h => escape(row[h])).join(','))
  }
  return lines.join('\r\n')
}

// deno-lint-ignore no-explicit-any
async function fetchSalesRows(supabase: any, dateFrom: string) {
  const { data } = await supabase
    .from('sales')
    .select('date, amount, total, quantity, currency, product:products(name), client:clients(name), branch:branches(name)')
    .gte('date', dateFrom)
    .order('date', { ascending: false })
    .limit(10000)
  return (data ?? []).map((r: Record<string, unknown>) => ({
    fecha:       (r.date as string)?.split('T')[0] ?? r.date,
    cliente:     ((r.client as Record<string, unknown>)?.name as string) ?? 'Consumidor Final',
    producto:    ((r.product as Record<string, unknown>)?.name as string) ?? 'Eliminado',
    cantidad:    r.quantity,
    precio_unit: r.amount,
    total:       r.total,
    moneda:      r.currency,
    sucursal:    ((r.branch as Record<string, unknown>)?.name as string) ?? 'Principal',
  }))
}

// deno-lint-ignore no-explicit-any
async function fetchPurchasesRows(supabase: any, dateFrom: string) {
  const { data } = await supabase
    .from('purchases')
    .select('date, amount, total, quantity, currency, product:products(name), branch:branches(name)')
    .gte('date', dateFrom)
    .order('date', { ascending: false })
    .limit(10000)
  return (data ?? []).map((r: Record<string, unknown>) => ({
    fecha:       (r.date as string)?.split('T')[0] ?? r.date,
    producto:    ((r.product as Record<string, unknown>)?.name as string) ?? 'Eliminado',
    cantidad:    r.quantity,
    precio_unit: r.amount,
    total:       r.total,
    moneda:      r.currency,
    sucursal:    ((r.branch as Record<string, unknown>)?.name as string) ?? 'Principal',
  }))
}

// deno-lint-ignore no-explicit-any
async function fetchExpensesRows(supabase: any, dateFrom: string) {
  const { data } = await supabase
    .from('expenses')
    .select('date, amount, category, description, currency, branch:branches(name)')
    .gte('date', dateFrom)
    .order('date', { ascending: false })
    .limit(10000)
  return (data ?? []).map((r: Record<string, unknown>) => ({
    fecha:       (r.date as string)?.split('T')[0] ?? r.date,
    categoria:   r.category,
    descripcion: r.description,
    monto:       r.amount,
    moneda:      r.currency,
    sucursal:    ((r.branch as Record<string, unknown>)?.name as string) ?? 'Principal',
  }))
}

// deno-lint-ignore no-explicit-any
async function fetchStockRows(supabase: any) {
  // C-21 checkpoint #2: stock vive en branch_stock — la vista expone stock = Σ branch_stock.
  // Se quita 'currency' del select: products nunca tuvo esa columna (el select fallaba
  // y la hoja de stock se exportaba vacía).
  const { data } = await supabase
    .from('v_products_with_stock')
    .select('name, sku, stock, min_stock, price')
    .order('name', { ascending: true })
    .limit(10000)
  return (data ?? []).map((r: Record<string, unknown>) => ({
    nombre:     r.name,
    sku:        r.sku,
    stock:      r.stock,
    min_stock:  r.min_stock,
    precio:     r.price,
  }))
}

// ─── XLSX via SheetJS (CDN) ────────────────────────────────────────────────────

// deno-lint-ignore no-explicit-any
async function buildXlsx(sheets: { name: string; rows: Record<string, unknown>[] }[]): Promise<Uint8Array> {
  // @ts-ignore — SheetJS loaded from CDN
  const XLSX = await import('https://cdn.sheetjs.com/xlsx-0.20.2/package/xlsx.mjs')
  const wb = XLSX.utils.book_new()
  for (const { name, rows } of sheets) {
    const ws = XLSX.utils.json_to_sheet(rows)
    XLSX.utils.book_append_sheet(wb, ws, name)
  }
  return XLSX.write(wb, { type: 'array', bookType: 'xlsx' }) as Uint8Array
}

// ─── Handler ──────────────────────────────────────────────────────────────────

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })

  console.log('[generate-export] Request received')

  try {
    // ── Auth ──────────────────────────────────────────────────────────────────
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_ANON_KEY') ?? '',
      { global: { headers: { Authorization: req.headers.get('Authorization')! } } }
    )

    const { data: { user }, error: userError } = await supabase.auth.getUser()
    if (userError || !user) {
      return jsonResponse({ ok: false, error: 'No autorizado' }, 401)
    }

    // ── Parse body ────────────────────────────────────────────────────────────
    const body = await req.json().catch(() => ({}))
    const exportType: ExportType = body.export_type
    const validTypes: ExportType[] = ['sales_csv', 'purchases_csv', 'expenses_csv', 'stock_csv', 'full_report_xlsx']
    if (!validTypes.includes(exportType)) {
      return jsonResponse({ ok: false, error: 'invalid_export_type' }, 400)
    }

    // ── Load profile + plan ───────────────────────────────────────────────────
    const { data: profile, error: profErr } = await supabase
      .from('profiles')
      .select('billing_plan, billing_status, trial_plan, trial_expires_at, exports_used')
      .eq('id', user.id)
      .single()

    if (profErr || !profile) {
      return jsonResponse({ ok: false, error: 'profile_not_found' }, 500)
    }

    const effectivePlan = getEffectivePlan(profile)

    // ── Load plan limits ──────────────────────────────────────────────────────
    const { data: limits, error: limErr } = await supabase
      .from('plan_limits')
      .select('max_exports_per_month, history_days')
      .eq('plan', effectivePlan)
      .single()

    if (limErr || !limits) {
      return jsonResponse({ ok: false, error: 'limits_not_found' }, 500)
    }

    // ── Quota check ───────────────────────────────────────────────────────────
    if (limits.max_exports_per_month === 0) {
      return jsonResponse({
        ok: false,
        error: 'export_not_allowed',
        plan: effectivePlan,
        message: 'Las exportaciones requieren plan Inicial o superior.',
      }, 403)
    }

    const exportsUsed = profile.exports_used ?? 0
    if (exportsUsed >= limits.max_exports_per_month) {
      // Calculate first day of next month for resetAt
      const now = new Date()
      const resetAt = new Date(now.getFullYear(), now.getMonth() + 1, 1).toISOString()
      return jsonResponse({
        ok: false,
        error: 'quota_exceeded',
        used: exportsUsed,
        limit: limits.max_exports_per_month,
        resetAt,
      }, 429)
    }

    // ── Generate file ─────────────────────────────────────────────────────────
    const dateFrom = historyDateFrom(limits.history_days)
    const exportId = crypto.randomUUID()

    let fileBytes: Uint8Array
    let contentType: string
    let fileExt: string

    if (exportType === 'full_report_xlsx') {
      const [salesRows, purchasesRows, expensesRows, stockRows] = await Promise.all([
        fetchSalesRows(supabase, dateFrom),
        fetchPurchasesRows(supabase, dateFrom),
        fetchExpensesRows(supabase, dateFrom),
        fetchStockRows(supabase),
      ])
      fileBytes = await buildXlsx([
        { name: 'Ventas',     rows: salesRows },
        { name: 'Compras',    rows: purchasesRows },
        { name: 'Gastos',     rows: expensesRows },
        { name: 'Inventario', rows: stockRows },
      ])
      contentType = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
      fileExt = 'xlsx'
    } else {
      let csvText: string
      if (exportType === 'sales_csv') {
        const rows = await fetchSalesRows(supabase, dateFrom)
        csvText = rowsToCsv(['fecha', 'cliente', 'producto', 'cantidad', 'precio_unit', 'total', 'moneda', 'sucursal'], rows)
      } else if (exportType === 'purchases_csv') {
        const rows = await fetchPurchasesRows(supabase, dateFrom)
        csvText = rowsToCsv(['fecha', 'producto', 'cantidad', 'precio_unit', 'total', 'moneda', 'sucursal'], rows)
      } else if (exportType === 'expenses_csv') {
        const rows = await fetchExpensesRows(supabase, dateFrom)
        csvText = rowsToCsv(['fecha', 'categoria', 'descripcion', 'monto', 'moneda', 'sucursal'], rows)
      } else {
        // stock_csv
        const rows = await fetchStockRows(supabase)
        csvText = rowsToCsv(['nombre', 'sku', 'stock', 'min_stock', 'precio', 'moneda'], rows)
      }
      fileBytes = new TextEncoder().encode('﻿' + csvText) // BOM for Excel UTF-8
      contentType = 'text/csv'
      fileExt = 'csv'
    }

    // ── Upload to Storage ─────────────────────────────────────────────────────
    const filePath = `${user.id}/${exportId}.${fileExt}`

    // Use service role for storage upload (anon key has RLS)
    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
    )

    const { error: uploadError } = await supabaseAdmin.storage
      .from('exports')
      .upload(filePath, fileBytes, { contentType, upsert: false })

    if (uploadError) {
      console.error('[generate-export] Storage upload error:', uploadError)
      return jsonResponse({ ok: false, error: 'upload_failed' }, 500)
    }

    // ── Signed URL (1 hour) ───────────────────────────────────────────────────
    const SIGNED_URL_SECONDS = 3600
    const { data: signedData, error: signedError } = await supabaseAdmin.storage
      .from('exports')
      .createSignedUrl(filePath, SIGNED_URL_SECONDS)

    if (signedError || !signedData?.signedUrl) {
      console.error('[generate-export] Signed URL error:', signedError)
      return jsonResponse({ ok: false, error: 'signed_url_failed' }, 500)
    }

    const signedUrl = signedData.signedUrl
    const expiresAt = new Date(Date.now() + SIGNED_URL_SECONDS * 1000).toISOString()

    // ── INSERT export_logs ────────────────────────────────────────────────────
    const { error: logError } = await supabase
      .from('export_logs')
      .insert({
        user_id:               user.id,
        export_type:           exportType,
        file_path:             filePath,
        signed_url:            signedUrl,
        signed_url_expires_at: expiresAt,
        status:                'generated',
      })

    if (logError) {
      console.error('[generate-export] export_logs insert error:', logError)
      // Non-fatal: the file was uploaded — proceed
    }

    // ── Increment exports_used ────────────────────────────────────────────────
    await supabase.rpc('rpc_increment_export_usage', { p_user_id: user.id })

    console.log(`[generate-export] Success: ${exportType} for user ${user.id}`)

    return jsonResponse({
      ok:          true,
      exportType,
      signedUrl,
      expiresAt,
      exportsUsed: exportsUsed + 1,
      exportsLimit: limits.max_exports_per_month,
    })

  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err)
    console.error('[generate-export] Unhandled error:', msg)
    return jsonResponse({ ok: false, error: msg }, 500)
  }
})
