-- ─────────────────────────────────────────────────────────────────────────────
-- A booked visit lands in the CRM automatically.
--
-- Run once in the Supabase SQL editor, after crm_schema.sql. Idempotent.
--
-- Done as a trigger, not a call from the app: a renter cannot write to
-- crm_clients or crm_activities (both are staff-only by RLS), and even if they
-- could, any path that books a visit and forgets to log it would leave the CRM
-- quietly out of date. This way every booking is recorded, from anywhere.
--
-- The lister is already notified by a separate route: public.my_recent_activity()
-- reads visit_bookings directly, so their notification bell picks this up with
-- no extra work here.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.crm_record_visit_booking()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  cid uuid;
  slot_label text;
begin
  if new.user_id is null then
    return new;
  end if;

  select id into cid from public.crm_clients where user_id = new.user_id;

  -- A visit from someone who has never appeared in the CRM still belongs there.
  if cid is null then
    insert into public.crm_clients (user_id, name, phone, email, source, status)
    select
      p.id,
      coalesce(nullif(p.name, ''), split_part(p.email, '@', 1)),
      coalesce(p.phone, ''),
      p.email,
      'app',
      'visit_pending'
    from public.user_profiles p
    where p.id = new.user_id
    on conflict (user_id) do nothing
    returning id into cid;

    if cid is null then
      select id into cid from public.crm_clients where user_id = new.user_id;
    end if;
  end if;

  if cid is null then
    return new;  -- no profile row yet; nothing to attach this to
  end if;

  -- A booking with no slot_at is someone who asked for "the next available
  -- slot" on a listing whose lister has published no times. The CRM has to be
  -- able to tell those apart: they are the ones needing a human to arrange a
  -- time, not just to show up.
  slot_label := coalesce(
    to_char(new.slot_at at time zone 'Asia/Kolkata', 'DD Mon, HH12:MI AM'),
    'NO TIME SET — needs scheduling'
  );

  -- Booking a visit moves them along, but never out of a closed state.
  update public.crm_clients
     set status = 'visit_pending',
         updated_at = now()
   where id = cid
     and status not in ('closed_by_us', 'closed_outside');

  insert into public.crm_activities (client_id, actor_email, type, body, meta)
  values (
    cid,
    '',
    'visit',
    case
      when new.slot_at is null
        then 'Wants a visit · ' || new.property_id || ' · ' || slot_label
      else 'Booked a visit · ' || new.property_id || ' · ' || slot_label
    end,
    jsonb_build_object(
      'property_id', new.property_id,
      'slot_at', new.slot_at,
      'kind', new.kind,
      'needs_scheduling', new.slot_at is null
    )
  );

  -- And tell the super admin, so a visit nobody can attend does not sit unseen.
  if new.slot_at is null then
    insert into public.crm_notifications (for_email, type, title, body, client_id)
    values (
      'yatharth200018@gmail.com',
      'visit',
      'Visit needs a time',
      'A tenant asked for the next available slot on ' || new.property_id ||
      ' — the lister has published no visit times.',
      cid
    );
  end if;

  -- Keep the property on their shortlist so the agent sees what was booked
  -- alongside whatever was shared. Doesn't overwrite a reply they already gave.
  insert into public.crm_shortlists (client_id, property_id, status)
  values (cid, new.property_id, 'shortlisted')
  on conflict (client_id, property_id) do nothing;

  return new;
end;
$$;

drop trigger if exists on_visit_booking_crm on public.visit_bookings;
create trigger on_visit_booking_crm
  after insert or update of slot_at on public.visit_bookings
  for each row
  execute function public.crm_record_visit_booking();

-- Renters need to see the slots they're being offered; only staff may create
-- them (that policy already exists in visits_schema.sql).
grant select on public.property_visit_slots to anon, authenticated;
