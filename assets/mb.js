/* Mutambo Beef shared client: Supabase connection and small helpers. */
window.MB = (() => {
  const SUPABASE_URL = "https://rbyuketcqhrziqozgtmh.supabase.co";
  const SUPABASE_KEY = "sb_publishable_-Qubn6ir9MZbvYswW9t_tg_N9T6FvGC"; // publishable: safe in the browser, RLS protects data
  const sb = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY, { auth: { persistSession: true, autoRefreshToken: true } });
  const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const money = v => { const n = Math.round(Number(v || 0) * 100) / 100, f = Number.isInteger(n) ? 0 : 2; return "K " + n.toLocaleString("en-ZM", { minimumFractionDigits: f, maximumFractionDigits: f }); };
  const when = t => new Date(t).toLocaleString("en-ZM", { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" });
  const errText = e => (e && (e.message || e.error_description)) || "Something went wrong. Try again.";
  const bonusFor = (settings, amount) => {
    const tiers = (settings && settings.topup_bonus) || [];
    const pct = tiers.filter(t => amount >= t.min).reduce((m, t) => Math.max(m, t.pct), 0);
    return Math.round(amount * pct) / 100;
  };
  let toastTimer;
  const toast = msg => {
    let el = document.getElementById("toast");
    if (!el) { el = document.createElement("div"); el.id = "toast"; el.className = "toast"; el.setAttribute("role", "status"); document.body.appendChild(el); }
    el.textContent = msg; el.hidden = false;
    clearTimeout(toastTimer); toastTimer = setTimeout(() => { el.hidden = true; }, 3200);
  };
  const LABEL = {
    topup: "Top-up", bonus: "Top-up bonus", purchase: "Purchase", refund: "Refund", adjust: "Adjustment",
    wallet: "Wallet", cash: "Cash", mobile_money: "Mobile money", card: "Card", pay_on_delivery: "Pay on delivery", gateway: "Online",
    pending: "Pending", paid: "Paid", packed: "Packed", out_for_delivery: "Out for delivery", delivered: "Delivered",
    collected: "Collected", completed: "Completed", cancelled: "Cancelled", delivery: "Delivery", collect: "Collect", in_store: "In store",
  };
  const label = k => LABEL[k] || k;
  return { sb, esc, money, when, errText, bonusFor, toast, label };
})();
