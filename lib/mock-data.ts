import type { Product, Sale, Purchase, Expense, Client, Insight, Post, Course } from "./types"

// Helpers
const today = new Date()
const daysAgo = (n: number) => {
  const d = new Date(today)
  d.setDate(d.getDate() - n)
  return d.toISOString().split("T")[0]
}

export const mockProducts: Product[] = [
  { id: "p1", name: "Auriculares Bluetooth", category: "Electrónica", cost: 15000, price: 35000, margin: 57, stock: 45, minStock: 10 },
  { id: "p2", name: "Funda iPhone 15", category: "Accesorios", cost: 3000, price: 12000, margin: 75, stock: 120, minStock: 30 },
  { id: "p3", name: "Cargador USB-C Rapido", category: "Electrónica", cost: 8000, price: 22000, margin: 64, stock: 60, minStock: 15 },
  { id: "p4", name: "Camiseta Algodon Premium", category: "Ropa", cost: 7000, price: 25000, margin: 72, stock: 80, minStock: 20 },
  { id: "p5", name: "Proteina Whey 1kg", category: "Salud", cost: 20000, price: 45000, margin: 56, stock: 25, minStock: 10 },
  { id: "p6", name: "Organizador Escritorio", category: "Hogar", cost: 10000, price: 28000, margin: 64, stock: 35, minStock: 8 },
  { id: "p7", name: "Cable HDMI 2m", category: "Electrónica", cost: 4000, price: 14000, margin: 71, stock: 90, minStock: 20 },
  { id: "p8", name: "Crema Hidratante Natural", category: "Salud", cost: 12000, price: 32000, margin: 63, stock: 40, minStock: 10 },
  { id: "p9", name: "Mochila Urbana", category: "Accesorios", cost: 18000, price: 48000, margin: 63, stock: 22, minStock: 8 },
  { id: "p10", name: "Mate con Bombilla", category: "Hogar", cost: 6000, price: 18000, margin: 67, stock: 55, minStock: 15 },
  { id: "p11", name: "Mouse Inalambrico", category: "Electrónica", cost: 10000, price: 28000, margin: 64, stock: 38, minStock: 10 },
  { id: "p12", name: "Termo 500ml", category: "Hogar", cost: 9000, price: 26000, margin: 65, stock: 42, minStock: 12 },
  { id: "p13", name: "Gafas de Sol", category: "Accesorios", cost: 5000, price: 20000, margin: 75, stock: 65, minStock: 15 },
  { id: "p14", name: "Zapatillas Running", category: "Ropa", cost: 30000, price: 75000, margin: 60, stock: 3, minStock: 8 },
  { id: "p15", name: "Power Bank 10000mAh", category: "Electrónica", cost: 14000, price: 38000, margin: 63, stock: 5, minStock: 10 },
  { id: "p16", name: "Aceite de Coco Organico", category: "Alimentos", cost: 8000, price: 22000, margin: 64, stock: 30, minStock: 10 },
  { id: "p17", name: "Lamina Protectora Pantalla", category: "Accesorios", cost: 1000, price: 8000, margin: 88, stock: 200, minStock: 50 },
  { id: "p18", name: "Hoodie Oversize", category: "Ropa", cost: 15000, price: 42000, margin: 64, stock: 28, minStock: 10 },
]

export const mockClients: Client[] = [
  { id: "c1", name: "Maria Garcia", email: "maria@email.com", phone: "+54 11 5555-1234", status: "activo", lastPurchase: daysAgo(2), totalSpent: 1250000 },
  { id: "c2", name: "Carlos Lopez", email: "carlos@email.com", phone: "+54 11 5555-5678", status: "activo", lastPurchase: daysAgo(5), totalSpent: 890000 },
  { id: "c3", name: "Ana Martinez", email: "ana@email.com", phone: "+54 11 5555-9012", status: "activo", lastPurchase: daysAgo(1), totalSpent: 2100000 },
  { id: "c4", name: "Pedro Rodriguez", email: "pedro@email.com", phone: "+54 11 5555-3456", status: "inactivo", lastPurchase: daysAgo(45), totalSpent: 430000 },
  { id: "c5", name: "Laura Fernandez", email: "laura@email.com", phone: "+54 11 5555-7890", status: "activo", lastPurchase: daysAgo(3), totalSpent: 1780000 },
  { id: "c6", name: "Diego Sanchez", email: "diego@email.com", phone: "+54 11 5555-2345", status: "activo", lastPurchase: daysAgo(7), totalSpent: 650000 },
  { id: "c7", name: "Valentina Ruiz", email: "valentina@email.com", phone: "+54 11 5555-6789", status: "perdido", lastPurchase: daysAgo(90), totalSpent: 220000 },
  { id: "c8", name: "Martin Diaz", email: "martin@email.com", phone: "+54 11 5555-0123", status: "activo", lastPurchase: daysAgo(4), totalSpent: 1450000 },
  { id: "c9", name: "Sofia Torres", email: "sofia@email.com", phone: "+54 11 5555-4567", status: "inactivo", lastPurchase: daysAgo(60), totalSpent: 340000 },
  { id: "c10", name: "Lucas Romero", email: "lucas@email.com", phone: "+54 11 5555-8901", status: "activo", lastPurchase: daysAgo(1), totalSpent: 3200000 },
  { id: "c11", name: "Camila Herrera", email: "camila@email.com", phone: "+54 11 5555-1122", status: "activo", lastPurchase: daysAgo(10), totalSpent: 560000 },
]

export const mockSales: Sale[] = [
  { id: "s1", date: daysAgo(0), productId: "p1", productName: "Auriculares Bluetooth", clientId: "c3", clientName: "Ana Martinez", quantity: 2, unitPrice: 35000, total: 70000, currency: "ARS" },
  { id: "s2", date: daysAgo(0), productId: "p2", productName: "Funda iPhone 15", clientId: "c10", clientName: "Lucas Romero", quantity: 3, unitPrice: 12000, total: 36000, currency: "ARS" },
  { id: "s3", date: daysAgo(0), productId: "p5", productName: "Proteina Whey 1kg", clientId: "c1", clientName: "Maria Garcia", quantity: 1, unitPrice: 45000, total: 45000, currency: "ARS" },
  { id: "s4", date: daysAgo(1), productId: "p4", productName: "Camiseta Algodon Premium", clientId: "c3", clientName: "Ana Martinez", quantity: 4, unitPrice: 25000, total: 100000, currency: "ARS" },
  { id: "s5", date: daysAgo(1), productId: "p9", productName: "Mochila Urbana", clientId: "c5", clientName: "Laura Fernandez", quantity: 1, unitPrice: 48000, total: 48000, currency: "ARS" },
  { id: "s6", date: daysAgo(1), productId: "p17", productName: "Lamina Protectora Pantalla", clientId: "c10", clientName: "Lucas Romero", quantity: 5, unitPrice: 8000, total: 40000, currency: "ARS" },
  { id: "s7", date: daysAgo(2), productId: "p3", productName: "Cargador USB-C Rapido", clientId: "c1", clientName: "Maria Garcia", quantity: 2, unitPrice: 22000, total: 44000, currency: "ARS" },
  { id: "s8", date: daysAgo(2), productId: "p11", productName: "Mouse Inalambrico", clientId: "c2", clientName: "Carlos Lopez", quantity: 1, unitPrice: 28000, total: 28000, currency: "ARS" },
  { id: "s9", date: daysAgo(2), productId: "p6", productName: "Organizador Escritorio", clientId: "c8", clientName: "Martin Diaz", quantity: 2, unitPrice: 28000, total: 56000, currency: "ARS" },
  { id: "s10", date: daysAgo(3), productId: "p18", productName: "Hoodie Oversize", clientId: "c5", clientName: "Laura Fernandez", quantity: 1, unitPrice: 42000, total: 42000, currency: "ARS" },
  { id: "s11", date: daysAgo(3), productId: "p7", productName: "Cable HDMI 2m", clientId: "c6", clientName: "Diego Sanchez", quantity: 3, unitPrice: 14000, total: 42000, currency: "ARS" },
  { id: "s12", date: daysAgo(3), productId: "p13", productName: "Gafas de Sol", clientId: "c3", clientName: "Ana Martinez", quantity: 2, unitPrice: 20000, total: 40000, currency: "ARS" },
  { id: "s13", date: daysAgo(4), productId: "p1", productName: "Auriculares Bluetooth", clientId: "c8", clientName: "Martin Diaz", quantity: 1, unitPrice: 35000, total: 35000, currency: "ARS" },
  { id: "s14", date: daysAgo(4), productId: "p10", productName: "Mate con Bombilla", clientId: "c2", clientName: "Carlos Lopez", quantity: 2, unitPrice: 18000, total: 36000, currency: "ARS" },
  { id: "s15", date: daysAgo(5), productId: "p12", productName: "Termo 500ml", clientId: "c2", clientName: "Carlos Lopez", quantity: 1, unitPrice: 26000, total: 26000, currency: "ARS" },
  { id: "s16", date: daysAgo(5), productId: "p8", productName: "Crema Hidratante Natural", clientId: "c1", clientName: "Maria Garcia", quantity: 2, unitPrice: 32000, total: 64000, currency: "ARS" },
  { id: "s17", date: daysAgo(5), productId: "p4", productName: "Camiseta Algodon Premium", clientId: "c11", clientName: "Camila Herrera", quantity: 3, unitPrice: 25000, total: 75000, currency: "USD" },
  { id: "s18", date: daysAgo(6), productId: "p15", productName: "Power Bank 10000mAh", clientId: "c6", clientName: "Diego Sanchez", quantity: 1, unitPrice: 38000, total: 38000, currency: "ARS" },
  { id: "s19", date: daysAgo(6), productId: "p2", productName: "Funda iPhone 15", clientId: "c5", clientName: "Laura Fernandez", quantity: 4, unitPrice: 12000, total: 48000, currency: "ARS" },
  { id: "s20", date: daysAgo(6), productId: "p16", productName: "Aceite de Coco Organico", clientId: "c8", clientName: "Martin Diaz", quantity: 2, unitPrice: 22000, total: 44000, currency: "ARS" },
  { id: "s21", date: daysAgo(7), productId: "p3", productName: "Cargador USB-C Rapido", clientId: "c10", clientName: "Lucas Romero", quantity: 1, unitPrice: 22000, total: 22000, currency: "ARS" },
  { id: "s22", date: daysAgo(7), productId: "p14", productName: "Zapatillas Running", clientId: "c3", clientName: "Ana Martinez", quantity: 1, unitPrice: 75000, total: 75000, currency: "ARS" },
  { id: "s23", date: daysAgo(8), productId: "p9", productName: "Mochila Urbana", clientId: "c1", clientName: "Maria Garcia", quantity: 1, unitPrice: 48000, total: 48000, currency: "ARS" },
  { id: "s24", date: daysAgo(9), productId: "p11", productName: "Mouse Inalambrico", clientId: "c11", clientName: "Camila Herrera", quantity: 2, unitPrice: 28000, total: 56000, currency: "ARS" },
  { id: "s25", date: daysAgo(10), productId: "p7", productName: "Cable HDMI 2m", clientId: "c5", clientName: "Laura Fernandez", quantity: 2, unitPrice: 14000, total: 28000, currency: "ARS" },
  { id: "s26", date: daysAgo(11), productId: "p1", productName: "Auriculares Bluetooth", clientId: "c6", clientName: "Diego Sanchez", quantity: 3, unitPrice: 35000, total: 105000, currency: "ARS" },
  { id: "s27", date: daysAgo(12), productId: "p5", productName: "Proteina Whey 1kg", clientId: "c10", clientName: "Lucas Romero", quantity: 2, unitPrice: 45000, total: 90000, currency: "ARS" },
  { id: "s28", date: daysAgo(14), productId: "p18", productName: "Hoodie Oversize", clientId: "c8", clientName: "Martin Diaz", quantity: 2, unitPrice: 42000, total: 84000, currency: "ARS" },
  { id: "s29", date: daysAgo(16), productId: "p13", productName: "Gafas de Sol", clientId: "c1", clientName: "Maria Garcia", quantity: 1, unitPrice: 20000, total: 20000, currency: "ARS" },
  { id: "s30", date: daysAgo(20), productId: "p6", productName: "Organizador Escritorio", clientId: "c2", clientName: "Carlos Lopez", quantity: 1, unitPrice: 28000, total: 28000, currency: "ARS" },
  { id: "s31", date: daysAgo(22), productId: "p10", productName: "Mate con Bombilla", clientId: "c11", clientName: "Camila Herrera", quantity: 3, unitPrice: 18000, total: 54000, currency: "ARS" },
  { id: "s32", date: daysAgo(25), productId: "p4", productName: "Camiseta Algodon Premium", clientId: "c6", clientName: "Diego Sanchez", quantity: 2, unitPrice: 25000, total: 50000, currency: "ARS" },
]

export const mockPurchases: Purchase[] = [
  { id: "pr1", date: daysAgo(1), productId: "p1", productName: "Auriculares Bluetooth", quantity: 50, unitCost: 15000, total: 750000 },
  { id: "pr2", date: daysAgo(3), productId: "p2", productName: "Funda iPhone 15", quantity: 100, unitCost: 3000, total: 300000 },
  { id: "pr3", date: daysAgo(5), productId: "p4", productName: "Camiseta Algodon Premium", quantity: 60, unitCost: 7000, total: 420000 },
  { id: "pr4", date: daysAgo(7), productId: "p5", productName: "Proteina Whey 1kg", quantity: 20, unitCost: 20000, total: 400000 },
  { id: "pr5", date: daysAgo(8), productId: "p7", productName: "Cable HDMI 2m", quantity: 80, unitCost: 4000, total: 320000 },
  { id: "pr6", date: daysAgo(10), productId: "p11", productName: "Mouse Inalambrico", quantity: 30, unitCost: 10000, total: 300000 },
  { id: "pr7", date: daysAgo(12), productId: "p13", productName: "Gafas de Sol", quantity: 50, unitCost: 5000, total: 250000 },
  { id: "pr8", date: daysAgo(14), productId: "p17", productName: "Lamina Protectora Pantalla", quantity: 200, unitCost: 1000, total: 200000 },
  { id: "pr9", date: daysAgo(15), productId: "p8", productName: "Crema Hidratante Natural", quantity: 40, unitCost: 12000, total: 480000 },
  { id: "pr10", date: daysAgo(18), productId: "p9", productName: "Mochila Urbana", quantity: 15, unitCost: 18000, total: 270000 },
  { id: "pr11", date: daysAgo(20), productId: "p3", productName: "Cargador USB-C Rapido", quantity: 40, unitCost: 8000, total: 320000 },
  { id: "pr12", date: daysAgo(22), productId: "p18", productName: "Hoodie Oversize", quantity: 25, unitCost: 15000, total: 375000 },
  { id: "pr13", date: daysAgo(25), productId: "p6", productName: "Organizador Escritorio", quantity: 30, unitCost: 10000, total: 300000 },
  { id: "pr14", date: daysAgo(28), productId: "p10", productName: "Mate con Bombilla", quantity: 50, unitCost: 6000, total: 300000 },
]

export const mockExpenses: Expense[] = [
  { id: "e1", date: daysAgo(0), category: "Marketing", description: "Publicidad en Instagram", amount: 150000 },
  { id: "e2", date: daysAgo(1), category: "Logistica", description: "Envios del dia", amount: 85000 },
  { id: "e3", date: daysAgo(1), category: "Servicios", description: "Internet fibra optica", amount: 45000 },
  { id: "e4", date: daysAgo(2), category: "Marketing", description: "Flyers y folleteria", amount: 60000 },
  { id: "e5", date: daysAgo(3), category: "Alquiler", description: "Alquiler local mensual", amount: 800000 },
  { id: "e6", date: daysAgo(3), category: "Personal", description: "Sueldo asistente part-time", amount: 500000 },
  { id: "e7", date: daysAgo(5), category: "Logistica", description: "Envios del dia", amount: 120000 },
  { id: "e8", date: daysAgo(6), category: "Marketing", description: "Google Ads campana", amount: 200000 },
  { id: "e9", date: daysAgo(7), category: "Servicios", description: "Luz y gas", amount: 90000 },
  { id: "e10", date: daysAgo(8), category: "Otros", description: "Material de oficina", amount: 35000 },
  { id: "e11", date: daysAgo(10), category: "Impuestos", description: "Monotributo mensual", amount: 120000 },
  { id: "e12", date: daysAgo(12), category: "Logistica", description: "Packaging y cajas", amount: 75000 },
  { id: "e13", date: daysAgo(15), category: "Marketing", description: "Diseno de logo actualizado", amount: 180000 },
  { id: "e14", date: daysAgo(18), category: "Servicios", description: "Hosting web + dominio", amount: 25000 },
  { id: "e15", date: daysAgo(20), category: "Personal", description: "Capacitacion equipo", amount: 300000 },
  { id: "e16", date: daysAgo(25), category: "Logistica", description: "Envios del dia", amount: 95000 },
]

export const mockInsights: Insight[] = [
  { id: "i1", type: "ventas", priority: "alta", message: "Las ventas de Auriculares Bluetooth crecieron un 35% esta semana. Considera aumentar el stock.", date: daysAgo(0) },
  { id: "i2", type: "stock", priority: "alta", message: "Zapatillas Running y Power Bank estan por debajo del stock minimo. Repone urgente.", date: daysAgo(0) },
  { id: "i3", type: "gastos", priority: "media", message: "Los gastos en Marketing representan el 28% de tus gastos totales. Revisa el ROI de cada campana.", date: daysAgo(1) },
  { id: "i4", type: "clientes", priority: "media", message: "Lucas Romero y Ana Martinez son tus clientes mas valiosos. Ofreceles descuentos exclusivos.", date: daysAgo(1) },
  { id: "i5", type: "margen", priority: "baja", message: "Las Laminas Protectoras tienen un margen del 88%. Es tu producto mas rentable.", date: daysAgo(2) },
]

export const mockPosts: Post[] = [
  { id: "po1", author: "EIE Oficial", title: "Bienvenidos a la comunidad", content: "Este es el espacio para compartir experiencias, hacer preguntas y aprender juntos. Las reglas son simples: respeto, colaboracion y ganas de crecer.", category: "General", date: daysAgo(30), replies: 12, likes: 45 },
  { id: "po2", author: "Maria G.", title: "Como duplique mis ventas en 30 dias", content: "Empece usando el simulador de precios y me di cuenta que tenia margenes muy bajos en algunos productos. Ajuste precios y mejore mi publicidad. Resultado: ventas x2.", category: "Casos de exito", date: daysAgo(5), replies: 8, likes: 32 },
  { id: "po3", author: "Carlos L.", title: "Tips para gestion de stock", content: "Despues de quedarme sin stock 3 veces seguidas, empece a usar el sistema de semaforo y ahora siempre se cuando reponer. Recomendado al 100%.", category: "Tips", date: daysAgo(3), replies: 5, likes: 18 },
  { id: "po4", author: "Laura F.", title: "Mejor plataforma de envios para emprendedores?", content: "Estoy buscando una plataforma de envios que sea economica y confiable. Alguna recomendacion? Actualmente uso correo tradicional pero los tiempos son muy largos.", category: "Preguntas", date: daysAgo(1), replies: 15, likes: 7 },
  { id: "po5", author: "Diego S.", title: "Experiencia con publicidad en Instagram", content: "Llevo 3 meses invirtiendo en Instagram Ads y quiero compartir mis aprendizajes. Lo mas importante: segmentar bien y usar creatividades que muestren el producto en uso.", category: "Tips", date: daysAgo(2), replies: 10, likes: 25 },
  { id: "po6", author: "Valentina R.", title: "Como calcular correctamente los margenes", content: "Muchos emprendedores cometen el error de calcular el margen sobre el costo en vez de sobre el precio de venta. Aca les explico la diferencia y por que importa.", category: "Educacion", date: daysAgo(7), replies: 20, likes: 55 },
]

export const mockCourses: Course[] = [
  {
    id: "cr1", title: "Fundamentos de Gestion para Emprendedores", description: "Aprende los conceptos basicos de gestion empresarial: finanzas, marketing, operaciones y liderazgo.", level: "basico", isPro: false, category: "Gestion",
    students: 1240, rating: 4.8,
    modules: [
      { id: "m1", title: "Introduccion a la gestion empresarial", duration: "15 min", completed: true },
      { id: "m2", title: "Finanzas basicas para emprendedores", duration: "20 min", completed: true },
      { id: "m3", title: "Marketing 101", duration: "25 min", completed: false },
      { id: "m4", title: "Operaciones y logistica", duration: "20 min", completed: false },
    ],
  },
  {
    id: "cr2", title: "Gestion de Inventario Inteligente", description: "Domina el arte de gestionar tu stock para nunca quedarte sin productos ni tener exceso de inventario.", level: "intermedio", isPro: false, category: "Operaciones",
    students: 856, rating: 4.6,
    modules: [
      { id: "m5", title: "Por que importa el inventario", duration: "10 min", completed: false },
      { id: "m6", title: "Metodos de reposicion", duration: "20 min", completed: false },
      { id: "m7", title: "El sistema de semaforo", duration: "15 min", completed: false },
      { id: "m8", title: "Prediccion de demanda", duration: "25 min", completed: false },
    ],
  },
  {
    id: "cr3", title: "Marketing Digital para Emprendedores", description: "Estrategias probadas de marketing digital para hacer crecer tu negocio online.", level: "basico", isPro: false, category: "Marketing",
    students: 2100, rating: 4.9,
    modules: [
      { id: "m9", title: "Ecosistema digital actual", duration: "15 min", completed: false },
      { id: "m10", title: "Redes sociales que venden", duration: "30 min", completed: false },
      { id: "m11", title: "Email marketing efectivo", duration: "20 min", completed: false },
    ],
  },
  {
    id: "cr4", title: "Estrategias Avanzadas de Pricing", description: "Aprende a fijar precios que maximicen tu ganancia sin perder clientes. Incluye simulaciones y casos reales.", level: "avanzado", isPro: true, category: "Finanzas",
    students: 430, rating: 4.7,
    modules: [
      { id: "m12", title: "Psicologia de precios", duration: "20 min", completed: false },
      { id: "m13", title: "Modelos de pricing", duration: "25 min", completed: false },
      { id: "m14", title: "Simulacion y analisis", duration: "30 min", completed: false },
      { id: "m15", title: "Casos reales", duration: "25 min", completed: false },
    ],
  },
  {
    id: "cr5", title: "Analisis de Datos para tu Negocio", description: "Converti tus datos en decisiones inteligentes. Aprende a leer metricas, detectar tendencias y actuar.", level: "avanzado", isPro: true, category: "Datos",
    students: 320, rating: 4.5,
    modules: [
      { id: "m16", title: "Que medir y por que", duration: "15 min", completed: false },
      { id: "m17", title: "KPIs esenciales", duration: "20 min", completed: false },
      { id: "m18", title: "Tendencias y predicciones", duration: "30 min", completed: false },
    ],
  },
  {
    id: "cr6", title: "Escalando tu Negocio", description: "Del emprendimiento al negocio real: procesos, equipo, financiamiento y expansion.", level: "avanzado", isPro: true, category: "Crecimiento",
    students: 275, rating: 4.8,
    modules: [
      { id: "m19", title: "Cuando escalar", duration: "15 min", completed: false },
      { id: "m20", title: "Construir un equipo", duration: "25 min", completed: false },
      { id: "m21", title: "Financiamiento y capital", duration: "20 min", completed: false },
      { id: "m22", title: "Automatizacion y sistemas", duration: "25 min", completed: false },
    ],
  },
]
