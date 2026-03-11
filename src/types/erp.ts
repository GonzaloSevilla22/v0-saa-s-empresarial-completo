export interface Company {
  id: string
  name: string
  created_at: string
}

export interface CompanyUser {
  id: string
  company_id: string
  user_id: string
  role: 'admin' | 'manager' | 'seller' | 'warehouse'
  created_at: string
}

export interface Product {
  id: string
  company_id: string
  name: string
  category?: string
  brand?: string
  created_at: string
  deleted_at?: string
  
  // Transformed relationships
  variants?: ProductVariant[]
}

export interface ProductVariant {
  id: string
  product_id: string
  sku?: string
  barcode?: string
  price: number
  cost: number
  attributes?: Record<string, string>
  created_at: string
  
  // Injected for UI ease
  stock?: number
}

export interface Warehouse {
  id: string
  company_id: string
  name: string
  created_at: string
}

export interface InventoryMovement {
  id: string
  company_id: string
  variant_id: string
  warehouse_id: string
  movement_type: 'purchase' | 'sale' | 'adjustment' | 'return' | 'transfer'
  quantity: number
  unit_cost: number
  reference_type?: string
  reference_id?: string
  created_by?: string
  created_at: string
}

export interface InventoryStock {
  variant_id: string
  warehouse_id: string
  quantity: number
}

export interface Sale {
  id: string
  company_id: string
  client_id?: string
  total: number
  currency: string
  created_at: string
  date: string // Legacy support
  
  items?: SaleItem[]
}

export interface SaleItem {
  id: string
  sale_id: string
  variant_id: string
  quantity: number
  price: number
  subtotal: number
}

export interface Supplier {
  id: string
  company_id: string
  name: string
  email?: string
  phone?: string
  tax_id?: string
  created_at: string
}

export interface Purchase {
  id: string
  company_id: string
  supplier_id?: string
  total: number
  created_at: string
  date: string // Legacy
  
  items?: PurchaseItem[]
}

export interface PurchaseItem {
  id: string
  purchase_id: string
  variant_id: string
  quantity: number
  price: number
  subtotal: number
}
