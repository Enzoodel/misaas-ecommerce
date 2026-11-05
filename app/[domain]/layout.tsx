import { headers } from 'next/headers'
import { notFound } from 'next/navigation'
import { REWRITE_HEADER } from '@/lib/tenant/constants'

// Solo el middleware setea este header: bloquea el acceso directo a /[domain] desde el dominio raíz.
export default function TenantLayout({ children }: { children: React.ReactNode }) {
  if (!headers().get(REWRITE_HEADER)) notFound()
  return <>{children}</>
}
