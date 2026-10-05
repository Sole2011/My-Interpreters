const sb = window.supabase.createClient(window.SUPABASE_URL, window.SUPABASE_ANON_KEY);
const $ = s => document.querySelector(s);
const dlg = $("#dlg");
const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const split = s => (s || "").split(",").map(x => x.trim()).filter(Boolean);
const attempt = async fn => { try { return await fn(); } catch (e) { alert(e.message || "Something went wrong"); } };
const check = ({ data, error }) => { if (error) throw error; return data; };

function initAccessibility() {
  let preferences = {};
  try { preferences = JSON.parse(localStorage.getItem("displayPreferences") || "{}"); } catch {}
  const sizes = ["normal", "large", "larger"];
  let sizeIndex = Math.max(0, sizes.indexOf(preferences.textSize));
  let highContrast = preferences.highContrast === true;
  const smaller = $("#text-smaller");
  const larger = $("#text-larger");
  const contrast = $("#contrast-toggle");
  const apply = () => {
    document.documentElement.dataset.textSize = sizes[sizeIndex];
    document.body.classList.toggle("high-contrast", highContrast);
    smaller.disabled = sizeIndex === 0;
    larger.disabled = sizeIndex === sizes.length - 1;
    contrast.setAttribute("aria-pressed", String(highContrast));
    try { localStorage.setItem("displayPreferences", JSON.stringify({ textSize: sizes[sizeIndex], highContrast })); } catch {}
  };
  smaller.addEventListener("click", () => { sizeIndex = Math.max(0, sizeIndex - 1); apply(); });
  larger.addEventListener("click", () => { sizeIndex = Math.min(sizes.length - 1, sizeIndex + 1); apply(); });
  $("#text-reset").addEventListener("click", () => { sizeIndex = 0; apply(); });
  contrast.addEventListener("click", () => { highContrast = !highContrast; apply(); });
  apply();
}

let me = null; // { user, profile, interpreter?, usage? }
let all = [];
let contacts = new Map(); // interpreter id -> { email, phone }

async function loadMe() {
  const { data: { session } } = await sb.auth.getSession();
  if (!session) { me = null; return; }
  const profile = check(await sb.from("profiles").select("*").eq("id", session.user.id).maybeSingle());
  me = { user: session.user, profile };
  if (profile?.role === "interpreter") {
    me.interpreter = check(await sb.from("interpreters").select("*").eq("id", session.user.id).maybeSingle());
    me.unlockCount = check(await sb.rpc("my_unlock_count"));
  }
}

function renderAuth() {
  const p = me?.profile;
  const accountLabel = p?.role === "interpreter" ? "interpreter" : `${p?.role === "personal" ? "personal" : "organization"}: ${esc(p?.plan)}`;
  $("#auth").innerHTML = me
    ? `${esc(p?.full_name || me.user.email)} (${accountLabel}) <button type="button" class="secondary" id="me">Account</button> <button type="button" class="secondary" id="out">Log out</button>`
    : `<button type="button" class="secondary" id="in">Log in</button> <button type="button" id="up">Sign up</button>`;
  $("#in")?.addEventListener("click", showLogin);
  $("#up")?.addEventListener("click", () => showSignup());
  $("#out")?.addEventListener("click", async () => { await sb.auth.signOut(); await refresh(); });
  $("#me")?.addEventListener("click", showAccount);
}

async function loadInterpreters() {
  const data = check(await sb.from("interpreters")
    .select("id, display_name, city, state, remote, in_person, hourly_rate, specialties, verified, featured, available, interpreter_languages(language), certifications(name,scope)"));
  all = data;
  contacts = new Map();
  if (["organization", "personal"].includes(me?.profile?.role)) {
    const ids = check(await sb.from("unlocks").select("interpreter_id")).map(r => r.interpreter_id);
    // Re-calling for an already unlocked contact does not use up a unlock.
    await Promise.all(ids.map(async id => {
      const rows = check(await sb.rpc("unlock_contact", { p_interpreter_id: id }));
      if (rows?.[0]) contacts.set(id, rows[0]);
    }));
  }
}

function fillFacets() {
  const langs = [...new Set(["ASL", "Spanish", ...all.flatMap(i => i.interpreter_languages.map(l => l.language))])].sort();
  const specs = [...new Set(["conference", "education", "legal", "medical", "other", ...all.flatMap(i => i.specialties || []).map(s => s.toLowerCase())])].sort();
  const certs = [...new Set(["CCHI", "NBCMI", "Court certified", ...all.flatMap(i => (i.certifications || []).map(c => c.name)).filter(Boolean)])].sort();
  const scopes = ["international", "local", "national", "state"];
  for (const [name, vals] of [["language", langs], ["specialty", specs], ["certification", certs], ["certification_scope", scopes]]) {
    const sel = document.querySelector(`[name=${name}]`);
    const cur = sel.value;
    sel.length = 1;
    vals.forEach(v => {
      const label = ["specialty", "certification_scope"].includes(name) ? v.charAt(0).toUpperCase() + v.slice(1) : v;
      sel.add(new Option(label, v));
    });
    sel.value = cur;
  }
}

function filtered() {
  const f = Object.fromEntries(new FormData($("#filters")));
  const q = (f.q || "").toLowerCase();
  return all
    .filter(i =>
      (!q || (i.display_name || "").toLowerCase().includes(q) || `${i.city} ${i.state}`.toLowerCase().includes(q)) &&
      (!f.language || i.interpreter_languages.some(l => l.language === f.language)) &&
      (!f.specialty || (i.specialties || []).includes(f.specialty)) &&
      (!f.certification || (i.certifications || []).some(c => c.name === f.certification)) &&
      (!f.certification_scope || (i.certifications || []).some(c => c.scope === f.certification_scope)) &&
      (!f.mode || (f.mode === "remote" ? i.remote : i.in_person)) &&
      (!f.maxRate || Number(i.hourly_rate) <= +f.maxRate) &&
      (!f.verified || i.verified) &&
      (!f.available || i.available))
    .sort((a, b) => b.featured - a.featured || b.verified - a.verified || (a.hourly_rate ?? 1e9) - (b.hourly_rate ?? 1e9));
}

function render() {
  const list = filtered();
  $("#count").textContent = `${list.length} interpreter${list.length === 1 ? "" : "s"}`;
  if (!list.length) {
    $("#results").innerHTML = '<p class="empty">No interpreters match these filters. Try removing a filter or <button type="button" class="link" id="clear-filters">clear all filters</button>.</p>';
    return;
  }
  $("#results").innerHTML = list.map(i => {
    const c = contacts.get(i.id);
    const modes = [i.remote && "remote", i.in_person && "in-person"].filter(Boolean).join(" / ");
    const initials = (i.display_name || "?").split(/\s+/).map(w => w[0]).slice(0, 2).join("").toUpperCase();
    const place = [i.city, i.state].filter(Boolean).join(", ");
    return `
    <article class="card ${i.featured ? "featured" : ""}" aria-labelledby="interpreter-${esc(i.id)}-name">
      <div class="card-head">
        <span class="avatar" aria-hidden="true">${esc(initials)}</span>
        <div>
          <h3 id="interpreter-${esc(i.id)}-name">${esc(i.display_name)}</h3>
          <p class="muted">${esc(place) || "Location not listed"}${modes ? " · " + esc(modes) : ""}</p>
        </div>
        <p class="rate">${i.hourly_rate != null ? "$" + esc(i.hourly_rate) + "<small>/hr</small>" : "<small>Rate on request</small>"}</p>
      </div>
      <p class="badges">
        ${i.verified ? '<span class="badge ok">Verified</span>' : ""}
        <span class="badge ${i.available ? "avail" : "busy"}">${i.available ? "Available" : "Unavailable"}</span>
      </p>
      <div>${i.interpreter_languages.map(l => `<span class="tag">${esc(l.language)}</span>`).join("")}${(i.specialties || []).map(s => `<span class="tag alt">${esc(s)}</span>`).join("")}</div>
      ${i.certifications.length ? `<p class="muted">Certifications: ${i.certifications.map(x => `${esc(x.name)}${x.scope ? ` (${esc(x.scope.charAt(0).toUpperCase() + x.scope.slice(1))})` : ""}`).join(", ")}</p>` : ""}
      ${c
        ? `<div class="locked">Email: ${esc(c.email)}<br>Phone: ${esc(c.phone || "not provided")}</div>`
        : `<div class="locked">Email and phone hidden</div><div class="row"><button type="button" data-unlock="${esc(i.id)}" aria-label="Unlock contact for ${esc(i.display_name)}">Unlock contact</button></div>`}
      </article>`;
  }).join("");
}

async function refresh() {
  try {
    await loadMe();
    renderAuth();
    await loadInterpreters();
    fillFacets();
    render();
  } catch (error) {
    console.error(error);
    $("#count").textContent = "Interpreter search is currently unavailable.";
    $("#results").innerHTML = '<button type="button" id="retry-search">Try again</button>';
  }
}

function showSignup(note) {
  dlg.innerHTML = `<h2 id="dialog-title">Sign up</h2>${note ? `<p class="error" role="alert">${esc(note)}</p>` : ""}
    <form id="su"><label>I am an <select name="role"><option value="organization">Organization (hospital, court, school, agency)</option><option value="personal">Personal use</option><option value="interpreter">Interpreter</option></select></label>
    <label>Name <input name="full_name" required maxlength="100"></label>
    <div id="orgf"><label>Organization name <input name="org_name" required maxlength="150"></label></div>
    <label>Email <input type="email" name="email" required></label>
    <label>Password (8+ characters) <input type="password" name="password" minlength="8" required autocomplete="new-password"></label>
    <div id="extra"></div>
    <div class="row"><button>Create account</button><button type="button" class="secondary" data-close>Cancel</button></div></form>`;
  const form = $("#su");
  const draw = () => {
    const isInt = form.role.value === "interpreter";
    const isOrg = form.role.value === "organization";
    $("#orgf").hidden = !isOrg;
    form.org_name.required = isOrg;
    $("#extra").innerHTML = isInt
      ? `<label>Languages (comma separated) <input name="languages" placeholder="ASL, Spanish" required></label>
         <label>Specialties (comma separated) <input name="specialties" placeholder="conference, legal, medical, education, other"></label>
        <label>Certifications (comma separated) <input name="certs" placeholder="CCHI, NBCMI, Court certified"></label>
         <label>Scope for these certifications
           <select name="certification_scope">
             <option value="">Choose a scope</option>
             <option value="national">National</option>
             <option value="international">International</option>
             <option value="state">State</option>
             <option value="local">Local</option>
           </select>
         </label>
         <label>City <input name="city" required></label>
         <label>State <input name="state"></label>
         <label>Phone (shown only to organizations that unlock you) <input name="phone"></label>
         <label>Rate ($/hr) <input type="number" name="rate" min="0" required></label>
         <label><input type="checkbox" name="remote" checked> Remote</label>
         <label><input type="checkbox" name="in_person" checked> In-person</label>`
      : "";
  };
  form.role.onchange = draw; draw();
  form.onsubmit = async e => {
    e.preventDefault();
    const f = Object.fromEntries(new FormData(form));
    const data = { role: f.role, full_name: f.full_name };
    if (f.role === "organization") data.org_name = f.org_name;
    else if (f.role === "interpreter") Object.assign(data, {
      languages: split(f.languages), specialties: split(f.specialties).map(s => s.toLowerCase()), certs: split(f.certs),
      certification_scope: f.certification_scope,
      city: f.city, state: f.state, phone: f.phone, hourly_rate: +f.rate, remote: !!f.remote, in_person: !!f.in_person,
    });
    await attempt(async () => {
      const { error } = await sb.auth.signUp({ email: f.email, password: f.password, options: { data } });
      if (error) throw error;
      dlg.close();
      alert("Check your email to confirm your account.");
      await refresh();
    });
  };
  dlg.showModal();
}

function showLogin() {
  dlg.innerHTML = `<h2 id="dialog-title">Log in</h2><form id="li"><label>Email <input type="email" name="email" required></label>
    <label>Password <input type="password" name="password" required autocomplete="current-password"></label>
    <div class="row"><button>Log in</button><button type="button" class="secondary" data-close>Cancel</button></div></form>`;
  $("#li").onsubmit = async e => {
    e.preventDefault();
    const f = Object.fromEntries(new FormData(e.target));
    await attempt(async () => {
      const { error } = await sb.auth.signInWithPassword(f);
      if (error) throw error;
      dlg.close(); await refresh();
    });
  };
  dlg.showModal();
}

function showAccount() {
  const p = me.profile;
  let body = `<p>${esc(me.user.email)}</p>`;
  if (p.role !== "interpreter") {
    const limit = { free: 0 }[p.plan];
    const accountType = p.role === "personal" ? "Personal account" : "Organization account";
    body += `<p>Plan: <b>${esc(p.plan)}</b> · unlocks this month: ${esc(p.unlocks_used)}${limit === undefined ? "" : " / " + limit}</p>
      <p class="muted">${p.account_verified ? `${accountType} verified.` : `${accountType} not verified yet. You can unlock contacts once we verify your account.`}</p>
      <p class="muted">${p.plan === "free" ? "Unlimited plans are custom-quoted." : ""}</p>`;
  } else {
    const i = me.interpreter;
    body += `<p>Contacts unlocked by organizations: <b>${esc(me.unlockCount)}</b></p>
      <label>Phone (shown to unlocking orgs) <input id="phone" value="${esc(me.user.user_metadata?.phone)}" maxlength="40"></label>
      <label><input type="checkbox" id="avail" ${i.available ? "checked" : ""}> Available</label>
      <p class="muted">${i.verified ? "Verified." : "Not verified. Verification is $10/month after we review your certifications."}</p>`;
  }
  dlg.innerHTML = `<h2 id="dialog-title">Account</h2>${body}<div class="row"><button type="button" class="secondary" data-close>Close</button></div>`;
  $("#phone")?.addEventListener("change", e => attempt(async () => {
    const phone = e.target.value.slice(0, 40);
    check(await sb.from("interpreter_contacts").update({ phone }).eq("interpreter_id", me.user.id));
    const { error } = await sb.auth.updateUser({ data: { phone } });
    if (error) throw error;
  }));
  $("#avail")?.addEventListener("change", e => attempt(async () => {
    check(await sb.from("interpreters").update({ available: e.target.checked }).eq("id", me.user.id));
    await refresh();
  }));
  dlg.showModal();
}

document.addEventListener("click", e => {
  const t = e.target;
  if (t.dataset.close !== undefined) dlg.close();
  if (t.id === "retry-search") refresh();
  if (t.id === "clear-filters") { $("#filters").reset(); render(); }
  if (t.dataset.openSignup !== undefined) showSignup();
  if (t.dataset.quickLanguage) {
    $("#filters").reset();
    $("[name=language]").value = t.dataset.quickLanguage;
    render();
    $("#search").scrollIntoView();
  }
  if (t.dataset.bill) {
    attempt(async () => {
      const body = t.dataset.bill === "portal" ? { action: "portal" } : { action: "checkout", interval: t.dataset.bill };
      const { data, error } = await sb.functions.invoke("billing", { body });
      if (error) throw new Error((await error.context?.json?.().catch(() => null))?.error || error.message);
      location.href = data.url;
    });
  }
  if (t.dataset.unlock) {
    if (!me) return showSignup("Sign up for personal or organization use to unlock contacts.");
    attempt(async () => {
      check(await sb.rpc("unlock_contact", { p_interpreter_id: t.dataset.unlock }));
      await refresh();
    });
  }
});

initAccessibility();
let timer;
$("#filters").addEventListener("input", () => { clearTimeout(timer); timer = setTimeout(render, 150); });
$("#filters").addEventListener("reset", () => setTimeout(render));
sb.auth.onAuthStateChange((event) => { if (event === "SIGNED_IN" || event === "SIGNED_OUT") refresh(); });
const billing = new URLSearchParams(location.search).get("billing");
if (billing === "success") alert("Thanks! Your plan will update in a moment.");
refresh();
