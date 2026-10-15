// Edge Function Supabase : paiement SimplyPaye + réservations gratuites + réservations "payer plus tard"
// Déploiement : supabase functions deploy simplypaye --no-verify-jwt
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const API = "https://api-simply-pay.net/api";
const MC = Deno.env.get("SIMPLYPAYE_MERCHANT_CODE") ?? "";
const KEY = Deno.env.get("SIMPLYPAYE_API_KEY") ?? "";
const SITE = (Deno.env.get("SITE_URL") ?? "").replace(/\/$/, "");
const SB_URL = Deno.env.get("SUPABASE_URL")!;
const SEND_CALLBACK = Deno.env.get("SIMPLYPAYE_CALLBACK") !== "0"; // callback ACTIVÉ par défaut (domaine autorisé par SimplyPaye). Mettre le secret SIMPLYPAYE_CALLBACK=0 pour le couper.
const SEND_CHANNEL = Deno.env.get("SIMPLYPAYE_CHANNEL") === "1"; // envoie le champ channel (opérateur) à SimplyPaye, seulement si leur API l'accepte
const MAIN_HOLD_HOURS = Math.min(Math.max(Number(Deno.env.get("HOLD_HOURS") ?? 48), 1), 168);
let SELF = "simplypaye"; // nom reel de la fonction, detecte automatiquement (ex. hyper-worker)
const db = createClient(SB_URL, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

// Origines autorisées : le site + l'application mobile Capacitor (Android/iOS). Ajoutez ALLOWED_ORIGINS="https://autre.site" si besoin.
const ALLOWED = new Set([
  SITE, "capacitor://localhost", "https://localhost", "http://localhost",
  ...(Deno.env.get("ALLOWED_ORIGINS") ?? "").split(",").map((x) => x.trim().replace(/\/$/, "")).filter(Boolean),
].filter(Boolean));
let CORS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Vary": "Origin",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json; charset=utf-8" } });
const fail = (m: string, s = 400) => json({ error: m }, s);

const MAIN: Record<string, [string, number, "FC" | "USD"]> = {
  standard: ["Standard", 5000, "FC"],
  vip: ["VIP", 10, "USD"],
  vvip: ["VVIP", 20, "USD"],
  sponsor: ["Sponsor", 50, "USD"],
  grand_sponsor: ["Grand Sponsor", 100, "USD"],
};
const MAIN_LIMIT_STANDARD = 300;

type Row = Record<string, any>;
// Les numéros sont chiffrés en base (AES-256) : on compare via un index aveugle calculé côté base.
const blind = async (p: unknown) => { const { data } = await db.rpc("blind", { t: String(p ?? "") }); return String(data ?? ""); };
const txt = (v: unknown, n = 200) => String(v ?? "").trim().slice(0, n);
const last9 = (p: unknown) => String(p ?? "").replace(/\D/g, "").slice(-9);
const phone243 = (p: string) => {
  let d = String(p || "").replace(/\D/g, "");
  if (d.startsWith("0")) d = "243" + d.slice(1);
  return /^243\d{9}$/.test(d) ? d : "";
};
const OPS_OK = ["mpesa", "airtel", "orange", "africell"];
const opByNumber = (p: unknown) => {
  let d = String(p ?? "").replace(/\D/g, "");
  if (d.startsWith("243")) d = d.slice(3); else if (d.startsWith("0")) d = d.slice(1);
  const m: Record<string, string> = { "81": "mpesa", "82": "mpesa", "83": "mpesa", "97": "airtel", "98": "airtel", "99": "airtel", "84": "orange", "85": "orange", "89": "orange", "90": "africell", "91": "africell" };
  return m[d.slice(0, 2)] || "";
};
// L'opérateur est déduit du numéro : plus aucun message de désaccord n'est nécessaire.
const pickOp = (b: Row) => OPS_OK.includes(String(b.op)) ? String(b.op) : OPS_OK.includes(String(b.method)) ? String(b.method) : opByNumber(b.mm);
const tableOf = (kind: string) => (kind === "event" ? "orders" : "reservations");
const codeOf = (kind: string, id: string) => (kind === "event" ? "EV-" : "LRR-") + id.slice(0, 8).toUpperCase();
const descOf = (kind: string, row: Row) =>
  kind === "event"
    ? (row.items || []).map((i: Row) => `${i.name} × ${i.qty}`).join(", ")
    : Object.entries(MAIN).filter(([k]) => row[k]).map(([k, v]) => `${v[0]} × ${row[k]}`).join(", ");
const ticketOf = (kind: string, row: Row) => ({ id: row.id, code: codeOf(kind, row.id), name: row.name, desc: descOf(kind, row) });

const spHeaders = () => {
  const h: Record<string, string> = { "Content-Type": "application/json", Accept: "application/json" };
  if (KEY) h["X-API-Key"] = KEY;
  return h;
};

async function expireHolds() {
  const now = new Date().toISOString();
  for (const t of ["orders", "reservations"]) {
    await db.from(t).update({ status: "cancelled" }).eq("hold", true).eq("status", "pending").is("pay_ref", null).lt("expires_at", now);
  }
}

// ---------- SimplyPaye ----------
// POST qui suit les redirections SANS transformer le POST en GET
// (corrige : "The GET method is not supported for route api/simply-production")
let SP_TRACE = "";
async function spPost(path: string, body: unknown) {
  let url = API + path;
  SP_TRACE = "";
  for (let i = 0; i < 5; i++) {
    const r = await fetch(url, { method: "POST", headers: spHeaders(), body: JSON.stringify(body), redirect: "manual" });
    SP_TRACE += `${r.status} ${url} | `;
    if ([301, 302, 303, 307, 308].includes(r.status)) {
      const loc = r.headers.get("location");
      if (!loc) return r;
      url = new URL(loc, url).toString();
      continue;
    }
    return r;
  }
  throw new Error("Trop de redirections SimplyPaye");
}
const PAID = ["0", "success", "successful", "completed", "paid", "approved", "succes", "succès", "complete", "done", "validated", "accepted", "paye", "payé", "successfull"];
const FAILED = ["2", "failed", "fail", "declined", "error", "rejected"];
const CANCELLED = ["3", "cancelled", "canceled"];

let LAST_RAW: unknown = null;
async function spStatus(orderNumber: string) {
  const r = await fetch(`${API}/checkstatus-ordernumber/${encodeURIComponent(orderNumber)}`, { headers: spHeaders() });
  const j = (await r.json().catch(() => ({}))) as Record<string, any>;
  LAST_RAW = { http: r.status, ...j };
  return j;
}
// SimplyPaye peut renvoyer l'état à la racine ou dans un sous-objet (simply_pay, data, transaction...).
// On lit d'abord les sous-objets (l'état réel du paiement), puis la racine.
const STATE_KEYS = ["status", "state", "transaction_status", "transactionStatus", "payment_status", "paymentStatus", "statut"];
function statesOf(s: Record<string, any>): string[] {
  const out: string[] = [];
  const pull = (o: any) => { if (o && typeof o === "object") for (const k of STATE_KEYS) if (o[k] !== undefined && o[k] !== null) out.push(String(o[k]).trim().toLowerCase()); };
  for (const sub of [s?.simply_pay, s?.data, s?.transaction, s?.payment, s?.result, s?.order]) pull(sub);
  pull(s);
  return out;
}

// Cherche la référence SimplyPaye (orderNumber) à la racine ou dans un sous-objet (réponse API ou corps du callback).
function orderNumberOf(s: Record<string, any>): string {
  for (const o of [s, s?.simply_pay, s?.data, s?.transaction, s?.payment, s?.result, s?.order]) {
    if (!o || typeof o !== "object") continue;
    for (const k of ["orderNumber", "order_number", "ordernumber", "orderNo"]) if (o[k]) return String(o[k]).trim().slice(0, 80);
  }
  return "";
}

// Délais : on ne déclare JAMAIS un échec tant que le client a peut-être encore le temps de saisir son code secret.
const GRACE_FAILED_MS = 240_000;   // 4 min : un état "échec" reçu avant est ignoré (le client est encore en train de valider)
const GRACE_CANCEL_MS = 120_000;   // 2 min pour un état "annulé"
const GIVE_UP_MS = 900_000;        // 15 min : on libère définitivement les billets d'un paiement jamais validé

const sameOrder = (kind: string, a: Row, b: Row) => {
  if (kind === "main") return ["standard", "vip", "vvip", "sponsor", "grand_sponsor"].every((k) => (+a[k] || 0) === (+b[k] || 0));
  const key = (o: Row) => JSON.stringify((o.items || []).map((i: Row) => [i.id, i.qty]).sort());
  return a.event_id === b.event_id && key(a) === key(b);
};

// Quand un paiement est confirmé, les demandes identiques en double (même numéro, mêmes billets) sont annulées : plus de double compte.
async function cleanupDuplicates(kind: string, row: Row) {
  try {
    if (!row.phone_idx) return;
    const since = new Date(new Date(row.created_at || Date.now()).getTime() - 30 * 60 * 1000).toISOString();
    const { data } = await db.from(tableOf(kind)).select("*").eq("phone_idx", row.phone_idx).eq("status", "pending")
      .eq("pay_provider", "simplypaye").neq("id", row.id).gte("created_at", since).limit(20);
    for (const d of data || []) if (sameOrder(kind, d, row)) await db.from(tableOf(kind)).update({ status: "cancelled" }).eq("id", d.id).eq("status", "pending");
  } catch (_) { /* sans gravité */ }
}

async function verify(kind: string, row: Row, hint = "") {
  if (row.status === "confirmed") return { status: "success", ticket: ticketOf(kind, row) };
  if (row.status === "cancelled") return { status: "cancelled" };
  const age = Date.now() - new Date(row.created_at || Date.now()).getTime();
  const code = codeOf(kind, row.id);
  // Sans référence enregistrée (cas du 502 au lancement) : on essaie avec la référence du callback, sinon avec notre code EV-/LRR-.
  const lookup = row.pay_ref || hint || code;
  const s = await spStatus(lookup);
  console.log("checkstatus", row.pay_ref, "age=" + Math.round(age / 1000) + "s", JSON.stringify(s)); // visible dans Edge Functions > Logs
  const ref = String(s.reference ?? s?.simply_pay?.reference ?? s?.data?.reference ?? "").trim().toUpperCase();
  if (/^(LRR|EV)-/.test(ref) && ref !== code) return { status: "pending" };
  if (!row.pay_ref) {
    // Sécurité : sans référence enregistrée, SimplyPaye doit nous renvoyer EXACTEMENT notre code, sinon on n'accepte rien.
    if (ref !== code) return { status: "pending", note: "Référence SimplyPaye absente : en attente du rappel (callback) ou à vérifier à la main." };
    const found = hint || orderNumberOf(s);
    if (found) { await db.from(tableOf(kind)).update({ pay_ref: found }).eq("id", row.id); row.pay_ref = found; }
  }
  const states = statesOf(s);
  // 1) Payé : prioritaire sur tout le reste
  if (states.some((st) => PAID.includes(st))) {
    await db.from(tableOf(kind)).update({ status: "confirmed", hold: false }).eq("id", row.id).neq("status", "confirmed");
    await cleanupDuplicates(kind, row);
    return { status: "success", ticket: ticketOf(kind, row) };
  }
  // 2) Échec / annulation : seulement après le délai de grâce
  if (states.some((st) => FAILED.includes(st))) {
    if (age < GRACE_FAILED_MS) return { status: "pending", waiting: true, age: Math.round(age / 1000) };
    if (age > GIVE_UP_MS) await db.from(tableOf(kind)).update({ status: "cancelled" }).eq("id", row.id).eq("status", "pending");
    return { status: "failed" };
  }
  if (states.some((st) => CANCELLED.includes(st))) {
    if (age < GRACE_CANCEL_MS) return { status: "pending", waiting: true, age: Math.round(age / 1000) };
    await db.from(tableOf(kind)).update({ status: "cancelled" }).eq("id", row.id).eq("status", "pending");
    return { status: "cancelled" };
  }
  return { status: "pending", age: Math.round(age / 1000) };
}

// Confirme les paiements deja effectues mais jamais enregistres (page fermee, reseau coupe...)
async function reconcilePending() {
  const since = new Date(Date.now() - 48 * 3600 * 1000).toISOString();
  for (const k of ["main", "event"]) {
    const { data } = await db.from(tableOf(k)).select("*").eq("status", "pending").eq("pay_provider", "simplypaye")
      .gte("created_at", since).order("created_at", { ascending: false }).limit(10);
    for (const row of data || []) { try { await verify(k, row); } catch (_) { /* on reessaiera */ } }
  }
}

// Lance le paiement SimplyPaye d'une commande déjà enregistrée
async function startProvider(kind: string, row: Row, method: string, mmRaw: string, title = "", op = "") {
  const mm = phone243(mmRaw);
  if (method === "mobile" && !mm) return { error: "Numéro Mobile Money invalide (format 2438XXXXXXXX)" };
  let total = 0, currency = "CDF";
  if (kind === "main") {
    if (row.fc && row.usd) return { error: "Payez les billets en FC et en $ séparément." };
    total = row.fc || row.usd; currency = row.fc ? "CDF" : "USD";
  } else {
    const cs = Object.keys(row.amounts || {});
    if (cs.length !== 1) return { error: "Payez les billets en FC et en $ séparément." };
    total = row.amounts[cs[0]]; currency = cs[0] === "USD" ? "USD" : "CDF";
  }
  if (!(total > 0)) return { error: "Montant invalide" };
  const code = codeOf(kind, row.id);
  const body: Record<string, unknown> = method === "card"
    ? { shortCode: MC, amount: total, currency, description: `Billet ${title || "Le Restau du Rire"} ${code}`.slice(0, 100),
        approve: `${SITE}/?pay=ok`, cancel: `${SITE}/?pay=cancel`, decline: `${SITE}/?pay=decline` }
    : { merchantCode: MC, phone: mm, amount: String(total), currency, reference: code, ...(op && SEND_CHANNEL ? { channel: op } : {}) };
  if (SEND_CALLBACK) {
    const cb = `${SB_URL}/functions/v1/${SELF}?cb=1&ref=${code}`;
    if (method === "card") body.callback = cb; else body.callbackUrl = cb;
  }
  // UNE SEULE tentative : meme si la passerelle repond 502, le paiement peut deja etre cree chez SimplyPaye.
  // Relancer la demande enverrait plusieurs demandes de paiement au client (risque de double debit).
  let r!: Response; let d: any = {}; let tries = "";
  try { r = await spPost(method === "card" ? "/simply-production-card" : "/simply-production", body); }
  catch (e) { return { error: "SimplyPaye injoignable : " + txt((e as Error).message, 120) }; }
  const raw = await r.text();
  try { d = JSON.parse(raw); } catch { d = { message: raw.slice(0, 160) }; }
  tries = `HTTP ${r.status} ${raw.slice(0, 90).replace(/\s+/g, " ")}`;
  if (!r.ok) console.log("simplypaye init", tries);
  const orderNumber = d?.simply_pay?.orderNumber ?? d?.orderNumber ?? null;
  const paymentUrl = d?.payment_url ?? null;
  const ok = r.ok && (method === "card" ? !!paymentUrl : String(d?.status) === "1" && !!orderNumber);
  if (!ok) console.log("simplypaye refus", tries, JSON.stringify(d));
  if (!ok && method !== "card" && (r.status >= 500 || String(d?.message || "").includes("GET method"))) {
    // Reponse illisible de la passerelle : la demande de paiement a pu partir quand meme sur le telephone du client.
    await db.from(tableOf(kind)).update({ pay_provider: "simplypaye", payer: mm || "Mobile Money", rec: "SimplyPaye (à vérifier)", ...(kind === "event" ? { kind: "online" } : {}) }).eq("id", row.id);
    return { ambiguous: true };
  }
  if (!ok) return { error: (txt(d?.message, 160) + (String(d?.message || "").includes("GET method") ? " [diag: " + tries.slice(0, 260) + "]" : "")) || "Paiement refusé par SimplyPaye. Vérifiez le numéro et réessayez." };
  await db.from(tableOf(kind)).update({ pay_ref: orderNumber ?? d?.reference ?? null, pay_provider: "simplypaye", payer: mm || "Carte", rec: "SimplyPaye", ...(kind === "event" ? { kind: "online" } : {}) }).eq("id", row.id);
  return { paymentUrl };
}

// ---------- Construction d'une commande (prix recalculés côté serveur) ----------
async function build(kind: string, b: Row, mode: "pay" | "free" | "hold") {
  if (kind === "main" && Deno.env.get("MAIN_OPEN") !== "1") return { error: "La billetterie de l'Édition 1.5 n'est pas encore ouverte." };
  const c = b.customer || {};
  const name = txt(c.name, 120), wa = txt(c.phone, 30);
  if (name.length < 3 || !wa) return { error: "Nom et numéro WhatsApp obligatoires" };
  const addr = {
    pays: txt(c.pays), province: txt(c.province), ville: txt(c.ville),
    commune: txt(c.commune), quartier: txt(c.quartier), avenue: txt(c.avenue), loc: txt(c.loc, 400),
  };
  if (kind === "main" && Object.values(addr).some((v) => !v)) return { error: "Adresse complète obligatoire" };
  const q: Record<string, number> = {};
  for (const [k, v] of Object.entries(b.qty || {})) {
    const n = Math.floor(Number(v));
    if (n > 0) q[k] = Math.min(n, 10);
  }
  if (!Object.keys(q).length) return { error: "Sélectionnez au moins un billet" };

  const id = crypto.randomUUID();
  const hold = mode === "hold";
  const base: Row = { id, name, phone: wa, email: txt(c.email) || null, seller: null, proof_path: null,
    status: mode === "free" ? "confirmed" : "pending", hold, payer: null, rec: null,
    pay_provider: mode === "pay" ? "simplypaye" : null };
  let hours = MAIN_HOLD_HOURS, title = "";

  if (kind === "main") {
    if (mode === "free") return { error: "Réservation gratuite indisponible" };
    const sums = { FC: 0, USD: 0 }; const cols: Record<string, number> = {}; let n = 0;
    for (const [k, v] of Object.entries(q)) {
      if (!MAIN[k]) return { error: "Catégorie inconnue" };
      sums[MAIN[k][2]] += MAIN[k][1] * v; cols[k] = v; n += v;
    }
    if (mode === "pay" && sums.FC && sums.USD) return { error: "Payez les billets en FC et en $ séparément." };
    if (cols.standard) {
      const { data } = await db.from("reservations").select("standard").neq("status", "cancelled");
      const taken = (data || []).reduce((a: number, r: Row) => a + (+r.standard || 0), 0);
      if (taken + cols.standard > MAIN_LIMIT_STANDARD) return { error: "Catégorie Standard complète." };
    }
    base.note = txt(c.note, 400);
    Object.assign(base, addr, { standard: 0, vip: 0, vvip: 0, sponsor: 0, grand_sponsor: 0 }, cols, { total: n, fc: sums.FC, usd: sums.USD });
  } else {
    const { data: ev } = await db.from("events").select("*").eq("id", txt(b.event_id, 60)).maybeSingle();
    if (!ev || ev.status !== "published") return { error: "Événement indisponible" };
    const modes = ev.modes || {};
    if (mode === "pay" && !modes.online) return { error: "Paiement en ligne indisponible pour cet événement" };
    if (mode === "hold" && !modes.hold) return { error: "Réservation sans paiement indisponible pour cet événement" };
    hours = Math.min(Math.max(Number(modes.hold_hours) || 48, 1), 168); title = ev.title;
    const { data: sold } = await db.from("orders").select("items").eq("event_id", ev.id).neq("status", "cancelled");
    const soldBy: Record<string, number> = {};
    (sold || []).forEach((o: Row) => (o.items || []).forEach((i: Row) => (soldBy[i.id] = (soldBy[i.id] || 0) + i.qty)));
    const amounts: Record<string, number> = {}; const items: Row[] = []; let n = 0;
    for (const [tid, qty] of Object.entries(q)) {
      const t = (ev.tickets || []).find((x: Row) => x.id === tid);
      if (!t) return { error: "Catégorie inconnue" };
      if (t.stock && (soldBy[tid] || 0) + qty > t.stock) return { error: `${t.name} : complet` };
      amounts[t.currency] = (amounts[t.currency] || 0) + t.price * qty; n += qty;
      items.push({ id: t.id, name: t.name, qty, price: t.price, currency: t.currency });
    }
    const totalAll = Object.values(amounts).reduce((a, v) => a + v, 0);
    if (mode === "free" && totalAll !== 0) return { error: "Cette commande n'est pas gratuite" };
    if (mode === "hold" && totalAll === 0) return { error: "Billets gratuits : réservez directement, sans attente." };
    if (mode === "pay" && (totalAll <= 0 || Object.keys(amounts).length > 1)) return { error: Object.keys(amounts).length > 1 ? "Payez les billets en FC et en $ séparément." : "Montant invalide" };
    Object.assign(base, { event_id: ev.id, kind: mode === "pay" ? "online" : "reservation", address: addr, items, total_qty: n, amounts });
  }
  if (hold) base.expires_at = new Date(Date.now() + hours * 3600e3).toISOString();
  return { row: base, wa, title, hours };
}

async function antiSpam(kind: string, wa: string) {
  const since = new Date(Date.now() - 10 * 60 * 1000).toISOString();
  const { count } = await db.from(tableOf(kind)).select("id", { count: "exact", head: true })
    .eq("phone_idx", await blind(wa)).eq("status", "pending").gte("created_at", since);
  return (count ?? 0) >= 3;
}

const amountsOf = (kind: string, row: Row) => (kind === "main" ? { FC: row.fc || 0, USD: row.usd || 0 } : row.amounts || {});

// Limitation de débit simple par IP (anti-abus) : 40 requêtes POST / minute
const HITS = new Map<string, number[]>();
const limited = (ip: string) => {
  const now = Date.now(), arr = (HITS.get(ip) ?? []).filter((x) => now - x < 60_000);
  arr.push(now); HITS.set(ip, arr);
  if (HITS.size > 5000) HITS.clear();
  return arr.length > 40;
};

Deno.serve(async (req) => {
  const origin = (req.headers.get("origin") ?? "").replace(/\/$/, "");
  // Par défaut : toutes les origines (comme avant). Mettre le secret STRICT_CORS=1 pour limiter au site + app mobile.
  const strict = Deno.env.get("STRICT_CORS") === "1";
  CORS = { ...CORS, "Access-Control-Allow-Origin": !strict ? "*" : ALLOWED.has(origin) ? origin : (SITE || "null") };
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method === "POST") {
    const ip = (req.headers.get("x-forwarded-for") ?? "").split(",")[0].trim() || "?";
    if (limited(ip)) return fail("Trop de requêtes, réessayez dans une minute.", 429);
    if (Number(req.headers.get("content-length") ?? 0) > 200_000) return fail("Requête trop volumineuse.", 413);
  }
  // Diagnostic (sans donnée sensible) : appelé par le Dashboard admin
  if (req.method === "GET" && !req.url.includes("cb=1")) return json({ ok: true, merchant: !!MC, key: !!KEY, site: !!SITE, main_open: Deno.env.get("MAIN_OPEN") === "1", callback: SEND_CALLBACK });
  const missing = [!MC && "SIMPLYPAYE_MERCHANT_CODE", !KEY && "SIMPLYPAYE_API_KEY", !SITE && "SITE_URL"].filter(Boolean);
  if (missing.length) return fail("Configuration serveur incomplète : secret(s) manquant(s) → " + missing.join(", "), 500);
  const url = new URL(req.url);
  SELF = url.pathname.split("/").filter(Boolean).pop() || SELF;

  // Callback SimplyPaye : on revérifie auprès de l'API, on ne fait pas confiance au contenu
  if (url.searchParams.get("cb")) {
    const b = await req.json().catch(() => ({}));
    console.log("callback recu", JSON.stringify(b).slice(0, 500)); // visible dans Edge Functions > Logs
    const ref = txt(url.searchParams.get("ref") || b.reference || b.ref || b?.simply_pay?.reference || b?.data?.reference, 40);
    const hint = orderNumberOf(b);
    const kind = ref.startsWith("EV-") ? "event" : "main";
    if (ref) {
      const { data } = await db.from(tableOf(kind)).select("*").order("created_at", { ascending: false }).limit(500);
      const row = (data || []).find((r: Row) => codeOf(kind, String(r.id)) === ref);
      if (row) await verify(kind, row, hint);
    }
    return json({ ok: true });
  }

  if (req.method !== "POST") return fail("Méthode non autorisée", 405);
  const b = await req.json().catch(() => null);
  if (!b) return fail("Requête invalide");
  const kind = b.kind === "event" ? "event" : "main";
  await expireHolds();
  if (b.action !== "status") await reconcilePending();
  if (b.action === "sync") return json({ ok: true });

  // Statut d'un paiement
  if (b.action === "status") {
    const { data: row } = await db.from(tableOf(kind)).select("*").eq("id", txt(b.id, 60)).maybeSingle();
    if (!row || row.pay_provider !== "simplypaye") return fail("Commande introuvable", 404);
    const v: Record<string, unknown> = await verify(kind, row);
    if (b.debug) v.raw = LAST_RAW; // utilisé par « Vérifier les paiements en attente » (Dashboard admin)
    return json(v);
  }

  // Test de liaison SimplyPaye (Dashboard admin > « Tester SimplyPaye ») : lecture seule, aucun paiement créé
  if (b.action === "probe") {
    const essais: Row[] = [];
    try {
      const r = await fetch(`${API}/checkstatus-ordernumber/PROBE-TEST`, { headers: spHeaders() });
      const raw = await r.text();
      essais.push({ essai: 1, statut: r.status, chemin: "/checkstatus-ordernumber", type: r.headers.get("content-type") ?? "", reponse: raw.slice(0, 200) });
    } catch (e) { essais.push({ essai: 1, erreur: txt((e as Error).message, 160) }); }
    return json({ ok: true, essais });
  }

  // Paiement immédiat
  if (b.action === "pay") {
    const method = b.method === "card" ? "card" : "mobile";
    const op = pickOp(b);
    if (method === "mobile" && !phone243(b.mm)) return fail("Numéro Mobile Money invalide (format 2438XXXXXXXX)");
    const r = await build(kind, b, "pay");
    if (r.error) return fail(r.error);
    // Anti-doublon : même numéro + mêmes billets depuis moins de 4 min => on reprend la demande en cours (pas de 2e message sur le téléphone)
    if (method === "mobile") {
      const since = new Date(Date.now() - GRACE_FAILED_MS).toISOString();
      const { data: recent } = await db.from(tableOf(kind)).select("*").eq("phone_idx", await blind(r.wa!)).eq("status", "pending")
        .eq("pay_provider", "simplypaye").gte("created_at", since).order("created_at", { ascending: false }).limit(10);
      const dup = (recent || []).find((d: Row) => sameOrder(kind, d, r.row!));
      if (dup) return json({ id: dup.id, code: codeOf(kind, dup.id), kind, method, payment_url: null, reused: true });
    }
    if (await antiSpam(kind, r.wa!)) return fail("Trop de tentatives. Patientez quelques minutes.", 429);
    const { error: ie } = await db.from(tableOf(kind)).insert(r.row!);
    if (ie) return fail("Enregistrement impossible : " + ie.message, 500);
    const p = await startProvider(kind, r.row!, method, b.mm, r.title, op);
    if (p.error) { await db.from(tableOf(kind)).delete().eq("id", r.row!.id); return fail(p.error, 502); }
    if (p.ambiguous) console.log("paiement ambigu conserve", codeOf(kind, r.row!.id));
    return json({ id: r.row!.id, code: codeOf(kind, r.row!.id), kind, method, payment_url: p.paymentUrl ?? null });
  }

  // Réservation gratuite : billet confirmé tout de suite
  if (b.action === "free") {
    const r = await build("event", b, "free");
    if (r.error) return fail(r.error);
    if (await antiSpam("event", r.wa!)) return fail("Trop de tentatives. Patientez quelques minutes.", 429);
    const { error: ie } = await db.from("orders").insert(r.row!);
    if (ie) return fail("Enregistrement impossible : " + ie.message, 500);
    return json({ status: "success", ticket: ticketOf("event", r.row!) });
  }

  // Réservation sans paiement immédiat
  if (b.action === "hold") {
    const r = await build(kind, b, "hold");
    if (r.error) return fail(r.error);
    if (await antiSpam(kind, r.wa!)) return fail("Trop de tentatives. Patientez quelques minutes.", 429);
    const { error: ie } = await db.from(tableOf(kind)).insert(r.row!);
    if (ie) return fail("Enregistrement impossible : " + ie.message, 500);
    return json({ id: r.row!.id, kind, code: codeOf(kind, r.row!.id), desc: descOf(kind, r.row!),
      amounts: amountsOf(kind, r.row!), expires_at: r.row!.expires_at, hours: r.hours });
  }

  // Retrouver ses réservations en attente de paiement (nom + téléphone)
  if (b.action === "lookup") {
    const n = txt(b.name, 120).toLowerCase(), p = last9(b.phone);
    if (n.length < 3 || p.length < 9) return json({ holds: [] });
    const pidx = await blind(b.phone);
    const holds: Row[] = [];
    for (const k of ["main", "event"]) {
      const { data } = await db.from(tableOf(k)).select("*").eq("hold", true).eq("status", "pending");
      for (const row of data || []) {
        if (row.phone_idx !== pidx || !String(row.name).toLowerCase().includes(n)) continue;
        let online = k === "main";
        if (k === "event") { const { data: ev } = await db.from("events").select("modes,title").eq("id", row.event_id).maybeSingle(); online = !!ev?.modes?.online; }
        holds.push({ id: row.id, kind: k, code: codeOf(k, row.id), desc: descOf(k, row), amounts: amountsOf(k, row), expires_at: row.expires_at, online });
      }
    }
    return json({ holds });
  }

  // Payer une réservation déjà faite
  if (b.action === "payhold") {
    const { data: row } = await db.from(tableOf(kind)).select("*").eq("id", txt(b.id, 60)).maybeSingle();
    if (!row || !row.hold || row.status !== "pending" || row.phone_idx !== await blind(b.phone)) return fail("Réservation introuvable ou expirée", 404);
    if (row.expires_at && new Date(row.expires_at) < new Date()) return fail("Réservation expirée", 410);
    let title = "";
    if (kind === "event") {
      const { data: ev } = await db.from("events").select("modes,title").eq("id", row.event_id).maybeSingle();
      if (!ev?.modes?.online) return fail("Paiement en ligne indisponible pour cet événement");
      title = ev.title;
    }
    const method = b.method === "card" ? "card" : "mobile";
    const op = pickOp(b);
    const p = await startProvider(kind, row, method, b.mm, title, op);
    if (p.error) return fail(p.error, 502);
    return json({ id: row.id, code: codeOf(kind, row.id), kind, method, payment_url: p.paymentUrl ?? null });
  }

  return fail("Action inconnue");
});
