-- Per-guest RSVP limits.  Run once in Supabase -> SQL Editor.
-- max_adults   : how many adults this invite covers (default 2 = guest + 1)
-- max_children : how many children are allowed (empty = no limit, 0 = no children)

alter table guests add column if not exists max_adults   int not null default 2;
alter table guests add column if not exists max_children int;

-- the page needs to know each guest's limits
create or replace function get_invite(p_token text) returns json
language sql security definer set search_path = public as $$
  select json_build_object(
    'name', g.display_name, 'language', g.language, 'note', g.note,
    'is_public', g.is_public,
    'max_adults', g.max_adults, 'max_children', g.max_children,
    'attending', g.attending, 'adults', g.adults, 'children', g.children,
    'venue', case when g.attending and not g.is_public
                  then (select row_to_json(v) from venue v where v.id = 1) end
  ) from guests g where g.token = p_token;
$$;

-- RSVP: enforce this guest's limits
create or replace function submit_rsvp(p_token text, p_attending boolean, p_adults int, p_children int)
returns json language plpgsql security definer set search_path = public as $$
declare g guests%rowtype;
begin
  select * into g from guests where token = p_token;
  if not found then raise exception 'Invite not found'; end if;
  if g.is_public then raise exception 'Please enter your name'; end if;
  if p_attending and coalesce(p_adults, 0) not between 1 and g.max_adults then
    raise exception 'This invitation is for up to % adult(s)', g.max_adults;
  end if;
  if p_attending and coalesce(p_children, 0) < 0 then raise exception 'Children cannot be negative'; end if;
  if p_attending and g.max_children is not null and coalesce(p_children, 0) > g.max_children then
    raise exception 'This invitation is for up to % child(ren)', g.max_children;
  end if;
  update guests set attending = p_attending,
         adults   = case when p_attending then p_adults else 0 end,
         children = case when p_attending then coalesce(p_children, 0) else 0 end,
         responded_at = now()
  where token = p_token;
  return get_invite(p_token);
end $$;

-- public link (/jemput): people who sign up there get the public invite's limits
create or replace function public_rsvp(p_code text, p_name text, p_attending boolean, p_adults int, p_children int)
returns json language plpgsql security definer set search_path = public as $$
declare pub guests%rowtype; new_token text := substr(md5(random()::text || clock_timestamp()::text), 1, 10);
begin
  select * into pub from guests where token = p_code and is_public;
  if not found then raise exception 'Invite not found'; end if;
  if length(trim(coalesce(p_name, ''))) = 0 then raise exception 'Please enter your name'; end if;
  if p_attending and coalesce(p_adults, 0) not between 1 and pub.max_adults then
    raise exception 'This invitation is for up to % adult(s)', pub.max_adults;
  end if;
  if p_attending and pub.max_children is not null and coalesce(p_children, 0) > pub.max_children then
    raise exception 'This invitation is for up to % child(ren)', pub.max_children;
  end if;
  insert into guests (token, display_name, language, attending, adults, children, responded_at, source, max_adults, max_children)
  values (new_token, left(trim(p_name), 60), pub.language, p_attending,
          case when p_attending then p_adults else 0 end,
          case when p_attending then coalesce(p_children, 0) else 0 end, now(), 'public', pub.max_adults, pub.max_children);
  return (get_invite(new_token)::jsonb || jsonb_build_object('token', new_token))::json;
end $$;
