// LoonVault frontend config — edit these for your deployment.
// No secrets here; just public endpoints.
window.LOONVAULT = {
  // Public API (ephemeral backend — only up during a demo). Cloudflare-fronted.
  apiBase: "https://api-loonvault.cloudsecuritypractice.com",

  // Resilience fallback: public S3 snapshots served via Cloudflare (ADR-0004).
  // Used when the ephemeral API is down. Must match the site CSP connect-src
  // (var.snapshot_origin in infra/frontend) — see ADR-0013.
  snapshotBase: "https://snapshots-loonvault.cloudsecuritypractice.com",

  // Series code to show in the live panel (a BoC Valet code in the indicators
  // catalogue). Set this to one that exists in your deployment.
  defaultSeries: "CPI",
};
