-- Runtime 0.2 — Community Discovery & Release Pages
--
-- A single read-model view, community_release_cards, so a page of N
-- Release cards can be fetched in ONE query instead of 1 (list) + N
-- (mod count) + N (tags) + N (remix count) queries (spec § 47 "No N+1
-- explosion"). Verified against current Supabase/Postgres guidance
-- before writing this (Supabase Docs "Row Level Security" +
-- "Postgres Views: The Hidden Security Gotcha in Supabase", both August
-- 2026): a plain view runs as its OWNER by default, silently bypassing
-- the underlying tables' RLS -- `security_invoker = true` (Postgres 15+;
-- this project runs Postgres 17) is the documented fix, making the view
-- evaluate entirely under the CALLING role's own RLS, exactly like a
-- direct table query would. This is deliberately NOT a SECURITY DEFINER
-- shortcut -- no elevated privilege is introduced anywhere in this
-- migration.
--
-- Every subquery below (mod_count/tags/remix_count/parent_title) reads
-- from community_releases/community_release_mods/community_release_tags
-- -- tables that already have their own RLS policies (see
-- COMMUNITY_BACKEND_SPEC.md § 5) -- and because the view itself is
-- security_invoker, those subqueries run under the SAME calling role,
-- so the view can never leak an unpublished release, an unpublished
-- parent's title, or an unpublished release into a remix_count. A
-- withdrawn/inaccessible parent's title subquery simply returns NULL to
-- an anonymous caller, which the UI renders as "original release
-- unavailable" -- never a broken page (spec § 19/85).

create view public.community_release_cards
with (security_invoker = true) as
select
  r.id,
  r.client_release_id,
  r.creator_id,
  r.title,
  r.description,
  r.author_display_name,
  r.language,
  r.release_note,
  r.generation,
  r.parent_release_id,
  (
    select p.title from public.community_releases p where p.id = r.parent_release_id
  ) as parent_title,
  r.runtime_version,
  r.api_version,
  r.vmp_version,
  r.game_package_format_version,
  r.community_release_format_version,
  r.is_published,
  r.published_at,
  r.created_at,
  (
    select count(*)::int from public.community_release_mods m where m.release_id = r.id
  ) as mod_count,
  (
    select coalesce(array_agg(t.tag order by t.tag), '{}'::text[])
    from public.community_release_tags t where t.release_id = r.id
  ) as tags,
  (
    select count(*)::int from public.community_releases c
    where c.parent_release_id = r.id and c.is_published = true
  ) as remix_count
from public.community_releases r;

comment on view public.community_release_cards is
  'Read model for Discovery card lists and Release detail pages -- security_invoker so every row/subquery still enforces community_releases/community_release_mods/community_release_tags RLS under the CALLING role. Never grant this view to a role without also trusting the underlying tables'' RLS: it adds no privilege of its own.';

-- Same "not auto-exposed without explicit GRANT" default that already
-- applied to every base table in this project (see
-- COMMUNITY_BACKEND_SPEC.md § 5) applies to views too.
grant select on public.community_release_cards to anon, authenticated;
