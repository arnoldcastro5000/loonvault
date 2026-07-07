// LoonVault API reverse proxy (Cloudflare Worker).
//
// Fronts the origin-protected API Gateway endpoint: allowlists exactly one read-only
// path shape, injects the shared X-Origin-Secret the Lambda authorizer validates, and
// rewrites the request to the origin. This is what makes the browser's "live API"
// fetch on the frontend work at all — a browser cannot hold the origin secret, so the
// edge injects it (same pattern as the site worker / ADR-0013). Deployed by copy-paste
// into the Cloudflare Worker editor (no wrangler). Bind it to the route
// `api-loonvault.cloudsecuritypractice.com/*`.
//
// Required Worker variables / secrets:
//   EXPECTED_HOST   canonical API host, e.g. api-loonvault.cloudsecuritypractice.com
//   ORIGIN_HOST     API Gateway host, e.g. <api-id>.execute-api.ca-central-1.amazonaws.com
//                   NOTE: the backend is EPHEMERAL — the api-id changes on every
//                   destroy/apply cycle, so update this var on each bring-up
//                   (terraform -chdir=infra/loonvault output -raw api_endpoint, minus scheme).
//   ORIGIN_SECRET   the SSM origin secret VALUE — set as an ENCRYPTED secret, not plaintext
//                   (same value the site worker holds; both authorizers read the same
//                   SSM parameter).

// Only public read path: GET /series/<code>. Codes are short alphanumeric series ids.
const SERIES_PATTERN = /^\/series\/[A-Za-z0-9._-]{1,32}$/;

function blocked(status, message) {
  return new Response(message, {
    status,
    headers: { "Content-Type": "text/plain", "Cache-Control": "no-store" },
  });
}

export default {
  async fetch(request, env) {
    // OPTIONS falls through to the origin: API Gateway owns the CORS config
    // (allowed origin/methods) and auto-answers preflights, so the edge must not
    // answer them itself (a 204 without Access-Control-Allow-Origin fails the check).
    if (request.method !== "GET" && request.method !== "HEAD" && request.method !== "OPTIONS") {
      return blocked(405, "Method Not Allowed");
    }
    if (request.body !== null) {
      return blocked(400, "Bad Request");
    }
    if (/%2e%2e|%252e|%2f|%00|%5c/i.test(request.url) || request.url.includes("\\")) {
      return blocked(400, "Bad Request");
    }

    const url = new URL(request.url); // normalizes any literal ".." segments
    if (url.pathname.length > 64 || url.search.length > 64) {
      return blocked(414, "URI Too Long");
    }
    if (!SERIES_PATTERN.test(url.pathname)) {
      return blocked(404, "Not Found");
    }

    // Only serve the canonical host.
    const reqHost = (request.headers.get("host") || "").toLowerCase();
    if (reqHost !== env.EXPECTED_HOST && reqHost !== env.EXPECTED_HOST + ":443") {
      return blocked(421, "Misdirected Request");
    }

    // Rewrite to the API Gateway origin and inject the origin secret. Origin is
    // otherwise unreachable in practice: without the header the Lambda authorizer
    // denies (attack-and-defense scenario #5).
    url.hostname = env.ORIGIN_HOST;
    const headers = new Headers();
    headers.set("X-Origin-Secret", env.ORIGIN_SECRET);
    // Forward only what the API needs; browser Origin passes through so API Gateway
    // CORS answers with the allowlisted site origin.
    const origin = request.headers.get("origin");
    if (origin) headers.set("Origin", origin);
    const accept = request.headers.get("accept");
    if (accept) headers.set("Accept", accept);
    // Preflight metadata, so API Gateway can answer OPTIONS correctly.
    for (const h of ["access-control-request-method", "access-control-request-headers"]) {
      const v = request.headers.get(h);
      if (v) headers.set(h, v);
    }

    let resp;
    try {
      resp = await fetch(url.toString(), { method: request.method, headers });
    } catch {
      return blocked(502, "Bad Gateway");
    }

    // Live means live: never let the edge cache observations.
    const out = new Response(resp.body, resp);
    out.headers.set("Cache-Control", "no-store");
    return out;
  },
};
