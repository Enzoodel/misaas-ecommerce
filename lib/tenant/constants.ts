// Sin dependencias pesadas: este archivo se importa desde el middleware (Edge).

export const ROOT_DOMAIN = (process.env.NEXT_PUBLIC_ROOT_DOMAIN ?? 'localhost:3000').toLowerCase()
export const ROOT_HOST = ROOT_DOMAIN.split(':')[0]

/** Subdominio del panel de administración: app.misaas.com */
export const APP_SUBDOMAIN = 'app'

/**
 * Header interno que SOLO el middleware puede setear. `app/[domain]/layout.tsx`
 * debe llamar notFound() si falta → evita que `misaas.com/tienda` renderice una tienda.
 */
export const REWRITE_HEADER = 'x-tenant-rewrite'

export const SLUG_REGEX = /^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$/

// Mantener sincronizada con el CHECK `tenants_slug_reserved` del SQL.
export const RESERVED_SLUGS: ReadonlySet<string> = new Set([
  'www', 'app', 'api', 'admin', 'dashboard', 'auth', 'login', 'signup', 'static', 'assets', 'cdn',
  'mail', 'smtp', 'ftp', 'docs', 'blog', 'help', 'support', 'status', 'billing', 'pricing',
  'sites', 'demo', 'test', 'staging', 'dev', 'preview',
])
