-- MovEazy flats partners never see by default: they came to MovEazy through
-- another broker, so there's no brokerage to share.
--
--   · Added through the CRM (source 'crm', or a post imported from a link:
--     'facebook' / 'whatsapp' / 'portal' / 'other'): the CRM form's "Show to
--     MovEazy partners" box starts unticked (CrmPropertyForm.jsx) and is
--     always sent, so the CRM decides flat by flat.
--   · Posted anywhere else by an account in partner_hidden_posters
--     (yatharth200018@gmail.com, amansolanki262@gmail.com to start): starts
--     hidden (partner_visible false). The CRM can tick it on later.
--   · The first run hides every such flat already on MovEazy. Partner
--     brokers' own listings (partner_listings) are untouched, and lists
--     already sent to tenants stay as they are. Re-running never hides a flat
--     the CRM has since ticked on.
--
-- Run after partner_schema.sql (inventory.partner_visible). Safe to re-run.

begin;

create temp table _hidden_first on commit drop as
  select to_regclass('public.partner_hidden_posters') is null as first;

create table if not exists public.partner_hidden_posters (
  email    text primary key check (email = lower(btrim(email)) and email like '%@%'),
  note     text not null default '',
  added_at timestamptz not null default now()
);
alter table public.partner_hidden_posters enable row level security;
revoke all on public.partner_hidden_posters from anon, authenticated;
insert into public.partner_hidden_posters (email, note) values
  ('yatharth200018@gmail.com', 'Flats from other brokers: no brokerage to share'),
  ('amansolanki262@gmail.com', 'Flats from other brokers: no brokerage to share')
on conflict (email) do nothing;

/** Added through the CRM: by hand, or imported from a post's link. */
create or replace function public.inventory_from_crm(p_source text)
returns boolean
language sql
immutable
as $$
  select coalesce(p_source, '') in ('crm', 'facebook', 'whatsapp', 'portal', 'other');
$$;

/** Posted by an account whose flats partners don't see. */
create or replace function public.inventory_hidden_poster(p_poster uuid, p_email text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.partner_hidden_posters h
     where h.email = lower(btrim(coalesce(p_email, '')))
        or h.email = (select lower(u.email) from auth.users u where u.id = p_poster));
$$;
revoke all on function public.inventory_hidden_poster(uuid, text) from public, anon, authenticated;

-- A new flat from one of those accounts, posted outside the CRM, starts hidden from partners.
create or replace function public.inventory_partner_hidden_default()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.inventory_from_crm(new.source) and public.inventory_hidden_poster(new.poster_id, new.poster_email) then
    new.partner_visible := false;
  end if;
  return new;
end;
$$;
revoke all on function public.inventory_partner_hidden_default() from public, anon, authenticated;
drop trigger if exists inventory_partner_hidden_default on public.inventory;
create trigger inventory_partner_hidden_default before insert on public.inventory
  for each row execute function public.inventory_partner_hidden_default();

-- Once: every CRM flat and every flat from those accounts already on MovEazy.
update public.inventory i
   set partner_visible = false
 where (select first from _hidden_first)
   and i.partner_visible
   and not exists (select 1 from public.partner_listings pl where pl.property_id = i.property_id)
   and (public.inventory_from_crm(i.source) or public.inventory_hidden_poster(i.poster_id, i.poster_email));

commit;
