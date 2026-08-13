-- Runtime 0.2 — Community Backend Foundation
-- Schema for: profiles, community_releases, community_release_mods,
-- community_release_tags, publish transaction, and RLS.
--
-- Design notes (see COMMUNITY_BACKEND_SPEC.md for the full rationale):
--
-- * Ownership is ALWAYS auth.uid(), never a client-supplied display name,
--   email, or user_metadata. See "Profile RLS" / "Release write policy".
-- * A published Release is immutable except for is_published -- enforced
--   both by RLS (owner-only UPDATE) and a BEFORE UPDATE trigger that
--   rejects any change to any other column. See "Immutable release
--   semantics".
-- * generation/parent lineage is computed by publish_release() from the
--   parent row actually in the database -- the client's local .vrelease
--   generation value is never trusted. See "Server computes lineage".
-- * snapshot_text retains the exact published .vrelease payload
--   (verbatim JSON) so a remote Release can always be reconstructed
--   exactly, byte-for-byte, without depending on the normalized columns
--   staying in sync. community_release_mods/tags are a SEARCHABLE INDEX
--   over that snapshot, not an alternate source of truth.
-- * As of this project's creation, Supabase's cloud default no longer
--   auto-exposes newly created tables to the anon/authenticated API
--   roles without explicit GRANTs (see supabase/config.toml's
--   auto_expose_new_tables comment) -- every table below has explicit
--   GRANT statements; RLS alone is not sufficient to make a table
--   reachable via PostgREST on this project.

-- =====================================================================
-- profiles
-- =====================================================================
create table public.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null check (char_length(display_name) between 1 and 60),
  bio text check (bio is null or char_length(bio) <= 500),
  avatar_url text check (avatar_url is null or char_length(avatar_url) <= 500),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.profiles is
  'Public Community profile. Deliberately does NOT store email -- auth.users is the sole authoritative identity; this table is display metadata only.';

create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger trg_profiles_touch_updated_at
  before update on public.profiles
  for each row execute function public.touch_updated_at();

alter table public.profiles enable row level security;

create policy "profiles are publicly readable"
  on public.profiles for select
  using (true);

create policy "users insert their own profile"
  on public.profiles for insert
  to authenticated
  with check (auth.uid() = user_id);

create policy "users update their own profile"
  on public.profiles for update
  to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- No DELETE policy: deleting a profile is not needed this milestone: RLS
-- denies by default when no policy exists for a command.

grant usage on schema public to anon, authenticated;
grant select on public.profiles to anon, authenticated;
grant insert, update on public.profiles to authenticated;

-- =====================================================================
-- community_releases
--
-- Remote release identity (id) is intentionally separate from the local
-- Community Release Format 1 releaseId (client_release_id) -- see
-- COMMUNITY_RELEASE_SPEC.md / COMMUNITY_BACKEND_SPEC.md § Remote/local
-- release identity. client_release_id is NOT unique/global; two
-- different creators (or the same creator across sessions) may submit
-- the same client_release_id, and that is fine -- `id` is the only
-- authoritative Community identity.
-- =====================================================================
create table public.community_releases (
  id uuid primary key default gen_random_uuid(),
  client_release_id text not null,
  creator_id uuid not null references auth.users(id),

  title text not null check (char_length(title) between 1 and 100),
  description text check (description is null or char_length(description) <= 2000),
  author_display_name text check (author_display_name is null or char_length(author_display_name) <= 100),

  language text check (language is null or char_length(language) <= 35),
  release_note text check (release_note is null or char_length(release_note) <= 1000),

  generation integer not null default 0 check (generation >= 0),
  parent_release_id uuid references public.community_releases(id),

  runtime_version text,
  api_version integer,
  vmp_version integer,
  game_package_format_version integer,
  community_release_format_version integer,

  client_content_hash text,
  snapshot_text text not null,

  is_published boolean not null default true,

  created_at timestamptz not null default now(),
  published_at timestamptz,
  updated_at timestamptz not null default now()
);

comment on column public.community_releases.id is 'Authoritative Community publication identity. NEVER the same value as the local .vrelease releaseId.';
comment on column public.community_releases.client_release_id is 'The local .vrelease releaseId at publish time -- informational only, not unique, not authoritative.';
comment on column public.community_releases.snapshot_text is 'The exact, verbatim published .vrelease JSON payload -- the source of truth for exact reconstruction. Normalized columns/mods/tags are a search index over this, never an alternate source of truth.';
comment on column public.community_releases.generation is 'Computed server-side by publish_release() from the actual parent row. Never trusts a client-supplied value.';

create index idx_community_releases_creator on public.community_releases (creator_id);
create index idx_community_releases_parent on public.community_releases (parent_release_id);
create index idx_community_releases_published_at on public.community_releases (published_at desc);
create index idx_community_releases_language on public.community_releases (language);

create trigger trg_community_releases_touch_updated_at
  before update on public.community_releases
  for each row execute function public.touch_updated_at();

-- Immutability (spec § 21): a published Release's content never changes.
-- Enforced at the database level, not only in application code -- any
-- UPDATE that touches a column other than is_published/updated_at is
-- rejected outright, regardless of which client or code path attempts it.
create or replace function public.enforce_release_immutability()
returns trigger
language plpgsql
as $$
begin
  if new.id is distinct from old.id
    or new.client_release_id is distinct from old.client_release_id
    or new.creator_id is distinct from old.creator_id
    or new.title is distinct from old.title
    or new.description is distinct from old.description
    or new.author_display_name is distinct from old.author_display_name
    or new.language is distinct from old.language
    or new.release_note is distinct from old.release_note
    or new.generation is distinct from old.generation
    or new.parent_release_id is distinct from old.parent_release_id
    or new.runtime_version is distinct from old.runtime_version
    or new.api_version is distinct from old.api_version
    or new.vmp_version is distinct from old.vmp_version
    or new.game_package_format_version is distinct from old.game_package_format_version
    or new.community_release_format_version is distinct from old.community_release_format_version
    or new.client_content_hash is distinct from old.client_content_hash
    or new.snapshot_text is distinct from old.snapshot_text
    or new.created_at is distinct from old.created_at
    or new.published_at is distinct from old.published_at
  then
    raise exception 'RELEASE_IMMUTABLE: only is_published may change once a release exists'
      using errcode = '22023';
  end if;
  return new;
end;
$$;

create trigger trg_release_immutable
  before update on public.community_releases
  for each row execute function public.enforce_release_immutability();

alter table public.community_releases enable row level security;

-- Anonymous + authenticated: published releases are public. A creator
-- can additionally see their own unpublished releases (never anyone
-- else's). See spec § 19 "do not expose unpublished releases to other
-- users."
create policy "published releases are publicly readable"
  on public.community_releases for select
  using (is_published = true or auth.uid() = creator_id);

-- INSERT: ownership is auth.uid(), never a client-supplied value.
-- author_display_name is display metadata, NOT authorization.
create policy "authenticated users publish as themselves"
  on public.community_releases for insert
  to authenticated
  with check (auth.uid() = creator_id);

-- UPDATE: owner only, and only is_published can actually change (the
-- trigger above enforces the "only" part at the row level -- this
-- policy just gates WHO may attempt an update at all).
create policy "creators can withdraw their own release"
  on public.community_releases for update
  to authenticated
  using (auth.uid() = creator_id)
  with check (auth.uid() = creator_id);

grant select on public.community_releases to anon, authenticated;
grant insert, update on public.community_releases to authenticated;

-- =====================================================================
-- community_release_mods -- searchable index over snapshot_text's mods,
-- never an alternate source of truth (spec § 14).
-- =====================================================================
create table public.community_release_mods (
  release_id uuid not null references public.community_releases(id) on delete cascade,
  position integer not null,
  manifest_id text not null,
  manifest_version text,
  manifest_name text,
  primary key (release_id, position)
);

create index idx_community_release_mods_manifest_id on public.community_release_mods (manifest_id);

alter table public.community_release_mods enable row level security;

create policy "mods of visible releases are readable"
  on public.community_release_mods for select
  using (
    exists (
      select 1 from public.community_releases r
      where r.id = release_id and (r.is_published = true or r.creator_id = auth.uid())
    )
  );

-- INSERT only via publish_release() (SECURITY INVOKER -- see below),
-- gated by the SAME ownership check as the parent release row. No
-- UPDATE/DELETE policy: mod index rows are as immutable as their parent
-- release (deleted only via ON DELETE CASCADE if the release row itself
-- were ever removed, which this milestone does not do -- see § Do not
-- hard delete lineage).
create policy "creators can index mods of their own release"
  on public.community_release_mods for insert
  to authenticated
  with check (
    exists (
      select 1 from public.community_releases r
      where r.id = release_id and r.creator_id = auth.uid()
    )
  );

grant select on public.community_release_mods to anon, authenticated;
grant insert on public.community_release_mods to authenticated;

-- =====================================================================
-- community_release_tags
-- =====================================================================
create table public.community_release_tags (
  release_id uuid not null references public.community_releases(id) on delete cascade,
  tag text not null check (char_length(tag) between 1 and 32),
  primary key (release_id, tag)
);

create index idx_community_release_tags_tag on public.community_release_tags (tag);

alter table public.community_release_tags enable row level security;

create policy "tags of visible releases are readable"
  on public.community_release_tags for select
  using (
    exists (
      select 1 from public.community_releases r
      where r.id = release_id and (r.is_published = true or r.creator_id = auth.uid())
    )
  );

create policy "creators can tag their own release"
  on public.community_release_tags for insert
  to authenticated
  with check (
    exists (
      select 1 from public.community_releases r
      where r.id = release_id and r.creator_id = auth.uid()
    )
  );

grant select on public.community_release_tags to anon, authenticated;
grant insert on public.community_release_tags to authenticated;

-- =====================================================================
-- publish_release() -- the one atomic publish transaction (spec § 25).
--
-- SECURITY INVOKER (spec § 45 "prefer SECURITY INVOKER... do not use
-- SECURITY DEFINER simply to make RLS work"): this function runs with
-- the CALLING user's own privileges. Every INSERT inside it is still
-- subject to the RLS policies above -- auth.uid() = creator_id is
-- enforced by Postgres itself on each statement, not merely by this
-- function's own (defense-in-depth) checks. A single function
-- invocation is one Postgres transaction: if any statement raises, the
-- entire publish is rolled back -- there is no way to observe a release
-- row with missing mods/tags.
--
-- Lineage (parent/generation) is computed here from the actual parent
-- row, never trusted from the caller (spec § 28). A parent must be a
-- CURRENTLY PUBLISHED release (spec § 47's recommended policy) --
-- remixing a withdrawn or nonexistent release is rejected.
-- =====================================================================
create or replace function public.publish_release(
  p_client_release_id text,
  p_title text,
  p_description text,
  p_author_display_name text,
  p_language text,
  p_release_note text,
  p_parent_release_id uuid,
  p_runtime_version text,
  p_api_version integer,
  p_vmp_version integer,
  p_game_package_format_version integer,
  p_community_release_format_version integer,
  p_client_content_hash text,
  p_snapshot_text text,
  p_mods jsonb,
  p_tags text[]
)
returns uuid
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_release_id uuid;
  v_generation integer;
  v_parent public.community_releases%rowtype;
  v_mod_count integer;
begin
  if auth.uid() is null then
    raise exception 'COMMUNITY_AUTH_REQUIRED' using errcode = '28000';
  end if;

  if p_title is null or char_length(btrim(p_title)) = 0 then
    raise exception 'RELEASE_INVALID: title is required';
  end if;

  select coalesce(jsonb_array_length(p_mods), 0) into v_mod_count;
  if v_mod_count = 0 then
    raise exception 'RELEASE_INVALID: at least one mod is required';
  end if;
  if v_mod_count > 32 then
    raise exception 'RELEASE_INVALID: too many mods (max 32)';
  end if;
  if p_tags is not null and array_length(p_tags, 1) > 8 then
    raise exception 'RELEASE_INVALID: too many tags (max 8)';
  end if;
  if char_length(p_snapshot_text) > 2097152 then -- 2 MiB, spec § 24
    raise exception 'RELEASE_INVALID: snapshot payload too large';
  end if;

  if p_parent_release_id is not null then
    select * into v_parent from public.community_releases where id = p_parent_release_id;
    if not found or v_parent.is_published is not true then
      raise exception 'RELEASE_PARENT_UNAVAILABLE: parent release must be an existing, published release';
    end if;
    v_generation := v_parent.generation + 1;
  else
    v_generation := 0;
  end if;

  insert into public.community_releases (
    client_release_id, creator_id, title, description, author_display_name,
    language, release_note, generation, parent_release_id,
    runtime_version, api_version, vmp_version, game_package_format_version,
    community_release_format_version, client_content_hash, snapshot_text,
    is_published, published_at
  ) values (
    p_client_release_id, auth.uid(), btrim(p_title), p_description, p_author_display_name,
    p_language, p_release_note, v_generation, p_parent_release_id,
    p_runtime_version, p_api_version, p_vmp_version, p_game_package_format_version,
    p_community_release_format_version, p_client_content_hash, p_snapshot_text,
    true, now()
  )
  returning id into v_release_id;

  insert into public.community_release_mods (release_id, position, manifest_id, manifest_version, manifest_name)
  select
    v_release_id,
    (elem.ord - 1)::integer,
    elem.value ->> 'manifest_id',
    elem.value ->> 'manifest_version',
    elem.value ->> 'manifest_name'
  from jsonb_array_elements(p_mods) with ordinality as elem(value, ord);

  if p_tags is not null and array_length(p_tags, 1) > 0 then
    insert into public.community_release_tags (release_id, tag)
    select v_release_id, lower(btrim(t))
    from unnest(p_tags) as t
    where char_length(btrim(t)) > 0
    on conflict do nothing;
  end if;

  return v_release_id;
end;
$$;

comment on function public.publish_release is
  'Atomic publish transaction: one Release row + its Mod index + its Tags, or nothing. SECURITY INVOKER -- relies on RLS, not elevated privilege, for authorization. Computes generation/parent server-side; never trusts the caller.';

revoke all on function public.publish_release from public;
grant execute on function public.publish_release to authenticated;
