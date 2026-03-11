import { SupabaseClient } from "@supabase/supabase-js"
import { InventoryMovement } from "../types/erp"

export class InventoryRepository {
  constructor(private readonly supabase: SupabaseClient) {}

  async createMovement(movement: Partial<InventoryMovement>): Promise<void> {
    const { error } = await this.supabase
      .from('inventory_movements')
      .insert([movement])

    if (error) throw new Error("Error creating inventory movement: " + error.message)
    // The trg_update_inventory_stock Postgres trigger will automatically update inventory_stock
  }

  async getMovementsByCompany(companyId: string, limit: number = 100): Promise<InventoryMovement[]> {
    const { data, error } = await this.supabase
      .from('inventory_movements')
      .select('*')
      .eq('company_id', companyId)
      .order('created_at', { ascending: false })
      .limit(limit)

    if (error) throw new Error("Error fetching inventory movements: " + error.message)
    return data as InventoryMovement[]
  }

  async getVariantStock(variantId: string, warehouseId?: string): Promise<number> {
    let query = this.supabase
      .from('inventory_stock')
      .select('quantity')
      .eq('variant_id', variantId)

    if (warehouseId) {
      query = query.eq('warehouse_id', warehouseId)
    }

    const { data, error } = await query

    if (error) throw new Error("Error fetching inventory stock: " + error.message)
    return data?.reduce((acc, curr) => acc + (curr.quantity || 0), 0) || 0
  }
}
