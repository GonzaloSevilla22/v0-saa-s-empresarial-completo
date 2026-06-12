import { SupabaseClient } from '@supabase/supabase-js'

// ─── Types ────────────────────────────────────────────────────────────────────

export interface BusinessSnapshot {
  periodo: string

  ventas: {
    total: number
    vs_periodo_anterior: string   // e.g. "+18%" | "-5%" | "sin datos previos"
    promedio_diario: number
    dias_con_ventas: number
  }

  gastos: {
    total: number
    margen_neto_pct: number
    categoria_top: string         // e.g. "Materiales: $28.000"
  }

  productos: {
    top_rentables: Array<{
      nombre: string
      revenue: number
      unidades: number
      margen_pct: number
    }>
    sin_rotacion: Array<{
      nombre: string
      stock: number
      dias_sin_vender: number
      valor_inmovilizado: number  // stock * costo
    }>
    stock_critico: Array<{
      nombre: string
      stock: number
      minimo: number
      dias_restantes_estimados: number
    }>
    margen_bajo: Array<{
      nombre: string
      margen_pct: number
      costo: number
      precio: number
    }>
  }

  clientes: {
    activos_periodo: number       // compraron al menos 1 vez
    nuevos: number                // creados en el período
    top_cliente_revenue: string   // "$35.000 (28% del total)"
  }
}

// ─── Builder ─────────────────────────────────────────────────────────────────

export async function buildBusinessSnapshot(
  supabase: SupabaseClient
): Promise<BusinessSnapshot> {
  const now = new Date()

  const d30 = new Date(now)
  d30.setDate(now.getDate() - 30)

  const d60 = new Date(now)
  d60.setDate(now.getDate() - 60)

  const nowStr  = now.toISOString().split('T')[0]
  const d30Str  = d30.toISOString().split('T')[0]
  const d60Str  = d60.toISOString().split('T')[0]

  // ── Parallel fetch ─────────────────────────────────────────────────────────
  const [
    { data: currentSales },
    { data: prevSales },
    { data: products },
    { data: expenses },
    { data: newClients },
    { data: recentSalesForRotation },
  ] = await Promise.all([
    // Ventas período actual — incluye join a products para margen
    supabase
      .from('sales')
      .select('amount, quantity, date, product_id, client_id, products(name, cost, price)')
      .gte('date', d30Str),

    // Ventas período anterior (solo monto, para comparativa)
    supabase
      .from('sales')
      .select('amount')
      .gte('date', d60Str)
      .lt('date', d30Str),

    // Productos (limitado para no inflar contexto)
    // C-21: lee de v_products_with_stock — stock = COALESCE(Σ branch_stock, 0)
    supabase
      .from('v_products_with_stock')
      .select('id, name, price, cost, stock, min_stock')
      .order('price', { ascending: false })
      .limit(50),

    // Gastos del período
    supabase
      .from('expenses')
      .select('amount, category')
      .gte('date', d30Str),

    // Clientes nuevos (para métricas de crecimiento)
    supabase
      .from('clients')
      .select('id')
      .gte('created_at', d30Str),

    // Todas las ventas de 60d para calcular última venta por producto
    supabase
      .from('sales')
      .select('product_id, date')
      .gte('date', d60Str)
      .order('date', { ascending: false }),
  ])

  const sales  = currentSales ?? []
  const prev   = prevSales    ?? []
  const prods  = products     ?? []
  const exps   = expenses     ?? []

  // ── VENTAS ─────────────────────────────────────────────────────────────────

  const totalRevenue = sales.reduce((s, r) => s + Number(r.amount), 0)
  const prevRevenue  = prev.reduce((s, r)  => s + Number(r.amount), 0)

  const vsPrev = prevRevenue > 0
    ? `${totalRevenue >= prevRevenue ? '+' : ''}${Math.round(((totalRevenue - prevRevenue) / prevRevenue) * 100)}%`
    : 'sin datos previos'

  const datesWithSales = new Set(sales.map(s => String(s.date).split('T')[0]))

  // ── GASTOS ─────────────────────────────────────────────────────────────────

  const totalExpenses = exps.reduce((s, r) => s + Number(r.amount), 0)
  const margenNeto    = totalRevenue > 0
    ? Math.round(((totalRevenue - totalExpenses) / totalRevenue) * 100)
    : 0

  const expByCategory = new Map<string, number>()
  for (const e of exps) {
    const cat = (e.category as string) ?? 'Sin categoría'
    expByCategory.set(cat, (expByCategory.get(cat) ?? 0) + Number(e.amount))
  }
  const topCatEntry = [...expByCategory.entries()].sort((a, b) => b[1] - a[1])[0]
  const categoriaTop = topCatEntry
    ? `${topCatEntry[0]}: $${Math.round(topCatEntry[1]).toLocaleString()}`
    : 'Sin gastos registrados'

  // ── PRODUCTOS ──────────────────────────────────────────────────────────────

  // Agregar ventas por producto
  const salesByProduct = new Map<string, {
    nombre: string; revenue: number; units: number; cost: number; price: number
  }>()

  for (const s of sales) {
    const pid = s.product_id as string | null
    if (!pid) continue
    const p   = s.products as { name?: string; cost?: number; price?: number } | null
    const cur = salesByProduct.get(pid) ?? {
      nombre:  p?.name  ?? 'Desconocido',
      revenue: 0,
      units:   0,
      cost:    Number(p?.cost  ?? 0),
      price:   Number(p?.price ?? 0),
    }
    salesByProduct.set(pid, {
      ...cur,
      revenue: cur.revenue + Number(s.amount),
      units:   cur.units   + Number(s.quantity),
    })
  }

  const topRentables = [...salesByProduct.values()]
    .sort((a, b) => b.revenue - a.revenue)
    .slice(0, 5)
    .map(p => ({
      nombre:     p.nombre,
      revenue:    Math.round(p.revenue),
      unidades:   p.units,
      margen_pct: p.price > 0
        ? Math.round(((p.price - p.cost) / p.price) * 100)
        : 0,
    }))

  // Última venta por producto (para rotación)
  const lastSaleDate = new Map<string, string>()
  for (const s of recentSalesForRotation ?? []) {
    const pid = s.product_id as string | null
    if (pid && !lastSaleDate.has(pid)) {
      lastSaleDate.set(pid, s.date as string)
    }
  }

  // Promedio diario de ventas por producto (para días restantes)
  const avgDailyUnits = new Map<string, number>()
  for (const [pid, data] of salesByProduct) {
    avgDailyUnits.set(pid, data.units / 30)
  }

  // Sin rotación: tiene stock pero no se vendió en ≥30 días
  const sinRotacion = prods
    .filter(p => Number(p.stock) > 0)
    .map(p => {
      const last = lastSaleDate.get(p.id as string)
      const dias = last
        ? Math.floor((now.getTime() - new Date(last).getTime()) / 86_400_000)
        : 61 // nunca vendido o fuera de ventana → tratar como +60d
      return { p, dias }
    })
    .filter(({ dias }) => dias >= 30)
    .sort((a, b) => b.dias - a.dias)
    .slice(0, 5)
    .map(({ p, dias }) => ({
      nombre:             p.name as string,
      stock:              Number(p.stock),
      dias_sin_vender:    dias,
      valor_inmovilizado: Math.round(Number(p.stock) * Number(p.cost)),
    }))

  // Stock crítico: stock ≤ min_stock
  const stockCritico = prods
    .filter(p => Number(p.stock) <= Number(p.min_stock ?? 5))
    .slice(0, 5)
    .map(p => {
      const avg  = avgDailyUnits.get(p.id as string) ?? 0
      const dias = avg > 0 ? Math.round(Number(p.stock) / avg) : 99
      return {
        nombre:                   p.name as string,
        stock:                    Number(p.stock),
        minimo:                   Number(p.min_stock ?? 5),
        dias_restantes_estimados: dias,
      }
    })

  // Margen bajo: < 20%
  const margenBajo = prods
    .filter(p => {
      const price = Number(p.price)
      const cost  = Number(p.cost)
      return price > 0 && (price - cost) / price < 0.2
    })
    .slice(0, 5)
    .map(p => ({
      nombre:     p.name as string,
      margen_pct: Math.round(((Number(p.price) - Number(p.cost)) / Number(p.price)) * 100),
      costo:      Number(p.cost),
      precio:     Number(p.price),
    }))

  // ── CLIENTES ───────────────────────────────────────────────────────────────

  const clientIds     = new Set(
    sales.filter(s => s.client_id).map(s => s.client_id as string)
  )
  const activosPeriodo = clientIds.size

  const revenueByClient = new Map<string, number>()
  for (const s of sales) {
    if (!s.client_id) continue
    const cid = s.client_id as string
    revenueByClient.set(cid, (revenueByClient.get(cid) ?? 0) + Number(s.amount))
  }
  const topClientRevenue = [...revenueByClient.values()].sort((a, b) => b - a)[0] ?? 0
  const topClientPct     = totalRevenue > 0
    ? Math.round((topClientRevenue / totalRevenue) * 100)
    : 0
  const topClientStr = topClientRevenue > 0
    ? `$${Math.round(topClientRevenue).toLocaleString()} (${topClientPct}% del total)`
    : 'Sin datos'

  // ── RESULT ─────────────────────────────────────────────────────────────────

  return {
    periodo: `${d30Str} al ${nowStr}`,
    ventas: {
      total:                totalRevenue,
      vs_periodo_anterior:  vsPrev,
      promedio_diario:      Math.round(totalRevenue / 30),
      dias_con_ventas:      datesWithSales.size,
    },
    gastos: {
      total:          totalExpenses,
      margen_neto_pct: margenNeto,
      categoria_top:  categoriaTop,
    },
    productos: {
      top_rentables: topRentables,
      sin_rotacion:  sinRotacion,
      stock_critico: stockCritico,
      margen_bajo:   margenBajo,
    },
    clientes: {
      activos_periodo:     activosPeriodo,
      nuevos:              (newClients ?? []).length,
      top_cliente_revenue: topClientStr,
    },
  }
}

// ─── Prompt builders ─────────────────────────────────────────────────────────

/** System prompt compartido por todos los asistentes de IA */
export const AI_SYSTEM_PROMPT = `Sos un consultor de negocios especializado en emprendimientos argentinos.
Recibís datos reales de un negocio y das consejos accionables.

REGLAS QUE NO PODÉS VIOLAR:
1. Cada consejo DEBE mencionar números específicos del contexto — no inventes cifras
2. PROHIBIDO dar consejos genéricos como "mejorá tus ventas" o "reducí costos"
3. Cada insight tiene estructura: QUÉ pasa + POR QUÉ pasa + QUÉ hacer HOY
4. Si no hay problema real en los datos, decilo — no fuerces insights vacíos
5. Español rioplatense, directo, sin relleno ni frases de relleno
6. Hablá como socio del negocio, no como asistente virtual`

/** Convierte el snapshot en un bloque de texto compacto para los prompts */
export function snapshotToText(s: BusinessSnapshot): string {
  const lines: string[] = [
    `PERÍODO: ${s.periodo}`,
    `VENTAS: $${Math.round(s.ventas.total).toLocaleString()} | ${s.ventas.vs_periodo_anterior} vs período anterior | ${s.ventas.dias_con_ventas}/30 días con ventas`,
    `GASTOS: $${Math.round(s.gastos.total).toLocaleString()} | Margen neto: ${s.gastos.margen_neto_pct}% | Top gasto: ${s.gastos.categoria_top}`,
  ]

  if (s.productos.top_rentables.length > 0) {
    lines.push('TOP PRODUCTOS:')
    for (const p of s.productos.top_rentables) {
      lines.push(`  • ${p.nombre}: $${p.revenue.toLocaleString()} (${p.unidades} uds, ${p.margen_pct}% margen)`)
    }
  }

  if (s.productos.sin_rotacion.length > 0) {
    lines.push('SIN ROTACIÓN (≥30 días sin vender):')
    for (const p of s.productos.sin_rotacion) {
      lines.push(`  • ${p.nombre}: ${p.stock} uds, ${p.dias_sin_vender} días parado, $${p.valor_inmovilizado.toLocaleString()} inmovilizado`)
    }
  }

  if (s.productos.stock_critico.length > 0) {
    lines.push('STOCK CRÍTICO:')
    for (const p of s.productos.stock_critico) {
      lines.push(`  • ${p.nombre}: ${p.stock} uds (mín ${p.minimo}), ~${p.dias_restantes_estimados} días restantes`)
    }
  }

  if (s.productos.margen_bajo.length > 0) {
    lines.push('MARGEN BAJO (<20%):')
    for (const p of s.productos.margen_bajo) {
      lines.push(`  • ${p.nombre}: ${p.margen_pct}% margen (costo $${p.costo} → precio $${p.precio})`)
    }
  }

  lines.push(`CLIENTES: ${s.clientes.activos_periodo} activos | ${s.clientes.nuevos} nuevos | Top: ${s.clientes.top_cliente_revenue}`)

  return lines.join('\n')
}

/** Contexto adaptativo para el Copiloto — solo manda lo relevante según la pregunta */
export function buildAdaptiveContext(s: BusinessSnapshot, question: string): string {
  const q = question.toLowerCase()
  const blocks: string[] = []

  // Siempre: resumen financiero (mínimo)
  blocks.push(
    `RESUMEN (${s.periodo}): Ventas $${Math.round(s.ventas.total).toLocaleString()} (${s.ventas.vs_periodo_anterior} vs anterior) | Margen ${s.gastos.margen_neto_pct}%`
  )

  if (/stock|producto|inventar|repon|mercader|unidad/.test(q)) {
    if (s.productos.stock_critico.length > 0) {
      blocks.push('STOCK CRÍTICO: ' +
        s.productos.stock_critico.map(p =>
          `${p.nombre}(${p.stock}uds,~${p.dias_restantes_estimados}d)`
        ).join(', ')
      )
    }
    if (s.productos.sin_rotacion.length > 0) {
      blocks.push('SIN ROTACIÓN: ' +
        s.productos.sin_rotacion.map(p =>
          `${p.nombre}(${p.dias_sin_vender}d,$${p.valor_inmovilizado.toLocaleString()}inmovilizado)`
        ).join(', ')
      )
    }
  }

  if (/venta|vendí|factur|ingreso|producto más/.test(q)) {
    blocks.push('TOP VENTAS: ' +
      s.productos.top_rentables.slice(0, 3).map(p =>
        `${p.nombre}:$${p.revenue.toLocaleString()}(${p.unidades}uds)`
      ).join(', ')
    )
  }

  if (/cliente|comprador|fiel|frecuente/.test(q)) {
    blocks.push(
      `CLIENTES: ${s.clientes.activos_periodo} activos, ${s.clientes.nuevos} nuevos, top cliente: ${s.clientes.top_cliente_revenue}`
    )
  }

  if (/gasto|costo|margen|precio|rentab/.test(q)) {
    blocks.push(`GASTOS: $${Math.round(s.gastos.total).toLocaleString()} | ${s.gastos.categoria_top}`)
    if (s.productos.margen_bajo.length > 0) {
      blocks.push('MARGEN BAJO: ' +
        s.productos.margen_bajo.map(p =>
          `${p.nombre}(${p.margen_pct}%,costo$${p.costo}→precio$${p.precio})`
        ).join(', ')
      )
    }
  }

  return blocks.join('\n')
}
