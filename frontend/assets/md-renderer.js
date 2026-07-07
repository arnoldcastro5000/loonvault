// First-party Markdown renderer — zero dependencies, no framework, no third-party
// libraries (so nothing to audit and the strictest CSP applies). Renders a focused
// subset: headings (with anchor ids), paragraphs, lists, GFM pipe tables, fenced
// code, blockquotes, hr, and inline bold/italic/code/links. All text is HTML-escaped
// and link hrefs are scheme-checked, so it is safe to assign the output to innerHTML
// for trusted, same-origin Markdown. See ADR-0012.
(function (global) {
  "use strict";

  function escapeHtml(s) {
    return s.replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }

  function slug(text) {
    return text
      .toLowerCase()
      .replace(/<[^>]+>/g, "")
      .replace(/[^\w\s-]/g, "")
      .trim()
      .replace(/\s+/g, "-");
  }

  // Only permit safe link schemes; block javascript:, data:, etc.
  function safeHref(url) {
    // The URL arrives already HTML-escaped by inline(); undo that first so the
    // single escapeHtml below doesn't double-escape (breaks &-separated queries).
    var u = url.trim().replace(/&(amp|lt|gt|quot|#39);/g, function (_, e) {
      return { amp: "&", lt: "<", gt: ">", quot: '"', "#39": "'" }[e];
    });
    if (/^(https?:\/\/|\/|#|\.\/|\.\.\/|[\w./?=&%-]+\.md)/i.test(u) && !/^\s*javascript:/i.test(u)) {
      return escapeHtml(u);
    }
    return "#";
  }

  function inline(text) {
    text = escapeHtml(text);
    var codes = [];
    text = text.replace(/`([^`]+)`/g, function (_, c) {
      codes.push(c);
      return "\u0000" + (codes.length - 1) + "\u0000";
    });
    text = text.replace(/\[([^\]]+)\]\(([^)]+)\)/g, function (_, t, u) {
      return '<a href="' + safeHref(u) + '">' + t + "</a>";
    });
    text = text.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
    // Italic without lookbehind (older Safari lacks lookbehind support).
    text = text.replace(/(^|[^*\w])\*([^*\s](?:[^*]*?[^*\s])?)\*(?!\w)/g, "$1<em>$2</em>");
    text = text.replace(/\u0000(\d+)\u0000/g, function (_, i) {
      return "<code>" + codes[+i] + "</code>";
    });
    return text;
  }

  function render(md) {
    var lines = md.replace(/\r\n/g, "\n").split("\n");
    var out = [];
    var i = 0;
    var n = lines.length;
    while (i < n) {
      var line = lines[i];

      if (/^\s*```/.test(line)) {
        i++;
        var code = [];
        while (i < n && !/^\s*```/.test(lines[i])) {
          code.push(escapeHtml(lines[i]));
          i++;
        }
        i++;
        out.push("<pre><code>" + code.join("\n") + "</code></pre>");
        continue;
      }
      if (!line.trim()) {
        i++;
        continue;
      }
      var h = /^(#{1,6})\s+(.*)$/.exec(line);
      if (h) {
        var lvl = h[1].length;
        var txt = h[2].trim();
        out.push("<h" + lvl + ' id="' + slug(txt) + '">' + inline(txt) + "</h" + lvl + ">");
        i++;
        continue;
      }
      if (/^\s*(-{3,}|\*{3,})\s*$/.test(line)) {
        out.push("<hr>");
        i++;
        continue;
      }
      // GFM pipe table: header row, then a |---| separator
      if (line.indexOf("|") !== -1 && i + 1 < n && /^\s*\|?[\s:|-]+\|[\s:|-]*$/.test(lines[i + 1])) {
        var headers = line.trim().replace(/^\||\|$/g, "").split("|").map(function (c) { return c.trim(); });
        i += 2;
        var rows = [];
        while (i < n && lines[i].indexOf("|") !== -1 && lines[i].trim()) {
          rows.push(lines[i].trim().replace(/^\||\|$/g, "").split("|").map(function (c) { return c.trim(); }));
          i++;
        }
        var thead = headers.map(function (c) { return "<th>" + inline(c) + "</th>"; }).join("");
        var tbody = rows.map(function (r) {
          return "<tr>" + r.map(function (c) { return "<td>" + inline(c) + "</td>"; }).join("") + "</tr>";
        }).join("");
        out.push('<div class="table-wrap"><table><thead><tr>' + thead + "</tr></thead><tbody>" + tbody + "</tbody></table></div>");
        continue;
      }
      if (/^\s*>/.test(line)) {
        var quote = [];
        while (i < n && /^\s*>/.test(lines[i])) {
          quote.push(lines[i].replace(/^\s*>\s?/, ""));
          i++;
        }
        out.push("<blockquote>" + inline(quote.join(" ")) + "</blockquote>");
        continue;
      }
      if (/^\s*([-*]|\d+\.)\s+/.test(line)) {
        var ordered = /^\s*\d+\.\s+/.test(line);
        var tag = ordered ? "ol" : "ul";
        var items = [];
        while (i < n && /^\s*([-*]|\d+\.)\s+/.test(lines[i])) {
          items.push(lines[i].replace(/^\s*([-*]|\d+\.)\s+/, ""));
          i++;
        }
        out.push("<" + tag + ">" + items.map(function (it) { return "<li>" + inline(it) + "</li>"; }).join("") + "</" + tag + ">");
        continue;
      }
      var para = [];
      while (i < n && lines[i].trim() && !/^(#{1,6}\s|\s*>|\s*([-*]|\d+\.)\s|```)/.test(lines[i])) {
        para.push(lines[i]);
        i++;
      }
      out.push("<p>" + inline(para.join(" ")) + "</p>");
    }
    return out.join("\n");
  }

  global.renderMarkdown = render;
})(typeof window !== "undefined" ? window : globalThis);

if (typeof module !== "undefined" && module.exports) module.exports = { renderMarkdown: globalThis.renderMarkdown };
