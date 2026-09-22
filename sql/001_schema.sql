-- Quincena / Supabase PostgreSQL. Ejecutar completo una vez en SQL Editor.
-- Migración idempotente. No incluye datos personales ni credenciales.
begin;
create schema if not exists quincena_private;
revoke all on schema quincena_private from public, anon;
grant usage on schema quincena_private to authenticated;
create table if not exists public.households (
 id uuid primary key default gen_random_uuid(),
 name text not null check(length(name) between 1 and 100),
 owner_id uuid not null references auth.users(id),
 created_at timestamptz not null default now()
);
create table if not exists public.household_members (
 household_id uuid not null references public.households(id) on delete cascade,
 user_id uuid not null references auth.users(id) on delete cascade,
 role text not null check(role in ('owner','member')),
 created_at timestamptz not null default now(),
 primary key(household_id,user_id),unique(user_id)
);
create table if not exists public.household_invites (
 household_id uuid primary key references public.households(id) on delete cascade,
 email text not null check(email=lower(email) and length(email)<255),
 created_at timestamptz not null default now()
);
create table if not exists public.household_state (
 household_id uuid primary key references public.households(id) on delete cascade,
 data jsonb not null default '{}'::jsonb,
 revision bigint not null default 0,
 updated_by uuid references auth.users(id),
 updated_at timestamptz not null default now(),
 check(jsonb_typeof(data)='object' and octet_length(data::text)<5000000)
);
create table if not exists public.household_audit (
 id bigint generated always as identity primary key,
 household_id uuid not null references public.households(id) on delete cascade,
 user_id uuid references auth.users(id),
 revision bigint not null,
 created_at timestamptz not null default now(),
 summary text not null
);
create index if not exists audit_household_date on public.household_audit(household_id,created_at desc);
create or replace function quincena_private.is_household_member(h uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.household_members where household_id=h and user_id=auth.uid());
$$;
create or replace function public.is_household_member(h uuid) returns boolean
language sql stable security invoker set search_path='' as $$ select quincena_private.is_household_member(h); $$;
alter table public.households enable row level security;
alter table public.household_members enable row level security;
alter table public.household_invites enable row level security;
alter table public.household_state enable row level security;
alter table public.household_audit enable row level security;
drop policy if exists household_read on public.households;
create policy household_read on public.households for select to authenticated using(public.is_household_member(id));
drop policy if exists members_read on public.household_members;
create policy members_read on public.household_members for select to authenticated using(public.is_household_member(household_id));
drop policy if exists invites_read on public.household_invites;
create policy invites_read on public.household_invites for select to authenticated using(exists(select 1 from public.households h where h.id=household_id and h.owner_id=auth.uid()));
drop policy if exists state_read on public.household_state;
create policy state_read on public.household_state for select to authenticated using(public.is_household_member(household_id));
drop policy if exists audit_read on public.household_audit;
create policy audit_read on public.household_audit for select to authenticated using(public.is_household_member(household_id));
-- Writes only through the checked RPCs. RLS also applies to Realtime reads.
revoke all on public.households,public.household_members,public.household_invites,public.household_state,public.household_audit from anon,authenticated;
grant select on public.households,public.household_members,public.household_invites,public.household_state,public.household_audit to authenticated;
create or replace function quincena_private.create_household(p_name text) returns uuid
language plpgsql security definer set search_path='' as $$
declare h uuid; u uuid:=auth.uid();
begin
 if u is null then raise exception 'AUTH_REQUIRED'; end if;
 perform pg_advisory_xact_lock(hashtextextended(u::text,0));
 if exists(select 1 from public.household_members where user_id=u) then raise exception 'ALREADY_MEMBER'; end if;
 insert into public.households(name,owner_id) values(trim(p_name),u) returning id into h;
 insert into public.household_members values(h,u,'owner',now());
 insert into public.household_state(household_id,updated_by) values(h,u);
 return h;
end;$$;
create or replace function quincena_private.set_household_invite(p_household uuid,p_email text) returns void
language plpgsql security definer set search_path='' as $$
declare owner_user uuid;
begin
 select owner_id into owner_user from public.households where id=p_household for update;
 if owner_user is distinct from auth.uid() or auth.uid() is null then raise exception 'FORBIDDEN'; end if;
 if (select count(*) from public.household_members where household_id=p_household)>=2 then raise exception 'HOUSEHOLD_FULL'; end if;
 if trim(p_email) not like '%_@_%._%' then raise exception 'INVALID_EMAIL'; end if;
 if lower(trim(p_email))=(select lower(email) from auth.users where id=auth.uid()) then raise exception 'SELF_INVITE'; end if;
 insert into public.household_invites(household_id,email) values(p_household,lower(trim(p_email))) on conflict(household_id) do update set email=excluded.email,created_at=now();
end;$$;
create or replace function quincena_private.accept_household_invite() returns uuid
language plpgsql security definer set search_path='' as $$
declare h uuid; address text; u uuid:=auth.uid();
begin
 if u is null then raise exception 'AUTH_REQUIRED'; end if;
 perform pg_advisory_xact_lock(hashtextextended(u::text,0));
 select household_id into h from public.household_members where user_id=u;
 if h is not null then return h; end if;
 select lower(email) into address from auth.users where id=u and email_confirmed_at is not null;
 if address is null then raise exception 'VERIFY_EMAIL'; end if;
 select household_id into h from public.household_invites where email=address order by created_at limit 1;
 if h is null then return null; end if;
 perform 1 from public.households where id=h for update;
 -- Recheck invite after obtaining lock, to avoid accepting a revoked or replaced invite.
 if not exists(select 1 from public.household_invites where household_id=h and email=address) then return null; end if;
 if (select count(*) from public.household_members where household_id=h)>=2 then raise exception 'HOUSEHOLD_FULL'; end if;
 insert into public.household_members values(h,u,'member',now());
 delete from public.household_invites where household_id=h;
 return h;
end;$$;
create or replace function quincena_private.save_household_state(p_household uuid,p_expected_revision bigint,p_data jsonb)
returns setof public.household_state
language plpgsql security definer set search_path='' as $$
declare current_revision bigint;
begin
 if not public.is_household_member(p_household) then raise exception 'FORBIDDEN'; end if;
 if jsonb_typeof(p_data) is distinct from 'object' or octet_length(p_data::text)>4900000
 or jsonb_typeof(p_data->'expenses') is distinct from 'array'
 or jsonb_typeof(p_data->'products') is distinct from 'array'
 or jsonb_typeof(p_data->'list') is distinct from 'array'
 or jsonb_typeof(p_data->'paid') is distinct from 'object'
 or jsonb_typeof(p_data->'income') is distinct from 'number'
 then raise exception 'INVALID_STATE'; end if;
 select revision into current_revision from public.household_state where household_id=p_household for update;
 if current_revision is distinct from p_expected_revision then raise exception 'REVISION_CONFLICT'; end if;
 update public.household_state set data=p_data,revision=revision+1,updated_by=auth.uid(),updated_at=now() where household_id=p_household;
 insert into public.household_audit(household_id,user_id,revision,summary) values(p_household,auth.uid(),current_revision+1,'Actualización del hogar');
 return query select * from public.household_state where household_id=p_household;
end;$$;
create or replace function public.create_household(p_name text) returns uuid
language sql security invoker set search_path='' as $$ select quincena_private.create_household(p_name); $$;
create or replace function public.set_household_invite(p_household uuid,p_email text) returns void
language sql security invoker set search_path='' as $$ select quincena_private.set_household_invite(p_household,p_email); $$;
create or replace function public.accept_household_invite() returns uuid
language sql security invoker set search_path='' as $$ select quincena_private.accept_household_invite(); $$;
create or replace function public.save_household_state(p_household uuid,p_expected_revision bigint,p_data jsonb) returns setof public.household_state
language sql security invoker set search_path='' as $$ select * from quincena_private.save_household_state(p_household,p_expected_revision,p_data); $$;
revoke all on function public.is_household_member(uuid),public.create_household(text),public.set_household_invite(uuid,text),public.accept_household_invite(),public.save_household_state(uuid,bigint,jsonb) from public,anon;
grant execute on function public.is_household_member(uuid),public.create_household(text),public.set_household_invite(uuid,text),public.accept_household_invite(),public.save_household_state(uuid,bigint,jsonb) to authenticated;
revoke execute on all functions in schema quincena_private from public,anon;
grant execute on all functions in schema quincena_private to authenticated;
do $$begin
 if exists(select 1 from pg_publication where pubname='supabase_realtime') and not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='household_state') then
 alter publication supabase_realtime add table public.household_state;
 end if;
end$$;
commit;
