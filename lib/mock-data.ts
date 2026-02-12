import type { Product, Sale, Purchase, Expense, Client, Insight, Post, Course } from "./types"

// Helpers
const today = new Date()
const daysAgo = (n: number) => {
  const d = new Date(today)
  d.setDate(d.getDate() - n)
  return d.toISOString().split("T")[0]
}

export const mockProducts: Product[] = [
  { id: "p1", name: "Auriculares Bluetooth", category: "Electrónica", cost: 15, price: 35, margin: 57, stock: 45, minStock: 10 },
  { id: "p2", name: "Funda iPhone 15", category: "Accesorios", cost: 3, price: 12, margin: 75, stock: 120, minStock: 30 },
  { id: "p3", name: "Cargador USB-C Rápido", category: "Electrónica", cost: 8, price: 22, margin: 64, stock: 60, minStock: 15 },
  { id: "p4", name: "Camiseta Algodón Premium", category: "Ropa", cost: 7, price: 25, margin: 72, stock: 80, minStock: 20 },
  { id: "p5", name: "Proteína Whey 1kg", category: "Salud", cost: 20, price: 45, margin: 56, stock: 25, minStock: 10 },
  { id: "p6", name: "Organizador Escritorio", category: "Hogar", cost: 10, price: 28, margin: 64, stock: 35, minStock: 8 },
  { id: "p7", name: "Cable HDMI 2m", category: "Electrónica", cost: 4, price: 14, margin: 71, stock: 90, minStock: 20 },
  { id: "p8", name: "Crema Hidratante Natural", category: "Salud", cost: 12, price: 32, margin: 63, stock: 40, minStock: 10 },
  { id: "p9", name: "Mochila Urbana", category: "Accesorios", cost: 18, price: 48, margin: 63, stock: 22, minStock: 8 },
  { id: "p10", name: "Mate con Bombilla", category: "Hogar", cost: 6, price: 18, margin: 67, stock: 55, minStock: 15 },
  { id: "p11", name: "Mouse Inalámbrico", category: "Electrónica", cost: 10, price: 28, margin: 64, stock: 38, minStock: 10 },
  { id: "p12", name: "Termo 500ml", category: "Hogar", cost: 9, price: 26, margin: 65, stock: 42, minStock: 12 },
  { id: "p13", name: "Gafas de Sol", category: "Accesorios", cost: 5, price: 20, margin: 75, stock: 65, minStock: 15 },
  { id: "p14", name: "Zapatillas Running", category: "Ropa", cost: 30, price: 75, margin: 60, stock: 3, minStock: 8 },
  { id: "p15", name: "Power Bank 10000mAh", category: "Electrónica", cost: 14, price: 38, margin: 63, stock: 5, minStock: 10 },
  { id: "p16", name: "Aceite de Coco Orgánico", category: "Alimentos", cost: 8, price: 22, margin: 64, stock: 30, minStock: 10 },
  { id: "p17", name: "Lámina Protectora Pantalla", category: "Accesorios", cost: 1, price: 8, margin: 88, stock: 200, minStock: 50 },
  { id: "p18", name: "Hoodie Oversize", category: "Ropa", cost: 15, price: 42, margin: 64, stock: 28, minStock: 10 },
]

export const mockClients: Client[] = [
  { id: "c1", name: "María García", email: "maria@email.com", phone: "+54 11 5555-1234", status: "activo", lastPurchase: daysAgo(2), totalSpent: 1250 },
  { id: "c2", name: "Carlos López", email: "carlos@email.com", phone: "+54 11 5555-5678", status: "activo", lastPurchase: daysAgo(5), totalSpent: 890 },
  { id: "c3", name: "Ana Martínez", email: "ana@email.com", phone: "+54 11 5555-9012", status: "activo", lastPurchase: daysAgo(1), totalSpent: 2100 },
  { id: "c4", name: "Pedro Rodríguez", email: "pedro@email.com", phone: "+54 11 5555-3456", status: "inactivo", lastPurchase: daysAgo(45), totalSpent: 430 },
  { id: "c5", name: "Laura Fernández", email: "laura@email.com", phone: "+54 11 5555-7890", status: "activo", lastPurchase: daysAgo(3), totalSpent: 1780 },
  { id: "c6", name: "Diego Sánchez", email: "diego@email.com", phone: "+54 11 5555-2345", status: "activo", lastPurchase: daysAgo(7), totalSpent: 650 },
  { id: "c7", name: "Valentina Ruiz", email: "valentina@email.com", phone: "+54 11 5555-6789", status: "perdido", lastPurchase: daysAgo(90), totalSpent: 220 },
  { id: "c8", name: "Martín Díaz", email: "martin@email.com", phone: "+54 11 5555-0123", status: "activo", lastPurchase: daysAgo(4), totalSpent: 1450 },
  { id: "c9", name: "Sofía Torres", email: "sofia@email.com", phone: "+54 11 5555-4567", status: "inactivo", lastPurchase: daysAgo(60), totalSpent: 340 },
  { id: "c10", name: "Lucas Romero", email: "lucas@email.com", phone: "+54 11 5555-8901", status: "activo", lastPurchase: daysAgo(1), totalSpent: 3200 },
  { id: "c11", name: "Camila Herrera", email: "camila@email.com", phone: "+54 11 5555-1122", status: "activo", lastPurchase: daysAgo(10), totalSpent: 560 },
]

export const mockSales: Sale[] = [
  { id: "s1", date: daysAgo(0), productId: "p1", productName: "Auriculares Bluetooth", clientId: "c3", clientName: "Ana Martínez", quantity: 2, unitPrice: 35, total: 70 },
  { id: "s2", date: daysAgo(0), productId: "p2", productName: "Funda iPhone 15", clientId: "c10", clientName: "Lucas Romero", quantity: 3, unitPrice: 12, total: 36 },
  { id: "s3", date: daysAgo(0), productId: "p5", productName: "Proteína Whey 1kg", clientId: "c1", clientName: "María García", quantity: 1, unitPrice: 45, total: 45 },
  { id: "s4", date: daysAgo(1), productId: "p4", productName: "Camiseta Algodón Premium", clientId: "c3", clientName: "Ana Martínez", quantity: 4, unitPrice: 25, total: 100 },
  { id: "s5", date: daysAgo(1), productId: "p9", productName: "Mochila Urbana", clientId: "c5", clientName: "Laura Fernández", quantity: 1, unitPrice: 48, total: 48 },
  { id: "s6", date: daysAgo(1), productId: "p17", productName: "Lámina Protectora Pantalla", clientId: "c10", clientName: "Lucas Romero", quantity: 5, unitPrice: 8, total: 40 },
  { id: "s7", date: daysAgo(2), productId: "p3", productName: "Cargador USB-C Rápido", clientId: "c1", clientName: "María García", quantity: 2, unitPrice: 22, total: 44 },
  { id: "s8", date: daysAgo(2), productId: "p11", productName: "Mouse Inalámbrico", clientId: "c2", clientName: "Carlos López", quantity: 1, unitPrice: 28, total: 28 },
  { id: "s9", date: daysAgo(2), productId: "p6", productName: "Organizador Escritorio", clientId: "c8", clientName: "Martín Díaz", quantity: 2, unitPrice: 28, total: 56 },
  { id: "s10", date: daysAgo(3), productId: "p18", productName: "Hoodie Oversize", clientId: "c5", clientName: "Laura Fernández", quantity: 1, unitPrice: 42, total: 42 },
  { id: "s11", date: daysAgo(3), productId: "p7", productName: "Cable HDMI 2m", clientId: "c6", clientName: "Diego Sánchez", quantity: 3, unitPrice: 14, total: 42 },
  { id: "s12", date: daysAgo(3), productId: "p13", productName: "Gafas de Sol", clientId: "c3", clientName: "Ana Martínez", quantity: 2, unitPrice: 20, total: 40 },
  { id: "s13", date: daysAgo(4), productId: "p1", productName: "Auriculares Bluetooth", clientId: "c8", clientName: "Martín Díaz", quantity: 1, unitPrice: 35, total: 35 },
  { id: "s14", date: daysAgo(4), productId: "p10", productName: "Mate con Bombilla", clientId: "c2", clientName: "Carlos López", quantity: 2, unitPrice: 18, total: 36 },
  { id: "s15", date: daysAgo(5), productId: "p12", productName: "Termo 500ml", clientId: "c2", clientName: "Carlos López", quantity: 1, unitPrice: 26, total: 26 },
  { id: "s16", date: daysAgo(5), productId: "p8", productName: "Crema Hidratante Natural", clientId: "c1", clientName: "María García", quantity: 2, unitPrice: 32, total: 64 },
  { id: "s17", date: daysAgo(5), productId: "p4", productName: "Camiseta Algodón Premium", clientId: "c11", clientName: "Camila Herrera", quantity: 3, unitPrice: 25, total: 75 },
  { id: "s18", date: daysAgo(6), productId: "p15", productName: "Power Bank 10000mAh", clientId: "c6", clientName: "Diego Sánchez", quantity: 1, unitPrice: 38, total: 38 },
  { id: "s19", date: daysAgo(6), productId: "p2", productName: "Funda iPhone 15", clientId: "c5", clientName: "Laura Fernández", quantity: 4, unitPrice: 12, total: 48 },
  { id: "s20", date: daysAgo(6), productId: "p16", productName: "Aceite de Coco Orgánico", clientId: "c8", clientName: "Martín Díaz", quantity: 2, unitPrice: 22, total: 44 },
  { id: "s21", date: daysAgo(7), productId: "p3", productName: "Cargador USB-C Rápido", clientId: "c10", clientName: "Lucas Romero", quantity: 1, unitPrice: 22, total: 22 },
  { id: "s22", date: daysAgo(7), productId: "p14", productName: "Zapatillas Running", clientId: "c3", clientName: "Ana Martínez", quantity: 1, unitPrice: 75, total: 75 },
  { id: "s23", date: daysAgo(8), productId: "p9", productName: "Mochila Urbana", clientId: "c1", clientName: "María García", quantity: 1, unitPrice: 48, total: 48 },
  { id: "s24", date: daysAgo(9), productId: "p11", productName: "Mouse Inalámbrico", clientId: "c11", clientName: "Camila Herrera", quantity: 2, unitPrice: 28, total: 56 },
  { id: "s25", date: daysAgo(10), productId: "p7", productName: "Cable HDMI 2m", clientId: "c5", clientName: "Laura Fernández", quantity: 2, unitPrice: 14, total: 28 },
  { id: "s26", date: daysAgo(11), productId: "p1", productName: "Auriculares Bluetooth", clientId: "c6", clientName: "Diego Sánchez", quantity: 3, unitPrice: 35, total: 105 },
  { id: "s27", date: daysAgo(12), productId: "p5", productName: "Proteína Whey 1kg", clientId: "c10", clientName: "Lucas Romero", quantity: 2, unitPrice: 45, total: 90 },
  { id: "s28", date: daysAgo(14), productId: "p18", productName: "Hoodie Oversize", clientId: "c8", clientName: "Martín Díaz", quantity: 2, unitPrice: 42, total: 84 },
  { id: "s29", date: daysAgo(16), productId: "p13", productName: "Gafas de Sol", clientId: "c1", clientName: "María García", quantity: 1, unitPrice: 20, total: 20 },
  { id: "s30", date: daysAgo(20), productId: "p6", productName: "Organizador Escritorio", clientId: "c2", clientName: "Carlos López", quantity: 1, unitPrice: 28, total: 28 },
  { id: "s31", date: daysAgo(22), productId: "p10", productName: "Mate con Bombilla", clientId: "c11", clientName: "Camila Herrera", quantity: 3, unitPrice: 18, total: 54 },
  { id: "s32", date: daysAgo(25), productId: "p4", productName: "Camiseta Algodón Premium", clientId: "c6", clientName: "Diego Sánchez", quantity: 2, unitPrice: 25, total: 50 },
]

export const mockPurchases: Purchase[] = [
  { id: "pr1", date: daysAgo(1), productId: "p1", productName: "Auriculares Bluetooth", quantity: 50, unitCost: 15, total: 750 },
  { id: "pr2", date: daysAgo(3), productId: "p2", productName: "Funda iPhone 15", quantity: 100, unitCost: 3, total: 300 },
  { id: "pr3", date: daysAgo(5), productId: "p4", productName: "Camiseta Algodón Premium", quantity: 60, unitCost: 7, total: 420 },
  { id: "pr4", date: daysAgo(7), productId: "p5", productName: "Proteína Whey 1kg", quantity: 20, unitCost: 20, total: 400 },
  { id: "pr5", date: daysAgo(8), productId: "p7", productName: "Cable HDMI 2m", quantity: 80, unitCost: 4, total: 320 },
  { id: "pr6", date: daysAgo(10), productId: "p11", productName: "Mouse Inalámbrico", quantity: 30, unitCost: 10, total: 300 },
  { id: "pr7", date: daysAgo(12), productId: "p13", productName: "Gafas de Sol", quantity: 50, unitCost: 5, total: 250 },
  { id: "pr8", date: daysAgo(14), productId: "p17", productName: "Lámina Protectora Pantalla", quantity: 200, unitCost: 1, total: 200 },
  { id: "pr9", date: daysAgo(15), productId: "p8", productName: "Crema Hidratante Natural", quantity: 40, unitCost: 12, total: 480 },
  { id: "pr10", date: daysAgo(18), productId: "p9", productName: "Mochila Urbana", quantity: 15, unitCost: 18, total: 270 },
  { id: "pr11", date: daysAgo(20), productId: "p3", productName: "Cargador USB-C Rápido", quantity: 40, unitCost: 8, total: 320 },
  { id: "pr12", date: daysAgo(22), productId: "p18", productName: "Hoodie Oversize", quantity: 25, unitCost: 15, total: 375 },
  { id: "pr13", date: daysAgo(25), productId: "p6", productName: "Organizador Escritorio", quantity: 30, unitCost: 10, total: 300 },
  { id: "pr14", date: daysAgo(28), productId: "p10", productName: "Mate con Bombilla", quantity: 50, unitCost: 6, total: 300 },
]

export const mockExpenses: Expense[] = [
  { id: "e1", date: daysAgo(0), category: "Marketing", description: "Publicidad en Instagram", amount: 150 },
  { id: "e2", date: daysAgo(1), category: "Logistica", description: "Envíos del día", amount: 85 },
  { id: "e3", date: daysAgo(1), category: "Servicios", description: "Internet fibra óptica", amount: 45 },
  { id: "e4", date: daysAgo(2), category: "Marketing", description: "Flyers y folletería", amount: 60 },
  { id: "e5", date: daysAgo(3), category: "Alquiler", description: "Alquiler local mensual", amount: 800 },
  { id: "e6", date: daysAgo(3), category: "Personal", description: "Sueldo asistente part-time", amount: 500 },
  { id: "e7", date: daysAgo(5), category: "Logistica", description: "Envíos del día", amount: 120 },
  { id: "e8", date: daysAgo(6), category: "Marketing", description: "Google Ads campaña", amount: 200 },
  { id: "e9", date: daysAgo(7), category: "Servicios", description: "Luz y gas", amount: 90 },
  { id: "e10", date: daysAgo(8), category: "Otros", description: "Material de oficina", amount: 35 },
  { id: "e11", date: daysAgo(10), category: "Impuestos", description: "Monotributo mensual", amount: 120 },
  { id: "e12", date: daysAgo(12), category: "Logistica", description: "Packaging y cajas", amount: 75 },
  { id: "e13", date: daysAgo(15), category: "Marketing", description: "Diseño de logo actualizado", amount: 180 },
  { id: "e14", date: daysAgo(18), category: "Servicios", description: "Hosting web + dominio", amount: 25 },
  { id: "e15", date: daysAgo(20), category: "Personal", description: "Capacitación equipo", amount: 300 },
  { id: "e16", date: daysAgo(25), category: "Logistica", description: "Envíos del día", amount: 95 },
]

export const mockInsights: Insight[] = [
  { id: "i1", type: "ventas", priority: "alta", message: "Las ventas de Auriculares Bluetooth crecieron un 35% esta semana. Considerá aumentar el stock.", date: daysAgo(0) },
  { id: "i2", type: "stock", priority: "alta", message: "Zapatillas Running y Power Bank están por debajo del stock mínimo. Reponé urgente.", date: daysAgo(0) },
  { id: "i3", type: "gastos", priority: "media", message: "Los gastos en Marketing representan el 28% de tus gastos totales. Revisá el ROI de cada campaña.", date: daysAgo(1) },
  { id: "i4", type: "clientes", priority: "media", message: "Lucas Romero y Ana Martínez son tus clientes más valiosos. Ofreceles descuentos exclusivos.", date: daysAgo(1) },
  { id: "i5", type: "margen", priority: "baja", message: "Las Láminas Protectoras tienen un margen del 88%. Es tu producto más rentable.", date: daysAgo(2) },
]

export const mockPosts: Post[] = [
  { id: "po1", author: "EIE Oficial", title: "Bienvenidos a la comunidad", content: "Este es el espacio para compartir experiencias, hacer preguntas y aprender juntos. Las reglas son simples: respeto, colaboración y ganas de crecer.", category: "General", date: daysAgo(30), replies: 12, likes: 45 },
  { id: "po2", author: "María G.", title: "Cómo duplicé mis ventas en 30 días", content: "Empecé usando el simulador de precios y me di cuenta que tenía márgenes muy bajos en algunos productos. Ajusté precios y mejoré mi publicidad. Resultado: ventas x2.", category: "Casos de éxito", date: daysAgo(5), replies: 8, likes: 32 },
  { id: "po3", author: "Carlos L.", title: "Tips para gestión de stock", content: "Después de quedarme sin stock 3 veces seguidas, empecé a usar el sistema de semáforo y ahora siempre sé cuándo reponer. Recomendado al 100%.", category: "Tips", date: daysAgo(3), replies: 5, likes: 18 },
  { id: "po4", author: "Laura F.", title: "Mejor plataforma de envíos para emprendedores?", content: "Estoy buscando una plataforma de envíos que sea económica y confiable. Alguna recomendación? Actualmente uso correo tradicional pero los tiempos son muy largos.", category: "Preguntas", date: daysAgo(1), replies: 15, likes: 7 },
  { id: "po5", author: "Diego S.", title: "Experiencia con publicidad en Instagram", content: "Llevo 3 meses invirtiendo en Instagram Ads y quiero compartir mis aprendizajes. Lo más importante: segmentar bien y usar creatividades que muestren el producto en uso.", category: "Tips", date: daysAgo(2), replies: 10, likes: 25 },
  { id: "po6", author: "Valentina R.", title: "Cómo calcular correctamente los márgenes", content: "Muchos emprendedores cometen el error de calcular el margen sobre el costo en vez de sobre el precio de venta. Acá les explico la diferencia y por qué importa.", category: "Educación", date: daysAgo(7), replies: 20, likes: 55 },
]

export const mockCourses: Course[] = [
  {
    id: "cr1", title: "Fundamentos de Gestión para Emprendedores", description: "Aprendé los conceptos básicos de gestión empresarial: finanzas, marketing, operaciones y liderazgo.", level: "basico", isPro: false, category: "Gestión",
    students: 1240, rating: 4.8,
    modules: [
      { id: "m1", title: "Introducción a la gestión empresarial", duration: "15 min", completed: true },
      { id: "m2", title: "Finanzas básicas para emprendedores", duration: "20 min", completed: true },
      { id: "m3", title: "Marketing 101", duration: "25 min", completed: false },
      { id: "m4", title: "Operaciones y logística", duration: "20 min", completed: false },
    ],
  },
  {
    id: "cr2", title: "Gestión de Inventario Inteligente", description: "Dominá el arte de gestionar tu stock para nunca quedarte sin productos ni tener exceso de inventario.", level: "intermedio", isPro: false, category: "Operaciones",
    students: 856, rating: 4.6,
    modules: [
      { id: "m5", title: "Por qué importa el inventario", duration: "10 min", completed: false },
      { id: "m6", title: "Métodos de reposición", duration: "20 min", completed: false },
      { id: "m7", title: "El sistema de semáforo", duration: "15 min", completed: false },
      { id: "m8", title: "Predicción de demanda", duration: "25 min", completed: false },
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
    id: "cr4", title: "Estrategias Avanzadas de Pricing", description: "Aprendé a fijar precios que maximicen tu ganancia sin perder clientes. Incluye simulaciones y casos reales.", level: "avanzado", isPro: true, category: "Finanzas",
    students: 430, rating: 4.7,
    modules: [
      { id: "m12", title: "Psicología de precios", duration: "20 min", completed: false },
      { id: "m13", title: "Modelos de pricing", duration: "25 min", completed: false },
      { id: "m14", title: "Simulación y análisis", duration: "30 min", completed: false },
      { id: "m15", title: "Casos reales", duration: "25 min", completed: false },
    ],
  },
  {
    id: "cr5", title: "Análisis de Datos para tu Negocio", description: "Convertí tus datos en decisiones inteligentes. Aprendé a leer métricas, detectar tendencias y actuar.", level: "avanzado", isPro: true, category: "Datos",
    students: 320, rating: 4.5,
    modules: [
      { id: "m16", title: "Qué medir y por qué", duration: "15 min", completed: false },
      { id: "m17", title: "KPIs esenciales", duration: "20 min", completed: false },
      { id: "m18", title: "Tendencias y predicciones", duration: "30 min", completed: false },
    ],
  },
  {
    id: "cr6", title: "Escalando tu Negocio", description: "Del emprendimiento al negocio real: procesos, equipo, financiamiento y expansión.", level: "avanzado", isPro: true, category: "Crecimiento",
    students: 275, rating: 4.8,
    modules: [
      { id: "m19", title: "Cuándo escalar", duration: "15 min", completed: false },
      { id: "m20", title: "Construir un equipo", duration: "25 min", completed: false },
      { id: "m21", title: "Financiamiento y capital", duration: "20 min", completed: false },
      { id: "m22", title: "Automatización y sistemas", duration: "25 min", completed: false },
    ],
  },
]
