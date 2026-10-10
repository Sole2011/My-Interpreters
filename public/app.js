const isPreviewMode = () => !window.SUPABASE_URL || window.SUPABASE_URL.includes("YOUR-PROJECT") || !window.SUPABASE_ANON_KEY || window.SUPABASE_ANON_KEY.includes("YOUR-ANON-KEY");
const sb = window.supabase.createClient(window.SUPABASE_URL, window.SUPABASE_ANON_KEY);
const $ = s => document.querySelector(s);
const dlg = $("#dlg");
const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const split = s => (s || "").split(",").map(x => x.trim()).filter(Boolean);
const attempt = async fn => { try { return await fn(); } catch (e) { alert(e.message || "Something went wrong"); } };
const check = ({ data, error }) => { if (error) throw error; return data; };
const money = cents => new Intl.NumberFormat("en-US", { style: "currency", currency: "USD" }).format((cents || 0) / 100);
// Calls a Supabase Edge Function and surfaces the server's own error message.
async function callFunction(name, body) {
  const { data, error } = await sb.functions.invoke(name, { body });
  if (error) {
    let message = error.message;
    try { message = (await error.context.json()).error || message; } catch {}
    throw new Error(message);
  }
  return data;
}
const POLICY_VERSIONS = { terms: "1.0", privacy: "1.0", rules: "1.0" };

let me = null; // { user, profile, interpreter?, usage? }
let all = [];

async function loadMe() {
  const { data: { session } } = await sb.auth.getSession();
  if (!session) { me = null; return; }
  const profile = check(await sb.from("profiles").select("*").eq("id", session.user.id).maybeSingle());
  me = { user: session.user, profile };
  if (profile?.role === "interpreter") {
    me.interpreter = check(await sb.from("interpreters").select("*").eq("id", session.user.id).maybeSingle());
    me.payout = check(await sb.from("interpreter_payout_accounts").select("payouts_enabled").eq("interpreter_id", session.user.id).maybeSingle());
  }
}

function renderAuth() {
  const p = me?.profile;
  const accountLabel = p?.role === "interpreter" ? "interpreter" : `${p?.role === "personal" ? "personal" : "organization"}: ${esc(p?.plan)}`;
  $("#auth").innerHTML = me
    ? `${esc(p?.full_name || me.user.email)} (${accountLabel}) <button type="button" class="secondary" id="updates">Updates</button> <button type="button" class="secondary" id="assignments">Assignments</button> <button type="button" class="secondary" id="messages">Messages</button> <button type="button" class="secondary" id="me">Account</button> <button type="button" class="secondary" id="out">Log out</button>`
    : `<button type="button" class="secondary" id="in">Log in</button> <button type="button" id="up">Sign up</button>`;
  $("#in")?.addEventListener("click", showLogin);
  $("#up")?.addEventListener("click", () => showSignup());
  $("#out")?.addEventListener("click", async () => { await sb.auth.signOut(); await refresh(); });
  $("#updates")?.addEventListener("click", showUpdates);
  $("#assignments")?.addEventListener("click", showAssignments);
  $("#messages")?.addEventListener("click", showInbox);
  $("#me")?.addEventListener("click", showAccount);
}

async function loadInterpreters() {
  const data = check(await sb.from("interpreters")
    .select("id, display_name, city, state, postal_code, remote, in_person, hourly_rate, specialties, verified, featured, available, interpreter_languages(language), certifications(name,scope)"));
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
  const languageSelect = $("#filter-language");
  const selectedLanguage = languageSelect.value;
  languageSelect.length = 1;
  for (const language of langs) languageSelect.add(new Option(language, language));
  languageSelect.value = selectedLanguage;
}

function matchesLocation(interpreter, query) {
  if (!query) return true;
  const place = [interpreter.city, interpreter.state, interpreter.postal_code]
    .filter(Boolean)
    .join(" ")
    .toLowerCase();
  if (place.includes(query)) return true;

  const values = [interpreter.city, interpreter.state, interpreter.postal_code]
    .filter(Boolean)
    .map(value => value.toLowerCase());
  const parts = query.split(/[,;]/).map(part => part.trim()).filter(Boolean);
  if (parts.some(part => values.some(value => value.includes(part) || part.includes(value)))) return true;

  const terms = query.split(/[\s,;]+/).filter(term => term.length >= 2);
  return terms.some(term => values.some(value =>
    term.length === 2 ? value === term : value.includes(term)));
}

function filtered() {
  const formData = new FormData($("#filters"));
  const f = Object.fromEntries(formData);
  const selectedScopes = formData.getAll("certification_scope");
  const q = (f.q || "").toLowerCase();
  return all
    .filter(i =>
      (!q || (i.display_name || "").toLowerCase().includes(q) || matchesLocation(i, q)) &&
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

function clearFilters() {
  const form = $("#filters");
  for (const control of form.elements) {
    if (control instanceof HTMLInputElement && ["checkbox", "radio"].includes(control.type)) {
      control.checked = false;
    } else if (control instanceof HTMLInputElement) {
      control.value = "";
    } else if (control instanceof HTMLSelectElement) {
      control.value = "";
    }
  }
  document.querySelectorAll("#top details").forEach(details => { details.open = false; });
  render();
}

function render() {
  if (isPreviewMode()) {
    $("#count").textContent = "Interpreter directory is not connected.";
    $("#results").innerHTML = '<p class="empty">Connect Supabase to display real interpreter listings. Sample profiles are not shown.</p>';
    return;
  }
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
      ${canMessage ? me
        ? `<div class="row"><button type="button" data-assignment-to="${esc(i.id)}" aria-label="Request an assignment with ${esc(i.display_name)}">Request assignment</button><button type="button" class="secondary" data-message-to="${esc(i.id)}" aria-label="Message ${esc(i.display_name)}">Message</button></div>`
        : `<div class="row"><button type="button" data-interact-signup>Sign up to interact</button></div>`
        : ""}
      </article>`;
  }).join("");
}

async function refresh() {
  if (isPreviewMode()) {
    me = null;
    all = [];
    renderAuth();
    fillFacets();
    render();
    return;
  }
  try {
    await loadMe();
    renderAuth();
    if (me) {
      const pending = check(await sb.from("site_notifications")
        .select("id, category, title, body, version, requires_ack")
        .eq("requires_ack", true).is("acknowledged_at", null));
      if (pending.length) {
        showRequiredPolicyUpdates(pending);
        return;
      }
    }
    await loadInterpreters();
    fillFacets();
    render();
  } catch (error) {
    console.error(error);
    $("#count").textContent = "Interpreter search is currently unavailable.";
    $("#results").innerHTML = '<button type="button" id="retry-search">Try again</button>';
  }
}

async function showRequiredPolicyUpdates(notices) {
  const items = notices.map(n => `<article class="notice-item"><h3>${esc(n.title)}</h3><p>${esc(n.body)}</p></article>`).join("");
  dlg.innerHTML = `<h2 id="dialog-title">Policy updates</h2>${items}
    <form id="policy-ack-form"><label class="check"><input type="checkbox" name="ack" required> I have reviewed and accept these updated policies.</label>
      <div class="row"><button type="submit">Accept and continue</button></div></form>`;
  $("#policy-ack-form").onsubmit = async event => {
    event.preventDefault();
    await attempt(async () => {
      for (const notice of notices) check(await sb.rpc("acknowledge_site_notification", { p_notification_id: notice.id }));
      await refresh();
    });
  };
  if (!dlg.open) dlg.showModal();
}

async function showUpdates() {
  if (!me) return showLogin();
  await attempt(async () => {
    const notifications = check(await sb.from("site_notifications")
      .select("id, category, title, body, version, requires_ack, created_at, read_at, acknowledged_at")
      .order("created_at", { ascending: false }));
    const list = notifications.length
      ? `<ul class="notice-list">${notifications.map(n => `<li class="notice-item ${n.read_at ? "read" : "unread"}">
          <p class="notice-meta">${n.category === "policy" ? "Policy update" : "Feature update"} · ${esc(new Date(n.created_at).toLocaleString())}</p>
          <h3>${esc(n.title)}</h3><p>${esc(n.body)}</p>
          ${n.requires_ack && !n.acknowledged_at ? `<button type="button" data-ack-notice="${esc(n.id)}">Review and accept</button>` : n.read_at ? "" : `<button type="button" class="secondary" data-read-notice="${esc(n.id)}">Mark as read</button>`}
        </li>`).join("")}</ul>`
      : '<p class="empty">No updates right now.</p>';
    dlg.innerHTML = `<h2 id="dialog-title">Updates</h2>${list}<div class="row"><button type="button" class="secondary" data-close>Close</button></div>`;
    if (!dlg.open) dlg.showModal();
  });
}

async function acknowledgeNotice(notificationId) {
  await attempt(async () => {
    check(await sb.rpc("acknowledge_site_notification", { p_notification_id: notificationId }));
    await refresh();
  });
}

async function markNoticeRead(notificationId) {
  await attempt(async () => {
    check(await sb.from("site_notifications").update({ read_at: new Date().toISOString() }).eq("id", notificationId));
    await showUpdates();
  });
}

async function showAssignments() {
  if (!me) return showLogin();
  await attempt(async () => {
    const rows = check(await sb.from("assignments")
      .select("id, customer_id, requested_interpreter_id, current_interpreter_id, language, specialty, city, state, service_mode, scheduled_for, status, current_response_deadline, accepted_at, address, room_number, parking_instructions, transit_stop, duration_hours, payment_status, authorized_amount_cents, captured_amount_cents, platform_fee_cents")
      .order("created_at", { ascending: false }));
    const isInterpreter = me.profile.role === "interpreter";
    const list = rows.length
      ? `<ul class="assignment-list">${rows.map(a => {
          const selected = all.find(i => i.id === a.current_interpreter_id)?.display_name || "Finding a match";
          const status = a.status === "awaiting_payment"
            ? "Waiting for your payment. Nothing has been sent to the interpreter yet."
            : a.status === "offered"
              ? `Awaiting ${isInterpreter ? "your response" : esc(selected)} until ${esc(new Date(a.current_response_deadline).toLocaleString())}`
              : a.status.charAt(0).toUpperCase() + a.status.slice(1).replace("_", " ");
          const hours = a.duration_hours ? `${Number(a.duration_hours)} h` : "";
          let money_line = "";
          if (isInterpreter) {
            if (a.status === "accepted" && a.captured_amount_cents != null) {
              money_line = `You receive ${money(a.captured_amount_cents - (a.platform_fee_cents || 0))} after Exponent's ${money(a.platform_fee_cents)} fee.`;
            } else if (a.status === "offered" && a.duration_hours && me.interpreter?.hourly_rate != null) {
              money_line = `Booking total at your rate: ${money(Math.round(Number(me.interpreter.hourly_rate) * Number(a.duration_hours) * 100))}. Payment is secured by the customer's card hold.`;
            }
          } else if (a.payment_status === "captured") {
            money_line = `Charged ${money(a.captured_amount_cents)}.`;
          } else if (a.payment_status === "authorized" && a.status === "unfilled") {
            money_line = `No interpreter accepted, so you won't be charged. Cancel the request to release the ${money(a.authorized_amount_cents)} hold now; otherwise your bank releases it within 7 days.`;
          } else if (a.payment_status === "authorized") {
            money_line = `${money(a.authorized_amount_cents)} is held on your card, and you are only charged if an interpreter accepts.`;
          } else if (a.payment_status === "released") {
            money_line = "Card hold released. You were not charged.";
          } else if (a.status === "awaiting_payment") {
            money_line = `${money(a.authorized_amount_cents)} will be held on your card, and charged only if an interpreter accepts.`;
          }
          const locationDetails = [
            a.address && `Address: ${a.address}`,
            a.room_number && `Room: ${a.room_number}`,
            a.parking_instructions && `Parking: ${a.parking_instructions}`,
            a.transit_stop && `Nearby transit: ${a.transit_stop}`,
          ].filter(Boolean);
          const canCancel = !isInterpreter && ["awaiting_payment", "offered", "unfilled"].includes(a.status) && a.payment_status !== "capturing";
          const actions = isInterpreter && a.status === "offered" && a.current_interpreter_id === me.user.id
            ? `<div class="row"><button type="button" data-assignment-response="${esc(a.id)}" data-accept="true">Accept</button><button type="button" class="secondary" data-assignment-response="${esc(a.id)}" data-accept="false">Decline</button></div>`
            : !isInterpreter && (a.status === "awaiting_payment" || canCancel)
              ? `<div class="row">${a.status === "awaiting_payment" ? `<button type="button" data-pay-booking="${esc(a.id)}">Complete payment</button>` : ""}${canCancel ? `<button type="button" class="secondary" data-cancel-booking="${esc(a.id)}">Cancel request</button>` : ""}</div>`
              : "";
          return `<li class="assignment-item"><div><h3>${esc(a.language)} · ${esc(a.specialty)}</h3><p>${esc([a.city, a.state].filter(Boolean).join(", ")) || "Remote"} · ${esc(a.service_mode)} · ${esc(new Date(a.scheduled_for).toLocaleString())}${hours ? ` · ${esc(hours)}` : ""}</p>${locationDetails.map(detail => `<p>${esc(detail)}</p>`).join("")}<p class="muted">${status}</p>${money_line ? `<p class="muted">${esc(money_line)}</p>` : ""}</div>${actions}</li>`;
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
    <p class="muted">You'll pay on Stripe's secure payment page. Your card is only held. You're charged when an interpreter accepts, and the hold is released if nobody does.</p>
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
      <label>Duration (hours) <input name="duration_hours" type="number" min="0.5" max="12" step="0.5" value="1" required></label>
      <label>Maximum hourly rate ($${interpreter.hourly_rate != null ? ", optional" : ", required"}) <input name="max_hourly_rate" type="number" min="1" inputmode="decimal" ${interpreter.hourly_rate != null ? "" : "required"}></label>
      <p class="muted" id="hold-estimate" role="status"></p>
      <div class="row"><button type="submit">Continue to secure payment</button><button type="button" class="secondary" data-close>Cancel</button></div>
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
  // The hold covers the highest rate any matched interpreter could charge for these hours.
  const updateHoldEstimate = () => {
    const hours = Number($("[name=duration_hours]").value);
    const rate = Number($("[name=max_hourly_rate]").value) || Number(interpreter.hourly_rate);
    $("#hold-estimate").textContent = hours >= 0.5 && rate > 0
      ? `Card hold: up to ${money(Math.ceil(rate * hours * 100))} (${hours} h at up to $${rate}/h). You're only charged the accepting interpreter's actual rate.`
      : "";
  };
  $("#assignment-form").addEventListener("input", updateHoldEstimate);
  updateHoldEstimate();
  toggleLocation.addEventListener("click", () => {
    locationFields.hidden = !locationFields.hidden;
    toggleLocation.setAttribute("aria-expanded", String(!locationFields.hidden));
  });
  updateModeRequirements();
  $("#assignment-form").onsubmit = async event => {
    event.preventDefault();
    const fields = Object.fromEntries(new FormData(event.currentTarget));
    await attempt(async () => {
      const submit = event.submitter;
      if (submit) submit.disabled = true;
      try {
        const assignmentId = check(await sb.rpc("request_interpreter_assignment", {
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
          p_duration_hours: Number(fields.duration_hours),
        }));
        const { url } = await callFunction("create-booking-checkout", { assignment_id: assignmentId });
        window.location.href = url;
      } catch (error) {
        if (submit) submit.disabled = false;
        throw error;
      }
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
  if (isPreviewMode()) {
    dlg.innerHTML = `<h2 id="dialog-title">Preview mode</h2><p>Interpreter samples are for preview only. Connect Supabase to create accounts and publish real profiles.</p><div class="row"><button type="button" data-close>Close</button></div>`;
    if (!dlg.open) dlg.showModal();
    return;
  }
  dlg.innerHTML = `<h2 id="dialog-title">Sign up</h2>${note ? `<p class="error" role="alert">${esc(note)}</p>` : ""}
    <form id="su"><label>I am an <select name="role"><option value="organization">Organization (hospital, court, school, agency)</option><option value="personal">Personal use</option><option value="interpreter">Interpreter</option></select></label>
    <label>Name <input name="full_name" required maxlength="100"></label>
    <div id="orgf"><label>Organization name <input name="org_name" required maxlength="150"></label></div>
    <label>Email <input type="email" name="email" required></label>
    <label>Password (8+ characters) <input type="password" name="password" minlength="8" required autocomplete="new-password"></label>
    <details class="policy-copy"><summary>Review Terms, Privacy Notice and Community Rules (v1.0)</summary>
      <h3>Terms of Use</h3><p>Exponent helps customers find interpreters and request assignments. An assignment is not confirmed until an interpreter accepts it. Users are responsible for accurate information and their agreements with each other.</p>
      <h3>Privacy Notice</h3><p>Exponent stores account details, interpreter profiles, messages and assignment information to provide the service. Interpreter email and phone details are kept private from public listings.</p>
      <h3>Community Rules</h3><p>Provide accurate identity and qualification information. Do not impersonate others, harass users, or put private contact details in messages.</p>
    </details>
    <label class="check consent-check"><input type="checkbox" name="accept_policies" required> I agree to the current Terms of Use, Privacy Notice and Community Rules (v1.0).</label>
    <label class="check consent-check"><input type="checkbox" name="required_policy_notifications" required> I agree to receive in-app notices about important Terms, Privacy Notice or Community Rules changes.</label>
    <label class="check consent-check"><input type="checkbox" name="feature_updates_opt_in"> Notify me in-app about new Exponent features (optional).</label>
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
        <label>Other languages (optional) <input name="other_languages" placeholder="e.g. French, Mandarin"></label>
        <label>Specialties (comma separated) <input name="specialties" placeholder="conference, legal, medical, education, other"></label>
        <label>Other expertise (optional) <input name="other_specialties" placeholder="e.g. immigration, mental health"></label>
        <label>Certifications (comma separated) <input name="certs" placeholder="CCHI, NBCMI, Court certified"></label>
         <fieldset class="filter-checks"><legend>Scope of interpretation</legend>
           <label class="check"><input type="checkbox" name="certification_scopes" value="national"> National</label>
           <label class="check"><input type="checkbox" name="certification_scopes" value="international"> International</label>
           <label class="check"><input type="checkbox" name="certification_scopes" value="state"> State</label>
           <label class="check"><input type="checkbox" name="certification_scopes" value="local"> Local</label>
         </fieldset>
         <label>City <input name="city" required maxlength="100"></label>
         <label>State <input name="state"></label>
          <label>ZIP code <input name="postal_code" inputmode="numeric" autocomplete="postal-code" pattern="[0-9]{5}(-[0-9]{4})?" required></label>
          <p class="muted">City, state, and ZIP help clients find you. Do not enter a street address; these location details appear in search results.</p>
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
    const data = {
      role: f.role,
      full_name: f.full_name,
      accepted_terms_version: POLICY_VERSIONS.terms,
      accepted_privacy_version: POLICY_VERSIONS.privacy,
      accepted_rules_version: POLICY_VERSIONS.rules,
      required_policy_notifications: f.required_policy_notifications === "on",
      feature_updates_opt_in: f.feature_updates_opt_in === "on",
      consented_at: new Date().toISOString(),
    };
    if (f.role === "organization") data.org_name = f.org_name;
    else if (f.role === "interpreter") Object.assign(data, {
      languages: [...new Set([...split(f.languages), ...split(f.other_languages)])],
      specialties: [...new Set([...split(f.specialties), ...split(f.other_specialties)])].map(s => s.toLowerCase()),
      certs: split(f.certs),
      certification_scopes: formData.getAll("certification_scopes"),
      city: f.city, state: f.state, postal_code: f.postal_code, phone: f.phone, hourly_rate: +f.rate, remote: !!f.remote, in_person: !!f.in_person,
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
  if (isPreviewMode()) {
    dlg.innerHTML = `<h2 id="dialog-title">Preview mode</h2><p>Connect Supabase to enable account sign-in.</p><div class="row"><button type="button" data-close>Close</button></div>`;
    if (!dlg.open) dlg.showModal();
    return;
  }
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
      <label>City <input id="profile-city" value="${esc(i.city)}" maxlength="100" autocomplete="address-level2"></label>
      <label>State <input id="profile-state" value="${esc(i.state)}" maxlength="50" autocomplete="address-level1"></label>
      <label>ZIP code <input id="profile-postal-code" value="${esc(i.postal_code)}" maxlength="10" inputmode="numeric" autocomplete="postal-code" pattern="[0-9]{5}(-[0-9]{4})?"></label>
      <p class="muted">City, state, and ZIP appear in search results. Keep your street address private.</p>
      <button type="button" id="save-location">Save location</button>
      <label>Phone (private) <input id="phone" value="${esc(me.user.user_metadata?.phone)}" maxlength="40"></label>
      <label><input type="checkbox" id="avail" ${i.available ? "checked" : ""}> Available</label>
      <h3>Payouts</h3>
      ${me.payout?.payouts_enabled
        ? '<p class="muted">Payouts are set up. You can accept paid bookings.</p>'
        : '<p class="muted">Set up payouts to receive payment and be bookable. Stripe, our payment partner, securely collects your ID and bank details; Exponent never sees or stores them.</p><button type="button" id="setup-payouts">Set up payouts</button>'}
      <p class="muted">${i.verified ? "Verified." : "Not verified. Optional $10/month certification verification is planned, but not available yet."}</p>`;
  }
  body += `<label class="check consent-check"><input type="checkbox" id="feature-updates" ${p.feature_updates_opt_in ? "checked" : ""}> Notify me in-app about new Exponent features.</label>`;
  dlg.innerHTML = `<h2 id="dialog-title">Account</h2>${body}<div class="row"><button type="button" class="secondary" data-close>Close</button></div>`;
  $("#phone")?.addEventListener("change", e => attempt(async () => {
    const phone = e.target.value.slice(0, 40);
    check(await sb.from("interpreter_contacts").update({ phone }).eq("interpreter_id", me.user.id));
    const { error } = await sb.auth.updateUser({ data: { phone } });
    if (error) throw error;
  }));
  $("#save-location")?.addEventListener("click", () => attempt(async () => {
    const postalCode = $("#profile-postal-code").value.trim();
    if (postalCode && !/^\d{5}(?:-\d{4})?$/.test(postalCode)) throw new Error("Enter a valid 5-digit ZIP code or ZIP+4.");
    check(await sb.from("interpreters").update({
      city: $("#profile-city").value.trim(),
      state: $("#profile-state").value.trim(),
      postal_code: postalCode || null,
    }).eq("id", me.user.id));
    await refresh();
    showAccount();
  }));
  $("#setup-payouts")?.addEventListener("click", e => attempt(async () => {
    e.target.disabled = true;
    const { url } = await callFunction("connect-onboarding", { action: "start" });
    window.location.href = url;
  }).finally(() => { e.target.disabled = false; }));
  $("#avail")?.addEventListener("change", e => attempt(async () => {
    check(await sb.from("interpreters").update({ available: e.target.checked }).eq("id", me.user.id));
    await refresh();
  }));
  $("#feature-updates")?.addEventListener("change", e => attempt(async () => {
    check(await sb.rpc("update_feature_updates_preference", { p_enabled: e.target.checked }));
    me.profile.feature_updates_opt_in = e.target.checked;
  }));
  dlg.showModal();
}

document.addEventListener("click", e => {
  const t = e.target.closest("button") || e.target;
  if (t.dataset.close !== undefined) dlg.close();
  if (t.id === "retry-search") refresh();
  if (t.id === "clear-filters") clearFilters();
  if (t.dataset.interactSignup !== undefined) showSignup("Create an account or log in to message interpreters and request assignments.");
  if (t.dataset.ackNotice) acknowledgeNotice(t.dataset.ackNotice);
  if (t.dataset.readNotice) markNoticeRead(t.dataset.readNotice);
  if (t.dataset.assignmentTo) showAssignmentForm(t.dataset.assignmentTo);
  if (t.dataset.assignmentResponse) {
    attempt(async () => {
      if (t.dataset.accept === "true") {
        t.disabled = true;
        try {
          await callFunction("accept-assignment", { assignment_id: t.dataset.assignmentResponse });
        } catch (error) {
          t.disabled = false;
          throw error;
        }
      } else {
        check(await sb.rpc("respond_to_assignment", {
          p_assignment_id: t.dataset.assignmentResponse,
          p_accept: false,
        }));
      }
      await showAssignments();
    });
  }
  if (t.dataset.payBooking) {
    attempt(async () => {
      t.disabled = true;
      try {
        const { url } = await callFunction("create-booking-checkout", { assignment_id: t.dataset.payBooking });
        window.location.href = url;
      } catch (error) {
        t.disabled = false;
        throw error;
      }
    });
  }
  if (t.dataset.cancelBooking && confirm("Cancel this request? Any card hold will be released and you won't be charged.")) {
    attempt(async () => {
      t.disabled = true;
      await callFunction("cancel-booking", { assignment_id: t.dataset.cancelBooking });
      await showAssignments();
    });
  }
  if (t.dataset.messageTo) showMessageForm(t.dataset.messageTo);
  if (t.dataset.thread) showThread(t.dataset.thread);
  if (t.dataset.backInbox !== undefined) showInbox();
});

// After Stripe sends people back (?payment=… or ?payouts=…), refresh state and show what happened.
async function handleStripeReturn() {
  const params = new URLSearchParams(location.search);
  const payment = params.get("payment");
  const payouts = params.get("payouts");
  if (!payment && !payouts) return;
  history.replaceState(null, "", location.pathname + location.hash);
  if (!me || isPreviewMode()) return;
  await attempt(async () => {
    if (payouts) {
      await callFunction("connect-onboarding", { action: "status" });
      await refresh();
      showAccount();
    } else if (payment === "success") {
      dlg.innerHTML = `<h2 id="dialog-title">Payment authorized</h2><p>Your card is held, not charged. Your request is going to the interpreter now. You're charged only if they accept.</p><div class="row"><button type="button" id="view-assignments">View my requests</button><button type="button" class="secondary" data-close>Close</button></div>`;
      $("#view-assignments").addEventListener("click", showAssignments);
      dlg.showModal();
    } else {
      await showAssignments();
    }
  });
}

let timer;
$("#start-search").addEventListener("click", () => {
  $("#top").classList.add("search-open");
  $("#search").hidden = false;
  $("#search").scrollIntoView({ behavior: "smooth", block: "start" });
  $("#filter-language").focus();
});
$("#filters").addEventListener("submit", e => { e.preventDefault(); render(); });
$("#filters").addEventListener("input", () => { clearTimeout(timer); timer = setTimeout(render, 150); });
sb.auth.onAuthStateChange((event) => { if (event === "SIGNED_IN" || event === "SIGNED_OUT") refresh(); });
refresh().then(handleStripeReturn);
