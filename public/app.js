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

async function loadMe() {
  const { data: { session } } = await sb.auth.getSession();
  if (!session) { me = null; return; }
  const profile = check(await sb.from("profiles").select("*").eq("id", session.user.id).maybeSingle());
  me = { user: session.user, profile };
  if (profile?.role === "interpreter") {
    me.interpreter = check(await sb.from("interpreters").select("*").eq("id", session.user.id).maybeSingle());
  }
}

function renderAuth() {
  const p = me?.profile;
  const accountLabel = p?.role === "interpreter" ? "interpreter" : `${p?.role === "personal" ? "personal" : "organization"}: ${esc(p?.plan)}`;
  $("#auth").innerHTML = me
    ? `${esc(p?.full_name || me.user.email)} (${accountLabel}) <button type="button" class="secondary" id="assignments">Assignments</button> <button type="button" class="secondary" id="messages">Messages</button> <button type="button" class="secondary" id="me">Account</button> <button type="button" class="secondary" id="out">Log out</button>`
    : `<button type="button" class="secondary" id="in">Log in</button> <button type="button" id="up">Sign up</button>`;
  $("#in")?.addEventListener("click", showLogin);
  $("#up")?.addEventListener("click", () => showSignup());
  $("#out")?.addEventListener("click", async () => { await sb.auth.signOut(); await refresh(); });
  $("#assignments")?.addEventListener("click", showAssignments);
  $("#messages")?.addEventListener("click", showInbox);
  $("#me")?.addEventListener("click", showAccount);
}

async function loadInterpreters() {
  const data = check(await sb.from("interpreters")
    .select("id, display_name, city, state, remote, in_person, hourly_rate, specialties, verified, featured, available, interpreter_languages(language), certifications(name,scope)"));
  all = data;
}

function fillFacets() {
  const langs = [...new Set(["ASL", "Spanish", ...all.flatMap(i => i.interpreter_languages.map(l => l.language))])].sort();
  const specs = [...new Set(["conference", "education", "legal", "medical", "other", ...all.flatMap(i => i.specialties || []).map(s => s.toLowerCase())])].sort();
  const certs = [...new Set(["CCHI", "NBCMI", "Court certified", ...all.flatMap(i => (i.certifications || []).map(c => c.name)).filter(Boolean)])].sort();
  for (const [name, vals] of [["language", langs], ["specialty", specs], ["certification", certs]]) {
    const sel = document.querySelector(`[name=${name}]`);
    const cur = sel.value;
    sel.length = 1;
    vals.forEach(v => {
      const label = name === "specialty" ? v.charAt(0).toUpperCase() + v.slice(1) : v;
      sel.add(new Option(label, v));
    });
    sel.value = cur;
  }
}

function filtered() {
  const formData = new FormData($("#filters"));
  const f = Object.fromEntries(formData);
  const selectedScopes = formData.getAll("certification_scope");
  const q = (f.q || "").toLowerCase();
  return all
    .filter(i =>
      (!q || (i.display_name || "").toLowerCase().includes(q) || `${i.city} ${i.state}`.toLowerCase().includes(q)) &&
      (!f.language || i.interpreter_languages.some(l => l.language === f.language)) &&
      (!f.specialty || (i.specialties || []).includes(f.specialty)) &&
      (!f.certification || (i.certifications || []).some(c => c.name === f.certification)) &&
      (!selectedScopes.length || (i.certifications || []).some(c => selectedScopes.includes(c.scope))) &&
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
    const modes = [i.remote && "remote", i.in_person && "in-person"].filter(Boolean).join(" / ");
    const initials = (i.display_name || "?").split(/\s+/).map(w => w[0]).slice(0, 2).join("").toUpperCase();
    const place = [i.city, i.state].filter(Boolean).join(", ");
    const canMessage = me?.profile?.role !== "interpreter";
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
      <div class="locked">Email and phone are private. Message through Exponent.</div>
      ${canMessage ? `<div class="row"><button type="button" data-assignment-to="${esc(i.id)}" aria-label="Request an assignment with ${esc(i.display_name)}">Request assignment</button><button type="button" class="secondary" data-message-to="${esc(i.id)}" aria-label="Message ${esc(i.display_name)}">Message</button></div>` : ""}
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

async function showAssignments() {
  if (!me) return showLogin();
  await attempt(async () => {
    const rows = check(await sb.from("assignments")
      .select("id, customer_id, requested_interpreter_id, current_interpreter_id, language, specialty, city, state, service_mode, scheduled_for, status, current_response_deadline, accepted_at, address, room_number, parking_instructions, transit_stop")
      .order("created_at", { ascending: false }));
    const isInterpreter = me.profile.role === "interpreter";
    const list = rows.length
      ? `<ul class="assignment-list">${rows.map(a => {
          const selected = all.find(i => i.id === a.current_interpreter_id)?.display_name || "Finding a match";
          const status = a.status === "offered"
            ? `Awaiting ${isInterpreter ? "your response" : esc(selected)} until ${esc(new Date(a.current_response_deadline).toLocaleString())}`
            : a.status.charAt(0).toUpperCase() + a.status.slice(1);
          const locationDetails = [
            a.address && `Address: ${a.address}`,
            a.room_number && `Room: ${a.room_number}`,
            a.parking_instructions && `Parking: ${a.parking_instructions}`,
            a.transit_stop && `Nearby transit: ${a.transit_stop}`,
          ].filter(Boolean);
          const actions = isInterpreter && a.status === "offered" && a.current_interpreter_id === me.user.id
            ? `<div class="row"><button type="button" data-assignment-response="${esc(a.id)}" data-accept="true">Accept</button><button type="button" class="secondary" data-assignment-response="${esc(a.id)}" data-accept="false">Decline</button></div>`
            : "";
          return `<li class="assignment-item"><div><h3>${esc(a.language)} · ${esc(a.specialty)}</h3><p>${esc([a.city, a.state].filter(Boolean).join(", ")) || "Remote"} · ${esc(a.service_mode)} · ${esc(new Date(a.scheduled_for).toLocaleString())}</p>${locationDetails.map(detail => `<p>${esc(detail)}</p>`).join("")}<p class="muted">${status}</p></div>${actions}</li>`;
        }).join("")}</ul>`
      : '<p class="empty">No assignments yet. Request one from an interpreter profile.</p>';
    dlg.innerHTML = `<h2 id="dialog-title">Assignments</h2>${list}<div class="row"><button type="button" class="secondary" data-close>Close</button></div>`;
    if (!dlg.open) dlg.showModal();
  });
}

function showAssignmentForm(interpreterId) {
  if (!me) return showSignup("Create a free personal or organization account to request an assignment.");
  if (me.profile.role === "interpreter") return showAssignments();
  const interpreter = all.find(i => i.id === interpreterId);
  if (!interpreter) return;
  const languages = [...new Set(["ASL", "Spanish", ...all.flatMap(i => i.interpreter_languages.map(l => l.language))])].sort();
  const specialties = ["conference", "education", "legal", "medical", "other"];
  dlg.innerHTML = `<h2 id="dialog-title">Request ${esc(interpreter.display_name)}</h2>
    <p class="muted">In-person offers have up to 24 hours to accept. Virtual offers expire after 24 hours or four hours before the assignment, whichever comes first. If the interpreter doesn't accept, Exponent offers it to the next matching available interpreter.</p>
    <form id="assignment-form">
      <label>Language <select name="language" required>${languages.map(language => `<option value="${esc(language)}" ${interpreter.interpreter_languages.some(l => l.language === language) ? "selected" : ""}>${esc(language)}</option>`).join("")}</select></label>
      <label>Specialty <select name="specialty" required>${specialties.map(specialty => `<option value="${specialty}" ${(interpreter.specialties || []).includes(specialty) ? "selected" : ""}>${specialty[0].toUpperCase() + specialty.slice(1)}</option>`).join("")}</select></label>
      <label>Service mode <select name="service_mode"><option value="remote" ${interpreter.remote ? "selected" : ""}>Remote</option><option value="in-person" ${interpreter.in_person ? "selected" : ""}>In person</option></select></label>
      <button type="button" class="link" id="toggle-location" hidden aria-expanded="false">Add address and arrival details</button>
      <fieldset id="location-fields" class="location-fields" hidden><legend>In-person location and arrival details</legend>
        <label>Street address <input name="address" maxlength="250" autocomplete="street-address"></label>
        <label>City <input name="city" maxlength="100" autocomplete="address-level2"></label>
        <label>State <input name="state" maxlength="50" autocomplete="address-level1"></label>
        <label>Room or suite number <input name="room_number" maxlength="80"></label>
        <label>Parking instructions <textarea name="parking_instructions" rows="2" maxlength="500"></textarea></label>
        <label>Nearby public transit stop <input name="transit_stop" maxlength="150" placeholder="Station, stop or route"></label>
      </fieldset>
      <label>Date and time <input type="datetime-local" name="scheduled_for" required></label>
      <label>Maximum hourly rate ($, optional) <input name="max_hourly_rate" type="number" min="0" inputmode="decimal"></label>
      <div class="row"><button type="submit">Send assignment request</button><button type="button" class="secondary" data-close>Cancel</button></div>
    </form>`;
  const modeSelect = $("[name=service_mode]");
  const cityInput = $("[name=city]");
  const addressInput = $("[name=address]");
  const locationFields = $("#location-fields");
  const toggleLocation = $("#toggle-location");
  const scheduleInput = $("[name=scheduled_for]");
  const updateModeRequirements = () => {
    const inPerson = modeSelect.value === "in-person";
    cityInput.required = inPerson;
    addressInput.required = inPerson;
    locationFields.hidden = !inPerson;
    toggleLocation.hidden = inPerson;
    toggleLocation.setAttribute("aria-expanded", String(inPerson));
    const minTime = new Date(Date.now() + (inPerson ? 65 : 245) * 60 * 1000);
    minTime.setMinutes(minTime.getMinutes() - minTime.getTimezoneOffset());
    scheduleInput.min = minTime.toISOString().slice(0, 16);
  };
  modeSelect.addEventListener("change", updateModeRequirements);
  toggleLocation.addEventListener("click", () => {
    locationFields.hidden = !locationFields.hidden;
    toggleLocation.setAttribute("aria-expanded", String(!locationFields.hidden));
  });
  updateModeRequirements();
  $("#assignment-form").onsubmit = async event => {
    event.preventDefault();
    const fields = Object.fromEntries(new FormData(event.currentTarget));
    await attempt(async () => {
      check(await sb.rpc("request_interpreter_assignment", {
        p_interpreter_id: interpreterId,
        p_language: fields.language,
        p_specialty: fields.specialty,
        p_city: fields.city,
        p_state: fields.state,
        p_service_mode: fields.service_mode,
        p_scheduled_for: new Date(fields.scheduled_for).toISOString(),
        p_max_hourly_rate: fields.max_hourly_rate ? Number(fields.max_hourly_rate) : null,
        p_address: fields.service_mode === "in-person" ? fields.address : null,
        p_room_number: fields.service_mode === "in-person" ? fields.room_number : null,
        p_parking_instructions: fields.service_mode === "in-person" ? fields.parking_instructions : null,
        p_transit_stop: fields.service_mode === "in-person" ? fields.transit_stop : null,
      }));
      await showAssignments();
    });
  };
  if (!dlg.open) dlg.showModal();
}

async function showInbox() {
  if (!me) return showLogin();
  await attempt(async () => {
    const rows = check(await sb.from("conversations")
      .select("id, customer_id, interpreter_id, customer_label, updated_at")
      .order("updated_at", { ascending: false }));
    const list = rows.length
      ? `<ul class="conversation-list">${rows.map(c => {
          const title = me.profile.role === "interpreter"
            ? c.customer_label
            : all.find(i => i.id === c.interpreter_id)?.display_name || "Interpreter";
          return `<li><button type="button" class="conversation-link" data-thread="${esc(c.id)}">${esc(title)}<small>${esc(new Date(c.updated_at).toLocaleString())}</small></button></li>`;
        }).join("")}</ul>`
      : '<p class="empty">No messages yet. Start a conversation from an interpreter profile.</p>';
    dlg.innerHTML = `<h2 id="dialog-title">Messages</h2>${list}<div class="row"><button type="button" class="secondary" data-close>Close</button></div>`;
    if (!dlg.open) dlg.showModal();
  });
}

async function showThread(conversationId) {
  await attempt(async () => {
    const conversation = check(await sb.from("conversations")
      .select("id, customer_id, interpreter_id, customer_label")
      .eq("id", conversationId).single());
    const messages = check(await sb.from("messages")
      .select("id, sender_id, body, created_at")
      .eq("conversation_id", conversationId).order("created_at"));
    const interpreterName = all.find(i => i.id === conversation.interpreter_id)?.display_name || "Interpreter";
    const title = me.profile.role === "interpreter" ? conversation.customer_label : interpreterName;
    const thread = messages.length
      ? messages.map(message => `<li class="message ${message.sender_id === me.user.id ? "mine" : ""}">
          <p class="message-meta">${message.sender_id === me.user.id ? "You" : esc(title)} · <time datetime="${esc(message.created_at)}">${esc(new Date(message.created_at).toLocaleString())}</time></p>
          <p class="message-body">${esc(message.body)}</p>
        </li>`).join("")
      : '<li class="empty">No messages yet.</li>';
    dlg.innerHTML = `<h2 id="dialog-title">${esc(title)}</h2>
      <ol class="message-thread" aria-label="Conversation with ${esc(title)}" aria-live="polite">${thread}</ol>
      <p class="muted">Your email and phone stay private. Please keep contact details out of messages.</p>
      <form id="reply-form"><label>Message <textarea name="body" rows="3" maxlength="4000" required></textarea></label>
        <div class="row"><button type="submit">Send message</button><button type="button" class="secondary" data-back-inbox>Back to messages</button></div></form>`;
    $("#reply-form").onsubmit = async event => {
      event.preventDefault();
      const form = event.currentTarget;
      const body = new FormData(form).get("body");
      await attempt(async () => {
        check(await sb.rpc("send_message", { p_conversation_id: conversationId, p_body: body }));
        await showThread(conversationId);
      });
    };
    if (!dlg.open) dlg.showModal();
    $(".message-thread").scrollTop = $(".message-thread").scrollHeight;
  });
}

function showMessageForm(interpreterId) {
  if (!me) return showSignup("Create a free personal or organization account to message interpreters.");
  if (me.profile.role === "interpreter") return showInbox();
  const interpreter = all.find(i => i.id === interpreterId);
  if (!interpreter) return;
  dlg.innerHTML = `<h2 id="dialog-title">Message ${esc(interpreter.display_name)}</h2>
    <p class="muted">Your email and phone stay private. Please keep contact details out of messages.</p>
    <form id="first-message-form"><label>Message <textarea name="body" rows="4" maxlength="4000" required></textarea></label>
      <div class="row"><button type="submit">Send message</button><button type="button" class="secondary" data-close>Cancel</button></div></form>`;
  $("#first-message-form").onsubmit = async event => {
    event.preventDefault();
    const body = new FormData(event.currentTarget).get("body");
    await attempt(async () => {
      const conversationId = check(await sb.rpc("start_conversation", { p_interpreter_id: interpreterId, p_body: body }));
      await showThread(conversationId);
    });
  };
  if (!dlg.open) dlg.showModal();
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
         <fieldset class="filter-checks"><legend>Certification scope (select all that apply)</legend>
           <label class="check"><input type="checkbox" name="certification_scopes" value="national"> National</label>
           <label class="check"><input type="checkbox" name="certification_scopes" value="international"> International</label>
           <label class="check"><input type="checkbox" name="certification_scopes" value="state"> State</label>
           <label class="check"><input type="checkbox" name="certification_scopes" value="local"> Local</label>
         </fieldset>
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
    const formData = new FormData(form);
    const f = Object.fromEntries(formData);
    const data = { role: f.role, full_name: f.full_name };
    if (f.role === "organization") data.org_name = f.org_name;
    else if (f.role === "interpreter") Object.assign(data, {
      languages: split(f.languages), specialties: split(f.specialties).map(s => s.toLowerCase()), certs: split(f.certs),
      certification_scopes: formData.getAll("certification_scopes"),
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
    const accountType = p.role === "personal" ? "Personal account" : "Organization account";
    body += `<p>${accountType} · Free</p>
      <p class="muted">${p.account_verified ? `${accountType} verified.` : `${accountType} not verified yet.`}</p>
      <p class="muted">Customer subscriptions are paused while the directory grows. Contact unlocking will open later.</p>`;
  } else {
    const i = me.interpreter;
    body += `<p>Your conversations are in Messages. Your contact details stay private.</p>
      <label>Phone (private) <input id="phone" value="${esc(me.user.user_metadata?.phone)}" maxlength="40"></label>
      <label><input type="checkbox" id="avail" ${i.available ? "checked" : ""}> Available</label>
      <p class="muted">${i.verified ? "Verified." : "Not verified. Optional $10/month certification verification is planned, but not available yet."}</p>`;
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
  const t = e.target.closest("button") || e.target;
  if (t.dataset.close !== undefined) dlg.close();
  if (t.id === "retry-search") refresh();
  if (t.id === "clear-filters") { $("#filters").reset(); render(); }
  if (t.dataset.openSignup !== undefined) showSignup();
  if (t.dataset.assignmentTo) showAssignmentForm(t.dataset.assignmentTo);
  if (t.dataset.assignmentResponse) {
    attempt(async () => {
      check(await sb.rpc("respond_to_assignment", {
        p_assignment_id: t.dataset.assignmentResponse,
        p_accept: t.dataset.accept === "true",
      }));
      await showAssignments();
    });
  }
  if (t.dataset.quickLanguage) {
    $("#filters").reset();
    $("[name=language]").value = t.dataset.quickLanguage;
    render();
    $("#search").scrollIntoView();
  }
  if (t.dataset.messageTo) showMessageForm(t.dataset.messageTo);
  if (t.dataset.thread) showThread(t.dataset.thread);
  if (t.dataset.backInbox !== undefined) showInbox();
});

initAccessibility();
let timer;
$("#filters").addEventListener("input", () => { clearTimeout(timer); timer = setTimeout(render, 150); });
$("#filters").addEventListener("reset", () => setTimeout(render));
sb.auth.onAuthStateChange((event) => { if (event === "SIGNED_IN" || event === "SIGNED_OUT") refresh(); });
refresh();
