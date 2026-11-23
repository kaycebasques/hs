/* ==========================================================================
   rules_haskell Vanilla Hakyll UI Helpers
   - Light / dark theme toggle
   - Mobile sidebar drawer toggle
   - Copy-code button on code blocks
   - Right-sidebar TOC active scrollspy
   - Progressive Mermaid diagram rendering (graceful offline fallback)
   ========================================================================== */
(function () {
  "use strict";

  var rootEl = document.documentElement;

  /* 1. Light / Dark Theme Toggle */
  var themeBtn = document.getElementById("theme-toggle-btn");
  if (themeBtn) {
    themeBtn.addEventListener("click", function () {
      var cur = rootEl.getAttribute("data-theme") === "dark" ? "dark" : "light";
      var next = cur === "dark" ? "light" : "dark";
      rootEl.setAttribute("data-theme", next);
      try {
        localStorage.setItem("rules_haskell_theme", next);
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
    var tocLinks = Array.prototype.slice.call(document.querySelectorAll(".docs-toc a"));
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

  /* 5. Progressive Mermaid Rendering Hook (graceful offline fallback) */
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
    script.onerror = function () {};
    document.head.appendChild(script);
  }

  document.addEventListener("DOMContentLoaded", function () {
    attachCopyButtons();
    initScrollSpy();
    initMermaidHook();
  });
})();
