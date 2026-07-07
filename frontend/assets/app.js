// Live indicators panel. Tries the ephemeral API first, falls back to the public
// S3 snapshot (ADR-0004 resilience) so the page stays useful when the backend is down.
// No inline script anywhere, so the site can run under a strict Content-Security-Policy.
(function () {
  "use strict";
  var cfg = window.LOONVAULT || {};
  var panel = document.getElementById("indicators");
  if (!panel) return;

  var code = cfg.defaultSeries || "CPI";
  var status = document.getElementById("data-status");
  var table = document.getElementById("data-table");

  function setStatus(msg, kind) {
    if (!status) return;
    status.textContent = msg;
    status.className = "status " + (kind || "");
  }

  function render(observations, source) {
    if (!table) return;
    // Both sources return observations newest-first (read lambda ORDER BY DESC;
    // snapshot sorted reverse=True), so the latest 12 are at the FRONT.
    var rows = (observations || [])
      .slice(0, 12)
      .map(function (o) {
        var d = o.date || o.d || "";
        var v = o.value != null ? o.value : o.v;
        return "<tr><td>" + escapeHtml(d) + "</td><td>" + escapeHtml(String(v)) + "</td></tr>";
      })
      .join("");
    table.innerHTML =
      "<thead><tr><th>Date</th><th>" + escapeHtml(code) + "</th></tr></thead><tbody>" +
      rows +
      "</tbody>";
    setStatus("Showing " + code + " — source: " + source, "ok");
  }

  function escapeHtml(s) {
    return s.replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }

  function fetchJson(url) {
    return fetch(url, { mode: "cors" }).then(function (r) {
      if (!r.ok) throw new Error("HTTP " + r.status);
      return r.json();
    });
  }

  function observationsOf(payload) {
    // Accept either a bare array or { observations: [...] } / { data: [...] }.
    if (Array.isArray(payload)) return payload;
    return payload.observations || payload.data || [];
  }

  setStatus("Loading live data…");
  fetchJson(cfg.apiBase + "/series/" + encodeURIComponent(code))
    .then(function (p) {
      render(observationsOf(p), "live API");
    })
    .catch(function () {
      setStatus("Live API unavailable — trying snapshot fallback…");
      return fetchJson(cfg.snapshotBase + "/" + encodeURIComponent(code) + ".json")
        .then(function (p) {
          render(observationsOf(p), "S3 snapshot (fallback)");
        })
        .catch(function () {
          setStatus(
            "Backend is offline. This is an ephemeral demo backend — it is stood up for live demos and torn down after. The security architecture above stands on its own.",
            "warn"
          );
        });
    });
})();
