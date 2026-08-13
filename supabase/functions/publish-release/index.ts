// publish-release: validates an uploaded .vrelease payload structurally,
// then calls the publish_release() RPC as the CALLING USER (never as an
// admin/service-role client) so that Postgres RLS and auth.uid() apply
// exactly as they would to a direct authenticated REST call. This
// function holds no elevated privilege of its own -- it only adds
// structural validation and a stable error-code contract in front of
// the RPC. See COMMUNITY_BACKEND_SPEC.md "Publishing transaction design".
//
// SECURITY: this function is constructed with SUPABASE_ANON_KEY (the
// publishable key), never SUPABASE_SERVICE_ROLE_KEY/secret key. The
// caller's own Authorization header is forwarded into the client so
// every RPC call runs under the CALLER's row-level-security context,
// not this function's.

import "@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const MAX_SNAPSHOT_BYTES = 2 * 1024 * 1024; // 2 MiB
const MAX_MOD_COUNT = 32;
const MAX_MOD_SOURCE_BYTES = 256 * 1024; // 256 KiB
const MAX_TITLE_LEN = 100;
const MAX_DESCRIPTION_LEN = 2000;
const MAX_RELEASE_NOTE_LEN = 1000;
const MAX_TAG_COUNT = 8;
const MAX_TAG_LEN = 32;
const SUPPORTED_FORMAT_VERSIONS = [1];

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

function errorResponse(status: number, code: string, message: string): Response {
  return jsonResponse(status, { error: { code, message } });
}

function byteLength(s: string): number {
  return new TextEncoder().encode(s).length;
}

function isNonEmptyString(v: unknown): v is string {
  return typeof v === "string" && v.length > 0;
}

// Structural validation only -- mirrors COMMUNITY_RELEASE_SPEC.md § 3/18.
// This never trusts the client for authorization or lineage; it only
// rejects obviously-malformed/oversized payloads before they reach the
// database. The publish_release() RPC re-derives generation/parent
// itself and is the actual authority.
function validateReleasePayload(raw: string): { ok: true; release: any } | { ok: false; code: string; message: string } {
  if (byteLength(raw) > MAX_SNAPSHOT_BYTES) {
    return { ok: false, code: "COMMUNITY_RELEASE_INVALID", message: "Release payload exceeds the 2 MiB size limit." };
  }

  let release: any;
  try {
    release = JSON.parse(raw);
  } catch {
    return { ok: false, code: "COMMUNITY_RELEASE_INVALID", message: "Release payload is not valid JSON." };
  }

  if (release?.format !== "voxel-release") {
    return { ok: false, code: "COMMUNITY_RELEASE_INVALID", message: "Unsupported release format." };
  }
  if (!SUPPORTED_FORMAT_VERSIONS.includes(release?.formatVersion)) {
    return { ok: false, code: "COMMUNITY_RELEASE_INVALID", message: "Unsupported release format version." };
  }
  if (!isNonEmptyString(release?.releaseId)) {
    return { ok: false, code: "COMMUNITY_RELEASE_INVALID", message: "Release is missing releaseId." };
  }

  const game = release?.game;
  if (!game || !isNonEmptyString(game.title)) {
    return { ok: false, code: "COMMUNITY_RELEASE_INVALID", message: "Release is missing game.title." };
  }
  if (game.title.length > MAX_TITLE_LEN) {
    return { ok: false, code: "COMMUNITY_RELEASE_INVALID", message: "game.title exceeds the length limit." };
  }
  if (typeof game.description === "string" && game.description.length > MAX_DESCRIPTION_LEN) {
    return { ok: false, code: "COMMUNITY_RELEASE_INVALID", message: "game.description exceeds the length limit." };
  }
  if (typeof game.authorDisplayName === "string" && game.authorDisplayName.length > 100) {
    return { ok: false, code: "COMMUNITY_RELEASE_INVALID", message: "game.authorDisplayName exceeds the length limit." };
  }

  const mods = release?.mods;
  if (!Array.isArray(mods) || mods.length === 0) {
    return { ok: false, code: "COMMUNITY_RELEASE_INVALID", message: "Release must contain at least one mod." };
  }
  if (mods.length > MAX_MOD_COUNT) {
    return { ok: false, code: "COMMUNITY_RELEASE_INVALID", message: `Release exceeds the ${MAX_MOD_COUNT}-mod limit.` };
  }
  for (const m of mods) {
    if (!isNonEmptyString(m?.source)) {
      return { ok: false, code: "COMMUNITY_RELEASE_INVALID", message: "A mod entry is missing its source." };
    }
    if (byteLength(m.source) > MAX_MOD_SOURCE_BYTES) {
      return { ok: false, code: "COMMUNITY_RELEASE_INVALID", message: "A mod's source exceeds the 256 KiB limit." };
    }
    if (!isNonEmptyString(m?.manifest?.id)) {
      return { ok: false, code: "COMMUNITY_RELEASE_INVALID", message: "A mod entry is missing manifest.id." };
    }
  }

  const metadata = release?.metadata ?? {};
  if (metadata.tags !== undefined) {
    if (!Array.isArray(metadata.tags) || metadata.tags.length > MAX_TAG_COUNT) {
      return { ok: false, code: "COMMUNITY_RELEASE_INVALID", message: `Release exceeds the ${MAX_TAG_COUNT}-tag limit.` };
    }
    for (const t of metadata.tags) {
      if (typeof t !== "string" || t.length > MAX_TAG_LEN) {
        return { ok: false, code: "COMMUNITY_RELEASE_INVALID", message: "A tag exceeds the length limit." };
      }
    }
  }
  if (typeof metadata.releaseNote === "string" && metadata.releaseNote.length > MAX_RELEASE_NOTE_LEN) {
    return { ok: false, code: "COMMUNITY_RELEASE_INVALID", message: "metadata.releaseNote exceeds the length limit." };
  }
  if (metadata.language !== undefined && typeof metadata.language !== "string") {
    return { ok: false, code: "COMMUNITY_RELEASE_INVALID", message: "metadata.language must be a string." };
  }

  const provenance = release?.provenance ?? {};
  if (provenance.parentReleaseId !== undefined && provenance.parentReleaseId !== null && typeof provenance.parentReleaseId !== "string") {
    return { ok: false, code: "COMMUNITY_RELEASE_INVALID", message: "provenance.parentReleaseId must be a string or null." };
  }
  if (provenance.communityParentReleaseId !== undefined && provenance.communityParentReleaseId !== null && typeof provenance.communityParentReleaseId !== "string") {
    return { ok: false, code: "COMMUNITY_RELEASE_INVALID", message: "provenance.communityParentReleaseId must be a string or null." };
  }

  const runtime = release?.runtime ?? {};

  return { ok: true, release };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: CORS_HEADERS });
  }
  if (req.method !== "POST") {
    return errorResponse(405, "COMMUNITY_PUBLISH_FAILED", "Method not allowed.");
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    return errorResponse(401, "COMMUNITY_AUTH_REQUIRED", "Sign in to publish a Community Release.");
  }

  let rawBody: string;
  try {
    const body = await req.json();
    if (typeof body?.releaseText !== "string") {
      return errorResponse(400, "COMMUNITY_RELEASE_INVALID", "Request body must include releaseText (the raw .vrelease JSON as a string).");
    }
    rawBody = body.releaseText;
  } catch {
    return errorResponse(400, "COMMUNITY_RELEASE_INVALID", "Request body must be valid JSON.");
  }

  const validated = validateReleasePayload(rawBody);
  if (!validated.ok) {
    return errorResponse(422, validated.code, validated.message);
  }
  const release = validated.release;

  // Client bound to the CALLER's own JWT -- every subsequent call runs
  // under the caller's RLS context, exactly like a direct authenticated
  // REST/RPC call would. This function never constructs or uses a
  // service-role/secret-key client.
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: authHeader } } },
  );

  const { data: userData, error: userErr } = await supabase.auth.getUser();
  if (userErr || !userData?.user) {
    return errorResponse(401, "COMMUNITY_AUTH_REQUIRED", "Sign in to publish a Community Release.");
  }

  const mods = release.mods.map((m: any) => ({
    manifest_id: m.manifest.id,
    manifest_version: m.manifest.version ?? null,
    manifest_name: m.manifest.name ?? null,
  }));

  // provenance.parentReleaseId is a LOCAL (client-generated) release id
  // and is never meaningful to this backend -- see
  // COMMUNITY_RELEASE_SPEC.md § 5 vs COMMUNITY_BACKEND_SPEC.md
  // "Remote/local release identity". Only provenance.communityParentReleaseId
  // (the parent's actual community_releases.id, set client-side only
  // when a Workspace was remixed from a Release fetched from this
  // backend) is ever used for server-side lineage.
  const parentReleaseId = release.provenance?.communityParentReleaseId ?? null;

  const { data, error } = await supabase.rpc("publish_release", {
    p_client_release_id: release.releaseId,
    p_title: release.game.title,
    p_description: release.game.description ?? null,
    p_author_display_name: release.game.authorDisplayName ?? null,
    p_language: release.metadata?.language ?? null,
    p_release_note: release.metadata?.releaseNote ?? null,
    p_parent_release_id: parentReleaseId,
    p_runtime_version: release.runtime?.runtimeVersion ?? null,
    p_api_version: release.runtime?.apiVersion ?? null,
    p_vmp_version: release.runtime?.vmpVersion ?? null,
    p_game_package_format_version: release.runtime?.packageFormatVersion ?? null,
    p_community_release_format_version: release.formatVersion,
    p_client_content_hash: release.contentHash ?? null,
    p_snapshot_text: rawBody,
    p_mods: mods,
    p_tags: release.metadata?.tags ?? null,
  });

  if (error) {
    const msg = String(error.message ?? "");
    if (msg.includes("RELEASE_PARENT_UNAVAILABLE")) {
      return errorResponse(422, "COMMUNITY_RELEASE_INVALID", "The parent release is unavailable (not found or not published).");
    }
    if (msg.includes("RELEASE_INVALID")) {
      return errorResponse(422, "COMMUNITY_RELEASE_INVALID", msg);
    }
    if (msg.includes("COMMUNITY_AUTH_REQUIRED") || error.code === "28000") {
      return errorResponse(401, "COMMUNITY_AUTH_REQUIRED", "Sign in to publish a Community Release.");
    }
    // Never surface raw Postgres internals to the client.
    console.error("publish_release RPC failed:", error);
    return errorResponse(500, "COMMUNITY_PUBLISH_FAILED", "Publishing failed. Please try again.");
  }

  return jsonResponse(200, { remoteId: data });
});

/* To invoke locally:

  1. Run `supabase start` (see: https://supabase.com/docs/reference/cli/supabase-start)
  2. Make an HTTP request:

  curl -i --location --request POST 'http://127.0.0.1:54321/functions/v1/publish-release' \
    --header 'Authorization: Bearer <user access token>' \
    --header 'Content-Type: application/json' \
    --data '{"releaseText": "{\"format\":\"voxel-release\", ...}"}'

*/
