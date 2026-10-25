// Ask transcript renderer: a port of StudyGPT's chat rendering (components/Markdown.tsx,
// ChatMessage.tsx, FlashcardDeck.tsx, Artifact.tsx, SourcesPanel.tsx, lib/markdown/normalize-math.ts)
// using marked (GFM) + KaTeX, driven from Swift through window.UP and answering through the
// "up" message handler. Raw HTML in answers is shown as text; only ```artifact blocks run code,
// in a sandboxed iframe without access to this page.
"use strict";
(function () {
  const post = (message) => { try { window.webkit.messageHandlers.up.postMessage(message); } catch (_) {} };
  const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const PH_START = "", PH_END = "";

  // ---- Math (StudyGPT normalizeMathDelimiters + remark-math's $ / $$) ----

  // \(...\) → $...$ and \[...\] → $$...$$, leaving code untouched.
  function normalizeMath(md) {
    const kept = [];
    const protect = (s) => PH_START + "C" + (kept.push(s) - 1) + PH_END;
    let out = md.replace(/```[\s\S]*?(?:```|$)/g, protect).replace(/`[^`\n]*`/g, protect);
    out = out.replace(/\\\[([\s\S]+?)\\\]/g, (_, c) => "$$" + c + "$$");
    out = out.replace(/\\\(([\s\S]+?)\\\)/g, (_, c) => "$" + c + "$");
    return out.replace(new RegExp(PH_START + "C(\\d+)" + PH_END, "g"), (_, i) => kept[Number(i)]);
  }

  // Pulls math out before Markdown (which would eat backslashes and underscores) and returns
  // placeholders that are swapped for KaTeX output afterwards.
  function extractMath(md) {
    const code = [], math = [];
    const keep = (s) => PH_START + "C" + (code.push(s) - 1) + PH_END;
    let out = md.replace(/```[\s\S]*?(?:```|$)/g, keep).replace(/`[^`\n]*`/g, keep);
    out = out.replace(/\$\$([\s\S]+?)\$\$/g, (_, t) => PH_START + "M" + (math.push({ t, display: true }) - 1) + PH_END);
    // Inline $…$: no space just inside the delimiters and no digit right after, so "$5 and $10" stays text.
    out = out.replace(/(^|[^\\$])\$(?!\s)([^\n$]+?)(?<!\s)\$(?!\d)/g,
      (_, pre, t) => pre + PH_START + "M" + (math.push({ t, display: false }) - 1) + PH_END);
    out = out.replace(new RegExp(PH_START + "C(\\d+)" + PH_END, "g"), (_, i) => code[Number(i)]);
    return { md: out, math };
  }

  function renderMath(html, math) {
    return html.replace(new RegExp(PH_START + "M(\\d+)" + PH_END, "g"), (_, i) => {
      const m = math[Number(i)];
      try {
        return katex.renderToString(m.t, { displayMode: m.display, throwOnError: false, strict: "ignore", output: "htmlAndMathml" });
      } catch (_) {
        return '<span class="math-error">' + esc(m.t) + "</span>";
      }
    });
  }

  // ---- Markdown (StudyGPT Markdown.tsx: GFM + math, fenced artifact/flashcard routing) ----

  marked.use({
    gfm: true,
    breaks: false,
    renderer: {
      html(token) { return esc(token.text || token.raw || ""); },
      image(token) { return esc(token.text || ""); },
      link(token) {
        const href = token.href || "";
        const text = this.parser.parseInline(token.tokens);
        return /^(https?:|mailto:)/i.test(href) ? '<a href="' + esc(href) + '" data-external="1">' + text + "</a>" : text;
      },
      code(token) {
        const lang = (token.lang || "").trim().split(/\s+/)[0].toLowerCase();
        if (lang === "artifact" || lang === "flashcard") {
          return '<div class="widget" data-kind="' + lang + '" data-src="' + encodeURIComponent(token.text) + '"></div>';
        }
        return '<pre><button class="copy">Copy</button><code class="language-' + esc(lang) + '">' + esc(token.text) + "</code></pre>";
      },
    },
  });

  function markdown(md) {
    const { md: text, math } = extractMath(normalizeMath(md || ""));
    return renderMath(marked.parse(text), math);
  }

  // ---- Citations: "[2]", "[1][3]", "[1, 3]" → chips that open the cited page ----

  function linkCitations(root, turnId, known) {
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode(node) {
        return node.parentElement.closest("pre, code, .katex, .cite, .flash, .artifact") ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT;
      },
    });
    const nodes = [];
    while (walker.nextNode()) if (/\[\d+(?:\s*,\s*\d+)*\]/.test(walker.currentNode.nodeValue)) nodes.push(walker.currentNode);
    for (const node of nodes) {
      const fragment = document.createDocumentFragment();
      let last = 0;
      const text = node.nodeValue;
      text.replace(/\[(\d+(?:\s*,\s*\d+)*)\]/g, (whole, inner, offset) => {
        fragment.append(text.slice(last, offset));
        for (const part of inner.split(",")) {
          const n = Number(part.trim());
          const chip = document.createElement("a");
          chip.className = "cite" + (known.has(n) ? "" : " missing");
          chip.textContent = String(n);
          if (known.has(n)) {
            chip.title = "Open the cited page";
            chip.addEventListener("click", () => post({ type: "cite", turn: turnId, number: n }));
          }
          fragment.append(chip);
        }
        last = offset + whole.length;
      });
      fragment.append(text.slice(last));
      node.replaceWith(fragment);
    }
  }

  // ---- Flashcards (StudyGPT lib/flashcards/parse.ts + FlashcardDeck.tsx) ----

  function parseFlashcards(source) {
    let title = null, body = source;
    const firstEnd = source.indexOf("\n");
    const first = (firstEnd === -1 ? source : source.slice(0, firstEnd)).trim();
    const titled = /^#\s+(.+)$/.exec(first);
    if (titled) { title = titled[1].trim(); body = firstEnd === -1 ? "" : source.slice(firstEnd + 1); }
    const cards = [];
    let front = null, back = null;
    const flush = () => {
      if (front !== null && back !== null) {
        const f = front.join("\n").trim(), b = back.join("\n").trim();
        if (f || b) cards.push({ front: f, back: b });
      }
      front = null; back = null;
    };
    for (const raw of body.split("\n")) {
      const m = /^(Q|A):\s?/.exec(raw);
      if (m) {
        const rest = raw.slice(m[0].length);
        if (m[1] === "Q") { flush(); front = [rest]; }
        else if (front !== null) { back = [rest]; }
      } else if (back !== null) back.push(raw);
      else if (front !== null) front.push(raw);
    }
    flush();
    return { title, cards };
  }

  function flashcardDeck(source) {
    const { title, cards } = parseFlashcards(source);
    const el = document.createElement("div");
    if (!cards.length) { el.className = "building"; el.textContent = "No flashcards found in this block."; return el; }
    el.className = "flash";
    let order = cards.map((_, i) => i), index = 0, flipped = false;
    el.innerHTML = '<div class="flash-head"><span class="title"></span><span class="count"></span></div>' +
      '<div class="flash-face" tabindex="0"><div class="side"></div><div class="prose-chat body"></div></div>' +
      '<div class="flash-bar"><button data-a="prev" title="Previous">‹</button><button data-a="flip">Flip</button><button data-a="next" title="Next">›</button><span class="spacer"></span><button data-a="shuffle">Shuffle</button></div>';
    el.querySelector(".title").textContent = title || "Flashcards";
    const draw = () => {
      const card = cards[order[index]];
      el.querySelector(".count").textContent = index + 1 + " of " + cards.length;
      el.querySelector(".side").textContent = flipped ? "Answer" : "Question";
      el.querySelector(".body").innerHTML = markdown(flipped ? card.back : card.front);
      el.querySelector('[data-a="prev"]').disabled = index === 0;
      el.querySelector('[data-a="next"]').disabled = index === cards.length - 1;
    };
    const act = (a) => {
      if (a === "flip") flipped = !flipped;
      if (a === "prev" && index > 0) { index--; flipped = false; }
      if (a === "next" && index < cards.length - 1) { index++; flipped = false; }
      if (a === "shuffle") { order = order.map((v) => [Math.random(), v]).sort((x, y) => x[0] - y[0]).map((p) => p[1]); index = 0; flipped = false; }
      draw();
    };
    el.querySelector(".flash-face").addEventListener("click", () => act("flip"));
    el.querySelector(".flash-face").addEventListener("keydown", (e) => {
      if (e.key === " " || e.key === "Enter") { e.preventDefault(); act("flip"); }
      if (e.key === "ArrowRight") act("next");
      if (e.key === "ArrowLeft") act("prev");
    });
    el.querySelectorAll("[data-a]").forEach((b) => b.addEventListener("click", () => act(b.dataset.a)));
    draw();
    return el;
  }

  // ---- Artifacts (StudyGPT Artifact.tsx): sandboxed iframe, height reported by the content ----

  const RESIZE = '<script>(function(){var last=-1;function measure(){var h=Math.max(document.body.scrollHeight,document.documentElement.scrollHeight);if(h>0&&Math.abs(h-last)>=3){last=h;parent.postMessage({__artifactHeight:h},"*");}}var raf=0;function schedule(){if(raf)return;raf=requestAnimationFrame(function(){raf=0;measure();});}if(document.readyState==="complete")schedule();else window.addEventListener("load",schedule);if(typeof ResizeObserver!=="undefined"){try{new ResizeObserver(schedule).observe(document.body);}catch(e){}}var n=0,iv=setInterval(function(){schedule();if(++n>=10)clearInterval(iv);},300);})();<\/script>';
  const frames = new Set();
  window.addEventListener("message", (e) => {
    for (const frame of frames) {
      if (e.source !== frame.contentWindow) continue;
      const h = e.data && e.data.__artifactHeight;
      if (typeof h === "number" && h > 0) frame.style.height = Math.min(1200, Math.max(240, h)) + "px";
    }
  });

  function artifact(html) {
    const el = document.createElement("div");
    el.className = "artifact";
    el.innerHTML = '<div class="artifact-head">Visualization<button class="copy">Copy HTML</button></div>';
    const frame = document.createElement("iframe");
    frame.setAttribute("sandbox", "allow-scripts");
    const i = html.lastIndexOf("</body>");
    frame.srcdoc = i >= 0 ? html.slice(0, i) + RESIZE + html.slice(i) : html + RESIZE;
    frames.add(frame);
    el.append(frame);
    el.querySelector(".copy").addEventListener("click", () => post({ type: "copy", text: html }));
    return el;
  }

  function hydrate(root, streaming) {
    root.querySelectorAll(".widget").forEach((w) => {
      const kind = w.dataset.kind, src = decodeURIComponent(w.dataset.src || "");
      if (streaming) {
        const placeholder = document.createElement("div");
        placeholder.className = "building";
        placeholder.textContent = kind === "artifact" ? "Building visualization…" : "Building flashcards…";
        w.replaceWith(placeholder);
      } else {
        w.replaceWith(kind === "artifact" ? artifact(src) : flashcardDeck(src));
      }
    });
    root.querySelectorAll("pre .copy").forEach((b) => b.addEventListener("click", () => {
      post({ type: "copy", text: b.parentElement.querySelector("code").textContent });
      b.textContent = "Copied";
      setTimeout(() => (b.textContent = "Copy"), 1200);
    }));
    root.querySelectorAll("a[data-external]").forEach((a) => a.addEventListener("click", (e) => {
      e.preventDefault();
      post({ type: "open", url: a.getAttribute("href") });
    }));
  }

  // ---- Messages ----

  const STATUS = { searching: "Searching your materials…", writing: "Writing…" };
  const sourcesOpen = new Map();

  function sourcesPanel(turn) {
    if (!turn.excerpts.length) return null;
    const cited = new Set(turn.cited);
    const materials = [];
    const byTitle = new Map();
    for (const e of turn.excerpts) {
      let m = byTitle.get(e.itemId);
      if (!m) { m = { title: e.title, course: e.course, color: e.color, items: [] }; byTitle.set(e.itemId, m); materials.push(m); }
      m.items.push(e);
    }
    const details = document.createElement("details");
    details.className = "sources";
    details.open = !!sourcesOpen.get(turn.id);
    details.addEventListener("toggle", () => sourcesOpen.set(turn.id, details.open));
    details.innerHTML = '<summary><span class="arrow">›</span>Sources<span class="meta">' + turn.excerpts.length + " excerpt" + (turn.excerpts.length === 1 ? "" : "s") +
      " from " + materials.length + " file" + (materials.length === 1 ? "" : "s") + "</span></summary>";
    for (const m of materials) {
      const used = cited.size === 0 || m.items.some((e) => cited.has(e.number));
      const box = document.createElement("div");
      box.className = "material" + (used ? "" : " unused");
      box.innerHTML = '<div class="material-head"><span class="course"></span><span class="title"></span><span class="meta"></span></div><ul class="excerpts"></ul>';
      box.querySelector(".course").style.background = m.color;
      box.querySelector(".title").textContent = m.title;
      box.querySelector(".meta").textContent = m.course;
      for (const e of m.items) {
        const li = document.createElement("li");
        li.innerHTML = '<div class="ref"></div><div class="snippet"></div>';
        li.querySelector(".ref").textContent = e.number + " · Page " + e.page;
        li.querySelector(".snippet").textContent = "“" + e.text.slice(0, 260) + (e.text.length > 260 ? "…" : "") + "”";
        li.addEventListener("click", () => post({ type: "cite", turn: turn.id, number: e.number }));
        box.querySelector(".excerpts").append(li);
      }
      details.append(box);
    }
    return details;
  }

  function renderTurn(turn) {
    const el = document.createElement("section");
    el.className = "turn";
    el.dataset.id = turn.id;

    const userRow = document.createElement("div");
    userRow.className = "row user";
    userRow.innerHTML = '<div class="user-bubble"></div>';
    userRow.querySelector(".user-bubble").textContent = turn.question;
    el.append(userRow);

    const card = document.createElement("div");
    card.className = "answer";
    const streaming = turn.phase === "searching" || turn.phase === "writing";
    if (streaming) {
      const status = document.createElement("div");
      status.className = "status";
      const label = turn.phase === "searching" ? STATUS.searching : turn.answer ? STATUS.writing : "Reading " + turn.excerpts.length + " passages…";
      status.innerHTML = '<span class="spinner"></span><span></span>';
      status.querySelector("span:last-child").textContent = label;
      card.append(status);
    }
    if (turn.answer) {
      const prose = document.createElement("div");
      prose.className = "prose-chat";
      prose.innerHTML = markdown(turn.answer);
      hydrate(prose, streaming);
      linkCitations(prose, turn.id, new Set(turn.excerpts.map((e) => e.number)));
      if (streaming) {
        const caret = document.createElement("span");
        caret.className = "caret";
        (prose.lastElementChild || prose).append(caret);
      }
      card.append(prose);
    }
    if (turn.error) {
      const error = document.createElement("div");
      error.className = "error";
      error.textContent = turn.error;
      if (turn.manageUsage) {
        const link = document.createElement("a");
        link.href = "#";
        link.textContent = " Manage usage";
        link.addEventListener("click", (e) => { e.preventDefault(); post({ type: "open", url: "https://chatgpt.com/settings/usage" }); });
        error.append(link);
      }
      card.append(error);
    }
    if (!streaming) {
      const sources = sourcesPanel(turn);
      if (sources) card.append(sources);
    }
    if (!streaming && turn.answer) {
      const footer = document.createElement("div");
      footer.className = "footer";
      if (turn.model) {
        const model = document.createElement("span");
        model.className = "model";
        model.textContent = turn.model;
        footer.append(model);
      }
      const copy = document.createElement("button");
      copy.textContent = "Copy";
      copy.addEventListener("click", () => { post({ type: "copy", text: turn.answer }); copy.textContent = "Copied"; setTimeout(() => (copy.textContent = "Copy"), 1200); });
      footer.append(copy);
      if (turn.canRegenerate) {
        const regen = document.createElement("button");
        regen.textContent = "Regenerate";
        regen.addEventListener("click", () => post({ type: "regenerate", turn: turn.id }));
        footer.append(regen);
      }
      card.append(footer);
    }
    const row = document.createElement("div");
    row.className = "row";
    row.append(card);
    el.append(row);
    return el;
  }

  function renderEmpty(empty) {
    const el = document.createElement("section");
    el.className = "empty";
    el.innerHTML = '<h1></h1><p></p><div class="chips"></div>';
    el.querySelector("h1").textContent = empty.title;
    el.querySelector("p").textContent = empty.text;
    for (const s of empty.suggestions) {
      const chip = document.createElement("button");
      chip.className = "chip";
      chip.textContent = s;
      chip.addEventListener("click", () => post({ type: "suggest", text: s }));
      el.querySelector(".chips").append(chip);
    }
    return el;
  }

  // ---- API for Swift ----

  const rendered = new Map(); // turn id → JSON last drawn
  const root = () => document.getElementById("transcript");
  const nearBottom = () => window.innerHeight + window.scrollY >= document.body.scrollHeight - 80;

  window.UP = {
    setState(state) {
      if (state.accent) document.documentElement.style.setProperty("--rule", state.accent);
      const stick = nearBottom();
      const container = root();
      if (!state.turns.length) {
        rendered.clear();
        container.replaceChildren(renderEmpty(state.empty));
        return;
      }
      container.querySelector(".empty")?.remove();
      const ids = new Set(state.turns.map((t) => t.id));
      for (const el of [...container.children]) if (!ids.has(el.dataset.id)) { rendered.delete(el.dataset.id); el.remove(); }
      let previous = null;
      for (const turn of state.turns) {
        const json = JSON.stringify(turn);
        let el = container.querySelector('[data-id="' + turn.id + '"]');
        if (!el || rendered.get(turn.id) !== json) {
          const fresh = renderTurn(turn);
          if (el) el.replaceWith(fresh); else if (previous) previous.after(fresh); else container.prepend(fresh);
          el = fresh;
          rendered.set(turn.id, json);
        }
        previous = el;
      }
      if (stick || state.scrollToEnd) window.scrollTo({ top: document.body.scrollHeight });
    },
  };

  post({ type: "ready" });
})();
