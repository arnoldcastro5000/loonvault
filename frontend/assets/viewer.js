// Live docs viewer. Fetches a manifest of docs, then fetches and renders the
// selected Markdown file LIVE (same-origin) with the first-party renderer. No
// framework, no third-party libraries. Routing is hash-based (#<key>).
(function () {
  "use strict";

  var sidebar = document.getElementById("doc-nav");
  var content = document.getElementById("doc-content");
  var titleEl = document.getElementById("doc-title");
  var docs = [];

  function esc(s) {
    return String(s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }

  function skeleton() {
    content.innerHTML =
      '<div class="skeleton"></div>'.repeat(6);
  }

  function showError(msg) {
    content.innerHTML = '<div class="error">' + esc(msg) + "</div>";
  }

  function buildSidebar(active) {
    var groups = {};
    docs.forEach(function (d) {
      (groups[d.group] = groups[d.group] || []).push(d);
    });
    var html = "";
    Object.keys(groups).forEach(function (g) {
      html += "<div class=\"nav-group\"><h3>" + esc(g) + "</h3><ul>";
      groups[g].forEach(function (d) {
        var cls = d.key === active ? ' class="active"' : "";
        html += '<li><a href="#' + esc(d.key) + '"' + cls + ">" + esc(d.title) + "</a></li>";
      });
      html += "</ul></div>";
    });
    sidebar.innerHTML = html;
  }

  function loadDoc(key) {
    var doc = docs.filter(function (d) { return d.key === key; })[0] || docs[0];
    if (!doc) return showError("No documents available.");
    buildSidebar(doc.key);
    titleEl.textContent = doc.title;
    document.title = doc.title + " — LoonVault docs";
    skeleton();
    fetch(doc.path, { cache: "no-cache" })
      .then(function (r) {
        if (!r.ok) throw new Error("HTTP " + r.status);
        return r.text();
      })
      .then(function (md) {
        content.innerHTML = window.renderMarkdown(md);
        // jump to in-page anchor if the hash has one (#key/anchor)
        var parts = location.hash.slice(1).split("/");
        if (parts[1]) {
          var t = document.getElementById(parts[1]);
          if (t) t.scrollIntoView();
        } else {
          content.scrollTop = 0;
        }
      })
      .catch(function (e) {
        showError("Could not load this document (" + e.message + "). It is served same-origin from the site bucket.");
      });
  }

  function route() {
    var key = location.hash.slice(1).split("/")[0];
    loadDoc(key);
  }

  fetch("content/manifest.json", { cache: "no-cache" })
    .then(function (r) {
      if (!r.ok) throw new Error("HTTP " + r.status);
      return r.json();
    })
    .then(function (data) {
      docs = data.docs || [];
      window.addEventListener("hashchange", route);
      route();
    })
    .catch(function (e) {
      showError("Could not load the docs manifest (" + e.message + ").");
    });
})();
