/**
 * Tipos de dominio + validación en el borde (formularios y API routes).
 * Espejo exacto de los JSON Schemas sembrados en `attribute_schemas`.
 * Tip: para tipos de tablas crudas, además corre `supabase gen types typescript`.
 */
import { z } from 'zod'
import { RESERVED_SLUGS, SLUG_REGEX } from '@/lib/tenant/constants'

/* ───────────────────────────── Enums ───────────────────────────── */

export const PRODUCT_TYPES = ['sneakers', 'apparel', 'accessory', 'mixed'] as const
export const PRODUCT_STATUSES = ['draft', 'active', 'archived'] as const
export const TENANT_STATUSES = ['active', 'suspended', 'archived'] as const
export const MEMBER_ROLES = ['owner', 'admin', 'editor'] as const
export const PLAN_IDS = ['free', 'premium'] as const
export const ACCENTS = ['blue', 'purple', 'green'] as const // acentos neón sobre base dark

export type ProductType = (typeof PRODUCT_TYPES)[number]
export type ProductStatus = (typeof PRODUCT_STATUSES)[number]
export type TenantStatus = (typeof TENANT_STATUSES)[number]
export type MemberRole = (typeof MEMBER_ROLES)[number]
export type PlanId = (typeof PLAN_IDS)[number]
export type Accent = (typeof ACCENTS)[number]

/* ───────────────────────────── Tenant ───────────────────────────── */

export const themeSchema = z.object({
  accent: z.enum(ACCENTS).default('purple'),
  glass: z.boolean().default(true),
  logo_url: z.string().url().nullable().default(null),
})
export type Theme = z.infer<typeof themeSchema>

export interface Plan {
  id: PlanId
  name: string
  max_products: number | null
  allow_3d: boolean
  allow_custom_domain: boolean
  allow_online_payments: boolean
}

export interface Tenant {
  id: string
  slug: string
  name: string
  plan: PlanId
  status: TenantStatus
  custom_domain: string | null
  custom_domain_verified_at: string | null
  whatsapp_number: string | null
  currency: string
  locale: string
  theme: Theme
  created_at: string
  updated_at: string
}

export const tenantSlugSchema = z
  .string()
  .trim()
  .toLowerCase()
  .regex(SLUG_REGEX, 'Usa 3–63 caracteres: letras, números y guiones')
  .refine((s) => !RESERVED_SLUGS.has(s), 'Ese subdominio está reservado')

export const whatsappSchema = z
  .string()
  .regex(/^[1-9][0-9]{7,14}$/, 'Formato internacional sin "+" (ej: 5493855123456)')

export const createTenantSchema = z.object({
  slug: tenantSlugSchema,
  name: z.string().trim().min(2).max(80),
  whatsapp_number: whatsappSchema.nullable().optional(),
})
export type CreateTenantInput = z.infer<typeof createTenantSchema>

/* ─────────────────── Atributos por rubro (products.attributes) ─────────────────── */

const GENDERS = ['men', 'women', 'unisex', 'kids'] as const
const tags = z.array(z.string().trim().min(1).max(30)).max(20).optional()

export const sneakersAttributesSchema = z
  .object({
    size_system: z.enum(['AR', 'US', 'EU', 'UK', 'BR']),
    gender: z.enum(GENDERS),
    brand: z.string().max(80).optional(),
    material: z.string().max(120).optional(),
    tags,
  })
  .strict()

export const apparelAttributesSchema = z
  .object({
    gender: z.enum(GENDERS),
    fit: z.enum(['regular', 'slim', 'oversize', 'relaxed']).optional(),
    composition: z.string().max(200).optional(),
    brand: z.string().max(80).optional(),
    tags,
  })
  .strict()

export const accessoryAttributesSchema = z
  .object({
    gender: z.enum(GENDERS).optional(),
    brand: z.string().max(80).optional(),
    material: z.string().max(120).optional(),
    dimensions_cm: z
      .object({
        width: z.number().positive().optional(),
        height: z.number().positive().optional(),
        depth: z.number().positive().optional(),
      })
      .strict()
      .optional(),
    tags,
  })
  .strict()

export const mixedAttributesSchema = z.record(z.string(), z.unknown())

/* ─────────────────── Opciones de variante (product_variants.options) ─────────────────── */

const color = z.string().trim().min(1).max(40)
export const APPAREL_SIZES = ['XXS', 'XS', 'S', 'M', 'L', 'XL', 'XXL', 'XXXL', 'UNICO'] as const

export const sneakersOptionsSchema = z
  .object({ size: z.number().min(20).max(55).multipleOf(0.5), color }) // talles NUMÉRICOS
  .strict()

export const apparelOptionsSchema = z
  .object({ size: z.enum(APPAREL_SIZES), color }) // talles ALFANUMÉRICOS
  .strict()

export const accessoryOptionsSchema = z
  .object({ size: z.string().max(20).optional(), color: color.optional() })
  .strict()

export const mixedOptionsSchema = z
  .object({ size: z.union([z.string(), z.number()]).optional(), color: z.string().optional() })
  .passthrough()

/* ───────────────────────────── Piezas comunes ───────────────────────────── */

export const productImageSchema = z.object({
  url: z.string().url(),
  alt: z.string().max(200).optional(),
})
export type ProductImage = z.infer<typeof productImageSchema>

export const model3dSchema = z.object({
  url: z.string().url(), // .glb en Storage (solo Premium)
  scale: z.number().positive().default(1),
  auto_rotate: z.boolean().default(true),
})
export type Model3D = z.infer<typeof model3dSchema>

const variantBase = {
  id: z.string().uuid().optional(),
  sku: z.string().trim().min(1).max(64).nullable().optional(),
  stock: z.number().int().min(0),
  price_override: z.number().nonnegative().nullable().optional(),
  is_active: z.boolean().default(true),
}

const productBase = z.object({
  name: z.string().trim().min(2).max(160),
  slug: z.string().regex(/^[a-z0-9]+(-[a-z0-9]+)*$/),
  description: z.string().max(5000).nullable().optional(),
  status: z.enum(PRODUCT_STATUSES).default('draft'),
  price: z.number().nonnegative(),
  compare_at_price: z.number().positive().nullable().optional(),
  category_id: z.string().uuid().nullable().optional(),
  images: z.array(productImageSchema).max(12).default([]),
  model_3d: model3dSchema.nullable().optional(),
  is_featured: z.boolean().default(false),
})

/* ───────────── Discriminated union sobre `product_type` (entrada de formularios) ───────────── */

export const productInputSchema = z.discriminatedUnion('product_type', [
  productBase.extend({
    product_type: z.literal('sneakers'),
    attributes: sneakersAttributesSchema,
    variants: z.array(z.object({ ...variantBase, options: sneakersOptionsSchema })).max(200),
  }),
  productBase.extend({
    product_type: z.literal('apparel'),
    attributes: apparelAttributesSchema,
    variants: z.array(z.object({ ...variantBase, options: apparelOptionsSchema })).max(200),
  }),
  productBase.extend({
    product_type: z.literal('accessory'),
    attributes: accessoryAttributesSchema,
    variants: z.array(z.object({ ...variantBase, options: accessoryOptionsSchema })).max(200),
  }),
  productBase.extend({
    product_type: z.literal('mixed'),
    attributes: mixedAttributesSchema,
    variants: z.array(z.object({ ...variantBase, options: mixedOptionsSchema })).max(200),
  }),
])
export type ProductInput = z.infer<typeof productInputSchema>

/* ───────────── Filas leídas desde la DB (también discriminadas por rubro) ───────────── */

export interface AttributesByType {
  sneakers: z.infer<typeof sneakersAttributesSchema>
  apparel: z.infer<typeof apparelAttributesSchema>
  accessory: z.infer<typeof accessoryAttributesSchema>
  mixed: z.infer<typeof mixedAttributesSchema>
}

export interface VariantOptionsByType {
  sneakers: z.infer<typeof sneakersOptionsSchema>
  apparel: z.infer<typeof apparelOptionsSchema>
  accessory: z.infer<typeof accessoryOptionsSchema>
  mixed: z.infer<typeof mixedOptionsSchema>
}

interface ProductColumns {
  id: string
  tenant_id: string
  category_id: string | null
  slug: string
  name: string
  description: string | null
  status: ProductStatus
  price: number
  compare_at_price: number | null
  images: ProductImage[]
  model_3d: Model3D | null
  is_featured: boolean
  created_at: string
  updated_at: string
}

interface VariantColumns {
  id: string
  tenant_id: string
  product_id: string
  sku: string | null
  stock: number
  price_override: number | null
  is_active: boolean
  position: number
}

export type Product<T extends ProductType = ProductType> = {
  [K in T]: ProductColumns & { product_type: K; attributes: AttributesByType[K] }
}[T]

export type ProductVariant<T extends ProductType = ProductType> = {
  [K in T]: VariantColumns & { options: VariantOptionsByType[K] }
}[T]

export type ProductWithVariants<T extends ProductType = ProductType> = {
  [K in T]: Product<K> & { variants: ProductVariant<K>[] }
}[T]

/** Type guard: `if (isProductOfType(p, 'sneakers')) p.attributes.size_system` */
export function isProductOfType<K extends ProductType>(p: Product, type: K): p is Product<K> {
  return p.product_type === type
}

/* ───────────── Errores de negocio emitidos por los triggers de Postgres ───────────── */

export type PlanErrorCode =
  | 'plan_limit_exceeded:max_products'
  | 'plan_feature_unavailable:3d'
  | 'plan_feature_unavailable:custom_domain'
  | 'tenant_limit_reached'

export function parsePlanError(message: string | undefined): PlanErrorCode | null {
  if (!message) return null
  const m = message.match(/(plan_limit_exceeded:\w+|plan_feature_unavailable:\w+|tenant_limit_reached)/)
  return (m?.[1] as PlanErrorCode | undefined) ?? null
}
