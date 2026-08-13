-- Fixes for issues raised by `supabase db advisors --linked` after the
-- initial schema migration (Acceptance Test B):
--
-- 1. function_search_path_mutable (SECURITY, WARN): touch_updated_at and
--    enforce_release_immutability did not pin search_path, which lets a
--    caller-controlled search_path influence unqualified name
--    resolution inside the function. Fix: set search_path = public,
--    matching what publish_release() already did.
-- 2. auth_rls_initplan (PERFORMANCE, WARN): RLS policies calling
--    auth.uid() directly cause it to be re-evaluated per row instead of
--    once per query. Fix: wrap every auth.uid() call in RLS policies as
--    (select auth.uid()), which Postgres can evaluate as an InitPlan.
--
-- (unused_index INFO findings are expected pre-launch noise -- there is
-- no data yet for the planner to have used the indexes against -- and
-- are not fixed here; see COMMUNITY_BACKEND_SPEC.md.)

create or replace function public.touch_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create or replace function public.enforce_release_immutability()
returns trigger
language plpgsql
set search_path = public
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

-- profiles
drop policy "users insert their own profile" on public.profiles;
create policy "users insert their own profile"
  on public.profiles for insert
  to authenticated
  with check ((select auth.uid()) = user_id);

drop policy "users update their own profile" on public.profiles;
create policy "users update their own profile"
  on public.profiles for update
  to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

-- community_releases
drop policy "published releases are publicly readable" on public.community_releases;
create policy "published releases are publicly readable"
  on public.community_releases for select
  using (is_published = true or (select auth.uid()) = creator_id);

drop policy "authenticated users publish as themselves" on public.community_releases;
create policy "authenticated users publish as themselves"
  on public.community_releases for insert
  to authenticated
  with check ((select auth.uid()) = creator_id);

drop policy "creators can withdraw their own release" on public.community_releases;
create policy "creators can withdraw their own release"
  on public.community_releases for update
  to authenticated
  using ((select auth.uid()) = creator_id)
  with check ((select auth.uid()) = creator_id);

-- community_release_mods
drop policy "mods of visible releases are readable" on public.community_release_mods;
create policy "mods of visible releases are readable"
  on public.community_release_mods for select
  using (
    exists (
      select 1 from public.community_releases r
      where r.id = release_id and (r.is_published = true or r.creator_id = (select auth.uid()))
    )
  );

drop policy "creators can index mods of their own release" on public.community_release_mods;
create policy "creators can index mods of their own release"
  on public.community_release_mods for insert
  to authenticated
  with check (
    exists (
      select 1 from public.community_releases r
      where r.id = release_id and r.creator_id = (select auth.uid())
    )
  );

-- community_release_tags
drop policy "tags of visible releases are readable" on public.community_release_tags;
create policy "tags of visible releases are readable"
  on public.community_release_tags for select
  using (
    exists (
      select 1 from public.community_releases r
      where r.id = release_id and (r.is_published = true or r.creator_id = (select auth.uid()))
    )
  );

drop policy "creators can tag their own release" on public.community_release_tags;
create policy "creators can tag their own release"
  on public.community_release_tags for insert
  to authenticated
  with check (
    exists (
      select 1 from public.community_releases r
      where r.id = release_id and r.creator_id = (select auth.uid())
    )
  );
