-- =============================================================================
-- FASE 1 · 02 · RLS ESTRICTO + GRANTS MÍNIMOS
-- Principio: deny-by-default. El aislamiento depende SOLO de tenant_id (columna
-- real) + tenant_members. Nada dentro de JSONB participa en seguridad.
-- =============================================================================

-- ----------------------------------------------------------------------------
-- Helper de rendimiento: tenants del usuario como array.
-- Se invoca como `(select private.user_tenant_ids())` → Postgres lo evalúa UNA
-- vez por consulta (InitPlan) en vez de una vez por fila.
-- ----------------------------------------------------------------------------
create or replace function private.user_tenant_ids(p_roles public.member_role[] default null)
returns uuid[]
language sql stable security definer set search_path = ''
as $$
  select coalesce(array_agg(m.tenant_id), '{}'::uuid[])
  from public.tenant_members m
  where m.user_id = (select auth.uid())
    and (p_roles is null or m.role = any (p_roles));
$$;

revoke execute on function private.user_tenant_ids(public.member_role[]) from public;
grant  execute on function private.user_tenant_ids(public.member_role[]) to authenticated, service_role;

-- ----------------------------------------------------------------------------
-- Grants: partimos de cero (Supabase otorga todo por defecto) y damos lo mínimo
-- ----------------------------------------------------------------------------
revoke all on all tables in schema public from anon, authenticated;
alter default privileges in schema public revoke all on tables from anon, authenticated;

grant select on public.plans, public.attribute_schemas, public.tenants,
                public.categories, public.products, public.product_variants
  to anon, authenticated;

grant insert, update, delete on public.categories, public.products, public.product_variants
  to authenticated;

grant select, insert, update, delete on public.tenant_members to authenticated;

-- Seguridad crítica: un admin NUNCA puede tocar `plan`, `status` ni `custom_domain`.
-- Esas columnas solo las cambia service_role (webhooks de billing) o RPCs dedicadas.
grant update (name, whatsapp_number, currency, locale, theme) on public.tenants to authenticated;

-- ----------------------------------------------------------------------------
-- Activar RLS
-- ----------------------------------------------------------------------------
alter table public.plans             enable row level security;
alter table public.attribute_schemas enable row level security;
alter table public.tenants           enable row level security;
alter table public.tenant_members    enable row level security;
alter table public.categories        enable row level security;
alter table public.products          enable row level security;
alter table public.product_variants  enable row level security;

-- ----------------------------------------------------------------------------
-- Catálogos globales (solo lectura)
-- ----------------------------------------------------------------------------
create policy plans_read             on public.plans             for select to anon, authenticated using (true);
create policy attribute_schemas_read on public.attribute_schemas for select to anon, authenticated using (true);

-- ----------------------------------------------------------------------------
-- tenants
-- ----------------------------------------------------------------------------
create policy tenants_public_read on public.tenants for select to anon, authenticated
  using (status = 'active');

create policy tenants_member_read on public.tenants for select to authenticated
  using (id = any ((select private.user_tenant_ids())));

create policy tenants_admin_update on public.tenants for update to authenticated
  using      (id = any ((select private.user_tenant_ids(array['owner','admin']::public.member_role[]))))
  with check (id = any ((select private.user_tenant_ids(array['owner','admin']::public.member_role[]))));
-- INSERT/DELETE: sin política → solo vía create_tenant() / service_role

-- ----------------------------------------------------------------------------
-- tenant_members (solo owners gestionan el equipo)
-- ----------------------------------------------------------------------------
create policy members_read on public.tenant_members for select to authenticated
  using (tenant_id = any ((select private.user_tenant_ids())));

create policy members_owner_write on public.tenant_members for all to authenticated
  using      (tenant_id = any ((select private.user_tenant_ids(array['owner']::public.member_role[]))))
  with check (tenant_id = any ((select private.user_tenant_ids(array['owner']::public.member_role[]))));

-- ----------------------------------------------------------------------------
-- categories
-- ----------------------------------------------------------------------------
create policy categories_public_read on public.categories for select to anon, authenticated
  using (exists (select 1 from public.tenants t where t.id = categories.tenant_id and t.status = 'active'));

create policy categories_member_all on public.categories for all to authenticated
  using      (tenant_id = any ((select private.user_tenant_ids())))
  with check (tenant_id = any ((select private.user_tenant_ids())));

-- ----------------------------------------------------------------------------
-- products (público: solo activos de tiendas activas; miembros: todo lo suyo)
-- ----------------------------------------------------------------------------
create policy products_public_read on public.products for select to anon, authenticated
  using (
    status = 'active'
    and exists (select 1 from public.tenants t where t.id = products.tenant_id and t.status = 'active')
  );

create policy products_member_all on public.products for all to authenticated
  using      (tenant_id = any ((select private.user_tenant_ids())))
  with check (tenant_id = any ((select private.user_tenant_ids())));

-- ----------------------------------------------------------------------------
-- product_variants (hereda la visibilidad del producto padre vía su propia RLS)
-- ----------------------------------------------------------------------------
create policy variants_public_read on public.product_variants for select to anon, authenticated
  using (
    is_active
    and exists (select 1 from public.products p where p.id = product_variants.product_id)
  );

create policy variants_member_all on public.product_variants for all to authenticated
  using      (tenant_id = any ((select private.user_tenant_ids())))
  with check (tenant_id = any ((select private.user_tenant_ids())));

-- ----------------------------------------------------------------------------
-- Storage: bucket público de lectura; escritura solo en la carpeta {tenant_id}/…
-- ----------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('product-media', 'product-media', true, 15728640,
        array['image/jpeg','image/png','image/webp','image/avif','model/gltf-binary'])
on conflict (id) do nothing;

create policy product_media_insert on storage.objects for insert to authenticated
  with check (
    bucket_id = 'product-media'
    and (storage.foldername(name))[1] in
        (select m.tenant_id::text from public.tenant_members m where m.user_id = (select auth.uid()))
  );

create policy product_media_update on storage.objects for update to authenticated
  using (
    bucket_id = 'product-media'
    and (storage.foldername(name))[1] in
        (select m.tenant_id::text from public.tenant_members m where m.user_id = (select auth.uid()))
  );

create policy product_media_delete on storage.objects for delete to authenticated
  using (
    bucket_id = 'product-media'
    and (storage.foldername(name))[1] in
        (select m.tenant_id::text from public.tenant_members m where m.user_id = (select auth.uid()))
  );
