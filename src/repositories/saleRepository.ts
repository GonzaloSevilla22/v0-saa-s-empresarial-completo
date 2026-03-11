import { SupabaseClient } from "@supabase/supabase-js"
import { Sale, SaleItem } from "../types/erp"

export class SaleRepository {
  constructor(private readonly supabase: SupabaseClient) {}

  async getSalesByCompany(companyId: string): Promise<Sale[]> {
    const { data, error } = await this.supabase
      .from('sales')
      .select(`
        *,
        items:sale_items(
          *,
          variant:product_variants(
            sku,
            product:products(name)
          )
        ),
        client:clients(name)
      `)
      .eq('company_id', companyId)
      .order('created_at', { ascending: false })

    if (error) throw new Error("Error fetching sales: " + error.message)
    return data as Sale[]
  }

  async createSaleAndItems(saleData: Partial<Sale>, itemsData: Partial<SaleItem>[]): Promise<void> {
    const { data: sale, error: sError } = await this.supabase
      .from('sales')
      .insert([saleData])
      .select()
      .single()

    if (sError) throw new Error("Error creating sale: " + sError.message)

    const itemsToInsert = itemsData.map(item => ({
      ...item,
      sale_id: sale.id
    }))

    const { error: iError } = await this.supabase
      .from('sale_items')
      .insert(itemsToInsert)

    if (iError) {
      // Best effort rollback
      await this.supabase.from('sales').delete().eq('id', sale.id)
      throw new Error("Error creating sale items: " + iError.message)
    }
  }

  async softDeleteSale(id: string): Promise<void> {
    const { error } = await this.supabase
      .from('sales')
      .delete()
      .eq('id', id)

    if (error) throw new Error("Error deleting sale: " + error.message)
  }
}
