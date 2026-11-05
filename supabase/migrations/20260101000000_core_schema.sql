-- =============================================================================
-- FASE 1 · 01 · CORE MULTITENANT
-- Modelo: base compartida, `tenant_id` real en TODAS las tablas de negocio.
-- Requisito: habilitar pg_jsonschema (Dashboard → Database → Extensions).
-- =============================================================================

create extension if not exists pg_jsonschema with schema extensions;
create extension if not exists pg_trgm       with schema extensions;

-- Schema privado: funciones internas NO expuestas por PostgREST
create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to authenticated, service_role;

-- ----------------------------------------------------------------------------
-- Enums
-- ----------------------------------------------------------------------------
create type public.tenant_status  as enum ('active', 'suspended', 'archived');
create type public.member_role    as enum ('owner', 'admin', 'editor');
create type public.product_type   as enum ('sneakers', 'apparel', 'accessory', 'mixed');
create type public.product_status as enum ('draft', 'active', 'archived');

-- ----------------------------------------------------------------------------
-- Planes (los límites son datos, no código: cambiar un plan = un UPDATE)
-- ----------------------------------------------------------------------------
create table public.plans (
  id                    text primary key,
  name                  text    not null,
  max_products          integer check (max_products is null or max_products > 0), -- null = ilimitado
  allow_3d              boolean not null default false,
  allow_custom_domain   boolean not null default false,
  allow_online_payments boolean not null default false,
  created_at            timestamptz not null default now()
);

insert into public.plans (id, name, max_products, allow_3d, allow_custom_domain, allow_online_payments) values
  ('free',    'Gratis',  50,   false, false, false),
  ('premium', 'Premium', null, true,  true,  true);

-- ----------------------------------------------------------------------------
-- Tenants (cada tienda)
-- ----------------------------------------------------------------------------
create table public.tenants (
  id                        uuid primary key default gen_random_uuid(),
  slug                      text not null unique,
  name                      text not null check (char_length(name) between 2 and 80),
  plan                      text not null default 'free' references public.plans (id),
  status                    public.tenant_status not null default 'active',
  custom_domain             text unique,
  custom_domain_verified_at timestamptz,
  whatsapp_number           text,                       -- solo dígitos, formato internacional sin "+"
  currency                  char(3) not null default 'ARS',
  locale                    text    not null default 'es-AR',
  theme                     jsonb   not null default '{"accent":"purple","glass":true,"logo_url":null}',
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now(),

  constraint tenants_slug_format    check (slug ~ '^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$'),
  -- Mantener sincronizada con RESERVED_SLUGS en lib/tenant/constants.ts
  constraint tenants_slug_reserved  check (slug <> all (array[
    'www','app','api','admin','dashboard','auth','login','signup','static','assets','cdn',
    'mail','smtp','ftp','docs','blog','help','support','status','billing','pricing',
    'sites','demo','test','staging','dev','preview'
  ])),
  constraint tenants_domain_format  check (custom_domain is null or
    custom_domain ~ '^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$'),
  constraint tenants_whatsapp_fmt   check (whatsapp_number is null or whatsapp_number ~ '^[1-9][0-9]{7,14}$'),
  constraint tenants_theme_object   check (jsonb_typeof(theme) = 'object')
);

-- ----------------------------------------------------------------------------
-- Membresías (un usuario puede pertenecer a varias tiendas)
-- ----------------------------------------------------------------------------
create table public.tenant_members (
  tenant_id  uuid not null references public.tenants (id) on delete cascade,
  user_id    uuid not null references auth.users (id)    on delete cascade,
  role       public.member_role not null default 'editor',
  created_at timestamptz not null default now(),
  primary key (tenant_id, user_id)
);
create index tenant_members_user_idx on public.tenant_members (user_id);

-- ----------------------------------------------------------------------------
-- Categorías
-- ----------------------------------------------------------------------------
create table public.categories (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenants (id) on delete cascade,
  name       text not null check (char_length(name) between 1 and 80),
  slug       text not null check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  position   integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint categories_tenant_slug_key  unique (tenant_id, slug),
  constraint categories_tenant_id_id_key unique (tenant_id, id)   -- habilita FK compuesta
);

-- ----------------------------------------------------------------------------
-- Esquemas de atributos por rubro (global, solo lectura para la app)
-- ----------------------------------------------------------------------------
create table public.attribute_schemas (
  product_type   public.product_type primary key,
  label          text    not null,
  version        integer not null default 1,
  json_schema    jsonb   not null,   -- valida products.attributes
  variant_schema jsonb   not null,   -- valida product_variants.options
  ui_schema      jsonb   not null default '{}', -- labels/widgets del form dinámico (Fase 2)
  updated_at     timestamptz not null default now()
);

insert into public.attribute_schemas (product_type, label, json_schema, variant_schema) values
('sneakers', 'Zapatillas',
 $${"type":"object","additionalProperties":false,"required":["size_system","gender"],
    "properties":{
      "size_system":{"enum":["AR","US","EU","UK","BR"]},
      "gender":{"enum":["men","women","unisex","kids"]},
      "brand":{"type":"string","maxLength":80},
      "material":{"type":"string","maxLength":120},
      "tags":{"type":"array","maxItems":20,"items":{"type":"string","minLength":1,"maxLength":30}}}}$$::jsonb,
 $${"type":"object","additionalProperties":false,"required":["size","color"],
    "properties":{
      "size":{"type":"number","minimum":20,"maximum":55,"multipleOf":0.5},
      "color":{"type":"string","minLength":1,"maxLength":40}}}$$::jsonb),

('apparel', 'Ropa',
 $${"type":"object","additionalProperties":false,"required":["gender"],
    "properties":{
      "gender":{"enum":["men","women","unisex","kids"]},
      "fit":{"enum":["regular","slim","oversize","relaxed"]},
      "composition":{"type":"string","maxLength":200},
      "brand":{"type":"string","maxLength":80},
      "tags":{"type":"array","maxItems":20,"items":{"type":"string","minLength":1,"maxLength":30}}}}$$::jsonb,
 $${"type":"object","additionalProperties":false,"required":["size","color"],
    "properties":{
      "size":{"enum":["XXS","XS","S","M","L","XL","XXL","XXXL","UNICO"]},
      "color":{"type":"string","minLength":1,"maxLength":40}}}$$::jsonb),

('accessory', 'Accesorios',
 $${"type":"object","additionalProperties":false,
    "properties":{
      "gender":{"enum":["men","women","unisex","kids"]},
      "brand":{"type":"string","maxLength":80},
      "material":{"type":"string","maxLength":120},
      "dimensions_cm":{"type":"object","additionalProperties":false,
        "properties":{"width":{"type":"number","exclusiveMinimum":0},
                      "height":{"type":"number","exclusiveMinimum":0},
                      "depth":{"type":"number","exclusiveMinimum":0}}},
      "tags":{"type":"array","maxItems":20,"items":{"type":"string","minLength":1,"maxLength":30}}}}$$::jsonb,
 $${"type":"object","additionalProperties":false,
    "properties":{
      "size":{"type":"string","maxLength":20},
      "color":{"type":"string","minLength":1,"maxLength":40}}}$$::jsonb),

('mixed', 'Mixto / Otros',
 $${"type":"object"}$$::jsonb,
 $${"type":"object","properties":{"size":{"type":["string","number"]},"color":{"type":"string"}}}$$::jsonb);

-- ----------------------------------------------------------------------------
-- Productos
-- ----------------------------------------------------------------------------
create table public.products (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenants (id) on delete cascade,
  category_id      uuid,
  slug             text not null check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  name             text not null check (char_length(name) between 2 and 160),
  description      text check (description is null or char_length(description) <= 5000),
  product_type     public.product_type   not null,
  status           public.product_status not null default 'draft',
  price            numeric(12,2) not null check (price >= 0),
  compare_at_price numeric(12,2) check (compare_at_price is null or compare_at_price > price),
  images           jsonb not null default '[]',
  model_3d         jsonb,                                  -- Premium: {url, scale, auto_rotate}
  attributes       jsonb not null default '{}',            -- dinámico por rubro (validado)
  is_featured      boolean not null default false,
  search           tsvector generated always as (
                     setweight(to_tsvector('spanish', coalesce(name, '')),        'A') ||
                     setweight(to_tsvector('spanish', coalesce(description, '')), 'B')
                   ) stored,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),

  constraint products_tenant_slug_key  unique (tenant_id, slug),
  constraint products_tenant_id_id_key unique (tenant_id, id),
  -- La categoría DEBE ser del mismo tenant (integridad cross-tenant a nivel de FK)
  constraint products_category_fk foreign key (tenant_id, category_id)
    references public.categories (tenant_id, id) on delete set null (category_id),
  constraint products_attributes_object check (jsonb_typeof(attributes) = 'object'),
  constraint products_images_array      check (jsonb_typeof(images) = 'array' and jsonb_array_length(images) <= 12),
  constraint products_model3d_object    check (model_3d is null or jsonb_typeof(model_3d) = 'object')
);

create index products_tenant_status_idx   on public.products (tenant_id, status, created_at desc);
create index products_tenant_type_idx     on public.products (tenant_id, product_type);
create index products_tenant_category_idx on public.products (tenant_id, category_id) where category_id is not null;
create index products_featured_idx        on public.products (tenant_id, created_at desc) where status = 'active' and is_featured;
create index products_attributes_gin_idx  on public.products using gin (attributes jsonb_path_ops);
create index products_search_idx          on public.products using gin (search);
create index products_name_trgm_idx       on public.products using gin (name extensions.gin_trgm_ops);

-- ----------------------------------------------------------------------------
-- Variantes (stock real, atómico e indexable)
-- ----------------------------------------------------------------------------
create table public.product_variants (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenants (id) on delete cascade,
  product_id     uuid not null,
  sku            text check (sku is null or char_length(sku) between 1 and 64),
  options        jsonb not null,                             -- {"size":39,"color":"negro"}
  stock          integer not null default 0 check (stock >= 0),
  price_override numeric(12,2) check (price_override is null or price_override >= 0),
  is_active      boolean not null default true,
  position       integer not null default 0,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),

  constraint variants_product_fk foreign key (tenant_id, product_id)
    references public.products (tenant_id, id) on delete cascade,
  constraint variants_options_object check (jsonb_typeof(options) = 'object')
);

create unique index variants_tenant_sku_key     on public.product_variants (tenant_id, sku) where sku is not null;
create unique index variants_product_options_key on public.product_variants (product_id, options);  -- sin combinaciones duplicadas
create index variants_product_idx               on public.product_variants (product_id);
create index variants_options_gin_idx           on public.product_variants using gin (options jsonb_path_ops);

-- =============================================================================
-- TRIGGERS Y FUNCIONES DE INTEGRIDAD
-- =============================================================================

create or replace function private.set_updated_at()
returns trigger language plpgsql set search_path = '' as $$
begin new.updated_at = now(); return new; end $$;

create or replace function private.prevent_tenant_id_change()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.tenant_id is distinct from old.tenant_id then
    raise exception 'tenant_id is immutable' using errcode = '42501';
  end if;
  return new;
end $$;

-- Valida products.attributes contra attribute_schemas (JSON Schema)
create or replace function private.validate_product()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_schema json;
begin
  if tg_op = 'UPDATE' and new.product_type <> old.product_type then
    raise exception 'product_type is immutable' using errcode = '23514';
  end if;

  select s.json_schema::json into v_schema
  from public.attribute_schemas s where s.product_type = new.product_type;

  if not extensions.jsonb_matches_schema(v_schema, new.attributes) then
    raise exception 'Invalid attributes for product_type "%"', new.product_type
      using errcode = '23514', hint = 'See attribute_schemas.json_schema';
  end if;
  return new;
end $$;

-- Valida product_variants.options según el rubro del producto padre
create or replace function private.validate_variant()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_schema json;
begin
  select s.variant_schema::json into v_schema
  from public.products p
  join public.attribute_schemas s on s.product_type = p.product_type
  where p.id = new.product_id and p.tenant_id = new.tenant_id;

  if v_schema is null then
    raise exception 'Parent product not found' using errcode = '23503';
  end if;
  if not extensions.jsonb_matches_schema(v_schema, new.options) then
    raise exception 'Invalid variant options for this product_type'
      using errcode = '23514', hint = 'See attribute_schemas.variant_schema';
  end if;
  return new;
end $$;

-- Límites freemium (se aplican aunque se use service_role)
create or replace function private.enforce_product_plan_limits()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_plan public.plans; v_count integer;
begin
  select p.* into v_plan
  from public.plans p join public.tenants t on t.plan = p.id
  where t.id = new.tenant_id;

  if tg_op = 'INSERT' and v_plan.max_products is not null then
    -- Serializa inserciones concurrentes del mismo tenant (evita pasarse del límite)
    perform pg_advisory_xact_lock(hashtextextended(new.tenant_id::text, 0));
    select count(*) into v_count from public.products
    where tenant_id = new.tenant_id and status <> 'archived';
    if v_count >= v_plan.max_products then
      raise exception 'plan_limit_exceeded:max_products' using errcode = 'P0001';
    end if;
  end if;

  if new.model_3d is not null
     and (tg_op = 'INSERT' or new.model_3d is distinct from old.model_3d)
     and not v_plan.allow_3d then
    raise exception 'plan_feature_unavailable:3d' using errcode = 'P0001';
  end if;
  return new;
end $$;

create or replace function private.enforce_tenant_features()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.custom_domain is not null
     and (tg_op = 'INSERT' or new.custom_domain is distinct from old.custom_domain)
     and not (select allow_custom_domain from public.plans where id = new.plan) then
    raise exception 'plan_feature_unavailable:custom_domain' using errcode = 'P0001';
  end if;
  return new;
end $$;

-- Un tenant nunca queda sin owner
create or replace function private.protect_last_owner()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if old.role = 'owner'
     and (tg_op = 'DELETE' or new.role <> 'owner')
     and exists (select 1 from public.tenants t where t.id = old.tenant_id)
     and not exists (select 1 from public.tenant_members m
                     where m.tenant_id = old.tenant_id and m.role = 'owner' and m.user_id <> old.user_id)
  then
    raise exception 'A tenant must keep at least one owner' using errcode = '23514';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;

-- Triggers --------------------------------------------------------------------
create trigger tenants_updated_at    before update on public.tenants          for each row execute function private.set_updated_at();
create trigger categories_updated_at before update on public.categories       for each row execute function private.set_updated_at();
create trigger products_updated_at   before update on public.products        for each row execute function private.set_updated_at();
create trigger variants_updated_at   before update on public.product_variants for each row execute function private.set_updated_at();

create trigger categories_tenant_immutable before update on public.categories       for each row execute function private.prevent_tenant_id_change();
create trigger products_tenant_immutable   before update on public.products         for each row execute function private.prevent_tenant_id_change();
create trigger variants_tenant_immutable   before update on public.product_variants for each row execute function private.prevent_tenant_id_change();
create trigger members_tenant_immutable    before update on public.tenant_members   for each row execute function private.prevent_tenant_id_change();

create trigger products_validate  before insert or update of attributes, product_type on public.products
  for each row execute function private.validate_product();
create trigger products_plan_limits before insert or update of model_3d on public.products
  for each row execute function private.enforce_product_plan_limits();
create trigger variants_validate  before insert or update of options on public.product_variants
  for each row execute function private.validate_variant();
create trigger tenants_features   before insert or update of custom_domain on public.tenants
  for each row execute function private.enforce_tenant_features();
create trigger members_last_owner before update of role or delete on public.tenant_members
  for each row execute function private.protect_last_owner();

-- ----------------------------------------------------------------------------
-- Alta de tienda atómica (tenant + owner). Único camino de INSERT en tenants.
-- ----------------------------------------------------------------------------
create or replace function public.create_tenant(p_slug text, p_name text, p_whatsapp text default null)
returns public.tenants
language plpgsql security definer set search_path = '' as $$
declare
  v_uid    uuid := (select auth.uid());
  v_tenant public.tenants;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;

  if (select count(*) from public.tenant_members where user_id = v_uid and role = 'owner') >= 3 then
    raise exception 'tenant_limit_reached' using errcode = 'P0001';  -- anti-abuso del tier gratuito
  end if;

  insert into public.tenants (slug, name, whatsapp_number)
  values (lower(p_slug), p_name, p_whatsapp)
  returning * into v_tenant;

  insert into public.tenant_members (tenant_id, user_id, role)
  values (v_tenant.id, v_uid, 'owner');

  return v_tenant;
end $$;

revoke all on function public.create_tenant(text, text, text) from public, anon;
grant execute on function public.create_tenant(text, text, text) to authenticated;
