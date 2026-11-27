-- TimberTrack (Aditya Traders): complete database for app version 3.3.
--
-- Builds everything from scratch on a new Supabase project:
--   tables, views, row-level security, triggers, permission helpers,
--   lookup lists (wood types, expense categories, settings),
--   the sign-up hook on auth.users, and the private "lorry-files" storage bucket.
--
-- Run once: Supabase Dashboard -> SQL Editor -> paste this file -> Run.
-- Then deploy supabase/functions/team-admin (the login service).
--
-- Generated with pg_dump from the database the tests run against (version 3.3),
-- so it matches the live app. Runs as one transaction.

begin;

--
-- PostgreSQL database dump
--

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: handle_new_user(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.handle_new_user() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  has_owner boolean;
begin
  select exists (select 1 from public.profiles where role = 'owner' and active)
    into has_owner;
  insert into public.profiles (id, email, full_name, role, active)
  values (new.id, new.email,
          coalesce(new.raw_user_meta_data->>'full_name', ''),
          case when has_owner then 'staff' else 'owner' end,
          not has_owner);
  return new;
end $$;

--
-- Name: has_perm(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.has_perm(p text) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select exists (select 1 from public.profiles pr
                  where pr.id = (select auth.uid()) and pr.active
                    and (pr.role = 'owner' or case p when 'plan' then pr.perm_plan when 'finance' then pr.perm_finance
                                                     when 'expenses' then pr.perm_expenses when 'people' then pr.perm_people
                                                     when 'rates' then pr.perm_rates else false end));
$$;

--
-- Name: is_admin(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_admin() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$ select public.has_perm('finance'); $$;

--
-- Name: is_member(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_member() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select exists (select 1 from public.profiles
                 where id = (select auth.uid()) and active);
$$;

--
-- Name: is_owner(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_owner() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select exists (select 1 from public.profiles
                 where id = (select auth.uid()) and active and role = 'owner');
$$;

--
-- Name: jsonb_diff(jsonb, jsonb, text[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.jsonb_diff(o jsonb, n jsonb, skip text[]) RETURNS jsonb
    LANGUAGE sql IMMUTABLE
    SET search_path TO ''
    AS $$
  select coalesce(jsonb_object_agg(k, jsonb_build_array(o -> k, n -> k)), '{}'::jsonb)
  from jsonb_object_keys(n) as k
  where k <> all (skip) and (o -> k) is distinct from (n -> k);
$$;

--
-- Name: size_grade_for(numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.size_grade_for(len numeric) RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select case
    when len is null then null
    when len < coalesce((select value from public.app_settings where key = 'size_small_below_ft'), 3) then 'small'
    when len >= coalesce((select value from public.app_settings where key = 'size_large_from_ft'), 5) then 'large'
    else 'medium' end;
$$;

--
-- Name: v2_alloc_rules(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.v2_alloc_rules() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare st text; lid bigint := coalesce(new.load_id, old.load_id);
begin
  select truck_stage into st from public.loads where id = lid;
  if st in ('loaded','in_transit','delivered') and tg_op in ('INSERT','DELETE') then
    raise exception 'This load is already %. Move it back to Under loading first to change its sawmills.', replace(st, '_', ' ') using errcode = 'P0001';
  end if;
  if tg_op = 'INSERT' and st not in ('planning','truck_fixed') and public.v2_setting('driver_photo_required') = 1 and not public.v2_has_driver_photo(lid) then
    raise exception 'Driver photo with truck is mandatory.' using errcode = 'P0001';
  end if;
  if tg_op = 'UPDATE' and new.load_id <> old.load_id then raise exception 'An allocation cannot move to another load.' using errcode = 'P0001'; end if;
  if tg_op = 'INSERT' and new.owner_name is null then
    select contact_name into new.owner_name from public.sawmills where id = new.sawmill_id;
  end if;
  return coalesce(new, old);
end $$;

--
-- Name: v2_expense_rules(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.v2_expense_rules() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  if new.allocation_id is not null and not exists (select 1 from public.load_allocations where id = new.allocation_id and load_id = new.load_id) then
    raise exception 'This sawmill is not on this load.' using errcode = 'P0001';
  end if;
  return new;
end $$;

--
-- Name: v2_file_rules(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.v2_file_rules() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  if new.kind = 'Weigh slip' and new.allocation_id is null then
    raise exception 'Choose the sawmill this weigh slip belongs to.' using errcode = 'P0001';
  end if;
  if new.allocation_id is not null and not exists (select 1 from public.load_allocations where id = new.allocation_id and load_id = new.load_id) then
    raise exception 'This sawmill is not on this load.' using errcode = 'P0001';
  end if;
  return new;
end $$;

--
-- Name: v2_has_driver_photo(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.v2_has_driver_photo(p_load bigint) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select exists (select 1 from public.load_files where load_id = p_load and kind = 'Driver with truck');
$$;

--
-- Name: v2_item_alloc(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.v2_item_alloc() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare a record;
begin
  select load_id, sawmill_id into a from public.load_allocations where id = new.allocation_id;
  if not found then raise exception 'Sawmill allocation not found.' using errcode = 'P0001'; end if;
  new.load_id := a.load_id; new.sawmill_id := a.sawmill_id;
  return new;
end $$;

--
-- Name: v2_line_rules(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.v2_line_rules() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare st text;
begin
  select truck_stage into st from public.loads where id = coalesce(new.load_id, old.load_id);
  if st in ('loaded','in_transit','delivered') then
    if tg_op = 'INSERT' or tg_op = 'DELETE' or new.line_status <> 'done' then
      raise exception 'This load is already %. Move it back to Under loading first to change its mill lines.', replace(st, '_', ' ')
        using errcode = 'P0001';
    end if;
  end if;
  if coalesce(current_setting('app.tally_write', true), '') <> '1' then
    if tg_op = 'INSERT' and new.tally_id is not null then
      raise exception 'Items from a piece tally are made by the tally.' using errcode = 'P0001';
    end if;
    if tg_op = 'UPDATE' and (old.tally_id is not null or new.tally_id is not null)
       and (new.quantity, new.pieces, new.size_grade, new.wood_type, new.unit, new.tally_id, new.allocation_id, new.dimensions, new.length_ft)
           is distinct from (old.quantity, old.pieces, old.size_grade, old.wood_type, old.unit, old.tally_id, old.allocation_id, old.dimensions, old.length_ft) then
      raise exception 'This item comes from the piece tally. Change the tally instead.' using errcode = 'P0001';
    end if;
    if tg_op = 'DELETE' and old.tally_id is not null
       and exists (select 1 from public.load_tallies where id = old.tally_id)
       and exists (select 1 from public.load_allocations where id = old.allocation_id) then
      raise exception 'This item comes from the piece tally. Remove the tally instead.' using errcode = 'P0001';
    end if;
  end if;
  if tg_op <> 'DELETE' and new.size_grade is null and new.length_ft is not null
     and coalesce((select value from public.app_settings where key = 'size_auto'), 0) = 1 then
    new.size_grade := public.size_grade_for(new.length_ft);
  end if;
  return coalesce(new, old);
end $$;

--
-- Name: v2_log(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.v2_log() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  skip  text[] := array['id','created_at','created_by','updated_at','updated_by','change_reason'];
  o     jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end;
  n     jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end;
  rec   jsonb := coalesce(n, o);
  lid   bigint;
  d     jsonb;
  act   text := lower(tg_op);
  st    text;
begin
  if tg_table_name = 'loads' then lid := (rec->>'id')::bigint;
  elsif tg_table_name = 'line_prices' then
    select load_id into lid from public.load_lines where id = (rec->>'line_id')::bigint;
  else lid := (rec->>'load_id')::bigint;
  end if;

  if tg_op = 'UPDATE' then
    d := public.jsonb_diff(o, n, skip);
    if d = '{}'::jsonb then return new; end if;
    if tg_table_name = 'loads' and d ? 'truck_stage' then act := 'stage'; end if;
  elsif tg_op = 'INSERT' then
    d := jsonb_strip_nulls(n) - skip;
  else
    d := jsonb_strip_nulls(o) - skip;
  end if;

  select truck_stage into st from public.loads where id = lid;
  if st is null and tg_table_name = 'loads' then st := rec->>'truck_stage'; end if;

  insert into public.activity (load_id, entity, entity_id, action, changes, reason, truck_stage, visibility, actor)
  values (lid, tg_table_name, coalesce(rec->>'id', rec->>'line_id', rec->>'load_id'), act, d,
          nullif(trim(coalesce(n->>'change_reason', '')), ''), st, tg_argv[0], auth.uid());
  perform public.v2_touch(lid);
  return coalesce(new, old);
end $$;

--
-- Name: v2_mark_checked(bigint[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.v2_mark_checked(p_load_ids bigint[]) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  if not public.is_member() then raise exception 'not allowed'; end if;
  insert into public.load_reviews (load_id, user_id, reviewed_at)
  select l.id, auth.uid(), now() from public.loads l where l.id = any (p_load_ids)
  on conflict (load_id, user_id) do update set reviewed_at = excluded.reviewed_at;
end $$;

--
-- Name: v2_post_note(bigint, text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.v2_post_note(p_load bigint, p_message text, p_admin_only boolean DEFAULT false) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare st text;
begin
  if not public.is_member() then raise exception 'not allowed'; end if;
  if coalesce(trim(p_message), '') = '' then raise exception 'Write the update first.'; end if;
  if p_admin_only and not public.has_perm('finance') then raise exception 'not allowed'; end if;
  select truck_stage into st from public.loads where id = p_load;
  if st is null then raise exception 'Load not found.'; end if;
  if st in ('planning','truck_fixed') and not public.has_perm('plan') then raise exception 'not allowed'; end if;
  insert into public.activity (load_id, entity, entity_id, action, changes, reason, truck_stage, visibility, actor)
  values (p_load, 'note', null, 'note', null, left(trim(p_message), 2000), st,
          case when p_admin_only then 'finance' else 'all' end, auth.uid());
  perform public.v2_touch(p_load);
end $$;

--
-- Name: v2_profile_guard(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.v2_profile_guard() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  if auth.uid() is null then return new; end if;   -- server-side (login service, which checks the caller itself)
  if not public.is_owner() and (new.role = 'owner' or old.role = 'owner' or new.perm_people is distinct from old.perm_people) then
    raise exception 'Only the owner can change owner accounts or the people permission.' using errcode = 'P0001';
  end if;
  return new;
end $$;

--
-- Name: v2_setting(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.v2_setting(p_key text) RETURNS numeric
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select coalesce((select value from public.app_settings where key = p_key), 0);
$$;

--
-- Name: v2_stage_rules(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.v2_stage_rules() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare n_lines int; n_open int; n_noslip int; moved boolean := (tg_op = 'INSERT' or new.truck_stage is distinct from old.truck_stage);
begin
  if new.truck_stage in ('truck_fixed','going_to_load','under_loading','loaded','in_transit','delivered')
     and coalesce(trim(new.vehicle_no), '') = '' then
    raise exception 'Enter the truck number before moving past Planning.' using errcode = 'P0001';
  end if;
  if moved and new.truck_stage in ('planning','truck_fixed','cancelled') and not public.has_perm('plan') then
    raise exception 'Only the owner can use Planning, Truck fixed or Cancel.' using errcode = 'P0001';
  end if;
  if moved and new.truck_stage in ('under_loading','loaded','in_transit','delivered')
     and public.v2_setting('driver_photo_required') = 1 and not public.v2_has_driver_photo(new.id) then
    raise exception 'Driver photo with truck is mandatory.' using errcode = 'P0001';
  end if;
  if moved and new.truck_stage = 'under_loading'
     and not exists (select 1 from public.load_allocations where load_id = new.id and reached_at is not null) then
    raise exception 'Mark the sawmill the truck has reached first. Under loading starts only at the sawmill.' using errcode = 'P0001';
  end if;
  if moved and new.truck_stage in ('loaded','in_transit','delivered') then
    select count(*), count(*) filter (where line_status <> 'done') into n_lines, n_open from public.load_lines where load_id = new.id;
    if n_lines = 0 then raise exception 'Add at least one sawmill item before marking the load as Loaded.' using errcode = 'P0001'; end if;
    if n_open > 0 then raise exception 'Cannot mark as Loaded: % item(s) are not done yet.', n_open using errcode = 'P0001'; end if;
    if public.v2_setting('weigh_slip_required') = 1 then
      select count(*) into n_noslip from public.load_allocations a
       where a.load_id = new.id and not exists (select 1 from public.load_files f where f.allocation_id = a.id and f.kind = 'Weigh slip');
      if n_noslip > 0 then raise exception 'Cannot mark as Loaded: % sawmill(s) have no weigh slip yet.', n_noslip using errcode = 'P0001'; end if;
    end if;
  end if;
  return new;
end $$;

--
-- Name: v2_stamp(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.v2_stamp() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
  new.updated_at := now();
  new.updated_by := auth.uid();
  return new;
end $$;

--
-- Name: v2_tally_clean(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.v2_tally_clean(p jsonb) RETURNS jsonb
    LANGUAGE plpgsql IMMUTABLE
    SET search_path TO ''
    AS $_$
declare t text; cells jsonb; k text; v jsonb; lw text[]; len numeric; w numeric; n numeric; o jsonb; res jsonb := '{}'::jsonb; tk text; ck text;
begin
  if p is null then return res; end if;
  if jsonb_typeof(p) <> 'object' then raise exception 'The tally is not in the right form.' using errcode = 'P0001'; end if;
  for t, cells in select key, value from jsonb_each(p) loop
    if t !~ '^[0-9]+(\.[0-9]+)?$' or t::numeric not in (1, 1.5, 2) then
      raise exception 'Thickness % inch is not on the tally (1, 1.5 or 2 inch).', t using errcode = 'P0001';
    end if;
    if jsonb_typeof(cells) <> 'object' then raise exception 'The tally is not in the right form.' using errcode = 'P0001'; end if;
    tk := trim_scale(t::numeric)::text;
    o := coalesce(res -> tk, '{}'::jsonb);
    for k, v in select key, value from jsonb_each(cells) loop
      lw := regexp_match(k, '^([0-9]+(?:\.[0-9]+)?)\|([0-9]+)$');
      if lw is null then raise exception 'Tally cell "%" is not a length|width.', k using errcode = 'P0001'; end if;
      len := lw[1]::numeric; w := lw[2]::numeric;
      if len < 1.5 or len > 11 or len * 4 <> trunc(len * 4) then
        raise exception 'Length % ft is not on the tally (1 ft 6 in to 11 ft, in 3-inch steps).', len using errcode = 'P0001';
      end if;
      if w < 3 or w > 18 then raise exception 'Width % inch is not on the tally (3 to 18 inches).', w using errcode = 'P0001'; end if;
      if jsonb_typeof(v) <> 'number' then raise exception 'Piece counts must be numbers.' using errcode = 'P0001'; end if;
      n := (v #>> '{}')::numeric;
      if n < 0 or n > 100000 or n <> trunc(n) then raise exception 'Piece counts must be whole numbers (0 to 100000).' using errcode = 'P0001'; end if;
      ck := trim_scale(len)::text || '|' || w::int::text;
      if n > 0 then o := o || jsonb_build_object(ck, n::int); else o := o - ck; end if;
    end loop;
    if o = '{}'::jsonb then res := res - tk; else res := res || jsonb_build_object(tk, o); end if;
  end loop;
  return res;
end $_$;

--
-- Name: v2_tally_items(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.v2_tally_items() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare g text; pcs bigint; cf numeric; th text; lid bigint; dims text;
begin
  perform set_config('app.tally_write', '1', true);
  foreach g in array array['small','medium','large'] loop
    select coalesce(sum(x.pieces), 0), round(coalesce(sum(x.cft), 0), 3),
           string_agg(trim_scale(x.thickness)::text || '"', ', ' order by x.thickness)
      into pcs, cf, th
      from public.v2_tally_totals(new.counts) x where x.size_grade = g;
    dims := 'Piece tally, ' || coalesce(th, '') || ' thick';
    select id into lid from public.load_lines where tally_id = new.id and size_grade = g;
    if pcs > 0 then
      if lid is null then
        insert into public.load_lines (allocation_id, wood_type, unit, quantity, pieces, size_grade, dimensions, tally_id, change_reason)
        values (new.allocation_id, new.wood_type, 'CFT', cf, pcs, g, dims, new.id, new.change_reason);
      else
        update public.load_lines set wood_type = new.wood_type, quantity = cf, pieces = pcs, dimensions = dims, change_reason = new.change_reason
         where id = lid and (wood_type, quantity, pieces, dimensions) is distinct from (new.wood_type, cf, pcs::int, dims);
      end if;
    elsif lid is not null then
      delete from public.load_lines where id = lid;
    end if;
  end loop;
  perform set_config('app.tally_write', '', true);
  return null;
end $$;

--
-- Name: v2_tally_rules(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.v2_tally_rules() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare a record; st text;
begin
  if tg_op <> 'DELETE' then
    if tg_op = 'UPDATE' and new.allocation_id <> old.allocation_id then
      raise exception 'A tally cannot move to another sawmill.' using errcode = 'P0001';
    end if;
    select load_id, sawmill_id into a from public.load_allocations where id = new.allocation_id;
    if not found then raise exception 'Sawmill allocation not found.' using errcode = 'P0001'; end if;
    new.load_id := a.load_id; new.sawmill_id := a.sawmill_id;
    new.wood_type := trim(new.wood_type);
    new.counts := public.v2_tally_clean(new.counts);
  end if;
  select truck_stage into st from public.loads where id = coalesce(new.load_id, old.load_id);
  if st in ('loaded','in_transit','delivered') then
    raise exception 'This load is already %. Move it back to Under loading first to change its tally.', replace(st, '_', ' ')
      using errcode = 'P0001';
  end if;
  return coalesce(new, old);
end $$;

--
-- Name: v2_tally_totals(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.v2_tally_totals(p jsonb) RETURNS TABLE(thickness numeric, size_grade text, pieces bigint, cft numeric)
    LANGUAGE sql STABLE
    SET search_path TO ''
    AS $$
  select t.key::numeric,
         public.size_grade_for(split_part(c.key, '|', 1)::numeric),
         sum((c.value #>> '{}')::bigint),
         sum(t.key::numeric * split_part(c.key, '|', 2)::numeric * split_part(c.key, '|', 1)::numeric * (c.value #>> '{}')::numeric / 144)
    from jsonb_each(coalesce(p, '{}'::jsonb)) t, jsonb_each(t.value) c
   group by 1, 2
$$;

--
-- Name: v2_touch(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.v2_touch(p_load bigint) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  if auth.uid() is null or p_load is null then return; end if;
  if not exists (select 1 from public.loads where id = p_load) then return; end if;
  insert into public.load_reviews (load_id, user_id, reviewed_at) values (p_load, auth.uid(), now())
  on conflict (load_id, user_id) do update set reviewed_at = excluded.reviewed_at;
end $$;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: activity; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.activity (
    id bigint NOT NULL,
    load_id bigint,
    entity text NOT NULL,
    entity_id text,
    action text NOT NULL,
    changes jsonb,
    reason text,
    truck_stage text,
    visibility text DEFAULT 'all'::text NOT NULL,
    actor uuid,
    at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT activity_action_check CHECK ((action = ANY (ARRAY['insert'::text, 'update'::text, 'delete'::text, 'stage'::text, 'note'::text]))),
    CONSTRAINT activity_visibility_check CHECK ((visibility = ANY (ARRAY['all'::text, 'finance'::text, 'expenses'::text])))
);

--
-- Name: activity_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.activity ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.activity_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

--
-- Name: app_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.app_settings (
    key text NOT NULL,
    value numeric NOT NULL,
    label text
);

--
-- Name: expense_categories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.expense_categories (
    name text NOT NULL,
    sort integer DEFAULT 100 NOT NULL,
    active boolean DEFAULT true NOT NULL,
    CONSTRAINT expense_categories_name_check CHECK ((length(TRIM(BOTH FROM name)) > 0))
);

--
-- Name: line_prices; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.line_prices (
    line_id bigint NOT NULL,
    rate numeric(12,2),
    adjustment numeric(12,2) DEFAULT 0 NOT NULL,
    change_reason text,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid,
    CONSTRAINT line_prices_rate_check CHECK ((rate >= (0)::numeric))
);

--
-- Name: load_allocations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.load_allocations (
    id bigint NOT NULL,
    load_id bigint NOT NULL,
    sawmill_id bigint NOT NULL,
    owner_name text,
    party_name text,
    notes text,
    change_reason text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT auth.uid(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid,
    reached_at timestamp with time zone,
    loading_done_at timestamp with time zone,
    slip_net_weight_t numeric(7,3),
    CONSTRAINT load_allocations_slip_net_weight_t_check CHECK (((slip_net_weight_t > (0)::numeric) AND (slip_net_weight_t < (100)::numeric)))
);

--
-- Name: load_allocations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.load_allocations ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.load_allocations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

--
-- Name: load_billing; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.load_billing (
    load_id bigint NOT NULL,
    invoice_no text,
    invoice_date date,
    sale_unit text,
    sale_qty numeric(12,3),
    sale_rate numeric(12,2),
    sale_adjustment numeric(12,2) DEFAULT 0 NOT NULL,
    gst_amount numeric(12,2) DEFAULT 0 NOT NULL,
    credit_days integer,
    change_reason text,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid,
    CONSTRAINT load_billing_credit_days_check CHECK (((credit_days >= 0) AND (credit_days <= 365))),
    CONSTRAINT load_billing_gst_amount_check CHECK ((gst_amount >= (0)::numeric)),
    CONSTRAINT load_billing_sale_qty_check CHECK ((sale_qty >= (0)::numeric)),
    CONSTRAINT load_billing_sale_rate_check CHECK ((sale_rate >= (0)::numeric)),
    CONSTRAINT load_billing_sale_unit_check CHECK ((sale_unit = ANY (ARRAY['CFT'::text, 'CBM'::text, 'RFT'::text, 'SFT'::text, 'Tons'::text, 'Pieces'::text, 'Quintal'::text, 'Kg'::text])))
);

--
-- Name: load_costs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.load_costs (
    id bigint NOT NULL,
    load_id bigint NOT NULL,
    cost_type text NOT NULL,
    amount numeric(12,2) NOT NULL,
    paid_to text,
    paid_on date,
    note text,
    change_reason text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT auth.uid(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid,
    allocation_id bigint,
    receipt_path text,
    CONSTRAINT load_costs_amount_check CHECK ((amount >= (0)::numeric)),
    CONSTRAINT load_costs_cost_type_check CHECK ((length(TRIM(BOTH FROM cost_type)) > 0))
);

--
-- Name: load_costs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.load_costs ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.load_costs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

--
-- Name: load_files; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.load_files (
    id bigint NOT NULL,
    load_id bigint NOT NULL,
    kind text DEFAULT 'Other'::text NOT NULL,
    storage_path text NOT NULL,
    file_name text,
    mime_type text,
    size_bytes integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT auth.uid(),
    allocation_id bigint,
    CONSTRAINT load_files_kind_check CHECK ((length(TRIM(BOTH FROM kind)) > 0))
);

--
-- Name: load_files_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.load_files ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.load_files_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

--
-- Name: load_lines; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.load_lines (
    id bigint NOT NULL,
    load_id bigint NOT NULL,
    sawmill_id bigint NOT NULL,
    wood_type text NOT NULL,
    unit text NOT NULL,
    quantity numeric(12,3),
    length_ft numeric(6,2),
    size_grade text,
    line_status text DEFAULT 'planned'::text NOT NULL,
    loaded_on date,
    notes text,
    change_reason text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT auth.uid(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid,
    allocation_id bigint NOT NULL,
    dimensions text,
    pieces integer,
    tally_id bigint,
    CONSTRAINT load_lines_length_ft_check CHECK ((length_ft > (0)::numeric)),
    CONSTRAINT load_lines_line_status_check CHECK ((line_status = ANY (ARRAY['planned'::text, 'loading'::text, 'done'::text]))),
    CONSTRAINT load_lines_pieces_check CHECK ((pieces >= 0)),
    CONSTRAINT load_lines_quantity_check CHECK ((quantity >= (0)::numeric)),
    CONSTRAINT load_lines_size_grade_check CHECK ((size_grade = ANY (ARRAY['small'::text, 'medium'::text, 'large'::text, 'mixed'::text]))),
    CONSTRAINT load_lines_unit_check CHECK ((unit = ANY (ARRAY['CFT'::text, 'CBM'::text, 'RFT'::text, 'SFT'::text, 'Tons'::text, 'Pieces'::text, 'Quintal'::text, 'Kg'::text]))),
    CONSTRAINT load_lines_wood_type_check CHECK ((length(TRIM(BOTH FROM wood_type)) > 0))
);

--
-- Name: load_lines_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.load_lines ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.load_lines_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

--
-- Name: load_no_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.load_no_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

--
-- Name: load_reviews; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.load_reviews (
    load_id bigint NOT NULL,
    user_id uuid DEFAULT auth.uid() NOT NULL,
    reviewed_at timestamp with time zone DEFAULT now() NOT NULL
);

--
-- Name: load_tallies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.load_tallies (
    id bigint NOT NULL,
    load_id bigint NOT NULL,
    allocation_id bigint NOT NULL,
    sawmill_id bigint NOT NULL,
    wood_type text NOT NULL,
    counts jsonb DEFAULT '{}'::jsonb NOT NULL,
    notes text,
    change_reason text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT auth.uid(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid,
    CONSTRAINT load_tallies_wood_type_check CHECK ((length(TRIM(BOTH FROM wood_type)) > 0))
);

--
-- Name: load_tallies_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.load_tallies ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.load_tallies_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

--
-- Name: loads; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.loads (
    id bigint NOT NULL,
    load_no text DEFAULT ('L-'::text || lpad((nextval('public.load_no_seq'::regclass))::text, 4, '0'::text)) NOT NULL,
    load_date date DEFAULT ((now() AT TIME ZONE 'Asia/Kolkata'::text))::date NOT NULL,
    truck_stage text DEFAULT 'planning'::text NOT NULL,
    vehicle_no text,
    capacity_t numeric(5,1),
    driver_name text,
    driver_phone text,
    transporter_id bigint,
    party_id bigint,
    destination text,
    destination_state text,
    eway_bill_no text,
    notes text,
    change_reason text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT auth.uid(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid,
    net_weight_t numeric(7,3),
    capacity_cft numeric(8,1),
    CONSTRAINT loads_capacity_cft_check CHECK ((capacity_cft > (0)::numeric)),
    CONSTRAINT loads_capacity_t_check CHECK ((capacity_t > (0)::numeric)),
    CONSTRAINT loads_net_weight_t_check CHECK (((net_weight_t > (0)::numeric) AND (net_weight_t < (100)::numeric))),
    CONSTRAINT loads_truck_stage_check CHECK ((truck_stage = ANY (ARRAY['planning'::text, 'truck_fixed'::text, 'going_to_load'::text, 'under_loading'::text, 'loaded'::text, 'in_transit'::text, 'delivered'::text, 'cancelled'::text])))
);

--
-- Name: loads_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.loads ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.loads_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

--
-- Name: parties; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.parties (
    id bigint NOT NULL,
    name text NOT NULL,
    city text,
    phone text,
    notes text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT auth.uid(),
    kind text DEFAULT 'buyer'::text NOT NULL,
    state text,
    credit_days integer DEFAULT 30 NOT NULL,
    gstin text,
    CONSTRAINT parties_credit_days_check CHECK (((credit_days >= 0) AND (credit_days <= 365))),
    CONSTRAINT parties_kind_check CHECK ((kind = ANY (ARRAY['buyer'::text, 'transporter'::text]))),
    CONSTRAINT parties_name_check CHECK ((length(TRIM(BOTH FROM name)) > 0))
);

--
-- Name: parties_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.parties ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.parties_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

--
-- Name: payments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.payments (
    id bigint NOT NULL,
    load_id bigint,
    party_kind text NOT NULL,
    party_id bigint,
    sawmill_id bigint,
    amount numeric(14,2) NOT NULL,
    paid_on date DEFAULT ((now() AT TIME ZONE 'Asia/Kolkata'::text))::date NOT NULL,
    mode text DEFAULT 'bank'::text NOT NULL,
    reference text,
    note text,
    change_reason text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT auth.uid(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid,
    CONSTRAINT payments_amount_check CHECK ((amount > (0)::numeric)),
    CONSTRAINT payments_check CHECK ((((party_kind = 'mill'::text) AND (sawmill_id IS NOT NULL) AND (party_id IS NULL)) OR ((party_kind = ANY (ARRAY['buyer'::text, 'transporter'::text])) AND (party_id IS NOT NULL) AND (sawmill_id IS NULL)))),
    CONSTRAINT payments_mode_check CHECK ((mode = ANY (ARRAY['cash'::text, 'upi'::text, 'bank'::text, 'cheque'::text, 'other'::text]))),
    CONSTRAINT payments_party_kind_check CHECK ((party_kind = ANY (ARRAY['buyer'::text, 'mill'::text, 'transporter'::text])))
);

--
-- Name: payments_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.payments ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.payments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

--
-- Name: profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.profiles (
    id uuid NOT NULL,
    email text,
    full_name text DEFAULT ''::text NOT NULL,
    role text DEFAULT 'staff'::text NOT NULL,
    active boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    phone text,
    perm_plan boolean DEFAULT false NOT NULL,
    perm_finance boolean DEFAULT false NOT NULL,
    perm_expenses boolean DEFAULT false NOT NULL,
    perm_people boolean DEFAULT false NOT NULL,
    perm_rates boolean DEFAULT false NOT NULL,
    CONSTRAINT profiles_role_check CHECK ((role = ANY (ARRAY['owner'::text, 'accountant'::text, 'freight'::text, 'staff'::text])))
);

--
-- Name: sawmill_rates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sawmill_rates (
    id bigint NOT NULL,
    sawmill_id bigint NOT NULL,
    wood_type text NOT NULL,
    size_grade text,
    unit text NOT NULL,
    rate numeric(12,2) NOT NULL,
    effective_from date DEFAULT ((now() AT TIME ZONE 'Asia/Kolkata'::text))::date NOT NULL,
    change_reason text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT auth.uid(),
    CONSTRAINT sawmill_rates_rate_check CHECK ((rate >= (0)::numeric)),
    CONSTRAINT sawmill_rates_size_grade_check CHECK ((size_grade = ANY (ARRAY['small'::text, 'medium'::text, 'large'::text]))),
    CONSTRAINT sawmill_rates_unit_check CHECK ((unit = ANY (ARRAY['CFT'::text, 'CBM'::text, 'RFT'::text, 'SFT'::text, 'Tons'::text, 'Pieces'::text, 'Quintal'::text, 'Kg'::text])))
);

--
-- Name: sawmill_rates_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.sawmill_rates ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.sawmill_rates_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

--
-- Name: sawmills; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sawmills (
    id bigint NOT NULL,
    name text NOT NULL,
    place text,
    phone text,
    notes text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT auth.uid(),
    area text,
    contact_name text,
    CONSTRAINT sawmills_name_check CHECK ((length(TRIM(BOTH FROM name)) > 0))
);

--
-- Name: sawmills_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.sawmills ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.sawmills_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

--
-- Name: v_allocations; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_allocations WITH (security_invoker='true') AS
 SELECT a.id,
    a.load_id,
    a.sawmill_id,
    a.owner_name,
    a.party_name,
    a.notes,
    a.change_reason,
    a.created_at,
    a.created_by,
    a.updated_at,
    a.updated_by,
    a.reached_at,
    a.loading_done_at,
    a.slip_net_weight_t,
    s.name AS sawmill_name,
    s.place AS sawmill_place,
    s.area AS sawmill_area,
    s.phone AS sawmill_phone,
    ( SELECT count(*) AS count
           FROM public.load_lines x
          WHERE (x.allocation_id = a.id)) AS items_total,
    ( SELECT count(*) AS count
           FROM public.load_lines x
          WHERE ((x.allocation_id = a.id) AND (x.line_status = 'done'::text))) AS items_done,
    ( SELECT count(*) AS count
           FROM public.load_files f
          WHERE ((f.allocation_id = a.id) AND (f.kind = 'Weigh slip'::text))) AS weigh_slips
   FROM (public.load_allocations a
     JOIN public.sawmills s ON ((s.id = a.sawmill_id)));

--
-- Name: v_balances; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_balances AS
SELECT
    NULL::text AS party_kind,
    NULL::bigint AS party_id,
    NULL::bigint AS sawmill_id,
    NULL::text AS name,
    NULL::text AS place,
    NULL::text AS phone,
    NULL::numeric AS total_due,
    NULL::numeric AS total_paid,
    NULL::bigint AS bills,
    NULL::date AS oldest_due;

--
-- Name: v_lines; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_lines WITH (security_invoker='true') AS
 SELECT ll.id,
    ll.load_id,
    ll.sawmill_id,
    ll.wood_type,
    ll.unit,
    ll.quantity,
    ll.length_ft,
    ll.size_grade,
    ll.line_status,
    ll.loaded_on,
    ll.notes,
    ll.change_reason,
    ll.created_at,
    ll.created_by,
    ll.updated_at,
    ll.updated_by,
    ll.allocation_id,
    ll.dimensions,
    ll.pieces,
    s.name AS sawmill_name,
    s.place AS sawmill_place,
    s.area AS sawmill_area,
    a.owner_name,
    a.party_name,
    lp.rate,
    lp.adjustment,
        CASE
            WHEN (lp.rate IS NULL) THEN NULL::numeric
            ELSE round(((COALESCE(ll.quantity, (0)::numeric) * lp.rate) + COALESCE(lp.adjustment, (0)::numeric)), 2)
        END AS amount,
    ll.tally_id
   FROM (((public.load_lines ll
     JOIN public.load_allocations a ON ((a.id = ll.allocation_id)))
     JOIN public.sawmills s ON ((s.id = ll.sawmill_id)))
     LEFT JOIN public.line_prices lp ON ((lp.line_id = ll.id)));

--
-- Name: v_loads; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_loads WITH (security_invoker='true') AS
 SELECT l.id,
    l.load_no,
    l.load_date,
    l.truck_stage,
    l.vehicle_no,
    l.capacity_t,
    l.driver_name,
    l.driver_phone,
    l.transporter_id,
    l.party_id,
    l.destination,
    l.destination_state,
    l.eway_bill_no,
    l.notes,
    l.change_reason,
    l.created_at,
    l.created_by,
    l.updated_at,
    l.updated_by,
    l.net_weight_t,
    l.capacity_cft,
    b.name AS party_name,
    b.city AS party_city,
    b.state AS party_state,
    b.phone AS party_phone,
    tr.name AS transporter_name,
    tr.phone AS transporter_phone,
    COALESCE(ln.n_lines, (0)::bigint) AS lines_total,
    COALESCE(ln.n_done, (0)::bigint) AS lines_done,
    COALESCE(ln.n_mills, (0)::bigint) AS mills_count,
    ln.qty_summary,
    ln.cft_total,
    ln.purchase_total,
        CASE
            WHEN (public.has_perm('expenses'::text) OR public.has_perm('finance'::text)) THEN COALESCE(cs.costs_total, (0)::numeric)
            ELSE NULL::numeric
        END AS costs_total,
        CASE
            WHEN (public.has_perm('expenses'::text) OR public.has_perm('finance'::text)) THEN cs.freight_total
            ELSE NULL::numeric
        END AS freight_total,
        CASE
            WHEN (public.has_perm('expenses'::text) OR public.has_perm('finance'::text)) THEN COALESCE(cs.costs_total, (0)::numeric)
            ELSE NULL::numeric
        END AS transport_total,
    fl.driver_photo,
    fl.licence_doc,
    fl.cbook_doc,
    fl.weigh_slips,
    COALESCE(al.allocs_without_slip, (0)::bigint) AS allocs_without_slip,
    bl.invoice_no,
    bl.invoice_date,
        CASE
            WHEN (bl.sale_rate IS NULL) THEN NULL::numeric
            ELSE round((((COALESCE(bl.sale_qty, (0)::numeric) * bl.sale_rate) + bl.sale_adjustment) + bl.gst_amount), 2)
        END AS invoice_total,
        CASE
            WHEN (bl.invoice_date IS NULL) THEN NULL::date
            ELSE (bl.invoice_date + COALESCE(bl.credit_days, b.credit_days, 30))
        END AS due_date,
    pin.received,
        CASE
            WHEN (NOT public.has_perm('finance'::text)) THEN NULL::text
            WHEN (bl.invoice_no IS NULL) THEN
            CASE
                WHEN (l.truck_stage = 'delivered'::text) THEN 'ready_to_bill'::text
                ELSE 'not_ready'::text
            END
            WHEN ((COALESCE(pin.received, (0)::numeric) >= round((((COALESCE(bl.sale_qty, (0)::numeric) * COALESCE(bl.sale_rate, (0)::numeric)) + bl.sale_adjustment) + bl.gst_amount), 2)) AND (COALESCE(bl.sale_rate, (0)::numeric) > (0)::numeric)) THEN 'paid'::text
            WHEN ((COALESCE(pin.received, (0)::numeric) > (0)::numeric) OR ((bl.invoice_date + COALESCE(bl.credit_days, b.credit_days, 30)) < ((now() AT TIME ZONE 'Asia/Kolkata'::text))::date)) THEN 'payment_pending'::text
            ELSE 'billed'::text
        END AS bill_stage,
    r.reviewed_at AS my_reviewed_at,
    la.at AS last_at,
    la.actor AS last_by,
    la.reason AS last_reason,
    la.action AS last_action,
        CASE
            WHEN (r.reviewed_at IS NULL) THEN 'new'::text
            WHEN (la.at > r.reviewed_at) THEN 'edited'::text
            ELSE 'ok'::text
        END AS my_flag
   FROM ((((((((((public.loads l
     LEFT JOIN public.parties b ON ((b.id = l.party_id)))
     LEFT JOIN public.parties tr ON ((tr.id = l.transporter_id)))
     LEFT JOIN LATERAL ( SELECT count(*) AS n_lines,
            count(*) FILTER (WHERE (vl.line_status = 'done'::text)) AS n_done,
            count(DISTINCT vl.sawmill_id) AS n_mills,
            ( SELECT string_agg(((rtrim(to_char(q.total, 'FM999G999G990D999'::text), '.'::text) || ' '::text) || q.unit), ' + '::text ORDER BY q.unit) AS string_agg
                   FROM ( SELECT load_lines.unit,
                            sum(load_lines.quantity) AS total
                           FROM public.load_lines
                          WHERE ((load_lines.load_id = l.id) AND (load_lines.quantity IS NOT NULL))
                          GROUP BY load_lines.unit) q) AS qty_summary,
            sum(vl.quantity) FILTER (WHERE (vl.unit = 'CFT'::text)) AS cft_total,
            sum(vl.amount) AS purchase_total
           FROM public.v_lines vl
          WHERE (vl.load_id = l.id)) ln ON (true))
     LEFT JOIN LATERAL ( SELECT sum(c.amount) AS costs_total,
            sum(c.amount) FILTER (WHERE (c.cost_type = 'Truck Freight'::text)) AS freight_total
           FROM public.load_costs c
          WHERE (c.load_id = l.id)) cs ON (true))
     LEFT JOIN LATERAL ( SELECT bool_or((f.kind = 'Driver with truck'::text)) AS driver_photo,
            bool_or((f.kind = 'Driving licence'::text)) AS licence_doc,
            bool_or((f.kind = 'C-Book / RC'::text)) AS cbook_doc,
            count(*) FILTER (WHERE (f.kind = 'Weigh slip'::text)) AS weigh_slips
           FROM public.load_files f
          WHERE (f.load_id = l.id)) fl ON (true))
     LEFT JOIN LATERAL ( SELECT count(*) AS allocs_without_slip
           FROM public.load_allocations a
          WHERE ((a.load_id = l.id) AND (NOT (EXISTS ( SELECT 1
                   FROM public.load_files f
                  WHERE ((f.allocation_id = a.id) AND (f.kind = 'Weigh slip'::text))))))) al ON (true))
     LEFT JOIN public.load_billing bl ON ((bl.load_id = l.id)))
     LEFT JOIN LATERAL ( SELECT sum(p.amount) AS received
           FROM public.payments p
          WHERE ((p.load_id = l.id) AND (p.party_kind = 'buyer'::text))) pin ON (true))
     LEFT JOIN public.load_reviews r ON (((r.load_id = l.id) AND (r.user_id = ( SELECT auth.uid() AS uid)))))
     LEFT JOIN LATERAL ( SELECT a.at,
            a.actor,
            a.reason,
            a.action
           FROM public.activity a
          WHERE (a.load_id = l.id)
          ORDER BY a.at DESC, a.id DESC
         LIMIT 1) la ON (true));

--
-- Name: wood_types; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.wood_types (
    name text NOT NULL,
    sort integer DEFAULT 100 NOT NULL,
    active boolean DEFAULT true NOT NULL,
    CONSTRAINT wood_types_name_check CHECK ((length(TRIM(BOTH FROM name)) > 0))
);

--
-- Name: activity activity_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activity
    ADD CONSTRAINT activity_pkey PRIMARY KEY (id);

--
-- Name: app_settings app_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_settings
    ADD CONSTRAINT app_settings_pkey PRIMARY KEY (key);

--
-- Name: expense_categories expense_categories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expense_categories
    ADD CONSTRAINT expense_categories_pkey PRIMARY KEY (name);

--
-- Name: line_prices line_prices_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.line_prices
    ADD CONSTRAINT line_prices_pkey PRIMARY KEY (line_id);

--
-- Name: load_allocations load_allocations_load_id_sawmill_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.load_allocations
    ADD CONSTRAINT load_allocations_load_id_sawmill_id_key UNIQUE (load_id, sawmill_id);

--
-- Name: load_allocations load_allocations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.load_allocations
    ADD CONSTRAINT load_allocations_pkey PRIMARY KEY (id);

--
-- Name: load_billing load_billing_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.load_billing
    ADD CONSTRAINT load_billing_pkey PRIMARY KEY (load_id);

--
-- Name: load_costs load_costs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.load_costs
    ADD CONSTRAINT load_costs_pkey PRIMARY KEY (id);

--
-- Name: load_files load_files_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.load_files
    ADD CONSTRAINT load_files_pkey PRIMARY KEY (id);

--
-- Name: load_files load_files_storage_path_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.load_files
    ADD CONSTRAINT load_files_storage_path_key UNIQUE (storage_path);

--
-- Name: load_lines load_lines_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.load_lines
    ADD CONSTRAINT load_lines_pkey PRIMARY KEY (id);

--
-- Name: load_reviews load_reviews_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.load_reviews
    ADD CONSTRAINT load_reviews_pkey PRIMARY KEY (load_id, user_id);

--
-- Name: load_tallies load_tallies_allocation_id_wood_type_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.load_tallies
    ADD CONSTRAINT load_tallies_allocation_id_wood_type_key UNIQUE (allocation_id, wood_type);

--
-- Name: load_tallies load_tallies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.load_tallies
    ADD CONSTRAINT load_tallies_pkey PRIMARY KEY (id);

--
-- Name: loads loads_load_no_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.loads
    ADD CONSTRAINT loads_load_no_key UNIQUE (load_no);

--
-- Name: loads loads_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.loads
    ADD CONSTRAINT loads_pkey PRIMARY KEY (id);

--
-- Name: parties parties_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.parties
    ADD CONSTRAINT parties_pkey PRIMARY KEY (id);

--
-- Name: payments payments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_pkey PRIMARY KEY (id);

--
-- Name: profiles profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_pkey PRIMARY KEY (id);

--
-- Name: sawmill_rates sawmill_rates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sawmill_rates
    ADD CONSTRAINT sawmill_rates_pkey PRIMARY KEY (id);

--
-- Name: sawmills sawmills_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sawmills
    ADD CONSTRAINT sawmills_pkey PRIMARY KEY (id);

--
-- Name: wood_types wood_types_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wood_types
    ADD CONSTRAINT wood_types_pkey PRIMARY KEY (name);

--
-- Name: activity_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX activity_at_idx ON public.activity USING btree (at DESC);

--
-- Name: activity_load_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX activity_load_idx ON public.activity USING btree (load_id, at DESC);

--
-- Name: load_allocations_load_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX load_allocations_load_idx ON public.load_allocations USING btree (load_id);

--
-- Name: load_costs_load_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX load_costs_load_idx ON public.load_costs USING btree (load_id);

--
-- Name: load_files_load_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX load_files_load_idx ON public.load_files USING btree (load_id);

--
-- Name: load_lines_alloc_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX load_lines_alloc_idx ON public.load_lines USING btree (allocation_id);

--
-- Name: load_lines_load_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX load_lines_load_idx ON public.load_lines USING btree (load_id);

--
-- Name: load_lines_mill_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX load_lines_mill_idx ON public.load_lines USING btree (sawmill_id);

--
-- Name: load_lines_tally_size_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX load_lines_tally_size_idx ON public.load_lines USING btree (tally_id, size_grade) WHERE (tally_id IS NOT NULL);

--
-- Name: load_tallies_load_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX load_tallies_load_idx ON public.load_tallies USING btree (load_id);

--
-- Name: loads_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX loads_date_idx ON public.loads USING btree (load_date DESC, id DESC);

--
-- Name: loads_party_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX loads_party_idx ON public.loads USING btree (party_id);

--
-- Name: loads_trans_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX loads_trans_idx ON public.loads USING btree (transporter_id);

--
-- Name: payments_load_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX payments_load_idx ON public.payments USING btree (load_id);

--
-- Name: payments_mill_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX payments_mill_idx ON public.payments USING btree (sawmill_id);

--
-- Name: payments_party_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX payments_party_idx ON public.payments USING btree (party_id);

--
-- Name: sawmill_rates_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX sawmill_rates_idx ON public.sawmill_rates USING btree (sawmill_id, wood_type, unit, effective_from DESC);

--
-- Name: v_balances _RETURN; Type: RULE; Schema: public; Owner: -
--

CREATE OR REPLACE VIEW public.v_balances WITH (security_invoker='true') AS
 SELECT 'buyer'::text AS party_kind,
    p.id AS party_id,
    NULL::bigint AS sawmill_id,
    p.name,
    p.city AS place,
    p.phone,
    COALESCE(sum(vl.invoice_total), (0)::numeric) AS total_due,
    COALESCE(( SELECT sum(x.amount) AS sum
           FROM public.payments x
          WHERE ((x.party_kind = 'buyer'::text) AND (x.party_id = p.id))), (0)::numeric) AS total_paid,
    count(vl.id) FILTER (WHERE (vl.invoice_no IS NOT NULL)) AS bills,
    min(vl.due_date) FILTER (WHERE (vl.bill_stage = ANY (ARRAY['billed'::text, 'payment_pending'::text]))) AS oldest_due
   FROM (public.parties p
     LEFT JOIN public.v_loads vl ON ((vl.party_id = p.id)))
  WHERE ((p.kind = 'buyer'::text) AND public.has_perm('finance'::text))
  GROUP BY p.id
UNION ALL
 SELECT 'mill'::text AS party_kind,
    NULL::bigint AS party_id,
    s.id AS sawmill_id,
    s.name,
    s.place,
    s.phone,
    COALESCE(( SELECT sum(z.amount) AS sum
           FROM public.v_lines z
          WHERE (z.sawmill_id = s.id)), (0)::numeric) AS total_due,
    COALESCE(( SELECT sum(x.amount) AS sum
           FROM public.payments x
          WHERE ((x.party_kind = 'mill'::text) AND (x.sawmill_id = s.id))), (0)::numeric) AS total_paid,
    ( SELECT count(DISTINCT z.load_id) AS count
           FROM public.load_lines z
          WHERE (z.sawmill_id = s.id)) AS bills,
    NULL::date AS oldest_due
   FROM public.sawmills s
  WHERE public.has_perm('finance'::text)
UNION ALL
 SELECT 'transporter'::text AS party_kind,
    p.id AS party_id,
    NULL::bigint AS sawmill_id,
    p.name,
    p.city AS place,
    p.phone,
    COALESCE(( SELECT sum(c.amount) AS sum
           FROM (public.load_costs c
             JOIN public.loads z ON ((z.id = c.load_id)))
          WHERE ((z.transporter_id = p.id) AND (c.cost_type = 'Truck Freight'::text))), (0)::numeric) AS total_due,
    COALESCE(( SELECT sum(x.amount) AS sum
           FROM public.payments x
          WHERE ((x.party_kind = 'transporter'::text) AND (x.party_id = p.id))), (0)::numeric) AS total_paid,
    ( SELECT count(*) AS count
           FROM public.loads z
          WHERE (z.transporter_id = p.id)) AS bills,
    NULL::date AS oldest_due
   FROM public.parties p
  WHERE ((p.kind = 'transporter'::text) AND public.has_perm('finance'::text));

--
-- Name: load_billing billing_log; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER billing_log AFTER INSERT OR DELETE OR UPDATE ON public.load_billing FOR EACH ROW EXECUTE FUNCTION public.v2_log('finance');

--
-- Name: load_billing billing_stamp; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER billing_stamp BEFORE INSERT OR UPDATE ON public.load_billing FOR EACH ROW EXECUTE FUNCTION public.v2_stamp();

--
-- Name: line_prices line_prices_log; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER line_prices_log AFTER INSERT OR DELETE OR UPDATE ON public.line_prices FOR EACH ROW EXECUTE FUNCTION public.v2_log('finance');

--
-- Name: line_prices line_prices_stamp; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER line_prices_stamp BEFORE INSERT OR UPDATE ON public.line_prices FOR EACH ROW EXECUTE FUNCTION public.v2_stamp();

--
-- Name: load_allocations load_allocations_log; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER load_allocations_log AFTER INSERT OR DELETE OR UPDATE ON public.load_allocations FOR EACH ROW EXECUTE FUNCTION public.v2_log('all');

--
-- Name: load_allocations load_allocations_rules; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER load_allocations_rules BEFORE INSERT OR DELETE OR UPDATE ON public.load_allocations FOR EACH ROW EXECUTE FUNCTION public.v2_alloc_rules();

--
-- Name: load_allocations load_allocations_stamp; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER load_allocations_stamp BEFORE UPDATE ON public.load_allocations FOR EACH ROW EXECUTE FUNCTION public.v2_stamp();

--
-- Name: load_costs load_costs_log; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER load_costs_log AFTER INSERT OR DELETE OR UPDATE ON public.load_costs FOR EACH ROW EXECUTE FUNCTION public.v2_log('expenses');

--
-- Name: load_costs load_costs_rules; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER load_costs_rules BEFORE INSERT OR UPDATE ON public.load_costs FOR EACH ROW EXECUTE FUNCTION public.v2_expense_rules();

--
-- Name: load_costs load_costs_stamp; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER load_costs_stamp BEFORE UPDATE ON public.load_costs FOR EACH ROW EXECUTE FUNCTION public.v2_stamp();

--
-- Name: load_files load_files_log; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER load_files_log AFTER INSERT OR DELETE ON public.load_files FOR EACH ROW EXECUTE FUNCTION public.v2_log('all');

--
-- Name: load_files load_files_rules; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER load_files_rules BEFORE INSERT OR UPDATE ON public.load_files FOR EACH ROW EXECUTE FUNCTION public.v2_file_rules();

--
-- Name: load_lines load_lines_alloc; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER load_lines_alloc BEFORE INSERT OR UPDATE OF allocation_id, load_id, sawmill_id ON public.load_lines FOR EACH ROW EXECUTE FUNCTION public.v2_item_alloc();

--
-- Name: load_lines load_lines_log; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER load_lines_log AFTER INSERT OR DELETE OR UPDATE ON public.load_lines FOR EACH ROW EXECUTE FUNCTION public.v2_log('all');

--
-- Name: load_lines load_lines_rules; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER load_lines_rules BEFORE INSERT OR DELETE OR UPDATE ON public.load_lines FOR EACH ROW EXECUTE FUNCTION public.v2_line_rules();

--
-- Name: load_lines load_lines_stamp; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER load_lines_stamp BEFORE UPDATE ON public.load_lines FOR EACH ROW EXECUTE FUNCTION public.v2_stamp();

--
-- Name: load_tallies load_tallies_items; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER load_tallies_items AFTER INSERT OR UPDATE ON public.load_tallies FOR EACH ROW EXECUTE FUNCTION public.v2_tally_items();

--
-- Name: load_tallies load_tallies_log; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER load_tallies_log AFTER INSERT OR DELETE OR UPDATE ON public.load_tallies FOR EACH ROW EXECUTE FUNCTION public.v2_log('all');

--
-- Name: load_tallies load_tallies_rules; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER load_tallies_rules BEFORE INSERT OR DELETE OR UPDATE ON public.load_tallies FOR EACH ROW EXECUTE FUNCTION public.v2_tally_rules();

--
-- Name: load_tallies load_tallies_stamp; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER load_tallies_stamp BEFORE UPDATE ON public.load_tallies FOR EACH ROW EXECUTE FUNCTION public.v2_stamp();

--
-- Name: loads loads_log; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER loads_log AFTER INSERT OR DELETE OR UPDATE ON public.loads FOR EACH ROW EXECUTE FUNCTION public.v2_log('all');

--
-- Name: loads loads_stage_rules; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER loads_stage_rules BEFORE INSERT OR UPDATE ON public.loads FOR EACH ROW EXECUTE FUNCTION public.v2_stage_rules();

--
-- Name: loads loads_stamp; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER loads_stamp BEFORE UPDATE ON public.loads FOR EACH ROW EXECUTE FUNCTION public.v2_stamp();

--
-- Name: payments payments_log; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER payments_log AFTER INSERT OR DELETE OR UPDATE ON public.payments FOR EACH ROW EXECUTE FUNCTION public.v2_log('finance');

--
-- Name: payments payments_stamp; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER payments_stamp BEFORE UPDATE ON public.payments FOR EACH ROW EXECUTE FUNCTION public.v2_stamp();

--
-- Name: profiles profiles_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER profiles_guard BEFORE UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.v2_profile_guard();

--
-- Name: sawmill_rates sawmill_rates_log; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER sawmill_rates_log AFTER INSERT ON public.sawmill_rates FOR EACH ROW EXECUTE FUNCTION public.v2_log('finance');

--
-- Name: line_prices line_prices_line_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.line_prices
    ADD CONSTRAINT line_prices_line_id_fkey FOREIGN KEY (line_id) REFERENCES public.load_lines(id) ON DELETE CASCADE;

--
-- Name: line_prices line_prices_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.line_prices
    ADD CONSTRAINT line_prices_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.profiles(id) ON DELETE SET NULL;

--
-- Name: load_allocations load_allocations_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.load_allocations
    ADD CONSTRAINT load_allocations_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.profiles(id) ON DELETE SET NULL;

--
-- Name: load_allocations load_allocations_load_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.load_allocations
    ADD CONSTRAINT load_allocations_load_id_fkey FOREIGN KEY (load_id) REFERENCES public.loads(id) ON DELETE CASCADE;

--
-- Name: load_allocations load_allocations_sawmill_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.load_allocations
    ADD CONSTRAINT load_allocations_sawmill_id_fkey FOREIGN KEY (sawmill_id) REFERENCES public.sawmills(id) ON DELETE RESTRICT;

--
-- Name: load_allocations load_allocations_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.load_allocations
    ADD CONSTRAINT load_allocations_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.profiles(id) ON DELETE SET NULL;

--
-- Name: load_billing load_billing_load_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.load_billing
    ADD CONSTRAINT load_billing_load_id_fkey FOREIGN KEY (load_id) REFERENCES public.loads(id) ON DELETE CASCADE;

--
-- Name: load_billing load_billing_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.load_billing
    ADD CONSTRAINT load_billing_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.profiles(id) ON DELETE SET NULL;

--
-- Name: load_costs load_costs_allocation_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.load_costs
    ADD CONSTRAINT load_costs_allocation_fk FOREIGN KEY (allocation_id) REFERENCES public.load_allocations(id) ON DELETE SET NULL;

--
-- Name: load_costs load_costs_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.load_costs
    ADD CONSTRAINT load_costs_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.profiles(id) ON DELETE SET NULL;

--
-- Name: load_costs load_costs_load_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.load_costs
    ADD CONSTRAINT load_costs_load_id_fkey FOREIGN KEY (load_id) REFERENCES public.loads(id) ON DELETE CASCADE;

--
-- Name: load_costs load_costs_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.load_costs
    ADD CONSTRAINT load_costs_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.profiles(id) ON DELETE SET NULL;

--
-- Name: load_files load_files_allocation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.load_files
    ADD CONSTRAINT load_files_allocation_id_fkey FOREIGN KEY (allocation_id) REFERENCES public.load_allocations(id) ON DELETE CASCADE;

--
-- Name: load_files load_files_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.load_files
    ADD CONSTRAINT load_files_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.profiles(id) ON DELETE SET NULL;

--
-- Name: load_files load_files_load_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.load_files
    ADD CONSTRAINT load_files_load_id_fkey FOREIGN KEY (load_id) REFERENCES public.loads(id) ON DELETE CASCADE;

--
-- Name: load_lines load_lines_allocation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.load_lines
    ADD CONSTRAINT load_lines_allocation_id_fkey FOREIGN KEY (allocation_id) REFERENCES public.load_allocations(id) ON DELETE CASCADE;

--
-- Name: load_lines load_lines_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.load_lines
    ADD CONSTRAINT load_lines_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.profiles(id) ON DELETE SET NULL;

--
-- Name: load_lines load_lines_load_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.load_lines
    ADD CONSTRAINT load_lines_load_id_fkey FOREIGN KEY (load_id) REFERENCES public.loads(id) ON DELETE CASCADE;

--
-- Name: load_lines load_lines_sawmill_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.load_lines
    ADD CONSTRAINT load_lines_sawmill_id_fkey FOREIGN KEY (sawmill_id) REFERENCES public.sawmills(id) ON DELETE RESTRICT;

--
-- Name: load_lines load_lines_tally_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.load_lines
    ADD CONSTRAINT load_lines_tally_id_fkey FOREIGN KEY (tally_id) REFERENCES public.load_tallies(id) ON DELETE CASCADE;

--
-- Name: load_lines load_lines_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.load_lines
    ADD CONSTRAINT load_lines_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.profiles(id) ON DELETE SET NULL;

--
-- Name: load_reviews load_reviews_load_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.load_reviews
    ADD CONSTRAINT load_reviews_load_id_fkey FOREIGN KEY (load_id) REFERENCES public.loads(id) ON DELETE CASCADE;

--
-- Name: load_reviews load_reviews_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.load_reviews
    ADD CONSTRAINT load_reviews_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;

--
-- Name: load_tallies load_tallies_allocation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.load_tallies
    ADD CONSTRAINT load_tallies_allocation_id_fkey FOREIGN KEY (allocation_id) REFERENCES public.load_allocations(id) ON DELETE CASCADE;

--
-- Name: load_tallies load_tallies_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.load_tallies
    ADD CONSTRAINT load_tallies_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.profiles(id) ON DELETE SET NULL;

--
-- Name: load_tallies load_tallies_load_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.load_tallies
    ADD CONSTRAINT load_tallies_load_id_fkey FOREIGN KEY (load_id) REFERENCES public.loads(id) ON DELETE CASCADE;

--
-- Name: load_tallies load_tallies_sawmill_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.load_tallies
    ADD CONSTRAINT load_tallies_sawmill_id_fkey FOREIGN KEY (sawmill_id) REFERENCES public.sawmills(id) ON DELETE RESTRICT;

--
-- Name: load_tallies load_tallies_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.load_tallies
    ADD CONSTRAINT load_tallies_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.profiles(id) ON DELETE SET NULL;

--
-- Name: loads loads_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.loads
    ADD CONSTRAINT loads_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.profiles(id) ON DELETE SET NULL;

--
-- Name: loads loads_party_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.loads
    ADD CONSTRAINT loads_party_id_fkey FOREIGN KEY (party_id) REFERENCES public.parties(id) ON DELETE RESTRICT;

--
-- Name: loads loads_transporter_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.loads
    ADD CONSTRAINT loads_transporter_id_fkey FOREIGN KEY (transporter_id) REFERENCES public.parties(id) ON DELETE RESTRICT;

--
-- Name: loads loads_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.loads
    ADD CONSTRAINT loads_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.profiles(id) ON DELETE SET NULL;

--
-- Name: parties parties_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.parties
    ADD CONSTRAINT parties_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.profiles(id) ON DELETE SET NULL;

--
-- Name: payments payments_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.profiles(id) ON DELETE SET NULL;

--
-- Name: payments payments_load_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_load_id_fkey FOREIGN KEY (load_id) REFERENCES public.loads(id) ON DELETE SET NULL;

--
-- Name: payments payments_party_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_party_id_fkey FOREIGN KEY (party_id) REFERENCES public.parties(id) ON DELETE RESTRICT;

--
-- Name: payments payments_sawmill_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_sawmill_id_fkey FOREIGN KEY (sawmill_id) REFERENCES public.sawmills(id) ON DELETE RESTRICT;

--
-- Name: payments payments_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.profiles(id) ON DELETE SET NULL;

--
-- Name: profiles profiles_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_id_fkey FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE;

--
-- Name: sawmill_rates sawmill_rates_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sawmill_rates
    ADD CONSTRAINT sawmill_rates_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.profiles(id) ON DELETE SET NULL;

--
-- Name: sawmill_rates sawmill_rates_sawmill_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sawmill_rates
    ADD CONSTRAINT sawmill_rates_sawmill_id_fkey FOREIGN KEY (sawmill_id) REFERENCES public.sawmills(id) ON DELETE RESTRICT;

--
-- Name: sawmills sawmills_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sawmills
    ADD CONSTRAINT sawmills_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.profiles(id) ON DELETE SET NULL;

--
-- Name: activity; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.activity ENABLE ROW LEVEL SECURITY;

--
-- Name: load_allocations add allocations; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "add allocations" ON public.load_allocations FOR INSERT TO authenticated WITH CHECK ((( SELECT public.is_member() AS is_member) AND (EXISTS ( SELECT 1
   FROM public.loads l
  WHERE (l.id = load_allocations.load_id)))));

--
-- Name: load_files add files; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "add files" ON public.load_files FOR INSERT TO authenticated WITH CHECK ((( SELECT public.is_member() AS is_member) AND (EXISTS ( SELECT 1
   FROM public.loads l
  WHERE (l.id = load_files.load_id)))));

--
-- Name: load_lines add items; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "add items" ON public.load_lines FOR INSERT TO authenticated WITH CHECK ((( SELECT public.is_member() AS is_member) AND (EXISTS ( SELECT 1
   FROM public.loads l
  WHERE (l.id = load_lines.load_id)))));

--
-- Name: loads add loads; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "add loads" ON public.loads FOR INSERT TO authenticated WITH CHECK ((( SELECT public.is_member() AS is_member) AND ((truck_stage <> ALL (ARRAY['planning'::text, 'truck_fixed'::text])) OR ( SELECT public.has_perm('plan'::text) AS has_perm))));

--
-- Name: load_tallies add tallies; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "add tallies" ON public.load_tallies FOR INSERT TO authenticated WITH CHECK ((( SELECT public.is_member() AS is_member) AND (EXISTS ( SELECT 1
   FROM public.loads l
  WHERE (l.id = load_tallies.load_id)))));

--
-- Name: app_settings; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.app_settings ENABLE ROW LEVEL SECURITY;

--
-- Name: load_allocations delete allocations; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "delete allocations" ON public.load_allocations FOR DELETE TO authenticated USING ((( SELECT public.is_member() AS is_member) AND (EXISTS ( SELECT 1
   FROM public.loads l
  WHERE (l.id = load_allocations.load_id)))));

--
-- Name: load_lines delete items; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "delete items" ON public.load_lines FOR DELETE TO authenticated USING ((( SELECT public.is_member() AS is_member) AND (EXISTS ( SELECT 1
   FROM public.loads l
  WHERE (l.id = load_lines.load_id)))));

--
-- Name: load_tallies delete tallies; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "delete tallies" ON public.load_tallies FOR DELETE TO authenticated USING ((( SELECT public.is_member() AS is_member) AND (EXISTS ( SELECT 1
   FROM public.loads l
  WHERE (l.id = load_tallies.load_id)))));

--
-- Name: load_allocations edit allocations; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "edit allocations" ON public.load_allocations FOR UPDATE TO authenticated USING ((( SELECT public.is_member() AS is_member) AND (EXISTS ( SELECT 1
   FROM public.loads l
  WHERE (l.id = load_allocations.load_id))))) WITH CHECK (( SELECT public.is_member() AS is_member));

--
-- Name: load_lines edit items; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "edit items" ON public.load_lines FOR UPDATE TO authenticated USING ((( SELECT public.is_member() AS is_member) AND (EXISTS ( SELECT 1
   FROM public.loads l
  WHERE (l.id = load_lines.load_id))))) WITH CHECK (( SELECT public.is_member() AS is_member));

--
-- Name: load_tallies edit tallies; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "edit tallies" ON public.load_tallies FOR UPDATE TO authenticated USING ((( SELECT public.is_member() AS is_member) AND (EXISTS ( SELECT 1
   FROM public.loads l
  WHERE (l.id = load_tallies.load_id))))) WITH CHECK (( SELECT public.is_member() AS is_member));

--
-- Name: loads edit visible loads; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "edit visible loads" ON public.loads FOR UPDATE TO authenticated USING ((( SELECT public.is_member() AS is_member) AND ((truck_stage <> ALL (ARRAY['planning'::text, 'truck_fixed'::text])) OR ( SELECT public.has_perm('plan'::text) AS has_perm)))) WITH CHECK ((( SELECT public.is_member() AS is_member) AND ((truck_stage <> ALL (ARRAY['planning'::text, 'truck_fixed'::text])) OR ( SELECT public.has_perm('plan'::text) AS has_perm))));

--
-- Name: expense_categories expense people add categories; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "expense people add categories" ON public.expense_categories FOR INSERT TO authenticated WITH CHECK (( SELECT public.has_perm('expenses'::text) AS has_perm));

--
-- Name: load_costs expense people add expenses; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "expense people add expenses" ON public.load_costs FOR INSERT TO authenticated WITH CHECK (( SELECT public.has_perm('expenses'::text) AS has_perm));

--
-- Name: load_costs expense people delete expenses; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "expense people delete expenses" ON public.load_costs FOR DELETE TO authenticated USING (( SELECT public.has_perm('expenses'::text) AS has_perm));

--
-- Name: load_costs expense people edit expenses; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "expense people edit expenses" ON public.load_costs FOR UPDATE TO authenticated USING (( SELECT public.has_perm('expenses'::text) AS has_perm)) WITH CHECK (( SELECT public.has_perm('expenses'::text) AS has_perm));

--
-- Name: expense_categories; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.expense_categories ENABLE ROW LEVEL SECURITY;

--
-- Name: load_billing finance all billing; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "finance all billing" ON public.load_billing TO authenticated USING (( SELECT public.has_perm('finance'::text) AS has_perm)) WITH CHECK (( SELECT public.has_perm('finance'::text) AS has_perm));

--
-- Name: payments finance all payments; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "finance all payments" ON public.payments TO authenticated USING (( SELECT public.has_perm('finance'::text) AS has_perm)) WITH CHECK (( SELECT public.has_perm('finance'::text) AS has_perm));

--
-- Name: line_prices finance reads item rates; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "finance reads item rates" ON public.line_prices FOR SELECT TO authenticated USING ((( SELECT public.has_perm('finance'::text) AS has_perm) OR ( SELECT public.has_perm('rates'::text) AS has_perm)));

--
-- Name: sawmill_rates finance reads rate cards; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "finance reads rate cards" ON public.sawmill_rates FOR SELECT TO authenticated USING ((( SELECT public.has_perm('finance'::text) AS has_perm) OR ( SELECT public.has_perm('rates'::text) AS has_perm)));

--
-- Name: line_prices; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.line_prices ENABLE ROW LEVEL SECURITY;

--
-- Name: load_allocations; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.load_allocations ENABLE ROW LEVEL SECURITY;

--
-- Name: load_billing; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.load_billing ENABLE ROW LEVEL SECURITY;

--
-- Name: load_costs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.load_costs ENABLE ROW LEVEL SECURITY;

--
-- Name: load_files; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.load_files ENABLE ROW LEVEL SECURITY;

--
-- Name: load_lines; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.load_lines ENABLE ROW LEVEL SECURITY;

--
-- Name: load_reviews; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.load_reviews ENABLE ROW LEVEL SECURITY;

--
-- Name: load_tallies; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.load_tallies ENABLE ROW LEVEL SECURITY;

--
-- Name: loads; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.loads ENABLE ROW LEVEL SECURITY;

--
-- Name: parties members add parties; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "members add parties" ON public.parties FOR INSERT TO authenticated WITH CHECK (( SELECT public.is_member() AS is_member));

--
-- Name: sawmills members add sawmills; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "members add sawmills" ON public.sawmills FOR INSERT TO authenticated WITH CHECK (( SELECT public.is_member() AS is_member));

--
-- Name: parties members edit parties; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "members edit parties" ON public.parties FOR UPDATE TO authenticated USING (( SELECT public.is_member() AS is_member)) WITH CHECK (( SELECT public.is_member() AS is_member));

--
-- Name: sawmills members edit sawmills; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "members edit sawmills" ON public.sawmills FOR UPDATE TO authenticated USING (( SELECT public.is_member() AS is_member)) WITH CHECK (( SELECT public.is_member() AS is_member));

--
-- Name: parties members read parties; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "members read parties" ON public.parties FOR SELECT TO authenticated USING (( SELECT public.is_member() AS is_member));

--
-- Name: sawmills members read sawmills; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "members read sawmills" ON public.sawmills FOR SELECT TO authenticated USING (( SELECT public.is_member() AS is_member));

--
-- Name: app_settings members read settings; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "members read settings" ON public.app_settings FOR SELECT TO authenticated USING (( SELECT public.is_member() AS is_member));

--
-- Name: wood_types members read wood types; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "members read wood types" ON public.wood_types FOR SELECT TO authenticated USING (( SELECT public.is_member() AS is_member));

--
-- Name: expense_categories money people read categories; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "money people read categories" ON public.expense_categories FOR SELECT TO authenticated USING ((( SELECT public.has_perm('expenses'::text) AS has_perm) OR ( SELECT public.has_perm('finance'::text) AS has_perm)));

--
-- Name: load_costs money people read expenses; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "money people read expenses" ON public.load_costs FOR SELECT TO authenticated USING ((( SELECT public.has_perm('expenses'::text) AS has_perm) OR ( SELECT public.has_perm('finance'::text) AS has_perm)));

--
-- Name: load_reviews my checks: add; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "my checks: add" ON public.load_reviews FOR INSERT TO authenticated WITH CHECK (((user_id = ( SELECT auth.uid() AS uid)) AND ( SELECT public.is_member() AS is_member)));

--
-- Name: load_reviews my checks: read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "my checks: read" ON public.load_reviews FOR SELECT TO authenticated USING ((user_id = ( SELECT auth.uid() AS uid)));

--
-- Name: load_reviews my checks: update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "my checks: update" ON public.load_reviews FOR UPDATE TO authenticated USING ((user_id = ( SELECT auth.uid() AS uid))) WITH CHECK ((user_id = ( SELECT auth.uid() AS uid)));

--
-- Name: loads owner deletes loads; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "owner deletes loads" ON public.loads FOR DELETE TO authenticated USING (( SELECT public.is_owner() AS is_owner));

--
-- Name: parties owner deletes parties v2; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "owner deletes parties v2" ON public.parties FOR DELETE TO authenticated USING (( SELECT public.is_owner() AS is_owner));

--
-- Name: sawmills owner deletes sawmills v2; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "owner deletes sawmills v2" ON public.sawmills FOR DELETE TO authenticated USING (( SELECT public.is_owner() AS is_owner));

--
-- Name: parties; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.parties ENABLE ROW LEVEL SECURITY;

--
-- Name: payments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.payments ENABLE ROW LEVEL SECURITY;

--
-- Name: app_settings people managers add settings; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "people managers add settings" ON public.app_settings FOR INSERT TO authenticated WITH CHECK (( SELECT public.has_perm('people'::text) AS has_perm));

--
-- Name: app_settings people managers change settings; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "people managers change settings" ON public.app_settings FOR UPDATE TO authenticated USING (( SELECT public.has_perm('people'::text) AS has_perm)) WITH CHECK (( SELECT public.has_perm('people'::text) AS has_perm));

--
-- Name: profiles people managers manage people; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "people managers manage people" ON public.profiles FOR UPDATE TO authenticated USING (( SELECT public.has_perm('people'::text) AS has_perm)) WITH CHECK (( SELECT public.has_perm('people'::text) AS has_perm));

--
-- Name: wood_types planners add wood types; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "planners add wood types" ON public.wood_types FOR INSERT TO authenticated WITH CHECK (( SELECT public.has_perm('plan'::text) AS has_perm));

--
-- Name: wood_types planners edit wood types; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "planners edit wood types" ON public.wood_types FOR UPDATE TO authenticated USING (( SELECT public.has_perm('plan'::text) AS has_perm)) WITH CHECK (( SELECT public.has_perm('plan'::text) AS has_perm));

--
-- Name: profiles; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

--
-- Name: line_prices rates people add item rates; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "rates people add item rates" ON public.line_prices FOR INSERT TO authenticated WITH CHECK (( SELECT public.has_perm('rates'::text) AS has_perm));

--
-- Name: sawmill_rates rates people add rate cards; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "rates people add rate cards" ON public.sawmill_rates FOR INSERT TO authenticated WITH CHECK (( SELECT public.has_perm('rates'::text) AS has_perm));

--
-- Name: line_prices rates people edit item rates; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "rates people edit item rates" ON public.line_prices FOR UPDATE TO authenticated USING (( SELECT public.has_perm('rates'::text) AS has_perm)) WITH CHECK (( SELECT public.has_perm('rates'::text) AS has_perm));

--
-- Name: line_prices rates people remove item rates; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "rates people remove item rates" ON public.line_prices FOR DELETE TO authenticated USING (( SELECT public.has_perm('rates'::text) AS has_perm));

--
-- Name: activity read activity; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "read activity" ON public.activity FOR SELECT TO authenticated USING ((( SELECT public.is_member() AS is_member) AND ((COALESCE(truck_stage, ''::text) <> ALL (ARRAY['planning'::text, 'truck_fixed'::text])) OR ( SELECT public.has_perm('plan'::text) AS has_perm)) AND ((visibility = 'all'::text) OR ((visibility = 'finance'::text) AND ( SELECT public.has_perm('finance'::text) AS has_perm)) OR ((visibility = 'expenses'::text) AND (( SELECT public.has_perm('expenses'::text) AS has_perm) OR ( SELECT public.has_perm('finance'::text) AS has_perm))))));

--
-- Name: load_allocations read allocations; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "read allocations" ON public.load_allocations FOR SELECT TO authenticated USING ((( SELECT public.is_member() AS is_member) AND (EXISTS ( SELECT 1
   FROM public.loads l
  WHERE (l.id = load_allocations.load_id)))));

--
-- Name: load_files read files; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "read files" ON public.load_files FOR SELECT TO authenticated USING ((( SELECT public.is_member() AS is_member) AND (EXISTS ( SELECT 1
   FROM public.loads l
  WHERE (l.id = load_files.load_id)))));

--
-- Name: load_lines read items; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "read items" ON public.load_lines FOR SELECT TO authenticated USING ((( SELECT public.is_member() AS is_member) AND (EXISTS ( SELECT 1
   FROM public.loads l
  WHERE (l.id = load_lines.load_id)))));

--
-- Name: load_tallies read tallies; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "read tallies" ON public.load_tallies FOR SELECT TO authenticated USING ((( SELECT public.is_member() AS is_member) AND (EXISTS ( SELECT 1
   FROM public.loads l
  WHERE (l.id = load_tallies.load_id)))));

--
-- Name: loads read visible loads; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "read visible loads" ON public.loads FOR SELECT TO authenticated USING ((( SELECT public.is_member() AS is_member) AND ((truck_stage <> ALL (ARRAY['planning'::text, 'truck_fixed'::text])) OR ( SELECT public.has_perm('plan'::text) AS has_perm))));

--
-- Name: load_files remove own files or owner; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "remove own files or owner" ON public.load_files FOR DELETE TO authenticated USING ((( SELECT public.is_owner() AS is_owner) OR ((created_by = ( SELECT auth.uid() AS uid)) AND ( SELECT public.is_member() AS is_member))));

--
-- Name: sawmill_rates; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.sawmill_rates ENABLE ROW LEVEL SECURITY;

--
-- Name: sawmills; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.sawmills ENABLE ROW LEVEL SECURITY;

--
-- Name: profiles see own or team profiles; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "see own or team profiles" ON public.profiles FOR SELECT TO authenticated USING (((id = ( SELECT auth.uid() AS uid)) OR ( SELECT public.is_member() AS is_member)));

--
-- Name: wood_types; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.wood_types ENABLE ROW LEVEL SECURITY;

--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA public TO anon;
GRANT USAGE ON SCHEMA public TO authenticated;
GRANT USAGE ON SCHEMA public TO service_role;

--
-- Name: FUNCTION handle_new_user(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.handle_new_user() FROM PUBLIC;
GRANT ALL ON FUNCTION public.handle_new_user() TO service_role;

--
-- Name: FUNCTION has_perm(p text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.has_perm(p text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.has_perm(p text) TO authenticated;
GRANT ALL ON FUNCTION public.has_perm(p text) TO service_role;

--
-- Name: FUNCTION is_admin(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.is_admin() FROM PUBLIC;
GRANT ALL ON FUNCTION public.is_admin() TO authenticated;
GRANT ALL ON FUNCTION public.is_admin() TO service_role;

--
-- Name: FUNCTION is_member(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.is_member() FROM PUBLIC;
GRANT ALL ON FUNCTION public.is_member() TO authenticated;
GRANT ALL ON FUNCTION public.is_member() TO service_role;

--
-- Name: FUNCTION is_owner(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.is_owner() FROM PUBLIC;
GRANT ALL ON FUNCTION public.is_owner() TO authenticated;
GRANT ALL ON FUNCTION public.is_owner() TO service_role;

--
-- Name: FUNCTION jsonb_diff(o jsonb, n jsonb, skip text[]); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.jsonb_diff(o jsonb, n jsonb, skip text[]) FROM PUBLIC;
GRANT ALL ON FUNCTION public.jsonb_diff(o jsonb, n jsonb, skip text[]) TO authenticated;
GRANT ALL ON FUNCTION public.jsonb_diff(o jsonb, n jsonb, skip text[]) TO service_role;

--
-- Name: FUNCTION size_grade_for(len numeric); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.size_grade_for(len numeric) FROM PUBLIC;
GRANT ALL ON FUNCTION public.size_grade_for(len numeric) TO authenticated;
GRANT ALL ON FUNCTION public.size_grade_for(len numeric) TO service_role;

--
-- Name: FUNCTION v2_alloc_rules(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.v2_alloc_rules() FROM PUBLIC;
GRANT ALL ON FUNCTION public.v2_alloc_rules() TO service_role;

--
-- Name: FUNCTION v2_expense_rules(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.v2_expense_rules() FROM PUBLIC;
GRANT ALL ON FUNCTION public.v2_expense_rules() TO service_role;

--
-- Name: FUNCTION v2_file_rules(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.v2_file_rules() FROM PUBLIC;
GRANT ALL ON FUNCTION public.v2_file_rules() TO service_role;

--
-- Name: FUNCTION v2_has_driver_photo(p_load bigint); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.v2_has_driver_photo(p_load bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION public.v2_has_driver_photo(p_load bigint) TO authenticated;
GRANT ALL ON FUNCTION public.v2_has_driver_photo(p_load bigint) TO service_role;

--
-- Name: FUNCTION v2_item_alloc(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.v2_item_alloc() FROM PUBLIC;
GRANT ALL ON FUNCTION public.v2_item_alloc() TO service_role;

--
-- Name: FUNCTION v2_line_rules(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.v2_line_rules() FROM PUBLIC;
GRANT ALL ON FUNCTION public.v2_line_rules() TO service_role;

--
-- Name: FUNCTION v2_log(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.v2_log() FROM PUBLIC;
GRANT ALL ON FUNCTION public.v2_log() TO service_role;

--
-- Name: FUNCTION v2_mark_checked(p_load_ids bigint[]); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.v2_mark_checked(p_load_ids bigint[]) FROM PUBLIC;
GRANT ALL ON FUNCTION public.v2_mark_checked(p_load_ids bigint[]) TO authenticated;
GRANT ALL ON FUNCTION public.v2_mark_checked(p_load_ids bigint[]) TO service_role;

--
-- Name: FUNCTION v2_post_note(p_load bigint, p_message text, p_admin_only boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.v2_post_note(p_load bigint, p_message text, p_admin_only boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.v2_post_note(p_load bigint, p_message text, p_admin_only boolean) TO authenticated;
GRANT ALL ON FUNCTION public.v2_post_note(p_load bigint, p_message text, p_admin_only boolean) TO service_role;

--
-- Name: FUNCTION v2_profile_guard(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.v2_profile_guard() FROM PUBLIC;
GRANT ALL ON FUNCTION public.v2_profile_guard() TO service_role;

--
-- Name: FUNCTION v2_setting(p_key text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.v2_setting(p_key text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.v2_setting(p_key text) TO authenticated;
GRANT ALL ON FUNCTION public.v2_setting(p_key text) TO service_role;

--
-- Name: FUNCTION v2_stage_rules(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.v2_stage_rules() FROM PUBLIC;
GRANT ALL ON FUNCTION public.v2_stage_rules() TO service_role;

--
-- Name: FUNCTION v2_stamp(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.v2_stamp() TO anon;
GRANT ALL ON FUNCTION public.v2_stamp() TO authenticated;
GRANT ALL ON FUNCTION public.v2_stamp() TO service_role;

--
-- Name: FUNCTION v2_tally_clean(p jsonb); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.v2_tally_clean(p jsonb) TO anon;
GRANT ALL ON FUNCTION public.v2_tally_clean(p jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.v2_tally_clean(p jsonb) TO service_role;

--
-- Name: FUNCTION v2_tally_items(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.v2_tally_items() FROM PUBLIC;
GRANT ALL ON FUNCTION public.v2_tally_items() TO service_role;

--
-- Name: FUNCTION v2_tally_rules(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.v2_tally_rules() FROM PUBLIC;
GRANT ALL ON FUNCTION public.v2_tally_rules() TO service_role;

--
-- Name: FUNCTION v2_tally_totals(p jsonb); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.v2_tally_totals(p jsonb) TO anon;
GRANT ALL ON FUNCTION public.v2_tally_totals(p jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.v2_tally_totals(p jsonb) TO service_role;

--
-- Name: FUNCTION v2_touch(p_load bigint); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.v2_touch(p_load bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION public.v2_touch(p_load bigint) TO service_role;

--
-- Name: TABLE activity; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE ON TABLE public.activity TO authenticated;
GRANT ALL ON TABLE public.activity TO service_role;

--
-- Name: SEQUENCE activity_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.activity_id_seq TO anon;
GRANT ALL ON SEQUENCE public.activity_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.activity_id_seq TO service_role;

--
-- Name: TABLE app_settings; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.app_settings TO authenticated;
GRANT ALL ON TABLE public.app_settings TO service_role;

--
-- Name: TABLE expense_categories; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.expense_categories TO authenticated;
GRANT ALL ON TABLE public.expense_categories TO service_role;

--
-- Name: TABLE line_prices; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.line_prices TO authenticated;
GRANT ALL ON TABLE public.line_prices TO service_role;

--
-- Name: TABLE load_allocations; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.load_allocations TO authenticated;
GRANT ALL ON TABLE public.load_allocations TO service_role;

--
-- Name: SEQUENCE load_allocations_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.load_allocations_id_seq TO anon;
GRANT ALL ON SEQUENCE public.load_allocations_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.load_allocations_id_seq TO service_role;

--
-- Name: TABLE load_billing; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.load_billing TO authenticated;
GRANT ALL ON TABLE public.load_billing TO service_role;

--
-- Name: TABLE load_costs; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.load_costs TO authenticated;
GRANT ALL ON TABLE public.load_costs TO service_role;

--
-- Name: SEQUENCE load_costs_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.load_costs_id_seq TO anon;
GRANT ALL ON SEQUENCE public.load_costs_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.load_costs_id_seq TO service_role;

--
-- Name: TABLE load_files; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.load_files TO authenticated;
GRANT ALL ON TABLE public.load_files TO service_role;

--
-- Name: SEQUENCE load_files_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.load_files_id_seq TO anon;
GRANT ALL ON SEQUENCE public.load_files_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.load_files_id_seq TO service_role;

--
-- Name: TABLE load_lines; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.load_lines TO authenticated;
GRANT ALL ON TABLE public.load_lines TO service_role;

--
-- Name: SEQUENCE load_lines_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.load_lines_id_seq TO anon;
GRANT ALL ON SEQUENCE public.load_lines_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.load_lines_id_seq TO service_role;

--
-- Name: SEQUENCE load_no_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.load_no_seq TO anon;
GRANT ALL ON SEQUENCE public.load_no_seq TO authenticated;
GRANT ALL ON SEQUENCE public.load_no_seq TO service_role;

--
-- Name: TABLE load_reviews; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.load_reviews TO authenticated;
GRANT ALL ON TABLE public.load_reviews TO service_role;

--
-- Name: TABLE load_tallies; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.load_tallies TO authenticated;
GRANT ALL ON TABLE public.load_tallies TO service_role;

--
-- Name: SEQUENCE load_tallies_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.load_tallies_id_seq TO anon;
GRANT ALL ON SEQUENCE public.load_tallies_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.load_tallies_id_seq TO service_role;

--
-- Name: TABLE loads; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.loads TO authenticated;
GRANT ALL ON TABLE public.loads TO service_role;

--
-- Name: SEQUENCE loads_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.loads_id_seq TO anon;
GRANT ALL ON SEQUENCE public.loads_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.loads_id_seq TO service_role;

--
-- Name: TABLE parties; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.parties TO authenticated;
GRANT ALL ON TABLE public.parties TO service_role;

--
-- Name: SEQUENCE parties_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.parties_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.parties_id_seq TO service_role;

--
-- Name: TABLE payments; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.payments TO authenticated;
GRANT ALL ON TABLE public.payments TO service_role;

--
-- Name: SEQUENCE payments_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.payments_id_seq TO anon;
GRANT ALL ON SEQUENCE public.payments_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.payments_id_seq TO service_role;

--
-- Name: TABLE profiles; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.profiles TO authenticated;
GRANT ALL ON TABLE public.profiles TO service_role;

--
-- Name: TABLE sawmill_rates; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.sawmill_rates TO authenticated;
GRANT ALL ON TABLE public.sawmill_rates TO service_role;

--
-- Name: SEQUENCE sawmill_rates_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.sawmill_rates_id_seq TO anon;
GRANT ALL ON SEQUENCE public.sawmill_rates_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.sawmill_rates_id_seq TO service_role;

--
-- Name: TABLE sawmills; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.sawmills TO authenticated;
GRANT ALL ON TABLE public.sawmills TO service_role;

--
-- Name: SEQUENCE sawmills_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.sawmills_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.sawmills_id_seq TO service_role;

--
-- Name: TABLE v_allocations; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.v_allocations TO authenticated;
GRANT ALL ON TABLE public.v_allocations TO service_role;

--
-- Name: TABLE v_balances; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.v_balances TO authenticated;
GRANT ALL ON TABLE public.v_balances TO service_role;

--
-- Name: TABLE v_lines; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.v_lines TO authenticated;
GRANT ALL ON TABLE public.v_lines TO service_role;

--
-- Name: TABLE v_loads; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.v_loads TO authenticated;
GRANT ALL ON TABLE public.v_loads TO service_role;

--
-- Name: TABLE wood_types; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.wood_types TO authenticated;
GRANT ALL ON TABLE public.wood_types TO service_role;

--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO service_role;

--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO service_role;

--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO service_role;

--
-- PostgreSQL database dump complete
--

-- ---------------------------------------------------------------------------
-- Lookup lists and settings
-- ---------------------------------------------------------------------------

-- Data for Name: app_settings; Type: TABLE DATA; Schema: public; Owner: postgres

INSERT INTO public.app_settings (key, value, label) VALUES ('size_auto', 0, 'Set size grade from length automatically (1 = on)');
INSERT INTO public.app_settings (key, value, label) VALUES ('driver_photo_required', 1, 'Driver photo with truck is compulsory (1 = yes)');
INSERT INTO public.app_settings (key, value, label) VALUES ('weigh_slip_required', 1, 'Every sawmill needs a weigh slip before Loaded (1 = yes)');
INSERT INTO public.app_settings (key, value, label) VALUES ('size_small_below_ft', 3, 'Small: shorter than (ft)');
INSERT INTO public.app_settings (key, value, label) VALUES ('size_large_from_ft', 5, 'Large: from (ft)');
INSERT INTO public.app_settings (key, value, label) VALUES ('tally_len_max_ft', 8.5, 'Tally grid: longest length shown (ft)');
INSERT INTO public.app_settings (key, value, label) VALUES ('tally_width_min_in', 4, 'Tally grid: narrowest width shown (in)');
INSERT INTO public.app_settings (key, value, label) VALUES ('tally_width_max_in', 11, 'Tally grid: widest width shown (in)');

-- Data for Name: expense_categories; Type: TABLE DATA; Schema: public; Owner: postgres

INSERT INTO public.expense_categories (name, sort, active) VALUES ('Truck Freight', 1, true);
INSERT INTO public.expense_categories (name, sort, active) VALUES ('Fuel', 2, true);
INSERT INTO public.expense_categories (name, sort, active) VALUES ('Toll', 3, true);
INSERT INTO public.expense_categories (name, sort, active) VALUES ('Hamali / Loading', 4, true);
INSERT INTO public.expense_categories (name, sort, active) VALUES ('Unloading', 5, true);
INSERT INTO public.expense_categories (name, sort, active) VALUES ('Weighbridge Charges', 6, true);
INSERT INTO public.expense_categories (name, sort, active) VALUES ('Other Travel Expenses', 99, true);

-- Data for Name: wood_types; Type: TABLE DATA; Schema: public; Owner: postgres

INSERT INTO public.wood_types (name, sort, active) VALUES ('Country Wood', 1, true);
INSERT INTO public.wood_types (name, sort, active) VALUES ('Acacia', 2, true);
INSERT INTO public.wood_types (name, sort, active) VALUES ('Teak', 3, true);
INSERT INTO public.wood_types (name, sort, active) VALUES ('Other', 99, true);
INSERT INTO public.wood_types (name, sort, active) VALUES ('Mango', 4, true);

-- ---------------------------------------------------------------------------
-- Sign-up hook: every new login gets a profile (inactive until approved;
-- the very first login becomes the owner).
-- ---------------------------------------------------------------------------
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------------
-- Photos and documents: private bucket. Expense receipts (expenses/...) can only
-- be opened by people who may see money.
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('lorry-files', 'lorry-files', false, 10485760,
        '{image/jpeg,image/png,image/webp,image/heic,image/heif,application/pdf}')
on conflict (id) do nothing;

create policy "lorry files: members upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'lorry-files' and (select public.is_member()));
create policy "lorry files: members read" on storage.objects for select to authenticated
  using (bucket_id = 'lorry-files' and (select public.is_member())
         and (name not like 'expenses/%' or (select public.has_perm('expenses')) or (select public.has_perm('finance'))));
create policy "lorry files: owner or uploader deletes" on storage.objects for delete to authenticated
  using (bucket_id = 'lorry-files' and ((select public.is_owner()) or (owner = (select auth.uid()) and (select public.is_member()))));

-- ---------------------------------------------------------------------------
-- Exact access rights. Supabase grants everything to anon/authenticated on new
-- objects by default; these lines set each table, view, sequence and function
-- to exactly what the app needs (the anonymous key reaches no table at all).
-- ---------------------------------------------------------------------------
revoke all on table public.activity from anon;
revoke all on table public.activity from authenticated; grant REFERENCES, SELECT, TRIGGER, TRUNCATE on table public.activity to authenticated;
revoke all on table public.activity from service_role; grant DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on table public.activity to service_role;
revoke all on sequence public.activity_id_seq from anon; grant SELECT, UPDATE, USAGE on sequence public.activity_id_seq to anon;
revoke all on sequence public.activity_id_seq from authenticated; grant SELECT, UPDATE, USAGE on sequence public.activity_id_seq to authenticated;
revoke all on sequence public.activity_id_seq from service_role; grant SELECT, UPDATE, USAGE on sequence public.activity_id_seq to service_role;
revoke all on table public.app_settings from anon;
revoke all on table public.app_settings from authenticated; grant DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on table public.app_settings to authenticated;
revoke all on table public.app_settings from service_role; grant DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on table public.app_settings to service_role;
revoke all on table public.expense_categories from anon;
revoke all on table public.expense_categories from authenticated; grant DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on table public.expense_categories to authenticated;
revoke all on table public.expense_categories from service_role; grant DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on table public.expense_categories to service_role;
revoke all on table public.line_prices from anon;
revoke all on table public.line_prices from authenticated; grant DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on table public.line_prices to authenticated;
revoke all on table public.line_prices from service_role; grant DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on table public.line_prices to service_role;
revoke all on table public.load_allocations from anon;
revoke all on table public.load_allocations from authenticated; grant DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on table public.load_allocations to authenticated;
revoke all on table public.load_allocations from service_role; grant DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on table public.load_allocations to service_role;
revoke all on sequence public.load_allocations_id_seq from anon; grant SELECT, UPDATE, USAGE on sequence public.load_allocations_id_seq to anon;
revoke all on sequence public.load_allocations_id_seq from authenticated; grant SELECT, UPDATE, USAGE on sequence public.load_allocations_id_seq to authenticated;
revoke all on sequence public.load_allocations_id_seq from service_role; grant SELECT, UPDATE, USAGE on sequence public.load_allocations_id_seq to service_role;
revoke all on table public.load_billing from anon;
revoke all on table public.load_billing from authenticated; grant DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on table public.load_billing to authenticated;
revoke all on table public.load_billing from service_role; grant DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on table public.load_billing to service_role;
revoke all on table public.load_costs from anon;
revoke all on table public.load_costs from authenticated; grant DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on table public.load_costs to authenticated;
revoke all on table public.load_costs from service_role; grant DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on table public.load_costs to service_role;
revoke all on sequence public.load_costs_id_seq from anon; grant SELECT, UPDATE, USAGE on sequence public.load_costs_id_seq to anon;
revoke all on sequence public.load_costs_id_seq from authenticated; grant SELECT, UPDATE, USAGE on sequence public.load_costs_id_seq to authenticated;
revoke all on sequence public.load_costs_id_seq from service_role; grant SELECT, UPDATE, USAGE on sequence public.load_costs_id_seq to service_role;
revoke all on table public.load_files from anon;
revoke all on table public.load_files from authenticated; grant DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on table public.load_files to authenticated;
revoke all on table public.load_files from service_role; grant DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on table public.load_files to service_role;
revoke all on sequence public.load_files_id_seq from anon; grant SELECT, UPDATE, USAGE on sequence public.load_files_id_seq to anon;
revoke all on sequence public.load_files_id_seq from authenticated; grant SELECT, UPDATE, USAGE on sequence public.load_files_id_seq to authenticated;
revoke all on sequence public.load_files_id_seq from service_role; grant SELECT, UPDATE, USAGE on sequence public.load_files_id_seq to service_role;
revoke all on table public.load_lines from anon;
revoke all on table public.load_lines from authenticated; grant DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on table public.load_lines to authenticated;
revoke all on table public.load_lines from service_role; grant DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on table public.load_lines to service_role;
revoke all on sequence public.load_lines_id_seq from anon; grant SELECT, UPDATE, USAGE on sequence public.load_lines_id_seq to anon;
revoke all on sequence public.load_lines_id_seq from authenticated; grant SELECT, UPDATE, USAGE on sequence public.load_lines_id_seq to authenticated;
revoke all on sequence public.load_lines_id_seq from service_role; grant SELECT, UPDATE, USAGE on sequence public.load_lines_id_seq to service_role;
revoke all on sequence public.load_no_seq from anon; grant SELECT, UPDATE, USAGE on sequence public.load_no_seq to anon;
revoke all on sequence public.load_no_seq from authenticated; grant SELECT, UPDATE, USAGE on sequence public.load_no_seq to authenticated;
revoke all on sequence public.load_no_seq from service_role; grant SELECT, UPDATE, USAGE on sequence public.load_no_seq to service_role;
revoke all on table public.load_reviews from anon;
revoke all on table public.load_reviews from authenticated; grant DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on table public.load_reviews to authenticated;
revoke all on table public.load_reviews from service_role; grant DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on table public.load_reviews to service_role;
revoke all on table public.load_tallies from anon;
revoke all on table public.load_tallies from authenticated; grant DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on table public.load_tallies to authenticated;
revoke all on table public.load_tallies from service_role; grant DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on table public.load_tallies to service_role;
revoke all on sequence public.load_tallies_id_seq from anon; grant SELECT, UPDATE, USAGE on sequence public.load_tallies_id_seq to anon;
revoke all on sequence public.load_tallies_id_seq from authenticated; grant SELECT, UPDATE, USAGE on sequence public.load_tallies_id_seq to authenticated;
revoke all on sequence public.load_tallies_id_seq from service_role; grant SELECT, UPDATE, USAGE on sequence public.load_tallies_id_seq to service_role;
revoke all on table public.loads from anon;
revoke all on table public.loads from authenticated; grant DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on table public.loads to authenticated;
revoke all on table public.loads from service_role; grant DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on table public.loads to service_role;
revoke all on sequence public.loads_id_seq from anon; grant SELECT, UPDATE, USAGE on sequence public.loads_id_seq to anon;
revoke all on sequence public.loads_id_seq from authenticated; grant SELECT, UPDATE, USAGE on sequence public.loads_id_seq to authenticated;
revoke all on sequence public.loads_id_seq from service_role; grant SELECT, UPDATE, USAGE on sequence public.loads_id_seq to service_role;
revoke all on table public.parties from anon;
revoke all on table public.parties from authenticated; grant DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on table public.parties to authenticated;
revoke all on table public.parties from service_role; grant DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on table public.parties to service_role;
revoke all on sequence public.parties_id_seq from anon;
revoke all on sequence public.parties_id_seq from authenticated; grant SELECT, UPDATE, USAGE on sequence public.parties_id_seq to authenticated;
revoke all on sequence public.parties_id_seq from service_role; grant SELECT, UPDATE, USAGE on sequence public.parties_id_seq to service_role;
revoke all on table public.payments from anon;
revoke all on table public.payments from authenticated; grant DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on table public.payments to authenticated;
revoke all on table public.payments from service_role; grant DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on table public.payments to service_role;
revoke all on sequence public.payments_id_seq from anon; grant SELECT, UPDATE, USAGE on sequence public.payments_id_seq to anon;
revoke all on sequence public.payments_id_seq from authenticated; grant SELECT, UPDATE, USAGE on sequence public.payments_id_seq to authenticated;
revoke all on sequence public.payments_id_seq from service_role; grant SELECT, UPDATE, USAGE on sequence public.payments_id_seq to service_role;
revoke all on table public.profiles from anon;
revoke all on table public.profiles from authenticated; grant DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on table public.profiles to authenticated;
revoke all on table public.profiles from service_role; grant DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on table public.profiles to service_role;
revoke all on table public.sawmill_rates from anon;
revoke all on table public.sawmill_rates from authenticated; grant DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on table public.sawmill_rates to authenticated;
revoke all on table public.sawmill_rates from service_role; grant DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on table public.sawmill_rates to service_role;
revoke all on sequence public.sawmill_rates_id_seq from anon; grant SELECT, UPDATE, USAGE on sequence public.sawmill_rates_id_seq to anon;
revoke all on sequence public.sawmill_rates_id_seq from authenticated; grant SELECT, UPDATE, USAGE on sequence public.sawmill_rates_id_seq to authenticated;
revoke all on sequence public.sawmill_rates_id_seq from service_role; grant SELECT, UPDATE, USAGE on sequence public.sawmill_rates_id_seq to service_role;
revoke all on table public.sawmills from anon;
revoke all on table public.sawmills from authenticated; grant DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on table public.sawmills to authenticated;
revoke all on table public.sawmills from service_role; grant DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on table public.sawmills to service_role;
revoke all on sequence public.sawmills_id_seq from anon;
revoke all on sequence public.sawmills_id_seq from authenticated; grant SELECT, UPDATE, USAGE on sequence public.sawmills_id_seq to authenticated;
revoke all on sequence public.sawmills_id_seq from service_role; grant SELECT, UPDATE, USAGE on sequence public.sawmills_id_seq to service_role;
revoke all on table public.v_allocations from anon;
revoke all on table public.v_allocations from authenticated; grant DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on table public.v_allocations to authenticated;
revoke all on table public.v_allocations from service_role; grant DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on table public.v_allocations to service_role;
revoke all on table public.v_balances from anon;
revoke all on table public.v_balances from authenticated; grant DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on table public.v_balances to authenticated;
revoke all on table public.v_balances from service_role; grant DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on table public.v_balances to service_role;
revoke all on table public.v_lines from anon;
revoke all on table public.v_lines from authenticated; grant DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on table public.v_lines to authenticated;
revoke all on table public.v_lines from service_role; grant DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on table public.v_lines to service_role;
revoke all on table public.v_loads from anon;
revoke all on table public.v_loads from authenticated; grant DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on table public.v_loads to authenticated;
revoke all on table public.v_loads from service_role; grant DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on table public.v_loads to service_role;
revoke all on table public.wood_types from anon;
revoke all on table public.wood_types from authenticated; grant DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on table public.wood_types to authenticated;
revoke all on table public.wood_types from service_role; grant DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on table public.wood_types to service_role;
revoke all on function public.v2_stamp() from public; grant execute on function public.v2_stamp() to public;
revoke all on function public.jsonb_diff(o jsonb, n jsonb, skip text[]) from public;
revoke all on function public.is_member() from public;
revoke all on function public.is_owner() from public;
revoke all on function public.handle_new_user() from public;
revoke all on function public.v2_touch(p_load bigint) from public;
revoke all on function public.v2_log() from public;
revoke all on function public.v2_setting(p_key text) from public;
revoke all on function public.v2_mark_checked(p_load_ids bigint[]) from public;
revoke all on function public.v2_line_rules() from public;
revoke all on function public.v2_stage_rules() from public;
revoke all on function public.v2_alloc_rules() from public;
revoke all on function public.size_grade_for(len numeric) from public;
revoke all on function public.v2_profile_guard() from public;
revoke all on function public.is_admin() from public;
revoke all on function public.v2_item_alloc() from public;
revoke all on function public.v2_has_driver_photo(p_load bigint) from public;
revoke all on function public.v2_file_rules() from public;
revoke all on function public.v2_expense_rules() from public;
revoke all on function public.has_perm(p text) from public;
revoke all on function public.v2_post_note(p_load bigint, p_message text, p_admin_only boolean) from public;
revoke all on function public.v2_tally_clean(p jsonb) from public; grant execute on function public.v2_tally_clean(p jsonb) to public;
revoke all on function public.v2_tally_totals(p jsonb) from public; grant execute on function public.v2_tally_totals(p jsonb) to public;
revoke all on function public.v2_tally_rules() from public;
revoke all on function public.v2_tally_items() from public;
revoke all on function public.v2_stamp() from anon; grant execute on function public.v2_stamp() to anon;
revoke all on function public.v2_stamp() from authenticated; grant execute on function public.v2_stamp() to authenticated;
revoke all on function public.v2_stamp() from service_role; grant execute on function public.v2_stamp() to service_role;
revoke all on function public.jsonb_diff(o jsonb, n jsonb, skip text[]) from anon;
revoke all on function public.jsonb_diff(o jsonb, n jsonb, skip text[]) from authenticated; grant execute on function public.jsonb_diff(o jsonb, n jsonb, skip text[]) to authenticated;
revoke all on function public.jsonb_diff(o jsonb, n jsonb, skip text[]) from service_role; grant execute on function public.jsonb_diff(o jsonb, n jsonb, skip text[]) to service_role;
revoke all on function public.is_member() from anon;
revoke all on function public.is_member() from authenticated; grant execute on function public.is_member() to authenticated;
revoke all on function public.is_member() from service_role; grant execute on function public.is_member() to service_role;
revoke all on function public.is_owner() from anon;
revoke all on function public.is_owner() from authenticated; grant execute on function public.is_owner() to authenticated;
revoke all on function public.is_owner() from service_role; grant execute on function public.is_owner() to service_role;
revoke all on function public.handle_new_user() from anon;
revoke all on function public.handle_new_user() from authenticated;
revoke all on function public.handle_new_user() from service_role; grant execute on function public.handle_new_user() to service_role;
revoke all on function public.v2_touch(p_load bigint) from anon;
revoke all on function public.v2_touch(p_load bigint) from authenticated;
revoke all on function public.v2_touch(p_load bigint) from service_role; grant execute on function public.v2_touch(p_load bigint) to service_role;
revoke all on function public.v2_log() from anon;
revoke all on function public.v2_log() from authenticated;
revoke all on function public.v2_log() from service_role; grant execute on function public.v2_log() to service_role;
revoke all on function public.v2_setting(p_key text) from anon;
revoke all on function public.v2_setting(p_key text) from authenticated; grant execute on function public.v2_setting(p_key text) to authenticated;
revoke all on function public.v2_setting(p_key text) from service_role; grant execute on function public.v2_setting(p_key text) to service_role;
revoke all on function public.v2_mark_checked(p_load_ids bigint[]) from anon;
revoke all on function public.v2_mark_checked(p_load_ids bigint[]) from authenticated; grant execute on function public.v2_mark_checked(p_load_ids bigint[]) to authenticated;
revoke all on function public.v2_mark_checked(p_load_ids bigint[]) from service_role; grant execute on function public.v2_mark_checked(p_load_ids bigint[]) to service_role;
revoke all on function public.v2_line_rules() from anon;
revoke all on function public.v2_line_rules() from authenticated;
revoke all on function public.v2_line_rules() from service_role; grant execute on function public.v2_line_rules() to service_role;
revoke all on function public.v2_stage_rules() from anon;
revoke all on function public.v2_stage_rules() from authenticated;
revoke all on function public.v2_stage_rules() from service_role; grant execute on function public.v2_stage_rules() to service_role;
revoke all on function public.v2_alloc_rules() from anon;
revoke all on function public.v2_alloc_rules() from authenticated;
revoke all on function public.v2_alloc_rules() from service_role; grant execute on function public.v2_alloc_rules() to service_role;
revoke all on function public.size_grade_for(len numeric) from anon;
revoke all on function public.size_grade_for(len numeric) from authenticated; grant execute on function public.size_grade_for(len numeric) to authenticated;
revoke all on function public.size_grade_for(len numeric) from service_role; grant execute on function public.size_grade_for(len numeric) to service_role;
revoke all on function public.v2_profile_guard() from anon;
revoke all on function public.v2_profile_guard() from authenticated;
revoke all on function public.v2_profile_guard() from service_role; grant execute on function public.v2_profile_guard() to service_role;
revoke all on function public.is_admin() from anon;
revoke all on function public.is_admin() from authenticated; grant execute on function public.is_admin() to authenticated;
revoke all on function public.is_admin() from service_role; grant execute on function public.is_admin() to service_role;
revoke all on function public.v2_item_alloc() from anon;
revoke all on function public.v2_item_alloc() from authenticated;
revoke all on function public.v2_item_alloc() from service_role; grant execute on function public.v2_item_alloc() to service_role;
revoke all on function public.v2_has_driver_photo(p_load bigint) from anon;
revoke all on function public.v2_has_driver_photo(p_load bigint) from authenticated; grant execute on function public.v2_has_driver_photo(p_load bigint) to authenticated;
revoke all on function public.v2_has_driver_photo(p_load bigint) from service_role; grant execute on function public.v2_has_driver_photo(p_load bigint) to service_role;
revoke all on function public.v2_file_rules() from anon;
revoke all on function public.v2_file_rules() from authenticated;
revoke all on function public.v2_file_rules() from service_role; grant execute on function public.v2_file_rules() to service_role;
revoke all on function public.v2_expense_rules() from anon;
revoke all on function public.v2_expense_rules() from authenticated;
revoke all on function public.v2_expense_rules() from service_role; grant execute on function public.v2_expense_rules() to service_role;
revoke all on function public.has_perm(p text) from anon;
revoke all on function public.has_perm(p text) from authenticated; grant execute on function public.has_perm(p text) to authenticated;
revoke all on function public.has_perm(p text) from service_role; grant execute on function public.has_perm(p text) to service_role;
revoke all on function public.v2_post_note(p_load bigint, p_message text, p_admin_only boolean) from anon;
revoke all on function public.v2_post_note(p_load bigint, p_message text, p_admin_only boolean) from authenticated; grant execute on function public.v2_post_note(p_load bigint, p_message text, p_admin_only boolean) to authenticated;
revoke all on function public.v2_post_note(p_load bigint, p_message text, p_admin_only boolean) from service_role; grant execute on function public.v2_post_note(p_load bigint, p_message text, p_admin_only boolean) to service_role;
revoke all on function public.v2_tally_clean(p jsonb) from anon; grant execute on function public.v2_tally_clean(p jsonb) to anon;
revoke all on function public.v2_tally_clean(p jsonb) from authenticated; grant execute on function public.v2_tally_clean(p jsonb) to authenticated;
revoke all on function public.v2_tally_clean(p jsonb) from service_role; grant execute on function public.v2_tally_clean(p jsonb) to service_role;
revoke all on function public.v2_tally_totals(p jsonb) from anon; grant execute on function public.v2_tally_totals(p jsonb) to anon;
revoke all on function public.v2_tally_totals(p jsonb) from authenticated; grant execute on function public.v2_tally_totals(p jsonb) to authenticated;
revoke all on function public.v2_tally_totals(p jsonb) from service_role; grant execute on function public.v2_tally_totals(p jsonb) to service_role;
revoke all on function public.v2_tally_rules() from anon;
revoke all on function public.v2_tally_rules() from authenticated;
revoke all on function public.v2_tally_rules() from service_role; grant execute on function public.v2_tally_rules() to service_role;
revoke all on function public.v2_tally_items() from anon;
revoke all on function public.v2_tally_items() from authenticated;
revoke all on function public.v2_tally_items() from service_role; grant execute on function public.v2_tally_items() to service_role;

commit;
