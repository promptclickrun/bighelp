// Catalog Reviewer: the reviewer-only console at bigreview, served behind Cloudflare Access.
// Same-origin JSON API under /review/*. Every piece of template or submitter data reaches the page
// through textContent or form values, never innerHTML, because community submissions are untrusted.
"use strict";

(() => {
  // ---- Shapes the catalog Worker accepts (mirrors services/catalog/src/templates.ts and variables.ts) ----
  const KINDS = ["agent", "blueprint"];
  const STATUSES = ["pending", "approved", "rejected"];
  const SOURCES = ["bighelp", "community"];
  const BOARDS = ["feed", "ideas", "goals"];
  const BLUEPRINT_CATEGORIES = ["productivity", "marketing", "content", "personal", "research"];
  const GOAL_CATEGORIES = ["health", "relationships", "finance", "career", "interests", "productivity", "other"];
  const AGENT_CATEGORIES = [
    "productivity", "business", "coding", "science", "education", "health", "creative", "personal", "leadership", "security",
  ];
  const VARIABLE_TYPES = ["text", "long_text", "choice", "number"];
  const RESERVED_KEYS = ["agent_name", "user_name"];
  const LIMITS = {
    blueprintText: 1000, name: 40, role: 80, vibe: 120, description: 240, instructions: 12000,
    creditName: 40, reviewNote: 1000, symbol: 60, variables: 12,
  };
  const KEY = /^[a-z][a-z0-9_]{0,39}$/;
  const PLACEHOLDER = /\{\{([a-z][a-z0-9_]{0,39})\}\}/g;
  const TEMPLATE_ID = /^[a-z0-9][a-z0-9-]{2,63}$/;
  const PAGE_SIZE = 200;
  const MAX_PAGES = 100; // backstop against a server that never stops paging

  const STATUS_LABEL = { pending: "Needs review", approved: "Published", rejected: "Rejected" };
  const KIND_LABEL = { agent: "Agent", blueprint: "Blueprint" };

  // ---- State ----
  /** @type {Map<string, any>} id → latest validated review row */
  const rows = new Map();
  /** id → version the reviewer saw when they ticked the row. */
  const selection = new Map();
  let view = "queue";
  let loaded = false;
  let loadSeq = 0;
  let mutationEpoch = 0;
  let mutating = false;
  let toastTimer = 0;

  const $ = (id) => document.getElementById(id);

  // ---- DOM helper: strings become text nodes, so data is never parsed as HTML ----
  function el(tag, props, ...children) {
    const node = document.createElement(tag);
    for (const [key, value] of Object.entries(props || {})) {
      if (value === undefined || value === null || value === false) continue;
      if (key === "class") node.className = value;
      else if (key === "text") node.textContent = value;
      else if (key === "value") node.value = value; // textarea content isn't an attribute
      else if (key.startsWith("on")) node.addEventListener(key.slice(2), value);
      else if (key in node && typeof value !== "string") node[key] = value;
      else node.setAttribute(key, value === true ? "" : String(value));
    }
    for (const child of children.flat()) {
      if (child === null || child === undefined || child === false) continue;
      node.append(child instanceof Node ? child : document.createTextNode(String(child)));
    }
    return node;
  }

  // ---- API ----
  class AuthError extends Error {}
  class ConflictError extends Error {}
  class ApiError extends Error {
    constructor(status, message, field) { super(message); this.status = status; this.field = field; }
  }
  class SchemaError extends Error {}

  /**
   * One same-origin request. Mutations carry the review header and, for existing rows, If-Match on the
   * version the reviewer last saw. An Access redirect or HTML login page means the session ran out.
   */
  async function api(method, path, { body, version } = {}) {
    const headers = { Accept: "application/json" };
    if (method !== "GET") {
      headers["Content-Type"] = "application/json";
      headers["X-Catalog-Review"] = "1";
      if (version !== undefined) headers["If-Match"] = `"v${version}"`;
    }
    let response;
    try {
      response = await fetch(path, {
        method, headers, credentials: "same-origin", redirect: "manual", cache: "no-store",
        body: body === undefined ? undefined : JSON.stringify(body),
      });
    } catch {
      throw new ApiError(0, "Couldn't reach the catalog. Check your connection and try again.");
    }
    if (response.type === "opaqueredirect" || (response.status >= 300 && response.status < 400) || response.redirected) {
      throw new AuthError("Your sign-in has expired.");
    }
    const isJson = (response.headers.get("Content-Type") || "").includes("application/json");
    if (!isJson && (response.status === 401 || response.status === 403 || response.ok)) {
      // Access answers an expired session with its own HTML page, not our JSON.
      throw new AuthError("Your sign-in has expired.");
    }
    let data = null;
    if (isJson) {
      try { data = await response.json(); } catch { data = null; }
    }
    if (response.status === 401) throw new AuthError("Your sign-in has expired.");
    if ((response.status === 409 || response.status === 412) && version !== undefined) {
      throw new ConflictError("This template changed somewhere else since you loaded it.");
    }
    if (!response.ok) {
      const message = data && typeof data.error === "string" ? data.error : `The catalog answered ${response.status}.`;
      throw new ApiError(response.status, message, data && typeof data.field === "string" ? data.field : undefined);
    }
    if (data === null) throw new SchemaError("The catalog sent a response this page can't read.");
    return data;
  }

  // ---- Response validation ----
  const isText = (value) => typeof value === "string";
  const isOptionalText = (value) => value === undefined || value === null || typeof value === "string";
  const isRecord = (value) => typeof value === "object" && value !== null && !Array.isArray(value);

  /** Returns a reason the row is unreadable, or "" when it matches the review row shape. */
  function rowProblem(row) {
    if (!isRecord(row)) return "not an object";
    if (!isText(row.id) || !row.id) return "missing id";
    if (!KINDS.includes(row.kind)) return "unknown kind";
    if (!STATUSES.includes(row.status)) return "unknown status";
    if (!SOURCES.includes(row.source)) return "unknown source";
    if (!isText(row.title)) return "missing title";
    if (!Number.isInteger(row.version) || row.version < 0) return "missing version";
    if (!isText(row.createdAt) || !isText(row.updatedAt)) return "missing timestamps";
    for (const key of ["credit", "submitterName", "submitterUsername", "submitterEmail", "reviewedAt", "reviewedBy", "reviewNote"]) {
      if (!isOptionalText(row[key])) return `bad ${key}`;
    }
    const github = row.submitterGithubId;
    if (!(github === undefined || github === null || isText(github) || Number.isFinite(github))) return "bad submitterGithubId";
    if (row.kind === "blueprint") {
      if (!BOARDS.includes(row.board)) return "bad board";
      if (!BLUEPRINT_CATEGORIES.includes(row.category)) return "bad category";
      if (!isText(row.text)) return "missing text";
      if (row.goalCategory !== undefined && row.goalCategory !== null && !GOAL_CATEGORIES.includes(row.goalCategory)) {
        return "bad goalCategory";
      }
    } else {
      for (const key of ["name", "role", "vibe", "instructions"]) if (!isText(row[key])) return `missing ${key}`;
      if (!AGENT_CATEGORIES.includes(row.category)) return "bad category";
      if (!isOptionalText(row.description) || !isOptionalText(row.symbol)) return "bad optional field";
      if (row.variables !== undefined && row.variables !== null
        && !(Array.isArray(row.variables) && row.variables.every(isRecord))) return "bad variables";
    }
    return "";
  }

  function validRow(data) {
    const problem = rowProblem(data);
    if (problem) throw new SchemaError(`The catalog sent a template this page can't read (${problem}).`);
    return data;
  }

  // ---- Loading ----
  async function loadSession() {
    const data = await api("GET", "/review/session");
    if (!isRecord(data) || !isText(data.reviewer)) throw new SchemaError("The session response was unreadable.");
    const identity = $("identity");
    identity.textContent = `${data.reviewer} · Access protected`;
    identity.classList.add("ok");
  }

  /** Loads every page. A newer load, or a mutation that lands meanwhile, makes this result stale. */
  async function loadAll() {
    const seq = ++loadSeq;
    const epoch = mutationEpoch;
    setListStatus("Loading templates…");
    $("load-banner").hidden = true;
    $("refresh").disabled = true;
    try {
      const fresh = new Map();
      const skipped = [];
      let offset = 0;
      let total = null;
      for (let page = 0; ; page++) {
        if (page >= MAX_PAGES) throw new SchemaError("The catalog kept paging past the limit this page reads.");
        const data = await api("GET", `/review/templates?status=all&limit=${PAGE_SIZE}&offset=${offset}`);
        if (seq !== loadSeq) return;
        if (!isRecord(data) || !Array.isArray(data.templates) || !Number.isInteger(data.total)
          || !(data.nextOffset === null || Number.isInteger(data.nextOffset))) {
          throw new SchemaError("The template list response was unreadable.");
        }
        total = data.total;
        for (const row of data.templates) {
          const problem = rowProblem(row);
          if (problem) skipped.push(isRecord(row) && isText(row.id) ? `${row.id} (${problem})` : problem);
          else fresh.set(row.id, row);
        }
        if (data.nextOffset === null) break;
        if (data.nextOffset <= offset) throw new SchemaError("The template list paged backwards.");
        offset = data.nextOffset;
      }
      if (seq !== loadSeq) return;
      if (epoch !== mutationEpoch) {
        // A save landed while this was in flight, so this snapshot may predate it. Fetch again.
        loadAll();
        return;
      }
      rows.clear();
      for (const [id, row] of fresh) rows.set(id, row);
      loaded = true;
      pruneSelection(true);
      render();
      syncEditorWithList();
      if (skipped.length) {
        showLoadBanner(`${skipped.length} template${skipped.length === 1 ? "" : "s"} couldn't be read and ${skipped.length === 1 ? "is" : "are"} hidden: ${skipped.slice(0, 5).join(", ")}${skipped.length > 5 ? "…" : ""}`, false);
      } else if (total !== null && total !== fresh.size) {
        showLoadBanner(`The catalog reported ${total} templates but sent ${fresh.size}. Refresh to try again.`, true);
      }
    } catch (error) {
      if (seq !== loadSeq) return;
      if (error instanceof AuthError) showAuthBanner();
      else showLoadBanner(`Couldn't load templates. ${error.message}`, true);
      setListStatus(loaded ? "Showing the last list that loaded." : "");
    } finally {
      if (seq === loadSeq) $("refresh").disabled = false;
    }
  }

  function showLoadBanner(message, retry) {
    const banner = $("load-banner");
    banner.replaceChildren(
      el("p", {}, message,
        retry ? el("button", { type: "button", class: "button-inline", text: "Retry", onclick: () => loadAll() }) : null),
    );
    banner.hidden = false;
  }

  function showAuthBanner() { $("auth-banner").hidden = false; }

  async function retryAuth() {
    const button = $("auth-retry");
    button.disabled = true;
    try {
      await loadSession();
      $("auth-banner").hidden = true;
      await loadAll();
      toast("You're signed in again. If a save didn't go through, try it again.");
    } catch (error) {
      if (!(error instanceof AuthError)) toast(error.message);
    } finally {
      button.disabled = false;
    }
  }

  // ---- Rendering the table ----
  function setListStatus(text) { $("list-status").textContent = text; }

  function searchText(row) {
    return [
      row.id, row.title, row.credit, row.submitterName, row.submitterUsername, row.category, row.board,
      row.text, row.name, row.role, row.vibe, row.description, row.instructions,
    ].filter(isText).join("\n").toLowerCase();
  }

  function visibleRows() {
    const query = $("search").value.trim().toLowerCase();
    const status = view === "queue" ? "pending" : $("filter-status").value;
    const kind = $("filter-kind").value;
    const list = [...rows.values()].filter((row) =>
      (status === "all" || row.status === status)
      && (kind === "all" || row.kind === kind)
      && (!query || searchText(row).includes(query)));
    // The queue reads oldest first, like an inbox; the library shows recent changes first.
    list.sort(view === "queue"
      ? (a, b) => a.createdAt.localeCompare(b.createdAt)
      : (a, b) => b.updatedAt.localeCompare(a.updatedAt));
    return list;
  }

  function formatDate(value) {
    if (!value) return "—";
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) return value;
    return date.toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" });
  }

  function formatDateTime(value) {
    if (!value) return "—";
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) return value;
    return date.toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });
  }

  function author(row) {
    if (row.credit) return row.credit;
    if (row.submitterUsername) return `@${row.submitterUsername}`;
    return row.source === "bighelp" ? "bighelp" : "—";
  }

  function statusTag(status) { return el("span", { class: `tag ${status}`, text: STATUS_LABEL[status] }); }

  function render() {
    const queue = view === "queue";
    for (const tab of document.querySelectorAll(".section-tab")) {
      if (tab.dataset.view === view) tab.setAttribute("aria-current", "page");
      else tab.removeAttribute("aria-current");
    }
    $("page-title").textContent = queue ? "Review queue" : "All templates";
    $("page-desc").textContent = queue
      ? "Community templates stay private until you approve them."
      : "Manage published templates and submissions in one place.";
    $("filter-status").hidden = queue;
    $("table-caption").textContent = queue ? "Templates waiting for review" : "All templates";

    if (loaded) {
      const pending = [...rows.values()].filter((row) => row.status === "pending").length;
      $("count-queue").textContent = String(pending);
      $("count-all").textContent = String(rows.size);
      $("count-queue").hidden = false;
      $("count-all").hidden = false;
    }

    const list = visibleRows();
    const body = $("rows");
    if (!loaded) {
      body.replaceChildren(el("tr", {}, el("td", { colspan: 8, class: "empty", text: "Loading…" })));
    } else if (!list.length) {
      const filtered = $("search").value.trim() || $("filter-kind").value !== "all" || (!queue && $("filter-status").value !== "all");
      body.replaceChildren(el("tr", {}, el("td", {
        colspan: 8, class: "empty",
        text: filtered ? "No templates match." : queue ? "Nothing is waiting for review." : "There are no templates yet.",
      })));
    } else {
      body.replaceChildren(...list.map(rowNode));
    }
    if (loaded) setListStatus(`Showing ${list.length} of ${rows.size} template${rows.size === 1 ? "" : "s"}.`);
    renderSelection(list);
  }

  function rowNode(row) {
    const checked = selection.has(row.id);
    const label = `Select ${row.title}`;
    const typeLine = row.kind === "blueprint" ? `${KIND_LABEL.blueprint} · ${capital(row.board)}` : KIND_LABEL.agent;
    const category = row.kind === "blueprint" && row.board === "goals" && row.goalCategory
      ? `${capital(row.category)} · ${capital(row.goalCategory)}`
      : capital(row.category);
    return el("tr", { class: checked ? "is-selected" : "" },
      el("td", { class: "check" }, el("label", {},
        el("input", {
          type: "checkbox", checked, "aria-label": label,
          onchange: (event) => {
            if (event.target.checked) selection.set(row.id, row.version);
            else selection.delete(row.id);
            // Update in place so keyboard focus stays on this checkbox.
            event.target.closest("tr").classList.toggle("is-selected", event.target.checked);
            renderSelection(visibleRows());
          },
        }))),
      el("td", {}, el("span", { class: "title", text: row.title }), el("small", { text: row.id })),
      el("td", { class: "nowrap", text: typeLine }),
      el("td", { class: "nowrap" }, statusTag(row.status),
        el("span", { class: "tag source", text: row.source === "community" ? "Community" : "bighelp" })),
      el("td", { class: "nowrap", text: category }),
      el("td", {}, el("span", { text: author(row) }),
        row.submitterName && row.source === "community" ? el("small", { text: row.submitterName }) : null),
      el("td", { class: "nowrap", text: formatDate(row.updatedAt) }),
      el("td", { class: "actions" }, el("button", {
        type: "button", text: view === "queue" ? "Review" : "Edit", "aria-label": `${view === "queue" ? "Review" : "Edit"} ${row.title}`,
        onclick: () => openEditor(row.id, view === "queue" ? "preview" : "edit"),
      })),
    );
  }

  function capital(value) { return value ? value.charAt(0).toUpperCase() + value.slice(1) : ""; }

  /** Drops ticks on rows that are gone, filtered out, or (after a reload) changed since they were ticked. */
  function pruneSelection(afterReload) {
    const visible = new Set(visibleRows().map((row) => row.id));
    let changed = 0;
    for (const [id, version] of selection) {
      const row = rows.get(id);
      if (!row || !visible.has(id)) selection.delete(id);
      else if (afterReload && row.version !== version) { selection.delete(id); changed++; }
    }
    if (changed) toast(`${changed} selected template${changed === 1 ? "" : "s"} changed elsewhere and ${changed === 1 ? "was" : "were"} unselected.`);
  }

  function renderSelection(list) {
    const shown = list.filter((row) => selection.has(row.id)).length;
    const all = $("select-all");
    all.checked = list.length > 0 && shown === list.length;
    all.indeterminate = shown > 0 && shown < list.length;
    all.disabled = !list.length;
    const count = selection.size;
    $("selected-count").textContent = count
      ? `${count} template${count === 1 ? "" : "s"} selected`
      : "Select templates to manage them together.";
    $("bulk-unpublish").disabled = mutating || ![...selection.keys()].some((id) => rows.get(id)?.status === "approved");
    $("bulk-delete").disabled = mutating || count === 0;
  }

  function setMutating(on) {
    mutating = on;
    if (session?.fields) for (const { input } of Object.values(session.fields)) input.disabled = on;
    for (const button of document.querySelectorAll("[data-mutates]")) {
      if (on) button.disabled = true;
    }
    if (!on) {
      $("new-template").disabled = false;
      renderSelection(visibleRows());
    } else {
      $("bulk-unpublish").disabled = true;
      $("bulk-delete").disabled = true;
    }
    if (editor.open) renderEditorActions();
  }

  /** Records a server row after a mutation. Never replaces a newer version with an older one. */
  function acceptRow(row) {
    const current = rows.get(row.id);
    if (!current || current.version <= row.version) rows.set(row.id, row);
    // The reviewer made this change, so a ticked row follows it instead of looking stale.
    if (selection.has(row.id)) selection.set(row.id, row.version);
    mutationEpoch++;
  }

  function toast(message) {
    const node = $("toast");
    node.textContent = message;
    node.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { node.hidden = true; }, 5000);
  }

  // ---- Confirmation dialog ----
  /**
   * Asks the reviewer to confirm. Options: title, body (nodes/strings), confirm label, danger,
   * note {label, required, placeholder}, typed (exact phrase to type), info (one Close button).
   * Resolves to {note} on confirm or null on cancel.
   */
  function ask({ title, body = [], confirm = "Confirm", danger = false, note, typed, info = false }) {
    const dialog = $("prompt");
    $("prompt-title").textContent = title;
    $("prompt-body").replaceChildren(...[body].flat().map((part) => (part instanceof Node ? part : el("p", { text: part }))));
    const noteField = $("prompt-note");
    const typedField = $("prompt-typed");
    const errorNode = $("prompt-error");
    $("prompt-note-wrap").hidden = !note;
    noteField.value = "";
    noteField.removeAttribute("aria-invalid");
    if (note) {
      $("prompt-note-label").textContent = note.label;
      noteField.placeholder = note.placeholder || "";
    }
    $("prompt-typed-wrap").hidden = !typed;
    typedField.value = "";
    if (typed) $("prompt-typed-label").textContent = `Type ${typed} to confirm`;
    errorNode.hidden = true;
    const confirmButton = $("prompt-confirm");
    confirmButton.textContent = info ? "Close" : confirm;
    confirmButton.className = danger ? "danger solid" : "primary";
    $("prompt-cancel").hidden = info;

    return new Promise((resolve) => {
      const finish = (result) => {
        form.removeEventListener("submit", onSubmit);
        cancelButton.removeEventListener("click", onCancel);
        dialog.removeEventListener("cancel", onEscape);
        dialog.close();
        resolve(result);
      };
      const form = $("prompt-form");
      const cancelButton = $("prompt-cancel");
      const onSubmit = (event) => {
        event.preventDefault();
        if (info) return finish({});
        const text = noteField.value.trim();
        if (note?.required && !text) return fail(noteField, "Say why, so the submitter knows what to change.");
        if (text.length > LIMITS.reviewNote) return fail(noteField, `Keep it under ${LIMITS.reviewNote} characters.`);
        if (typed && typedField.value.trim() !== typed) return fail(typedField, `Type ${typed} exactly.`);
        finish({ note: text || undefined });
      };
      const fail = (field, message) => {
        errorNode.textContent = message;
        errorNode.hidden = false;
        field.setAttribute("aria-invalid", "true");
        field.focus();
      };
      const onCancel = () => finish(null);
      const onEscape = (event) => { event.preventDefault(); finish(info ? {} : null); };
      form.addEventListener("submit", onSubmit);
      cancelButton.addEventListener("click", onCancel);
      dialog.addEventListener("cancel", onEscape);
      dialog.showModal();
      (note ? noteField : typed ? typedField : confirmButton).focus();
    });
  }

  // ---- Editor dialog ----
  const editor = $("editor");
  /**
   * The open editor. `row` is the snapshot being edited (null when creating); `initial` is the
   * serialized form right after it was built, so `dirty` compares against what the server had.
   */
  let session = null;

  function openEditor(id, tab) {
    const row = rows.get(id);
    if (!row) return;
    session = { mode: "edit", row, kind: row.kind, tab, busy: "", stale: "", fields: {} };
    buildEditForm();
    showEditor();
  }

  function openCreate() {
    session = { mode: "create", row: null, kind: "agent", tab: "edit", busy: "", stale: "", fields: {} };
    buildEditForm();
    showEditor();
  }

  function showEditor() {
    hideEditorError();
    renderEditorChrome();
    selectTab(session.tab);
    if (!editor.open) editor.showModal();
  }

  function renderEditorChrome() {
    const row = session.row;
    const tag = $("editor-tag");
    if (row) {
      tag.className = `tag ${row.status}`;
      tag.textContent = STATUS_LABEL[row.status];
      $("editor-title").textContent = row.title;
      const by = row.source === "community" ? `Submitted by ${author(row)}` : `Credit: ${author(row)}`;
      $("editor-meta").textContent = `${KIND_LABEL[row.kind]} · ${row.id} · ${by}`;
      const live = $("editor-live");
      live.hidden = row.status !== "approved";
      live.textContent = "Published. Saved edits go live in the public catalog right away.";
    } else {
      tag.className = "tag approved";
      tag.textContent = "New";
      $("editor-title").textContent = "New template";
      $("editor-meta").textContent = "Templates you create here are published straight away, credited as you choose.";
      $("editor-live").hidden = true;
    }
    $("tab-details").hidden = !row;
    renderEditorActions();
  }

  function selectTab(tab) {
    if (tab === "details" && !session.row) tab = "edit";
    session.tab = tab;
    for (const name of ["preview", "edit", "details"]) {
      const selected = name === tab;
      $(`tab-${name}`).setAttribute("aria-selected", String(selected));
      $(`tab-${name}`).tabIndex = selected ? 0 : -1;
      $(`panel-${name}`).hidden = !selected;
    }
    if (tab === "preview") renderPreview();
    if (tab === "details") renderDetails();
    renderEditorActions();
  }

  // Form construction. Each field records its input and error node by payload field name.
  function field(name, label, input, help) {
    const error = el("p", { class: "field-error", role: "alert", hidden: true });
    input.id = `f-${name}`;
    input.name = name;
    input.addEventListener("input", onFormInput);
    // Text fields already emit input. Replacing actions on blur can swallow the pending click.
    if (name === "kind") input.addEventListener("change", onFormInput);
    session.fields[name] = { input, error };
    return el("label", { for: input.id }, label, input, help ? el("small", { text: help }) : null, error);
  }

  function select(options, value, labels) {
    return el("select", {}, options.map((option) =>
      el("option", { value: option, selected: option === value, text: labels ? labels(option) : capital(option) })));
  }

  function buildEditForm() {
    session.fields = {};
    const row = session.row;
    const kind = session.kind;
    const value = (key) => (row && isText(row[key]) ? row[key] : "");
    const form = el("form", { class: "form", novalidate: true, onsubmit: (event) => { event.preventDefault(); save(); } });

    if (session.mode === "create") {
      form.append(el("div", { class: "two" },
        field("kind", "Template type", select(KINDS, kind, (option) => KIND_LABEL[option])),
        field("id", "Template id (optional)", el("input", { autocomplete: "off", spellcheck: "false", placeholder: "weekly-reset" }),
          "Lowercase letters, digits and dashes. Leave empty to get one made for you."),
      ));
    }

    if (kind === "blueprint") {
      const board = row ? row.board : "feed";
      form.append(
        el("div", { class: "two" },
          field("board", "Board", select(BOARDS, board)),
          field("category", "Category", select(BLUEPRINT_CATEGORIES, row ? row.category : "productivity")),
        ),
        field("goalCategory", "Goal section", select(GOAL_CATEGORIES, (row && row.goalCategory) || "other"),
          "Only used for the Goals board."),
        field("text", "Prompt", el("textarea", { rows: 8, value: value("text") }),
          "Parts people fill in go in [brackets]. 20 to 1,000 characters."),
      );
    } else {
      form.append(
        el("div", { class: "two" },
          field("name", "Name", el("input", { value: value("name"), autocomplete: "off" }), "Up to 40 characters."),
          field("category", "Topic", select(AGENT_CATEGORIES, row ? row.category : "productivity")),
        ),
        field("role", "Role", el("input", { value: value("role"), autocomplete: "off" }), "Up to 80 characters. May use {{variables}}."),
        field("vibe", "Vibe", el("input", { value: value("vibe"), autocomplete: "off" }), "Up to 120 characters."),
        field("description", "Description (optional)", el("textarea", { rows: 3, value: value("description") }),
          "What it's especially good at, shown on its card. Up to 240 characters. May use {{variables}}."),
        field("symbol", "SF Symbol (optional)", el("input", { value: value("symbol"), autocomplete: "off", spellcheck: "false", placeholder: "sparkles" }),
          "An SF Symbol name for its card, like book.closed."),
        field("instructions", "Instructions", el("textarea", { rows: 12, value: value("instructions") }),
          "Its personality. {{agent_name}} and {{user_name}} are filled in by the app; declare any other {{key}} under Variables."),
        field("variables", "Variables (JSON, optional)", el("textarea", {
          class: "code", rows: 10, spellcheck: "false",
          value: row && Array.isArray(row.variables) && row.variables.length ? JSON.stringify(row.variables, null, 2) : "",
          placeholder: '[\n  { "key": "topic", "label": "Topic", "type": "text", "required": true }\n]',
        }), "A list of variable objects: key, label, type (text, long_text, choice, number), required, and the optional fields in docs/TEMPLATE_VARIABLES.md. Leave empty for none."),
      );
    }

    form.append(field("creditName", "Public credit (optional)", el("input", { value: row && isText(row.credit) ? row.credit : "", autocomplete: "off" }),
      "Shown on the public card. Up to 40 characters. Leave empty for no credit."));
    $("panel-edit").replaceChildren(form);
    updateGoalVisibility();
    session.initial = serializeForm();
  }

  function serializeForm() {
    const values = {};
    for (const [name, { input }] of Object.entries(session.fields)) values[name] = input.value;
    return JSON.stringify(values);
  }

  function isDirty() { return !!session && serializeForm() !== session.initial; }

  function updateGoalVisibility() {
    const goal = session.fields.goalCategory;
    if (goal) goal.input.closest("label").hidden = session.fields.board.input.value !== "goals";
  }

  async function onFormInput(event) {
    if (event.target.name === "kind" && event.type === "change") {
      const next = event.target.value;
      if (next === session.kind) return;
      // Only the type-specific fields are lost on a switch; id and credit carry over.
      const now = JSON.parse(serializeForm());
      const before = JSON.parse(session.initial);
      const wasDirty = Object.keys(now).some((key) => !["kind", "id", "creditName"].includes(key) && now[key] !== before[key]);
      if (wasDirty) {
        const ok = await ask({
          title: "Switch template type?", body: "Switching type clears the fields you've filled in.", confirm: "Switch type",
        });
        if (!ok) { event.target.value = session.kind; return; }
      }
      const id = session.fields.id.input.value;
      const credit = session.fields.creditName.input.value;
      session.kind = next;
      buildEditForm();
      session.fields.id.input.value = id;
      session.fields.creditName.input.value = credit;
      session.fields.kind.input.focus();
      renderEditorActions();
      return;
    }
    if (event.target.name === "board") updateGoalVisibility();
    clearFieldError(event.target.name);
    renderEditorActions();
  }

  function clearFieldError(name) {
    const entry = session.fields[name];
    if (!entry) return;
    entry.error.hidden = true;
    entry.input.removeAttribute("aria-invalid");
  }

  function setFieldError(name, message) {
    const entry = session.fields[name];
    if (!entry) return false;
    entry.error.textContent = message;
    entry.error.hidden = false;
    entry.input.setAttribute("aria-invalid", "true");
    return true;
  }

  // Client checks mirror the Worker's so most mistakes show up before a round trip.
  // The Worker stays authoritative: its 400 {error, field} lands on the same fields.
  const collapse = (value) => value.replace(/\r\n?/g, "\n").trim().replace(/\s+/g, " ");
  const multiline = (value) => value.replace(/\r\n?/g, "\n").trim();

  /** Reads the form into a request body, or returns field errors. Clears optional fields with null. */
  function readForm() {
    const v = (name) => session.fields[name]?.input.value ?? "";
    const errors = [];
    const err = (name, message) => errors.push([name, message]);
    const body = {};

    if (session.kind === "blueprint") {
      body.board = v("board");
      body.category = v("category");
      body.text = multiline(v("text"));
      if (body.text.length < 20) err("text", "Write at least 20 characters.");
      if (body.text.length > LIMITS.blueprintText) err("text", `Keep it under ${LIMITS.blueprintText} characters (now ${body.text.length}).`);
      if (body.board === "goals") body.goalCategory = v("goalCategory");
    } else {
      body.name = collapse(v("name"));
      body.role = collapse(v("role"));
      body.vibe = collapse(v("vibe"));
      body.description = collapse(v("description")) || null;
      body.instructions = multiline(v("instructions"));
      body.category = v("category");
      body.symbol = collapse(v("symbol")) || null;
      const lengths = [["name", LIMITS.name, 1], ["role", LIMITS.role, 2], ["vibe", LIMITS.vibe, 2]];
      for (const [name, max, min] of lengths) {
        if (body[name].length < min) err(name, "This one is required.");
        else if (body[name].length > max) err(name, `Keep it under ${max} characters (now ${body[name].length}).`);
      }
      if (body.description && body.description.length > LIMITS.description) {
        err("description", `Keep it under ${LIMITS.description} characters (now ${body.description.length}).`);
      }
      if (body.instructions.length < 80) err("instructions", "Write at least 80 characters.");
      if (body.instructions.length > LIMITS.instructions) err("instructions", `Keep it under ${LIMITS.instructions} characters.`);
      if (body.symbol && (body.symbol.length > LIMITS.symbol || !/^[a-z0-9.]+$/.test(body.symbol))) err("symbol", "Use an SF Symbol name.");
      for (const name of ["name", "vibe"]) {
        if (body[name].includes("{{") || body[name].includes("}}")) err(name, "Variables go in the instructions, role or description, not here.");
      }
      body.variables = null;
      const raw = v("variables").trim();
      if (raw) {
        try {
          body.variables = JSON.parse(raw);
        } catch (error) {
          err("variables", `That isn't valid JSON: ${error.message}`);
        }
      }
      if (!errors.some(([name]) => name === "variables")) {
        for (const problem of variableProblems(body)) err(...problem);
      }
      if (Array.isArray(body.variables) && !body.variables.length) body.variables = null;
    }

    const credit = collapse(v("creditName"));
    if (credit.length > LIMITS.creditName) err("creditName", `Keep it under ${LIMITS.creditName} characters.`);
    body.creditName = credit || null;

    if (session.mode === "create") {
      body.kind = session.kind;
      const id = v("id").trim();
      if (id && !TEMPLATE_ID.test(id)) err("id", "Use lowercase letters, digits and dashes, 3 to 64 characters.");
      if (id) body.id = id;
      for (const key of Object.keys(body)) if (body[key] === null) delete body[key];
    }
    return { body, errors };
  }

  /** The structural checks from variables.ts that are cheap to run here. */
  function variableProblems(body) {
    const problems = [];
    const texts = { role: body.role, description: body.description, instructions: body.instructions };
    const used = new Map();
    for (const [name, text] of Object.entries(texts)) {
      if (!text) continue;
      const rest = text.replace(PLACEHOLDER, "");
      if (rest.includes("{{") || rest.includes("}}")) {
        problems.push([name, "Use {{ and }} only around a variable key, like {{agent_role}}."]);
      }
      for (const match of text.matchAll(PLACEHOLDER)) if (!used.has(match[1])) used.set(match[1], name);
    }
    const list = body.variables;
    const declared = new Set();
    if (list !== null) {
      if (!Array.isArray(list)) return [...problems, ["variables", "Send a list ([…]) of variables."]];
      if (list.length > LIMITS.variables) problems.push(["variables", `Use at most ${LIMITS.variables} variables.`]);
      list.forEach((entry, index) => {
        const at = `variables[${index}]`;
        if (!isRecord(entry)) { problems.push(["variables", `${at}: each variable is an object.`]); return; }
        if (!isText(entry.key) || !KEY.test(entry.key)) {
          problems.push(["variables", `${at}.key: use lowercase letters, digits and underscores, starting with a letter.`]);
          return;
        }
        if (RESERVED_KEYS.includes(entry.key)) problems.push(["variables", `${at}.key: ${entry.key} is filled in automatically. Remove it.`]);
        if (declared.has(entry.key)) problems.push(["variables", `${at}.key: ${entry.key} is already declared.`]);
        declared.add(entry.key);
        if (!used.has(entry.key) && !RESERVED_KEYS.includes(entry.key)) {
          problems.push(["variables", `${at}.key: the text never uses {{${entry.key}}}. Use it or remove it.`]);
        }
        if (!isText(entry.label) || !entry.label.trim()) problems.push(["variables", `${at}.label: give it a label.`]);
        if (!VARIABLE_TYPES.includes(entry.type)) problems.push(["variables", `${at}.type: pick one of ${VARIABLE_TYPES.join(", ")}.`]);
        if (entry.type === "choice" && (!Array.isArray(entry.options) || entry.options.length < 2 || entry.options.length > 12)) {
          problems.push(["variables", `${at}.options: give 2 to 12 options.`]);
        }
      });
    }
    for (const [key, name] of used) {
      if (!RESERVED_KEYS.includes(key) && !declared.has(key)) {
        problems.push([name, `{{${key}}} isn't in variables. Add it there or take it out of the text.`]);
      }
    }
    return problems;
  }

  function showFormErrors(errors) {
    for (const name of Object.keys(session.fields)) clearFieldError(name);
    const byField = new Map();
    for (const [name, message] of errors) byField.set(name, [...(byField.get(name) || []), message]);
    for (const [name, messages] of byField) setFieldError(name, messages.join(" "));
    selectTab("edit");
    const first = errors[0] && session.fields[errors[0][0]];
    if (first) first.input.focus();
    showEditorError(`Fix ${errors.length === 1 ? "the highlighted field" : `${errors.length} problems`} before saving.`);
  }

  /** Puts a Worker validation error on its field (variables[2].options → the variables box). */
  function showServerFieldError(error) {
    let name = error.field || "";
    if (name.startsWith("variables")) name = "variables";
    if (name === "note") name = "";
    const message = error.field && error.field.startsWith("variables[") ? `${error.field}: ${error.message}` : error.message;
    if (name && setFieldError(name, message)) {
      selectTab("edit");
      session.fields[name].input.focus();
      showEditorError("The catalog didn't accept that. See the highlighted field.");
    } else {
      showEditorError(error.message);
    }
  }

  function showEditorError(message, action) {
    const node = $("editor-error");
    node.replaceChildren(el("p", {}, message, action || null));
    node.hidden = false;
  }

  function hideEditorError() { $("editor-error").hidden = true; }

  // Preview reflects the form as it stands, so a reviewer can check edits before saving.
  function draftValues() {
    const source = {};
    for (const [name, { input }] of Object.entries(session.fields)) source[name] = input.value;
    return source;
  }

  function highlighted(text, pattern) {
    const node = el("pre", { class: "prompt-text" });
    const parts = text.split(pattern);
    parts.forEach((part, index) => {
      if (!part) return;
      node.append(index % 2 ? el("span", { class: "slot", text: part }) : document.createTextNode(part));
    });
    return node;
  }

  function renderPreview() {
    const draft = draftValues();
    const panel = $("panel-preview");
    const parts = [];
    if (isDirty()) parts.push(el("p", { class: "notice", text: "Showing your unsaved edits." }));
    if (session.kind === "blueprint") {
      parts.push(el("p", { class: "preview-label", text: "Prompt" }),
        highlighted(draft.text || "", /(\[[^\]\n]+\])/),
        facts([
          ["Board", capital(draft.board)],
          ["Category", capital(draft.category)],
          draft.board === "goals" ? ["Goal section", capital(draft.goalCategory)] : null,
          ["Credit", collapse(draft.creditName || "") || "None"],
        ]));
    } else {
      parts.push(facts([
        ["Name", draft.name], ["Role", draft.role], ["Vibe", draft.vibe],
        ["Description", draft.description || "—"], ["Topic", capital(draft.category)],
        ["Symbol", draft.symbol || "—"], ["Credit", collapse(draft.creditName || "") || "None"],
      ]));
      parts.push(el("p", { class: "preview-label", text: "Instructions" }),
        highlighted(draft.instructions || "", /(\{\{[a-z][a-z0-9_]{0,39}\}\})/));
      let variables = null;
      try { variables = draft.variables.trim() ? JSON.parse(draft.variables) : []; } catch { variables = null; }
      parts.push(el("p", { class: "preview-label", text: "Variables" }));
      if (variables === null || !Array.isArray(variables)) {
        parts.push(el("p", { class: "field-error", text: "The variables JSON isn't a valid list yet." }));
      } else if (!variables.length) {
        parts.push(el("p", { class: "muted", text: "None." }));
      } else {
        parts.push(el("ul", { class: "var-list" }, variables.map((variable) => el("li", {},
          el("code", { text: `{{${isRecord(variable) ? variable.key : "?"}}}` }),
          ` ${isRecord(variable) && isText(variable.label) ? variable.label : ""} · ${isRecord(variable) ? variable.type : ""}`,
          isRecord(variable) && variable.required === false ? " · optional" : "",
          isRecord(variable) && Array.isArray(variable.options) ? ` · ${variable.options.join(" / ")}` : "",
        ))));
      }
    }
    panel.replaceChildren(...parts);
  }

  function facts(pairs) {
    return el("dl", { class: "facts" }, pairs.filter(Boolean).flatMap(([term, value]) =>
      [el("dt", { text: term }), el("dd", { text: value === null || value === undefined || value === "" ? "—" : String(value) })]));
  }

  function renderDetails() {
    const row = session.row;
    if (!row) return;
    $("panel-details").replaceChildren(facts([
      ["Template id", row.id],
      ["Status", STATUS_LABEL[row.status]],
      ["Source", row.source === "community" ? "Community submission" : "bighelp"],
      ["Version", row.version],
      ["Public credit", row.credit],
      ["Submitter name", row.submitterName],
      ["Submitter username", row.submitterUsername ? `@${row.submitterUsername}` : null],
      ["Submitter email (private)", row.submitterEmail],
      ["Submitter GitHub id", row.submitterGithubId],
      ["Created", formatDateTime(row.createdAt)],
      ["Updated", formatDateTime(row.updatedAt)],
      ["Reviewed", row.reviewedAt ? formatDateTime(row.reviewedAt) : null],
      ["Reviewed by", row.reviewedBy],
      ["Review note", row.reviewNote],
    ]));
  }

  function actionButton(label, className, onClick, disabled) {
    return el("button", { type: "button", class: className, text: label, disabled, onclick: onClick });
  }

  function renderEditorActions() {
    if (!session) return;
    const row = session.row;
    const dirty = isDirty();
    const locked = mutating || !!session.busy;
    const actions = [];
    let hint = "";
    if (session.mode === "create") {
      actions.push(actionButton("Cancel", "", () => requestClose(), !!session.busy));
      actions.push(actionButton(session.busy ? "Publishing…" : "Publish template", "primary", () => save(), locked));
    } else {
      const gone = session.stale === "deleted";
      actions.push(actionButton("Delete", "danger", () => deleteOne(), locked || gone));
      if (row.status === "pending") {
        actions.push(actionButton("Reject with reason", "danger", () => transition("reject"), locked || dirty || gone));
      }
      if (row.status !== "approved") {
        actions.push(actionButton("Approve & publish", "primary", () => transition("approve"), locked || dirty || gone));
      } else {
        actions.push(actionButton("Unpublish", "", () => transition("unpublish"), locked || dirty || gone));
      }
      actions.push(actionButton(session.busy === "save" ? "Saving…" : row.status === "approved" ? "Save live changes" : "Save changes",
        row.status === "pending" ? "" : "primary", () => save(), locked || !dirty || gone));
      if (dirty && row.status !== "rejected") hint = "Save or discard your edits before changing the status.";
      else if (dirty) hint = "You have unsaved edits.";
      if (session.stale === "changed") hint = "This template changed elsewhere. Reload it before saving.";
      if (gone) hint = "This template was deleted elsewhere.";
    }
    if (session.busy) hint = "Working…";
    $("editor-hint").textContent = hint;
    $("editor-actions").replaceChildren(...actions);
    $("editor-close").disabled = !!session.busy;
  }

  async function requestClose() {
    if (!session || session.busy) return;
    if (isDirty()) {
      const ok = await ask({ title: "Discard your edits?", body: "Your changes to this template haven't been saved.", confirm: "Discard edits", danger: true });
      if (!ok) return;
    }
    closeEditor();
  }

  function closeEditor() {
    session = null;
    editor.close();
  }

  /** After a list reload: refresh a clean editor in place, or warn a dirty one instead of overwriting. */
  function syncEditorWithList() {
    if (!session || !session.row || !editor.open || session.busy) return;
    const fresh = rows.get(session.row.id);
    if (!fresh) {
      session.stale = "deleted";
      showEditorError("This template was deleted elsewhere. Copy anything you need, then close.");
    } else if (fresh.version !== session.row.version) {
      if (isDirty()) {
        session.stale = "changed";
        showEditorError("Someone changed this template elsewhere while you were editing. Your edits weren't saved.",
          reloadLatestButton());
      } else {
        session.row = fresh;
        session.stale = "";
        const tab = session.tab;
        buildEditForm();
        renderEditorChrome();
        selectTab(tab);
      }
    }
    renderEditorActions();
  }

  function reloadLatestButton() {
    return el("button", {
      type: "button", class: "button-inline", text: "Load latest (discards your edits)",
      onclick: async () => {
        if (!session) return;
        const id = session.row.id;
        const tab = session.tab;
        await loadAll();
        if (!session || session.row?.id !== id) return;
        const fresh = rows.get(id);
        if (!fresh) { session.stale = "deleted"; renderEditorActions(); return; }
        session.row = fresh;
        session.stale = "";
        buildEditForm();
        hideEditorError();
        renderEditorChrome();
        selectTab(tab);
      },
    });
  }

  /** Runs one editor mutation with the global lock held; maps failures onto the editor. */
  async function withEditorLock(label, work) {
    if (mutating || !session || session.busy) return;
    const owner = session;
    owner.busy = label;
    hideEditorError();
    setMutating(true);
    try {
      await work(owner);
    } catch (error) {
      if (session !== owner) { toast(error.message); return; }
      if (error instanceof AuthError) {
        showAuthBanner();
        showEditorError("Your sign-in expired, so nothing was changed. Your edits are still here: sign in again, then retry.");
      } else if (error instanceof ConflictError) {
        owner.stale = "changed";
        showEditorError("Someone changed this template elsewhere since you opened it, so nothing was overwritten.",
          reloadLatestButton());
      } else if (error instanceof ApiError && error.status === 400) {
        showServerFieldError(error);
      } else if (error instanceof ApiError && error.status === 409 && owner.mode === "create" && setFieldError("id", error.message)) {
        selectTab("edit");
        showEditorError(error.message);
      } else if (error instanceof ApiError && error.status === 404 && owner.row) {
        owner.stale = "deleted";
        showEditorError("This template no longer exists. It was probably deleted elsewhere.");
      } else {
        showEditorError(error.message);
      }
    } finally {
      owner.busy = "";
      setMutating(false);
    }
  }

  function save() {
    if (!session || !session.fields) return;
    if (session.mode === "edit" && !isDirty()) return;
    const { body, errors } = readForm();
    if (errors.length) { showFormErrors(errors); return; }
    return withEditorLock("save", async (owner) => {
      if (owner.mode === "create") {
        const row = validRow(await api("POST", "/review/templates", { body }));
        acceptRow(row);
        render();
        if (session === owner) closeEditor();
        toast(`Published “${row.title}”.`);
      } else {
        const row = validRow(await api("PATCH", `/review/templates/${encodeURIComponent(owner.row.id)}`,
          { body, version: owner.row.version }));
        acceptRow(row);
        render();
        if (session !== owner) return;
        const tab = owner.tab;
        owner.row = row;
        buildEditForm();
        renderEditorChrome();
        selectTab(tab);
        toast(row.status === "approved" ? "Saved. The live template is updated." : "Saved.");
      }
    });
  }

  async function transition(action) {
    if (!session?.row || mutating) return;
    const row = session.row;
    const prompts = {
      approve: { title: "Approve and publish?", body: `“${row.title}” will appear in the public bighelp catalog.`,
        confirm: "Approve & publish", note: { label: "Note for the submitter (optional)" } },
      reject: { title: "Reject this submission?", body: "Explain what needs to change. The submitter can read this with their private receipt.",
        confirm: "Reject", danger: true, note: { label: "Reason", required: true, placeholder: "Please make the prompt more specific and remove personal information." } },
      unpublish: { title: "Unpublish this template?", body: "It leaves the public catalog and goes back to the review queue. Nothing is deleted.",
        confirm: "Unpublish", note: { label: "Note (optional)" } },
    };
    const answer = await ask(prompts[action]);
    if (!answer || session?.row !== row) return;
    await withEditorLock(action, async (owner) => {
      const updated = validRow(await api("POST", `/review/templates/${encodeURIComponent(row.id)}/${action}`,
        { body: answer.note ? { note: answer.note } : {}, version: row.version }));
      acceptRow(updated);
      selection.delete(row.id);
      render();
      if (session === owner) closeEditor();
      toast({ approve: `Published “${updated.title}”.`, reject: `Rejected “${updated.title}”.`, unpublish: `Unpublished “${updated.title}”.` }[action]);
    });
  }

  async function deleteOne() {
    if (!session?.row || mutating) return;
    const row = session.row;
    const answer = await ask({
      title: "Delete this template?", danger: true, confirm: "Delete permanently", typed: "DELETE",
      body: [`“${row.title}” (${row.id}) will be permanently deleted. This can't be undone.`],
    });
    if (!answer || session?.row !== row) return;
    await withEditorLock("delete", async (owner) => {
      const result = await api("DELETE", `/review/templates/${encodeURIComponent(row.id)}`, { version: row.version });
      if (!isRecord(result) || result.id !== row.id || result.deleted !== true) throw new SchemaError("The delete response was unreadable. Refresh to check.");
      rows.delete(row.id);
      selection.delete(row.id);
      mutationEpoch++;
      render();
      if (session === owner) closeEditor();
      toast(`Deleted “${row.title}”.`);
    });
  }

  // ---- Bulk actions ----
  /**
   * Runs one action per template, one at a time, against a frozen snapshot of id + version.
   * Stops early if sign-in expires. Reports exactly what succeeded and what didn't.
   */
  async function runBulk(action, items, note) {
    setMutating(true);
    const done = [];
    const failed = [];
    let stoppedAt = -1;
    try {
      for (let index = 0; index < items.length; index++) {
        const item = items[index];
        setListStatus(`${action === "delete" ? "Deleting" : "Unpublishing"} ${index + 1} of ${items.length}…`);
        try {
          const path = `/review/templates/${encodeURIComponent(item.id)}`;
          if (action === "delete") {
            const result = await api("DELETE", path, { version: item.version });
            if (!isRecord(result) || result.id !== item.id || result.deleted !== true) throw new SchemaError("Unreadable response; refresh to check.");
            rows.delete(item.id);
            mutationEpoch++;
          } else {
            acceptRow(validRow(await api("POST", `${path}/unpublish`, { body: note ? { note } : {}, version: item.version })));
          }
          selection.delete(item.id);
          done.push(item);
        } catch (error) {
          if (error instanceof AuthError) { showAuthBanner(); stoppedAt = index; break; }
          const reason = error instanceof ConflictError ? "changed elsewhere since you selected it; nothing was overwritten"
            : error instanceof ApiError && error.status === 404 ? "no longer exists" : error.message;
          failed.push({ ...item, reason });
        }
      }
    } finally {
      setMutating(false);
      render();
    }
    const notTried = stoppedAt >= 0 ? items.slice(stoppedAt) : [];
    const verb = action === "delete" ? "Deleted" : "Unpublished";
    if (!failed.length && !notTried.length) {
      toast(`${verb} ${done.length} template${done.length === 1 ? "" : "s"}.`);
    } else {
      const body = [`${verb} ${done.length} of ${items.length}.`];
      if (failed.length) {
        body.push(el("p", { text: "These didn't go through and are still selected:" }),
          el("ul", {}, failed.map((item) => el("li", { text: `${item.title} (${item.id}): ${item.reason}` }))));
      }
      if (notTried.length) {
        body.push(el("p", { text: `Your sign-in expired, so ${notTried.length} weren't tried. Sign in again, then retry them:` }),
          el("ul", {}, notTried.map((item) => el("li", { text: `${item.title} (${item.id})` }))));
      }
      await ask({ title: "Some templates weren't changed", body, info: true });
    }
    loadAll();
  }

  async function bulkUnpublish() {
    if (mutating) return;
    const snapshot = Object.freeze([...selection].map(([id, version]) => {
      const row = rows.get(id);
      return row ? Object.freeze({ id, version, title: row.title, status: row.status }) : null;
    }).filter(Boolean));
    const items = snapshot.filter((item) => item.status === "approved");
    if (!items.length) { toast("None of the selected templates are published."); return; }
    const skipped = snapshot.length - items.length;
    const body = [`${items.length} published template${items.length === 1 ? "" : "s"} will leave the public catalog and go back to the review queue. Nothing is deleted.`];
    if (skipped) body.push(`${skipped} selected template${skipped === 1 ? " isn't" : "s aren't"} published and will be left alone.`);
    const answer = await ask({
      title: `Unpublish ${items.length} template${items.length === 1 ? "" : "s"}?`, body,
      confirm: `Unpublish ${items.length}`, note: { label: "Note (optional)" },
    });
    if (!answer) return;
    await runBulk("unpublish", items, answer.note);
  }

  async function bulkDelete() {
    if (mutating) return;
    const items = Object.freeze([...selection].map(([id, version]) => {
      const row = rows.get(id);
      return row ? Object.freeze({ id, version, title: row.title, status: row.status }) : null;
    }).filter(Boolean));
    if (!items.length) return;
    const count = items.length;
    const phrase = `DELETE ${count}`;
    const answer = await ask({
      title: `Delete ${count} template${count === 1 ? "" : "s"}?`, danger: true, confirm: `Delete ${count} permanently`, typed: phrase,
      body: [
        `These ${count} template${count === 1 ? "" : "s"} will be permanently deleted, including any that are published. This can't be undone.`,
        el("ul", {}, items.map((item) => el("li", { text: `${item.title} (${STATUS_LABEL[item.status]})` }))),
      ],
    });
    if (!answer) return;
    await runBulk("delete", items);
  }

  // ---- Wiring ----
  function setViewFromHash() {
    view = location.hash === "#all" ? "all" : "queue";
    pruneSelection(false);
    render();
  }

  window.addEventListener("hashchange", setViewFromHash);
  for (const id of ["search", "filter-status", "filter-kind"]) {
    $(id).addEventListener("input", () => { pruneSelection(false); render(); });
  }
  $("select-all").addEventListener("change", (event) => {
    for (const row of visibleRows()) {
      if (event.target.checked) selection.set(row.id, row.version);
      else selection.delete(row.id);
    }
    render();
  });
  $("refresh").addEventListener("click", () => loadAll());
  $("new-template").addEventListener("click", () => { if (!mutating) openCreate(); });
  $("bulk-unpublish").addEventListener("click", bulkUnpublish);
  $("bulk-delete").addEventListener("click", bulkDelete);
  $("auth-retry").addEventListener("click", retryAuth);
  $("editor-close").addEventListener("click", requestClose);
  editor.addEventListener("cancel", (event) => { event.preventDefault(); requestClose(); });
  for (const tab of ["preview", "edit", "details"]) {
    $(`tab-${tab}`).addEventListener("click", () => selectTab(tab));
  }
  $("editor").querySelector(".subtabs").addEventListener("keydown", (event) => {
    if (event.key !== "ArrowRight" && event.key !== "ArrowLeft") return;
    const tabs = [...event.currentTarget.querySelectorAll("[role=tab]")].filter((tab) => !tab.hidden);
    const index = tabs.indexOf(document.activeElement);
    if (index < 0) return;
    const next = tabs[(index + (event.key === "ArrowRight" ? 1 : tabs.length - 1)) % tabs.length];
    next.click();
    next.focus();
  });
  window.addEventListener("beforeunload", (event) => {
    if (mutating || isDirty()) { event.preventDefault(); event.returnValue = ""; }
  });

  setViewFromHash();
  loadSession()
    .then(() => loadAll())
    .catch((error) => {
      if (error instanceof AuthError) showAuthBanner();
      else {
        $("identity").textContent = "Couldn't confirm sign-in";
        showLoadBanner(`Couldn't start the reviewer. ${error.message}`, false);
        loadAll();
      }
    });
})();
