"use client"

import Link from "next/link"
import { Button } from "@/components/ui/button"
import {
  LayoutDashboard, TrendingUp, ShoppingCart, Package, BarChart3, Sparkles,
  CheckCircle2, ArrowRight, MessageCircle, Clock, Star, Menu, X, Shield,
} from "lucide-react"
import { useState } from "react"
import type { LandingSection } from "@/lib/landing"

function Navbar() {
  const [open, setOpen] = useState(false)
  const links = [
    { label: "Funcionalidades", href: "#features" },
    { label: "Precios", href: "#pricing" },
    { label: "Testimonios", href: "#testimonials" },
    { label: "IA", href: "#ai" },
  ]
  return (
    <header className="fixed top-0 left-0 right-0 z-50 border-b border-slate-800/60 bg-slate-950/90 backdrop-blur-md">
      <div className="container mx-auto flex h-16 items-center justify-between px-4">
        <Link href="/" className="flex items-center gap-2.5">
          <img src="/aliadata-logo.png" alt="ALIADATA" className="h-8 w-8 object-contain" />
          <span className="text-lg font-bold tracking-widest text-white uppercase">ALIADATA</span>
        </Link>
        <nav className="hidden md:flex items-center gap-8">
          {links.map((l) => (
            <a key={l.href} href={l.href} className="text-sm text-slate-400 hover:text-white transition-colors">{l.label}</a>
          ))}
        </nav>
        <div className="hidden md:flex items-center gap-3">
          <Button variant="ghost" size="sm" className="text-slate-400 hover:text-white hover:bg-slate-800" asChild>
            <Link href="/auth/login">Iniciar sesion</Link>
          </Button>
          <Button size="sm" className="rounded-full bg-emerald-600 hover:bg-emerald-500 text-white font-semibold px-5" asChild>
            <Link href="/auth/login">Empezar Gratis</Link>
          </Button>
        </div>
        <button className="md:hidden text-slate-400 hover:text-white" onClick={() => setOpen(!open)}>
          {open ? <X className="h-5 w-5" /> : <Menu className="h-5 w-5" />}
        </button>
      </div>
      {open && (
        <div className="md:hidden border-t border-slate-800 bg-slate-950 px-4 py-4 flex flex-col gap-4">
          {links.map((l) => (
            <a key={l.href} href={l.href} className="text-slate-300 hover:text-white" onClick={() => setOpen(false)}>{l.label}</a>
          ))}
          <Button className="rounded-full bg-emerald-600 hover:bg-emerald-500 text-white font-semibold" asChild>
            <Link href="/auth/login">Empezar Gratis</Link>
          </Button>
        </div>
      )}
    </header>
  )
}

function Hero({ section }: { section?: LandingSection }) {
  const title = section?.title ?? "Todo lo que necesitas para ordenar tu negocio"
  const subtitle = section?.subtitle ?? "Controla ventas, stock, compras e informes desde un solo lugar. Rapido, simple e intuitivo con IA que trabaja por vos."
  const buttonText = section?.button_text ?? "Empezar Gratis"
  const buttonLink = section?.button_link ?? "/auth/login"

  return (
    <section className="relative overflow-hidden bg-slate-950 pt-32 pb-24 sm:pt-40 sm:pb-32">
      <div className="pointer-events-none absolute inset-0 overflow-hidden">
        <div className="absolute -top-[15%] -left-[10%] h-[50%] w-[40%] rounded-full bg-emerald-500 opacity-10 blur-[130px]" />
        <div className="absolute top-[30%] -right-[10%] h-[40%] w-[35%] rounded-full bg-blue-600 opacity-10 blur-[120px]" />
        <div className="absolute bottom-0 left-[30%] h-[30%] w-[30%] rounded-full bg-emerald-700 opacity-10 blur-[100px]" />
      </div>
      <div className="container relative z-10 mx-auto px-4 text-center">
        <div className="mb-8 inline-flex items-center gap-2 rounded-full border border-emerald-500/30 bg-emerald-500/10 px-4 py-1.5 text-sm text-emerald-400">
          <Sparkles className="h-4 w-4" />
          Inteligencia Artificial incluida en todos los planes
        </div>
        <h1 className="mx-auto mb-6 max-w-4xl text-4xl font-bold tracking-tight text-white sm:text-6xl lg:text-7xl">
          {title.includes("ordenar") ? (
            <>
              {title.split("ordenar")[0]}
              <span className="bg-gradient-to-r from-emerald-400 to-teal-400 bg-clip-text text-transparent">
                ordenar{title.split("ordenar")[1]}
              </span>
            </>
          ) : (
            <span className="bg-gradient-to-r from-emerald-400 to-teal-400 bg-clip-text text-transparent">{title}</span>
          )}
        </h1>
        <p className="mx-auto mb-10 max-w-2xl text-lg leading-8 text-slate-400 sm:text-xl">
          {subtitle}
        </p>
        <div className="flex flex-col items-center justify-center gap-4 sm:flex-row">
          <Button size="lg" className="rounded-full bg-emerald-600 px-10 font-bold text-white hover:bg-emerald-500 shadow-lg shadow-emerald-900/40" asChild>
            <Link href={buttonLink}>{buttonText} <ArrowRight className="ml-2 h-4 w-4" /></Link>
          </Button>
          <Button variant="outline" size="lg" className="rounded-full border-slate-700 px-10 text-slate-300 hover:bg-slate-800 hover:text-white" asChild>
            <a href="#features">Ver Funcionalidades</a>
          </Button>
        </div>
        <p className="mt-8 text-sm text-slate-500">
          Mas de <span className="text-emerald-400 font-semibold">500 negocios</span> ya confian en ALIADATA
        </p>
        <div className="mt-16 sm:mt-20">
          <div className="relative mx-auto max-w-5xl rounded-2xl border border-slate-700/50 bg-slate-900 p-2 shadow-2xl shadow-black/60 ring-1 ring-white/5">
            <div className="flex items-center gap-2 rounded-t-xl border-b border-slate-800 bg-slate-900 px-4 py-2.5">
              <div className="h-3 w-3 rounded-full bg-red-500/70" />
              <div className="h-3 w-3 rounded-full bg-yellow-500/70" />
              <div className="h-3 w-3 rounded-full bg-emerald-500/70" />
              <div className="ml-4 flex-1 rounded-md bg-slate-800 px-3 py-1 text-xs text-slate-500">app.aliadata.com</div>
            </div>
            <div className="rounded-b-xl bg-slate-950 p-6">
              <div className="grid grid-cols-2 gap-4 sm:grid-cols-4">
                {[
                  { label: "Ventas del mes", value: "$248.500", color: "text-emerald-400" },
                  { label: "Compras", value: "$89.200", color: "text-blue-400" },
                  { label: "Stock total", value: "1.432 uds", color: "text-violet-400" },
                  { label: "Clientes activos", value: "87", color: "text-amber-400" },
                ].map((stat) => (
                  <div key={stat.label} className="rounded-xl border border-slate-800 bg-slate-900 p-4 text-left">
                    <p className="text-xs text-slate-500 mb-1">{stat.label}</p>
                    <p className={`text-lg font-bold ${stat.color}`}>{stat.value}</p>
                  </div>
                ))}
              </div>
              <div className="mt-4 grid grid-cols-1 gap-4 sm:grid-cols-3">
                <div className="col-span-2 rounded-xl border border-slate-800 bg-slate-900 p-4">
                  <p className="text-xs text-slate-500 mb-3">Evolucion de ventas</p>
                  <div className="flex items-end gap-2 h-20">
                    {[40,65,45,80,60,90,75,85,55,95,70,100].map((h, i) => (
                      <div key={i} className="flex-1 rounded-t-sm bg-emerald-500/30 hover:bg-emerald-500/50 transition-colors" style={{ height: `${h}%` }} />
                    ))}
                  </div>
                </div>
                <div className="rounded-xl border border-slate-800 bg-slate-900 p-4">
                  <p className="text-xs text-slate-500 mb-3">IA Insights</p>
                  <div className="space-y-2">
                    {["Stock bajo en 3 productos","Pico de ventas el martes","Margen mejoro +12%"].map((t) => (
                      <div key={t} className="flex items-start gap-2">
                        <Sparkles className="h-3 w-3 text-emerald-400 mt-0.5 shrink-0" />
                        <p className="text-xs text-slate-400">{t}</p>
                      </div>
                    ))}
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </section>
  )
}

function StatsStrip() {
  return (
    <section className="border-y border-slate-800 bg-slate-900/50 py-12">
      <div className="container mx-auto px-4">
        <div className="grid grid-cols-2 gap-8 sm:grid-cols-4">
          {[
            { value: "+500", label: "Negocios activos" },
            { value: "98%", label: "Satisfaccion" },
            { value: "24/7", label: "Soporte incluido" },
            { value: "100%", label: "Cloud y seguro" },
          ].map((s) => (
            <div key={s.label} className="text-center">
              <p className="text-3xl font-bold text-emerald-400">{s.value}</p>
              <p className="mt-1 text-sm text-slate-500">{s.label}</p>
            </div>
          ))}
        </div>
      </div>
    </section>
  )
}

const DEFAULT_MODULES = [
  { icon: LayoutDashboard, title: "Panel de Control", desc: "Visualiza todas tus metricas clave en tiempo real. Ventas, stock, compras y rentabilidad en un solo dashboard.", color: "bg-emerald-500/10 ring-emerald-500/20 text-emerald-400" },
  { icon: TrendingUp,      title: "Ventas",           desc: "Registra tus ventas al instante, asignales un cliente y segui tu historial de ingresos con filtros avanzados.", color: "bg-blue-500/10 ring-blue-500/20 text-blue-400" },
  { icon: ShoppingCart,    title: "Compras",          desc: "Controla cada compra de mercaderia. Actualiza tu stock automaticamente con cada nueva entrada.", color: "bg-violet-500/10 ring-violet-500/20 text-violet-400" },
  { icon: Package,         title: "Stock",            desc: "Inventario inteligente con soporte para unidades de medida (kg, litros, metros). Alertas de stock bajo.", color: "bg-amber-500/10 ring-amber-500/20 text-amber-400" },
  { icon: BarChart3,       title: "Informes",         desc: "Reportes detallados de rentabilidad, evolucion de ventas y comportamiento de clientes para mejores decisiones.", color: "bg-pink-500/10 ring-pink-500/20 text-pink-400" },
  { icon: Sparkles,        title: "Inteligencia Artificial", desc: "Insights automaticos, prediccion de demanda y recomendaciones de precios generadas por IA.", color: "bg-teal-500/10 ring-teal-500/20 text-teal-400" },
]

const COLORS = [
  "bg-emerald-500/10 ring-emerald-500/20 text-emerald-400",
  "bg-blue-500/10 ring-blue-500/20 text-blue-400",
  "bg-violet-500/10 ring-violet-500/20 text-violet-400",
  "bg-amber-500/10 ring-amber-500/20 text-amber-400",
  "bg-pink-500/10 ring-pink-500/20 text-pink-400",
  "bg-teal-500/10 ring-teal-500/20 text-teal-400",
]

const ICON_LIST = [LayoutDashboard, TrendingUp, ShoppingCart, Package, BarChart3, Sparkles]

function Features({ section }: { section?: LandingSection }) {
  let modules = DEFAULT_MODULES
  try {
    if (section?.content?.trim().startsWith("[")) {
      const parsed = JSON.parse(section.content)
      if (Array.isArray(parsed) && parsed.length > 0) {
        modules = parsed.map((f: any, i: number) => ({
          icon: ICON_LIST[i % ICON_LIST.length],
          title: f.title ?? f.name ?? `Modulo ${i + 1}`,
          desc: f.desc ?? f.description ?? "",
          color: COLORS[i % COLORS.length],
        }))
      }
    }
  } catch {}

  const sectionTitle = section?.title ?? "Una plataforma. Todo lo que necesitas."
  const sectionSubtitle = section?.subtitle ?? "Cada modulo fue disenado para pymes y emprendedores que quieren crecer sin complicarse."
  return (
    <section id="features" className="bg-slate-950 py-24 sm:py-32">
      <div className="container mx-auto px-4">
        <div className="mx-auto max-w-2xl text-center mb-16">
          <span className="text-sm font-semibold text-emerald-400 uppercase tracking-widest">Funcionalidades</span>
          <h2 className="mt-3 text-3xl font-bold tracking-tight text-white sm:text-4xl">{sectionTitle}</h2>
          <p className="mt-4 text-lg text-slate-400">{sectionSubtitle}</p>
        </div>
        <div className="grid grid-cols-1 gap-6 sm:grid-cols-2 lg:grid-cols-3">
          {modules.map((m) => (
            <div key={m.title} className="group flex flex-col gap-4 rounded-2xl border border-slate-800 bg-slate-900 p-7 hover:border-slate-700 hover:bg-slate-800/80 transition-all duration-200">
              <div className={`w-fit rounded-xl p-3 ring-1 ${m.color}`}>
                <m.icon className="h-6 w-6" />
              </div>
              <h3 className="text-lg font-semibold text-white">{m.title}</h3>
              <p className="flex-1 text-sm leading-relaxed text-slate-400">{m.desc}</p>
            </div>
          ))}
        </div>
      </div>
    </section>
  )
}

function HowItWorks() {
  const steps = [
    { num: "01", title: "Crea tu cuenta gratis", desc: "Sin tarjeta de credito. En 2 minutos ya tenes tu espacio de trabajo listo." },
    { num: "02", title: "Carga productos y clientes", desc: "Importa desde Excel o carga uno por uno. La IA te ayuda a organizar todo desde el principio." },
    { num: "03", title: "Toma decisiones con datos", desc: "Registra ventas, compras y movimientos. Mira tus reportes en tiempo real y crece con confianza." },
  ]
  return (
    <section className="bg-slate-900 py-24 sm:py-32">
      <div className="container mx-auto px-4">
        <div className="mx-auto max-w-2xl text-center mb-16">
          <span className="text-sm font-semibold text-emerald-400 uppercase tracking-widest">Como funciona</span>
          <h2 className="mt-3 text-3xl font-bold tracking-tight text-white sm:text-4xl">Empieza en 3 pasos simples</h2>
        </div>
        <div className="grid grid-cols-1 gap-8 md:grid-cols-3 max-w-4xl mx-auto">
          {steps.map((step, i) => (
            <div key={step.num} className="flex flex-col items-start">
              <div className="mb-5 flex h-14 w-14 items-center justify-center rounded-2xl border border-emerald-500/30 bg-emerald-500/10 text-xl font-bold text-emerald-400">
                {step.num}
              </div>
              <h3 className="mb-2 text-lg font-semibold text-white">{step.title}</h3>
              <p className="text-sm leading-relaxed text-slate-400">{step.desc}</p>
            </div>
          ))}
        </div>
      </div>
    </section>
  )
}

function AISection() {
  const features = [
    "Analisis de ventas y tendencias automatico",
    "Prediccion de demanda por producto",
    "Recomendaciones de precios basadas en datos",
    "Alertas inteligentes de stock bajo",
    "Resumen ejecutivo diario generado por IA",
    "Identificacion de clientes de alto valor",
  ]
  return (
    <section id="ai" className="relative overflow-hidden bg-slate-950 py-24 sm:py-32">
      <div className="pointer-events-none absolute inset-0">
        <div className="absolute left-[10%] top-[20%] h-[50%] w-[30%] rounded-full bg-emerald-600 opacity-5 blur-[120px]" />
      </div>
      <div className="container relative z-10 mx-auto px-4">
        <div className="grid grid-cols-1 gap-12 lg:grid-cols-2 lg:items-center">
          <div>
            <div className="mb-4 inline-flex items-center gap-2 rounded-full border border-emerald-500/30 bg-emerald-500/10 px-4 py-1.5 text-sm text-emerald-400">
              <Sparkles className="h-4 w-4" />
              Inteligencia Artificial
            </div>
            <h2 className="mb-5 text-3xl font-bold tracking-tight text-white sm:text-4xl">
              Tu asistente de negocio trabaja{" "}
              <span className="bg-gradient-to-r from-emerald-400 to-teal-400 bg-clip-text text-transparent">las 24 horas</span>
            </h2>
            <p className="mb-8 text-lg text-slate-400">
              ALIADATA analiza automaticamente tus datos y te entrega insights accionables.
              Sin configuracion. Sin formulas. Solo informacion util cuando la necesitas.
            </p>
            <ul className="space-y-3">
              {features.map((f) => (
                <li key={f} className="flex items-center gap-3">
                  <CheckCircle2 className="h-5 w-5 shrink-0 text-emerald-500" />
                  <span className="text-slate-300">{f}</span>
                </li>
              ))}
            </ul>
          </div>
          <div className="rounded-2xl border border-slate-700/50 bg-slate-900 p-6 shadow-2xl shadow-black/40">
            <div className="mb-5 flex items-center gap-3">
              <div className="flex h-9 w-9 items-center justify-center rounded-xl bg-emerald-500/20">
                <Sparkles className="h-5 w-5 text-emerald-400" />
              </div>
              <div>
                <p className="text-sm font-semibold text-white">ALIADATA IA</p>
                <p className="text-xs text-slate-500">Resumen del dia</p>
              </div>
            </div>
            <div className="space-y-4">
              {[
                { title: "Ventas", text: "Tus ventas subieron un 18% respecto a la semana pasada. El producto mas vendido fue Remera Blanca XL." },
                { title: "Stock bajo", text: "Pantalon Cargo talla M tiene solo 3 unidades. Considera hacer un pedido pronto." },
                { title: "Sugerencia", text: "Los martes tenes un pico de ventas. Te recomiendo tener stock reforzado para el proximo." },
              ].map((card) => (
                <div key={card.title} className="rounded-xl border border-slate-800 bg-slate-800/50 p-4">
                  <p className="mb-1 text-sm font-semibold text-white">{card.title}</p>
                  <p className="text-xs leading-relaxed text-slate-400">{card.text}</p>
                </div>
              ))}
            </div>
          </div>
        </div>
      </div>
    </section>
  )
}

function Pricing() {
  const plans = [
    {
      name: "Starter", price: "Gratis", period: "",
      desc: "Para empezar a ordenar tu negocio sin costo.",
      features: ["Hasta 50 operaciones/mes","1 usuario","Panel de control","Ventas y compras","Soporte por email"],
      cta: "Empezar Gratis", highlighted: false,
    },
    {
      name: "Pro", price: "$15.900", period: "/mes",
      desc: "Para negocios en crecimiento que quieren mas.",
      features: ["Operaciones ilimitadas","Hasta 3 usuarios","Todo del plan Starter","Informes avanzados","IA incluida","Soporte prioritario","Unidades de medida"],
      cta: "Comenzar Ahora", highlighted: true,
    },
    {
      name: "Empresa", price: "A consultar", period: "",
      desc: "Para equipos grandes con necesidades especificas.",
      features: ["Todo del plan Pro","Usuarios ilimitados","Onboarding dedicado","SLA garantizado","Integraciones personalizadas","Soporte telefonico"],
      cta: "Hablar con ventas", highlighted: false,
    },
  ]
  return (
    <section id="pricing" className="bg-slate-900 py-24 sm:py-32">
      <div className="container mx-auto px-4">
        <div className="mx-auto max-w-2xl text-center mb-16">
          <span className="text-sm font-semibold text-emerald-400 uppercase tracking-widest">Precios</span>
          <h2 className="mt-3 text-3xl font-bold tracking-tight text-white sm:text-4xl">Planes para cada etapa de tu negocio</h2>
          <p className="mt-4 text-lg text-slate-400">Empieza gratis y escala cuando lo necesites. Sin permanencia.</p>
        </div>
        <div className="grid grid-cols-1 gap-8 lg:grid-cols-3 lg:items-start max-w-5xl mx-auto">
          {plans.map((plan) => (
            <div key={plan.name} className={`relative flex flex-col rounded-2xl border p-8 ${plan.highlighted ? "border-emerald-500/50 bg-slate-950 shadow-2xl shadow-emerald-900/20 ring-1 ring-emerald-500/20" : "border-slate-800 bg-slate-900"}`}>
              {plan.highlighted && (
                <div className="absolute -top-4 left-1/2 -translate-x-1/2">
                  <span className="rounded-full bg-emerald-600 px-4 py-1 text-xs font-bold text-white uppercase tracking-wide shadow-lg">Mas popular</span>
                </div>
              )}
              <div className="mb-6">
                <h3 className="text-xl font-bold text-white">{plan.name}</h3>
                <div className="mt-3 flex items-baseline gap-1">
                  <span className={`text-4xl font-extrabold ${plan.highlighted ? "text-emerald-400" : "text-white"}`}>{plan.price}</span>
                  {plan.period && <span className="text-slate-500 text-sm">{plan.period}</span>}
                </div>
                <p className="mt-2 text-sm text-slate-400">{plan.desc}</p>
              </div>
              <ul className="mb-8 flex-1 space-y-3">
                {plan.features.map((f) => (
                  <li key={f} className="flex items-center gap-3">
                    <CheckCircle2 className={`h-4 w-4 shrink-0 ${plan.highlighted ? "text-emerald-400" : "text-slate-500"}`} />
                    <span className="text-sm text-slate-300">{f}</span>
                  </li>
                ))}
              </ul>
              <Button size="lg" className={`w-full rounded-full font-semibold ${plan.highlighted ? "bg-emerald-600 hover:bg-emerald-500 text-white shadow-lg shadow-emerald-900/40" : "bg-slate-800 hover:bg-slate-700 text-white"}`} asChild>
                <Link href="/auth/login">{plan.cta}</Link>
              </Button>
            </div>
          ))}
        </div>
        <p className="mt-10 text-center text-sm text-slate-500">Precios en pesos argentinos · Sin costo de cancelacion · Datos seguros en la nube</p>
      </div>
    </section>
  )
}

const DEFAULT_TESTIMONIALS = [
  { text: "Desde que uso ALIADATA deje de perder ventas por no saber que tenia en stock. El panel de control me cambio la forma de trabajar.", name: "Martina Lopez", role: "Duena de tienda de ropa, Cordoba" },
  { text: "La IA me aviso que un producto se estaba agotando antes de que yo me diera cuenta. Eso solo ya justifica el plan Pro.", name: "Rodrigo Fernandez", role: "Ferreteria, Buenos Aires" },
  { text: "Llevo el control de mi negocio de catering desde el celular. Antes usaba hojas de calculo y siempre habia errores.", name: "Valeria Sanchez", role: "Emprendedora gastronómica, Rosario" },
  { text: "ALIADATA es util, funcional y super necesario para cualquier pyme que quiera crecer de manera ordenada.", name: "Diego Morales", role: "Distribuidora, Mendoza" },
]

function Testimonials({ section }: { section?: LandingSection }) {
  let testimonials = DEFAULT_TESTIMONIALS
  try {
    if (section?.content?.trim().startsWith("[")) {
      const parsed = JSON.parse(section.content)
      if (Array.isArray(parsed) && parsed.length > 0) {
        testimonials = parsed.map((t: any) => ({
          text: t.text ?? t.quote ?? "",
          name: t.name ?? t.author ?? "",
          role: t.role ?? t.position ?? "",
        }))
      }
    }
  } catch {}

  const sectionTitle = section?.title ?? "Lo que dicen nuestros clientes"
  return (
    <section id="testimonials" className="bg-slate-950 py-24 sm:py-32">
      <div className="container mx-auto px-4">
        <div className="mx-auto max-w-2xl text-center mb-16">
          <span className="text-sm font-semibold text-emerald-400 uppercase tracking-widest">Testimonios</span>
          <h2 className="mt-3 text-3xl font-bold tracking-tight text-white sm:text-4xl">{sectionTitle}</h2>
        </div>
        <div className="grid grid-cols-1 gap-6 md:grid-cols-2 max-w-5xl mx-auto">
          {testimonials.map((t) => (
            <div key={t.name} className="flex flex-col gap-5 rounded-2xl border border-slate-800 bg-slate-900 p-8">
              <div className="flex gap-1">
                {[1,2,3,4,5].map((s) => <Star key={s} className="h-4 w-4 fill-emerald-500 text-emerald-500" />)}
              </div>
              <p className="flex-1 italic text-slate-300 leading-relaxed">"{t.text}"</p>
              <div>
                <p className="font-semibold text-white">{t.name}</p>
                <p className="text-sm text-slate-500">{t.role}</p>
              </div>
            </div>
          ))}
        </div>
      </div>
    </section>
  )
}

function Support() {
  const pillars = [
    { icon: MessageCircle, title: "Chat instantaneo", desc: "Respondemos en menos de 5 minutos durante el horario comercial. Sin bots, personas reales." },
    { icon: Clock, title: "Respuesta rapida", desc: "Tiempo promedio de resolucion: 2 horas. Sabemos que cada minuto de tu negocio importa." },
    { icon: Star, title: "5 estrellas", desc: "Calificacion promedio de nuestro soporte. Mas de 300 resenas verificadas de clientes reales." },
  ]
  return (
    <section className="bg-slate-900 py-24 sm:py-32">
      <div className="container mx-auto px-4">
        <div className="mx-auto max-w-2xl text-center mb-16">
          <span className="text-sm font-semibold text-emerald-400 uppercase tracking-widest">Soporte</span>
          <h2 className="mt-3 text-3xl font-bold tracking-tight text-white sm:text-4xl">Nunca estas solo en tu negocio</h2>
          <p className="mt-4 text-lg text-slate-400">Nuestro equipo esta disponible para ayudarte a sacar el maximo provecho de ALIADATA.</p>
        </div>
        <div className="grid grid-cols-1 gap-8 md:grid-cols-3 max-w-4xl mx-auto">
          {pillars.map((p) => (
            <div key={p.title} className="flex flex-col items-center text-center gap-4 rounded-2xl border border-slate-800 bg-slate-900/50 p-8">
              <div className="flex h-14 w-14 items-center justify-center rounded-2xl border border-emerald-500/30 bg-emerald-500/10">
                <p.icon className="h-7 w-7 text-emerald-400" />
              </div>
              <h3 className="text-lg font-semibold text-white">{p.title}</h3>
              <p className="text-sm leading-relaxed text-slate-400">{p.desc}</p>
            </div>
          ))}
        </div>
      </div>
    </section>
  )
}

function FinalCTA({ section }: { section?: LandingSection }) {
  const title = section?.title ?? "Empieza a ordenar tu negocio hoy mismo"
  const subtitle = section?.subtitle ?? "Unite a mas de 500 negocios que ya usan ALIADATA para crecer con datos, no con suposiciones."
  const buttonText = section?.button_text ?? "Empezar Gratis"
  const buttonLink = section?.button_link ?? "/auth/login"

  return (
    <section className="bg-slate-950 py-16 sm:py-24">
      <div className="container mx-auto px-4">
        <div className="relative isolate overflow-hidden rounded-3xl bg-emerald-700 px-6 py-24 text-center shadow-2xl sm:px-24 xl:py-32">
          <h2 className="mx-auto max-w-2xl text-3xl font-bold tracking-tight text-white sm:text-4xl">
            {title}
          </h2>
          <p className="mx-auto mt-6 max-w-xl text-lg leading-8 text-emerald-100">
            {subtitle}
          </p>
          <div className="mt-10 flex flex-col items-center justify-center gap-4 sm:flex-row">
            <Button size="lg" className="rounded-full bg-white px-10 font-bold text-emerald-700 hover:bg-emerald-50 shadow-lg" asChild>
              <Link href={buttonLink}>{buttonText} <ArrowRight className="ml-2 h-4 w-4" /></Link>
            </Button>
          </div>
          <p className="mt-5 text-sm text-emerald-200/70">Sin tarjeta de credito · Cancela cuando quieras</p>
          <svg viewBox="0 0 1024 1024" className="absolute left-1/2 top-1/2 -z-10 h-[64rem] w-[64rem] -translate-x-1/2 -translate-y-1/2 [mask-image:radial-gradient(closest-side,white,transparent)]" aria-hidden="true">
            <circle cx="512" cy="512" r="512" fill="url(#cta-gradient)" fillOpacity="0.7" />
            <defs><radialGradient id="cta-gradient"><stop stopColor="#10b981" /><stop offset="1" stopColor="#047857" /></radialGradient></defs>
          </svg>
        </div>
      </div>
    </section>
  )
}

function Footer() {
  return (
    <footer className="border-t border-slate-800 bg-slate-950 py-12">
      <div className="container mx-auto px-4">
        <div className="grid grid-cols-2 gap-8 md:grid-cols-4 mb-10">
          <div className="col-span-2 md:col-span-1">
            <div className="flex items-center gap-2 mb-3">
              <img src="/aliadata-logo.png" alt="ALIADATA" className="h-7 w-7 object-contain" />
              <span className="font-bold tracking-widest text-white uppercase text-sm">ALIADATA</span>
            </div>
            <p className="text-xs text-slate-500 leading-relaxed">La plataforma de gestion inteligente para pymes y emprendedores argentinos.</p>
          </div>
          <div>
            <h4 className="mb-4 text-sm font-semibold text-white">Producto</h4>
            <ul className="space-y-2.5 text-sm text-slate-500">
              {["Funcionalidades","Precios","IA","Integraciones"].map((l) => (
                <li key={l}><a href="#" className="hover:text-slate-300 transition-colors">{l}</a></li>
              ))}
            </ul>
          </div>
          <div>
            <h4 className="mb-4 text-sm font-semibold text-white">Empresa</h4>
            <ul className="space-y-2.5 text-sm text-slate-500">
              {["Nosotros","Blog","Comunidad","Contacto"].map((l) => (
                <li key={l}><a href="#" className="hover:text-slate-300 transition-colors">{l}</a></li>
              ))}
            </ul>
          </div>
          <div>
            <h4 className="mb-4 text-sm font-semibold text-white">Legal</h4>
            <ul className="space-y-2.5 text-sm text-slate-500">
              {["Terminos de uso","Privacidad","Seguridad","Cookies"].map((l) => (
                <li key={l}><a href="#" className="hover:text-slate-300 transition-colors">{l}</a></li>
              ))}
            </ul>
          </div>
        </div>
        <div className="border-t border-slate-800 pt-8 flex flex-col sm:flex-row items-center justify-between gap-4">
          <p className="text-xs text-slate-600">© 2026 ALIADATA. Todos los derechos reservados.</p>
          <div className="flex items-center gap-2 text-xs text-slate-600">
            <Shield className="h-3.5 w-3.5" />
            Datos protegidos · Hosting en Argentina
          </div>
        </div>
      </div>
    </footer>
  )
}

// ─────────────────────────────────────────────
// MAIN EXPORT — receives DB sections from server component
// Admin-editable: hero, features, testimonials, cta
// Hardcoded: Navbar, Stats, HowItWorks, AI, Pricing, Support, Footer
// ─────────────────────────────────────────────
export function LandingPageFull({ sections = [] }: { sections?: LandingSection[] }) {
  const heroSection        = sections.find(s => s.type === "hero")
  const featuresSection    = sections.find(s => s.type === "features")
  const testimonialsSection = sections.find(s => s.type === "testimonials")
  const ctaSection         = sections.find(s => s.type === "cta")

  return (
    <div className="bg-slate-950">
      <Navbar />
      <Hero section={heroSection} />
      <StatsStrip />
      <Features section={featuresSection} />
      <HowItWorks />
      <AISection />
      <Pricing />
      <Testimonials section={testimonialsSection} />
      <Support />
      <FinalCTA section={ctaSection} />
      <Footer />
    </div>
  )
}
