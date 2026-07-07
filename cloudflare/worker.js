// LoonVault always-on frontend reverse proxy (Cloudflare Worker).
//
// Fronts the origin-protected Lambda Function URL (ADR-0013): allowlists paths and
// methods, injects the shared X-Origin-Secret the Lambda validates, and rewrites the
// request to the origin. Deployed by copy-paste into the Cloudflare Worker editor
// (no wrangler). Bind it to the route `loonvault.cloudsecuritypractice.com/*`.
//
// Required Worker variables / secrets:
//   EXPECTED_HOST   canonical site host, e.g. loonvault.cloudsecuritypractice.com
//   ROOT_DOMAIN     apex to redirect to EXPECTED_HOST (set unused to disable)
//   ORIGIN_HOST     Lambda Function URL host, e.g. <id>.lambda-url.ca-central-1.on.aws
//                   (terraform -chdir=infra/frontend output -raw site_function_url, minus scheme/slash)
//   ORIGIN_SECRET   the SSM origin secret VALUE — set as an ENCRYPTED secret, not plaintext

const VALID_PATHS = new Set(["/", "/index.html", "/docs.html"]);
// Unhashed static assets + the live-rendered docs content (manifest + .md files).
const ASSET_PATTERN = /^\/assets\/[A-Za-z0-9._/-]+\.(css|js|woff2|svg|png|ico|txt)$/;
const CONTENT_PATTERN = /^\/content\/[A-Za-z0-9._/-]+\.(md|json)$/;

function blocked(status, message) {
  return new Response(message, {
    status,
    headers: { "Content-Type": "text/plain", "Cache-Control": "no-store" },
  });
}

export default {
  async fetch(request, env) {
    const reqHost = (request.headers.get("host") || "").toLowerCase();

    // Optional apex -> canonical redirect.
    if (reqHost === env.ROOT_DOMAIN || reqHost === env.ROOT_DOMAIN + ":443") {
      const redirectUrl = new URL(request.url);
      redirectUrl.hostname = env.EXPECTED_HOST;
      return Response.redirect(redirectUrl.toString(), 301);
    }

    if (request.method === "OPTIONS") {
      return new Response(null, {
        status: 204,
        headers: { "Access-Control-Allow-Methods": "GET, HEAD, OPTIONS" },
      });
    }
    if (request.method !== "GET" && request.method !== "HEAD") {
      return blocked(405, "Method Not Allowed");
    }
    if (request.body !== null) {
      return blocked(400, "Bad Request");
    }
    if (/%2e%2e|%252e|%2f|%00|%5c/i.test(request.url) || request.url.includes("\\")) {
      return blocked(400, "Bad Request");
    }

    const url = new URL(request.url); // normalizes any literal ".." segments
    if (url.pathname.length > 256) {
      return blocked(414, "URI Too Long");
    }

    // Path allowlist for the LoonVault site.
    if (
      !VALID_PATHS.has(url.pathname) &&
      !ASSET_PATTERN.test(url.pathname) &&
      !CONTENT_PATTERN.test(url.pathname)
    ) {
      return blocked(404, "Not Found");
    }

    // Header size limits.
    let totalHeaderSize = 0;
    for (const [name, value] of request.headers) {
      if (name.length + value.length > 4096) {
        return blocked(431, "Request Header Fields Too Large");
      }
      totalHeaderSize += name.length + value.length;
    }
    if (totalHeaderSize > 16384) {
      return blocked(431, "Request Header Fields Too Large");
    }

    // Only serve the canonical host.
    if (reqHost !== env.EXPECTED_HOST && reqHost !== env.EXPECTED_HOST + ":443") {
      return blocked(421, "Misdirected Request");
    }

    // Rewrite to the Lambda Function URL origin and inject the origin secret.
    url.hostname = env.ORIGIN_HOST;
    const headers = new Headers(request.headers);
    headers.set("X-Origin-Secret", env.ORIGIN_SECRET);
    headers.delete("host"); // IMPORTANT: let the Function URL receive its own host
    // The site is credential-free: never forward browser credentials to the origin.
    headers.delete("cookie");
    headers.delete("authorization");

    const modified = new Request(url.toString(), { method: request.method, headers });
    try {
      return await fetch(modified);
    } catch {
      return blocked(502, "Bad Gateway");
    }
  },
};
