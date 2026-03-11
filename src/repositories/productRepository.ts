import { SupabaseClient } from "@supabase/supabase-js"
import { Product, ProductVariant } from "../types/erp"

export class ProductRepository {
  constructor(private readonly supabase: SupabaseClient) {}

  async getProductsByCompany(companyId: string): Promise<Product[]> {
    const { data: products, error } = await this.supabase
      .from('products')
      .select(`
        *,
        variants:product_variants(*, inventory_stock(quantity))
      `)
      .eq('company_id', companyId)
      .is('deleted_at', null)
      .order('created_at', { ascending: false })

    if (error) throw new Error("Error fetching products: " + error.message)
    
    // Map the nested stock quantities back into the variants for ease of use
    return products.map(product => ({
      ...product,
      variants: product.variants?.map((v: any) => ({
        ...v,
        stock: v.inventory_stock?.reduce((acc: number, item: any) => acc + item.quantity, 0) || 0
      })) || []
    })) as Product[]
  }

  async createProductAndVariant(productData: Partial<Product>, variantData: Partial<ProductVariant>): Promise<Product> {
    // Note: Emulating a transaction. If using a custom Postgres RPC, use that instead.
    const { data: product, error: pError } = await this.supabase
      .from('products')
      .insert([productData])
      .select()
      .single()

    if (pError) throw new Error("Error creating product: " + pError.message)

    const { data: variant, error: vError } = await this.supabase
      .from('product_variants')
      .insert([{ ...variantData, product_id: product.id }])
      .select()
      .single()

    if (vError) {
      // Rollback (best effort in JS)
      await this.supabase.from('products').delete().eq('id', product.id)
      throw new Error("Error creating product variant: " + vError.message)
    }

    return { ...product, variants: [variant] } as Product
  }

  async updateProduct(id: string, updates: Partial<Product>): Promise<void> {
    const { error } = await this.supabase
      .from('products')
      .update(updates)
      .eq('id', id)

    if (error) throw new Error("Error updating product: " + error.message)
  }

  async updateVariant(id: string, updates: Partial<ProductVariant>): Promise<void> {
    const { error } = await this.supabase
      .from('product_variants')
      .update(updates)
      .eq('id', id)

    if (error) throw new Error("Error updating variant: " + error.message)
  }

  async softDeleteProduct(id: string): Promise<void> {
    const { error } = await this.supabase
      .from('products')
      .update({ deleted_at: new Date().toISOString() })
      .eq('id', id)

    if (error) throw new Error("Error deleting product: " + error.message)
  }
}
