import { createServerClient } from '@supabase/ssr'
import { NextResponse, type NextRequest } from 'next/server'

/**
 * Refresca la sesión de Supabase y devuelve la respuesta (next o rewrite) con las
 * cookies actualizadas. Solo se invoca en el host del panel (app.*): las tiendas
 * públicas NO pagan latencia de auth, y las cookies son host-only, así que el JS
 * de un storefront jamás tiene acceso a la sesión del administrador.
 */
export async function updateSession(
  request: NextRequest,
  requestHeaders: Headers,
  rewriteTo?: URL,
) {
  const build = () =>
    rewriteTo
      ? NextResponse.rewrite(rewriteTo, { request: { headers: requestHeaders } })
      : NextResponse.next({ request: { headers: requestHeaders } })

  let response = build()

  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll: () => request.cookies.getAll(),
        setAll(cookiesToSet) {
          cookiesToSet.forEach(({ name, value }) => request.cookies.set(name, value))
          requestHeaders.set('cookie', request.cookies.toString())
          response = build()
          cookiesToSet.forEach(({ name, value, options }) =>
            response.cookies.set(name, value, options),
          )
        },
      },
    },
  )

  // getUser() valida el JWT contra Supabase Auth (no confiar en getSession() en servidor)
  const {
    data: { user },
  } = await supabase.auth.getUser()

  return { response, user }
}
