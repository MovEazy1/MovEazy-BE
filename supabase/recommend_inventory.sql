-- Backend recommendation scoring (fe/src/lib/recommend.js → /recommendations page).
-- Scores every published inventory row against a seeker requirement (the Find My
-- Flat prefs, passed as jsonb) and returns them ranked by match score, with
-- deal-breakers hard-excluded. Mirrors fe/src/lib/inventoryMatch.js so the client
-- fallback and this server path agree.
--
-- Run once in the Supabase SQL editor (after inventory_schema.sql).

create or replace function public.recommend_inventory(req jsonb, min_score int default 30)
returns table (property_id text, match_score int, match_reasons text[], listing jsonb)
language sql
stable
security definer
set search_path = public
as $$
with r as (
  select
    coalesce(array(select lower(x) from jsonb_array_elements_text(req->'areas') x), '{}')        as areas,
    coalesce(array(select lower(x) from jsonb_array_elements_text(req->'flatTypes') x), '{}')    as flats,
    coalesce(array(select lower(x) from jsonb_array_elements_text(req->'mustHaves') x), '{}')    as musts,
    coalesce(array(select lower(x) from jsonb_array_elements_text(req->'occupants') x), '{}')    as occ,
    coalesce(array(select lower(x) from jsonb_array_elements_text(req->'dealBreakers') x), '{}') as deals,
    lower(coalesce(req->>'furnishing',''))       as furn,
    nullif(req->>'budgetMin','')::numeric        as bmin,
    nullif(req->>'budgetMax','')::numeric        as bmax
),
comp as (
  select
    inv.property_id, inv.area, inv.flat_type, inv.furnishing, inv.rent,
    to_jsonb(inv) as listing_json,
    r.*,
    coalesce((select array_agg(lower(e)) from unnest(array[inv.area] || coalesce(inv.nearby_areas,'{}')) e), '{}') as l_areas,
    coalesce((select array_agg(lower(e)) from unnest(coalesce(inv.amenities,'{}')) e), '{}')        as l_amen,
    coalesce((select array_agg(lower(e)) from unnest(coalesce(inv.house_rules,'{}')) e), '{}')      as l_rules,
    coalesce((select array_agg(lower(e)) from unnest(coalesce(inv.occupants_allowed,'{}')) e), '{}') as l_occ
  from public.inventory inv, r
  where inv.status = 'published'
),
scored as (
  select
    property_id, area, flat_type, furnishing, rent, listing_json, musts, l_amen,
    (
      exists (
        select 1 from unnest(deals) d
        where exists (select 1 from unnest(l_rules || l_amen) t where t like '%'||d||'%' or d like '%'||t||'%')
      )
      or (
        exists (select 1 from unnest(deals) d where d like '%bachelor%')
        and array_length(l_occ,1) is not null
        and not ('bachelor' = any(l_occ))
      )
    ) as blocked,
    (case when array_length(areas,1) is not null then 30 else 0 end) as p_area,
    (case when array_length(areas,1) is not null and (l_areas && areas) then 30 else 0 end) as s_area,
    (case when rent is not null and (bmin is not null or bmax is not null) then 25 else 0 end) as p_bud,
    (case when rent is not null and (bmin is not null or bmax is not null) then
       case
         when rent >= coalesce(bmin,0) and rent <= coalesce(bmax, 1e12) then 25
         when bmax is not null and rent > bmax and rent <= bmax * 1.15 then 13
         when bmin is not null and rent < bmin then 20
         else 0
       end
     else 0 end) as s_bud,
    (case when array_length(flats,1) is not null and flat_type <> '' then 15 else 0 end) as p_flat,
    (case when array_length(flats,1) is not null and flat_type <> '' and exists (
        select 1 from unnest(flats) f
        where f = lower(flat_type) or f like '%'||lower(flat_type)||'%' or lower(flat_type) like '%'||f||'%'
      ) then 15 else 0 end) as s_flat,
    (case when array_length(musts,1) is not null then 15 else 0 end) as p_must,
    (case when array_length(musts,1) is not null then
       round(15.0 * (select count(*) from unnest(musts) m where m = any(l_amen)) / array_length(musts,1))
     else 0 end) as s_must,
    (case when furn <> '' and furnishing <> '' then 8 else 0 end) as p_furn,
    (case when furn <> '' and lower(furnishing) = furn then 8 else 0 end) as s_furn,
    (case when array_length(occ,1) is not null and array_length(l_occ,1) is not null then 7 else 0 end) as p_occ,
    (case when array_length(occ,1) is not null and (l_occ && occ) then 7 else 0 end) as s_occ
  from comp
)
select
  property_id,
  case
    when blocked then 0
    when (p_area+p_bud+p_flat+p_must+p_furn+p_occ) = 0 then 0
    else round(100.0 * (s_area+s_bud+s_flat+s_must+s_furn+s_occ) / (p_area+p_bud+p_flat+p_must+p_furn+p_occ))::int
  end as match_score,
  array_remove(array[
    case when s_area > 0 then 'In '||area end,
    case when s_bud = 25 then 'Within budget' when s_bud = 20 then 'Under budget' when s_bud = 13 then 'Slightly over budget' end,
    case when s_flat > 0 then flat_type end,
    case when s_must > 0 then (select count(*) from unnest(musts) m where m = any(l_amen))::text||'/'||array_length(musts,1)::text||' must-haves' end,
    case when s_furn > 0 then furnishing end,
    case when s_occ > 0 then 'Occupant-friendly' end
  ], null) as match_reasons,
  listing_json as listing
from scored
where not blocked
  and (p_area+p_bud+p_flat+p_must+p_furn+p_occ) > 0
  and round(100.0 * (s_area+s_bud+s_flat+s_must+s_furn+s_occ) / nullif(p_area+p_bud+p_flat+p_must+p_furn+p_occ,0)) >= min_score
order by match_score desc, rent asc;
$$;

grant execute on function public.recommend_inventory(jsonb, int) to anon, authenticated;
