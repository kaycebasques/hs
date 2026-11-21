/* ==========================================================================
   rules_hs Documentation Interactive Runtime
   - Instant client-side search modal (`/` or Ctrl/Cmd+K) with snippet highlighting
   - Persistent light/dark theme toggle
   - Copy-code buttons on all code blocks
   - Right-sidebar TOC active scrollspy
   - Mobile navigation drawer
   - Optional client-side Mermaid diagram rendering hook (graceful offline fallback)
   ========================================================================== */
(function () {
  "use strict";

  var rootEl = document.documentElement;
  var siteRoot = rootEl.getAttribute("data-site-root") || ".";

  function joinSitePath(relPath) {
    var clean = String(relPath || "").replace(/^\/+/, "");
    return siteRoot === "." ? clean : siteRoot + "/" + clean;
  }

  /* 1. Light / Dark Theme Toggle */
  var themeBtn = document.getElementById("theme-toggle-btn");
  if (themeBtn) {
    themeBtn.addEventListener("click", function () {
      var cur = rootEl.getAttribute("data-theme") === "dark" ? "dark" : "light";
      var next = cur === "dark" ? "light" : "dark";
      rootEl.setAttribute("data-theme", next);
      try {
        localStorage.setItem("rules_hs_theme", next);
      } catch (_) {}
    });
  }

  /* 2. Mobile Navigation Drawer */
  var mobileBtn = document.getElementById("mobile-menu-btn");
  var sidebar = document.getElementById("docs-sidebar");
  var backdrop = document.getElementById("sidebar-backdrop");

  function setDrawerOpen(open) {
    if (!sidebar || !mobileBtn || !backdrop) return;
    sidebar.classList.toggle("open", open);
    mobileBtn.setAttribute("aria-expanded", open ? "true" : "false");
    backdrop.hidden = !open;
  }

  if (mobileBtn) {
    mobileBtn.addEventListener("click", function () {
      setDrawerOpen(!sidebar.classList.contains("open"));
    });
  }
  if (backdrop) {
    backdrop.addEventListener("click", function () {
      setDrawerOpen(false);
    });
  }

  /* 3. Copy-Code Buttons */
  function attachCopyButtons() {
    var blocks = document.querySelectorAll("div.sourceCode, .docs-prose pre:not(.sourceCode):not(.mermaid)");
    blocks.forEach(function (container) {
      if (container.tagName === "PRE" && container.parentElement && container.parentElement.classList.contains("sourceCode")) {
        return;
      }
      var targetContainer = container;
      if (container.tagName === "PRE") {
        var wrapper = document.createElement("div");
        wrapper.className = "code-block-wrapper";
        container.parentNode.insertBefore(wrapper, container);
        wrapper.appendChild(container);
        targetContainer = wrapper;
      }
      var codeEl = targetContainer.querySelector("code") || targetContainer.querySelector("pre");
      if (!codeEl) return;

      var btn = document.createElement("button");
      btn.type = "button";
      btn.className = "copy-code-btn";
      btn.textContent = "Copy";
      btn.setAttribute("aria-label", "Copy code snippet");
      btn.addEventListener("click", function () {
        var text = codeEl.innerText || codeEl.textContent || "";
        if (navigator.clipboard && navigator.clipboard.writeText) {
          navigator.clipboard.writeText(text).then(function () {
            btn.textContent = "Copied!";
            btn.classList.add("copied");
            setTimeout(function () {
              btn.textContent = "Copy";
              btn.classList.remove("copied");
            }, 1600);
          });
        }
      });
      targetContainer.appendChild(btn);
    });
  }

  /* 4. Right-Sidebar TOC Scrollspy */
  function initScrollSpy() {
    var tocLinks = Array.prototype.slice.call(document.querySelectorAll(".toc-link"));
    if (!tocLinks.length) return;

    var pairs = tocLinks
      .map(function (link) {
        var hash = link.getAttribute("href") || "";
        if (hash.charAt(0) !== "#") return null;
        var el = document.getElementById(hash.slice(1));
        return el ? { link: link, el: el } : null;
      })
      .filter(Boolean);

    if (!pairs.length) return;

    function updateActive() {
      var threshold = window.scrollY + 110;
      var active = pairs[0];
      for (var i = 0; i < pairs.length; i++) {
        if (pairs[i].el.offsetTop <= threshold) {
          active = pairs[i];
        } else {
          break;
        }
      }
      pairs.forEach(function (p) {
        p.link.classList.toggle("active", p === active);
      });
    }

    window.addEventListener("scroll", updateActive, { passive: true });
    updateActive();
  }

  /* 5. Client-Side Instant Search Modal */
  var modal = document.getElementById("search-modal");
  var openBtn = document.getElementById("search-open-btn");
  var closeBtn = document.getElementById("search-close-btn");
  var searchInput = document.getElementById("search-input");
  var resultsContainer = document.getElementById("search-results");
  var searchIndexPromise = null;
  var activeResultIdx = 0;
  var currentRenderedLinks = [];

  function loadSearchIndex() {
    if (!searchIndexPromise) {
      searchIndexPromise = fetch(joinSitePath("search-index.json"))
        .then(function (res) {
          if (!res.ok) throw new Error("HTTP " + res.status);
          return res.json();
        })
        .catch(function () {
          return [];
        });
    }
    return searchIndexPromise;
  }

  function escapeHtml(str) {
    return String(str)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  function highlightMatches(text, terms) {
    var safe = escapeHtml(text);
    if (!terms.length) return safe;
    var escapedTerms = terms
      .map(function (t) {
        return escapeHtml(t).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      })
      .filter(Boolean);
    if (!escapedTerms.length) return safe;
    var re = new RegExp("(" + escapedTerms.join("|") + ")", "gi");
    return safe.replace(re, "<mark>$1</mark>");
  }

  function extractSnippet(body, terms, fallbackDesc) {
    var src = body || fallbackDesc || "";
    if (!src) return "";
    if (!terms.length) return src.slice(0, 150) + (src.length > 150 ? "..." : "");
    var lower = src.toLowerCase();
    var pos = -1;
    for (var i = 0; i < terms.length; i++) {
      pos = lower.indexOf(terms[i]);
      if (pos !== -1) break;
    }
    if (pos === -1) return (fallbackDesc || src).slice(0, 150);
    var start = Math.max(0, pos - 48);
    var end = Math.min(src.length, pos + 112);
    var prefix = start > 0 ? "..." : "";
    var suffix = end < src.length ? "..." : "";
    return prefix + src.slice(start, end) + suffix;
  }

  function scoreDoc(doc, terms) {
    if (!terms.length) return { score: 1, anchor: "" };
    var titleL = (doc.title || "").toLowerCase();
    var navL = (doc.nav_title || "").toLowerCase();
    var descL = (doc.description || "").toLowerCase();
    var bodyL = (doc.body || "").toLowerCase();
    var headings = doc.headings || [];

    var total = 0;
    var bestHeading = null;

    for (var i = 0; i < terms.length; i++) {
      var t = terms[i];
      var termScore = 0;
      if (titleL.indexOf(t) !== -1) termScore += 30;
      if (navL.indexOf(t) !== -1) termScore += 25;
      if (descL.indexOf(t) !== -1) termScore += 12;
      for (var h = 0; h < headings.length; h++) {
        var ht = (headings[h].title || "").toLowerCase();
        var hid = (headings[h].id || "").toLowerCase();
        if (ht.indexOf(t) !== -1 || hid.indexOf(t) !== -1) {
          termScore += 18;
          if (!bestHeading) bestHeading = headings[h];
        }
      }
      if (bodyL.indexOf(t) !== -1) termScore += 5;
      if (termScore === 0) return { score: 0, anchor: "" };
      total += termScore;
    }
    return { score: total, matchedHeading: bestHeading };
  }

  function renderResults(docs, rawQuery) {
    if (!resultsContainer) return;
    var terms = String(rawQuery || "")
      .toLowerCase()
      .split(/\s+/)
      .filter(Boolean);

    var ranked = [];
    for (var i = 0; i < docs.length; i++) {
      var res = scoreDoc(docs[i], terms);
      if (res.score > 0) {
        ranked.push({ doc: docs[i], score: res.score, heading: res.matchedHeading });
      }
    }
    if (terms.length) {
      ranked.sort(function (a, b) {
        return b.score - a.score;
      });
    }
    ranked = ranked.slice(0, 14);

    if (!ranked.length) {
      resultsContainer.innerHTML = '<div class="search-empty">No matching documentation found for <strong>' + escapeHtml(rawQuery) + "</strong>.</div>";
      currentRenderedLinks = [];
      activeResultIdx = 0;
      return;
    }

    var html = ranked
      .map(function (entry, idx) {
        var doc = entry.doc;
        var anchorSuffix = entry.heading && entry.heading.id ? "#" + entry.heading.id : "";
        var href = joinSitePath(doc.url) + anchorSuffix;
        var headingSuffix = entry.heading ? " &rsaquo; " + escapeHtml(entry.heading.title) : "";
        var snippet = extractSnippet(doc.body, terms, doc.description);
        return (
          '<a role="option" class="search-result-item' +
          (idx === 0 ? " selected" : "") +
          '" href="' +
          escapeHtml(href) +
          '">' +
          '<div class="search-result-meta">' +
          escapeHtml(doc.section || "Docs") +
          headingSuffix +
          "</div>" +
          '<div class="search-result-title">' +
          highlightMatches(doc.title || doc.nav_title, terms) +
          "</div>" +
          '<div class="search-result-snippet">' +
          highlightMatches(snippet, terms) +
          "</div></a>"
        );
      })
      .join("");

    resultsContainer.innerHTML = html;
    currentRenderedLinks = Array.prototype.slice.call(resultsContainer.querySelectorAll(".search-result-item"));
    activeResultIdx = 0;
    currentRenderedLinks.forEach(function (a) {
      a.addEventListener("click", function () {
        closeSearch();
      });
    });
  }

  function updateSelectedResult(nextIdx) {
    if (!currentRenderedLinks.length) return;
    activeResultIdx = (nextIdx + currentRenderedLinks.length) % currentRenderedLinks.length;
    currentRenderedLinks.forEach(function (el, idx) {
      el.classList.toggle("selected", idx === activeResultIdx);
      if (idx === activeResultIdx && el.scrollIntoView) {
        el.scrollIntoView({ block: "nearest" });
      }
    });
  }

  function openSearch() {
    if (!modal || !searchInput) return;
    modal.hidden = false;
    searchInput.focus();
    searchInput.select();
    loadSearchIndex().then(function (docs) {
      renderResults(docs, searchInput.value);
    });
  }

  function closeSearch() {
    if (!modal) return;
    modal.hidden = true;
  }

  if (openBtn) openBtn.addEventListener("click", openSearch);
  if (closeBtn) closeBtn.addEventListener("click", closeSearch);
  if (modal) {
    modal.addEventListener("click", function (ev) {
      if (ev.target && ev.target.getAttribute("data-close-search") === "true") {
        closeSearch();
      }
    });
  }

  if (searchInput) {
    searchInput.addEventListener("input", function () {
      var val = searchInput.value;
      loadSearchIndex().then(function (docs) {
        renderResults(docs, val);
      });
    });
    searchInput.addEventListener("keydown", function (ev) {
      if (ev.key === "ArrowDown") {
        ev.preventDefault();
        updateSelectedResult(activeResultIdx + 1);
      } else if (ev.key === "ArrowUp") {
        ev.preventDefault();
        updateSelectedResult(activeResultIdx - 1);
      } else if (ev.key === "Enter" && currentRenderedLinks[activeResultIdx]) {
        ev.preventDefault();
        var href = currentRenderedLinks[activeResultIdx].getAttribute("href");
        closeSearch();
        if (href) window.location.href = href;
      }
    });
  }

  document.addEventListener("keydown", function (ev) {
    var tag = ev.target && ev.target.tagName ? ev.target.tagName.toLowerCase() : "";
    var isEditable = tag === "input" || tag === "textarea" || (ev.target && ev.target.isContentEditable);

    if (ev.key === "Escape" && modal && !modal.hidden) {
      ev.preventDefault();
      closeSearch();
      return;
    }
    if ((ev.metaKey || ev.ctrlKey) && ev.key.toLowerCase() === "k") {
      ev.preventDefault();
      if (modal && !modal.hidden) closeSearch();
      else openSearch();
      return;
    }
    if (ev.key === "/" && !isEditable && modal && modal.hidden) {
      ev.preventDefault();
      openSearch();
    }
  });

  /* 6. Progressive Mermaid Rendering Hook (gracefully readable as source offline) */
  function initMermaidHook() {
    var blocks = document.querySelectorAll("pre.mermaid");
    if (!blocks.length) return;
    if (window.mermaid && typeof window.mermaid.run === "function") {
      window.mermaid.run({ nodes: blocks });
      return;
    }
    if (navigator.onLine === false) return;
    var script = document.createElement("script");
    script.src = "https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js";
    script.async = true;
    script.onload = function () {
      if (window.mermaid) {
        var isDark = rootEl.getAttribute("data-theme") === "dark";
        window.mermaid.initialize({ startOnLoad: false, theme: isDark ? "dark" : "default" });
        window.mermaid.run({ nodes: blocks });
      }
    };
    script.onerror = function () {
      /* Offline or blocked: `<pre class="mermaid">` stays clean and readable! */
    };
    document.head.appendChild(script);
  }

  document.addEventListener("DOMContentLoaded", function () {
    attachCopyButtons();
    initScrollSpy();
    initMermaidHook();
  });
})();
