import { NextResponse, type NextRequest } from 'next/server'
import { updateSession } from '@/lib/supabase/middleware'
import {
  APP_SUBDOMAIN,
  REWRITE_HEADER,
  RESERVED_SLUGS,
  ROOT_DOMAIN,
  ROOT_HOST,
  SLUG_REGEX,
} from '@/lib/tenant/constants'

/**
 * Enrutamiento por host (cero consultas a DB en el edge → escala a miles de tiendas):
 *
 *   misaas.com / www.misaas.com   → marketing (sin rewrite)
 *   app.misaas.com                → /dashboard/*   (panel, con sesión Supabase)
 *   tienda.misaas.com             → /tienda/*      (app/[domain], slug)
 *   www.mitienda.com (Premium)    → /www.mitienda.com/*  (app/[domain], host completo)
 *
 * La resolución slug|host → tenant ocurre en app/[domain] (con caché por tenant).
 * Distinción: un slug nunca contiene "." y un dominio propio siempre.
 *
 * ⚠️ app/[domain]/layout.tsx DEBE incluir:
 *      if (!headers().get(REWRITE_HEADER)) notFound()
 *    para que `misaas.com/tienda` no pueda renderizar una tienda sin pasar por aquí.
 */

export const config = {
  matcher: ['/((?!api/|_next/|_static/|_vercel/|.*\\..*).*)'],
}

type Target =
  | { kind: 'marketing' }
  | { kind: 'app' }
  | { kind: 'tenant'; domain: string }
  | { kind: 'invalid' }

function resolveTarget(rawHost: string | null): Target {
  const host = (rawHost ?? '').toLowerCase().split(':')[0]
  if (!host) return { kind: 'invalid' }

  if (host === ROOT_HOST || host === `www.${ROOT_HOST}`) return { kind: 'marketing' }
  if (host === `${APP_SUBDOMAIN}.${ROOT_HOST}`) return { kind: 'app' }
  if (host.endsWith('.vercel.app')) return { kind: 'marketing' } // previews de Vercel

  if (host.endsWith(`.${ROOT_HOST}`)) {
    const sub = host.slice(0, -(ROOT_HOST.length + 1))
    if (SLUG_REGEX.test(sub) && !RESERVED_SLUGS.has(sub)) return { kind: 'tenant', domain: sub }
    return { kind: 'invalid' }
  }

  // Cualquier otro host se trata como dominio propio (se valida contra la DB en la página)
  return { kind: 'tenant', domain: host }
}

const PUBLIC_APP_PATHS = ['/login', '/signup', '/auth']

async function handleApp(req: NextRequest, headers: Headers) {
  const { pathname } = req.nextUrl
  const isPublic = PUBLIC_APP_PATHS.some((p) => pathname === p || pathname.startsWith(`${p}/`))

  const rewriteUrl = req.nextUrl.clone()
  rewriteUrl.pathname = `/dashboard${pathname === '/' ? '' : pathname}`

  const { response, user } = await updateSession(req, headers, rewriteUrl)

  if (!user && !isPublic) {
    const login = req.nextUrl.clone()
    login.pathname = '/login'
    login.search = ''
    const redirect = NextResponse.redirect(login)
    response.cookies.getAll().forEach((c) => redirect.cookies.set(c)) // conserva cookies refrescadas
    return redirect
  }

  if (user && (pathname === '/login' || pathname === '/signup')) {
    const home = req.nextUrl.clone()
    home.pathname = '/'
    home.search = ''
    return NextResponse.redirect(home)
  }

  return response
}

export async function middleware(req: NextRequest) {
  const { pathname } = req.nextUrl
  const target = resolveTarget(req.headers.get('host'))

  // Anti-spoofing: ningún cliente puede inyectar el header interno
  const headers = new Headers(req.headers)
  headers.delete(REWRITE_HEADER)

  switch (target.kind) {
    case 'invalid':
      return new NextResponse('Not found', { status: 404 })

    case 'marketing':
      if (pathname === '/dashboard' || pathname.startsWith('/dashboard/')) {
        const appOrigin = `${req.nextUrl.protocol}//${APP_SUBDOMAIN}.${ROOT_DOMAIN}`
        return NextResponse.redirect(new URL(pathname.replace(/^\/dashboard/, '') || '/', appOrigin))
      }
      return NextResponse.next({ request: { headers } })

    case 'app':
      return handleApp(req, headers)

    case 'tenant': {
      const url = req.nextUrl.clone()
      url.pathname = `/${encodeURIComponent(target.domain)}${pathname === '/' ? '' : pathname}`
      headers.set(REWRITE_HEADER, '1')
      return NextResponse.rewrite(url, { request: { headers } })
    }
  }
}
