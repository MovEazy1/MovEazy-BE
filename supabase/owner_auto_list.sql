-- ─────────────────────────────────────────────────────────────────────────────
-- Owner flats go live on MovEazy by themselves.
--
-- Run in the Supabase SQL editor AFTER owner_schema.sql and owner_buildings.sql.
-- Safe to re-run.
--
--   inventory.list_when_ready   the owner wants the flat live. A vacant
--                               ('paused') flat with this on goes 'published'
--                               the moment it has a photo — straight away if it
--                               already has one — and the flag clears itself.
--                               Any hand-made status change (listed by hand,
--                               marked occupied) clears it too.
--
--   owner_list_when_ready(p, on)   the owner app's "List on MovEazy" switch,
--                                  on by default when a flat is added.
--   owner_waiting_to_list()        the owner's flats waiting for a photo.
--
-- The first run also turns it on for every vacant owner flat that isn't live:
-- those with a photo go live at once, the rest as soon as they get one.
-- ─────────────────────────────────────────────────────────────────────────────

begin;

-- Same test as fe/src/lib/listingMedia.js isVideoUrl.
create or replace function public.listing_url_is_video(u text)
returns boolean
language sql
immutable
as $$
  select case
    when coalesce(u, '') = '' then false
    when u ~* '\.(jpe?g|png|webp|gif|avif|heic|heif|bmp|svg)([?#]|$)' then false
    when u ~* '\.(mp4|m4v|webm|ogv|ogg|mov|qt|3gp)([?#]|$)' then true
    else u ~* '/videos?/'
  end;
$$;

create or replace function public.listing_has_photo(p_images text[], p_cover text)
returns boolean
language sql
immutable
as $$
  select exists (
    select 1 from unnest(coalesce(p_images, '{}'::text[]) || array[coalesce(p_cover, '')]) u
    where coalesce(u, '') <> '' and not public.listing_url_is_video(u)
  );
$$;

-- Added (and the old flats switched on) once, on the first run only.
create temp table _owner_auto_list_first on commit drop as
  select not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'inventory' and column_name = 'list_when_ready'
  ) as first;

alter table public.inventory add column if not exists list_when_ready boolean not null default false;

create or replace function public.inventory_list_when_ready()
returns trigger
language plpgsql
as $$
begin
  if not new.list_when_ready then
    return new;
  end if;
  if new.status = 'paused' and public.listing_has_photo(new.images, new.cover_image_url) then
    new.status := 'published';
    new.list_when_ready := false;
  elsif new.status is distinct from 'paused'
     or (tg_op = 'UPDATE' and new.status is distinct from old.status) then
    -- Somebody set the status by hand: that is the decision now.
    new.list_when_ready := false;
  end if;
  return new;
end;
$$;

revoke all on function public.inventory_list_when_ready() from public, anon, authenticated;

drop trigger if exists inventory_list_when_ready on public.inventory;
create trigger inventory_list_when_ready
  before insert or update of images, cover_image_url, status, list_when_ready on public.inventory
  for each row execute function public.inventory_list_when_ready();

/** The owner app's "List on MovEazy" switch. Returns the flat's status after it. */
create or replace function public.owner_list_when_ready(p_property text, p_on boolean)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  st text;
begin
  if not (public.is_approved_owner() and public.owner_has_property(p_property)) then
    raise exception 'That is not one of your properties.' using errcode = '42501';
  end if;
  update public.inventory i
     set list_when_ready = coalesce(p_on, false) and i.status = 'paused',
         updated_at = now()
   where i.property_id = p_property
  returning i.status into st;
  return st;
end;
$$;

/** The owner's flats that go live once they have a photo. */
create or replace function public.owner_waiting_to_list()
returns setof text
language sql
stable
security definer
set search_path = public
as $$
  select i.property_id
    from public.inventory i
    join public.owner_property_links l on l.property_id = i.property_id
   where l.owner_id = auth.uid() and i.list_when_ready and public.is_approved_owner();
$$;

revoke all on function public.owner_list_when_ready(text, boolean) from public, anon;
revoke all on function public.owner_waiting_to_list() from public, anon;
grant execute on function public.owner_list_when_ready(text, boolean) to authenticated;
grant execute on function public.owner_waiting_to_list() to authenticated;

-- Every vacant owner flat not yet live: live now if it has a photo, else on its first.
update public.inventory i
   set list_when_ready = true
 where (select first from _owner_auto_list_first)
   and i.status = 'paused'
   and exists (select 1 from public.owner_property_links l where l.property_id = i.property_id)
   and not exists (
     select 1 from public.tenants t
      where t.property_id = i.property_id and t.status in ('active', 'invited')
   );

commit;
