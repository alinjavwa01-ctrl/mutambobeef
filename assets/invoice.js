/* Mutambo Beef invoice template. One template for the web page (/i/<token>), the POS preview and the
   server-rendered PDF (api/invoice-pdf.js), so the PDF matches the page. Works in the browser and in Node. */
(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory();
  else root.MBInvoice = factory();
})(typeof self !== "undefined" ? self : this, function () {
  const COMPANY = {
    name: "Mutambo Beef Limited",
    tpin: "1002332223",
    city: "Lusaka, Zambia",
    momo: "+260 57 098 9456",
    site: "mutambobeef.vercel.app",
  };
  const FONTS = "https://fonts.googleapis.com/css2?family=Manrope:wght@500;600;700;800&family=Instrument+Sans:wght@400;500;600&display=swap";
  const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

  const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const group = (n, dp) => {
    const [i, f] = (Math.round(Number(n || 0) * 100) / 100).toFixed(dp).split(".");
    return i.replace(/\B(?=(\d{3})+(?!\d))/g, ",") + (f ? "." + f : "");
  };
  const kw = n => "K " + group(n, 2);
  const kg = n => group(n, 2);
  // Dates arrive as YYYY-MM-DD (dates) or ISO timestamps; show them in Lusaka time (UTC+2, no DST).
  const day = v => {
    if (!v) return "";
    let y, m, d;
    if (/^\d{4}-\d{2}-\d{2}$/.test(v)) [y, m, d] = v.split("-").map(Number);
    else { const t = new Date(new Date(v).getTime() + 2 * 3600e3); y = t.getUTCFullYear(); m = t.getUTCMonth() + 1; d = t.getUTCDate(); }
    return `${d} ${MONTHS[m - 1]} ${y}`;
  };
  const METHOD = { balance: "Account balance", momo: "MTN MoMo", cash: "Cash", bank: "Bank transfer" };

  const logo = (h = 74) => `<svg class="inv-logo" viewBox="0 0 200 84" height="${h}" role="img" aria-label="Mutambo Beef"><ellipse cx="100" cy="42" rx="98" ry="40" fill="#de1b23"/><ellipse cx="100" cy="42" rx="91" ry="33" fill="none" stroke="#fff" stroke-width="1.6"/><text transform="translate(100 45) skewX(-9)" text-anchor="middle" font-family="Manrope, Helvetica Neue, Arial, sans-serif" font-weight="800" font-size="33" letter-spacing="-1" fill="#fff">Mutambo</text><path d="M50 62.5h18M134 62.5h18" stroke="#fff" stroke-width="1.6" stroke-linecap="round"/><text x="103" y="68" text-anchor="middle" font-family="Manrope, Helvetica Neue, Arial, sans-serif" font-weight="800" font-size="15" letter-spacing="5" fill="#fff">BEEF</text></svg>`;

  const css = `
.inv { --r: #de1b23; --ink: #1b1613; --ink2: #4d4540; --mut: #7a716b; --line: #e9e4e0; --wash: #faf6f3;
  position: relative; background: #fff; color: var(--ink); width: 100%; max-width: 794px; margin: 0 auto; padding: 48px 52px 36px;
  font: 14px/1.5 "Instrument Sans", "Helvetica Neue", Helvetica, Arial, sans-serif; -webkit-font-smoothing: antialiased; box-sizing: border-box; overflow: hidden; }
.inv *, .inv *::before, .inv *::after { box-sizing: border-box; }
.inv h1, .inv h2, .inv h3, .inv b, .inv th, .inv .num { font-family: Manrope, "Helvetica Neue", Helvetica, Arial, sans-serif; }
.inv p { margin: 0; }
.inv .top { display: flex; justify-content: space-between; gap: 24px; align-items: flex-start; }
.inv .co { display: flex; flex-direction: column; align-items: flex-start; gap: 10px; }
.inv-logo { display: block; width: auto; }
.inv .co .nm { font-size: 13px; color: var(--ink2); }
.inv .co .nm b { color: var(--ink); font-weight: 700; }
.inv .meta { text-align: right; }
.inv h1 { margin: 0 0 12px; font-size: 40px; font-weight: 800; letter-spacing: -.03em; line-height: 1; }
.inv .meta table { margin-left: auto; border-collapse: collapse; }
.inv .meta td { padding: 2px 0 2px 18px; font-size: 13px; white-space: nowrap; }
.inv .meta td:first-child { color: var(--mut); }
.inv .meta td:last-child { font-weight: 600; text-align: right; }
.inv .parties { display: grid; grid-template-columns: 1fr 1fr; gap: 24px; margin-top: 34px; padding-top: 22px; border-top: 2px solid var(--ink); }
.inv .lbl { font: 700 11px/1.2 Manrope, Arial, sans-serif; letter-spacing: .14em; text-transform: uppercase; color: var(--r); margin-bottom: 8px; }
.inv .who b { display: block; font-size: 17px; font-weight: 800; margin-bottom: 2px; }
.inv .who p { color: var(--ink2); }
.inv table.inv-lines { width: 100%; border-collapse: collapse; margin-top: 30px; font-variant-numeric: tabular-nums; }
.inv .inv-lines th { font-size: 11px; font-weight: 700; letter-spacing: .1em; text-transform: uppercase; color: var(--mut); text-align: right; padding: 0 0 10px; border-bottom: 1px solid var(--ink); }
.inv .inv-lines th:first-child, .inv .inv-lines td:first-child { text-align: left; }
.inv .inv-lines td { padding: 11px 0; border-bottom: 1px solid var(--line); text-align: right; }
.inv .inv-lines td:first-child { font-weight: 600; }
.inv .inv-lines th + th, .inv .inv-lines td + td { padding-left: 14px; }
.inv .inv-lines tfoot td { border-bottom: 0; padding-top: 14px; font-weight: 800; font-family: Manrope, Arial, sans-serif; font-size: 15px; }
.inv .sum { display: flex; justify-content: space-between; align-items: stretch; gap: 24px; margin-top: 22px; }
.inv .pay { flex: 1; font-size: 13px; color: var(--ink2); display: flex; flex-direction: column; justify-content: center; gap: 4px; }
.inv .pay b { color: var(--ink); }
.inv .due { background: var(--r); color: #fff; border-radius: 14px; padding: 18px 22px; min-width: 260px; text-align: right; }
.inv .due span { display: block; font: 700 11px/1.2 Manrope, Arial, sans-serif; letter-spacing: .14em; text-transform: uppercase; opacity: .92; }
.inv .due b { display: block; font-size: 32px; font-weight: 800; letter-spacing: -.02em; line-height: 1.15; margin-top: 6px; font-variant-numeric: tabular-nums; }
.inv .due small { display: block; font-size: 12px; opacity: .92; margin-top: 2px; }
.inv .due.settled { background: var(--wash); color: var(--ink); }
.inv .notes { display: grid; grid-template-columns: 1fr 1fr; gap: 16px 28px; margin-top: 30px; padding-top: 20px; border-top: 1px solid var(--line); font-size: 12.5px; color: var(--ink2); }
.inv .notes h3 { margin: 0 0 4px; font-size: 12px; font-weight: 800; color: var(--ink); }
.inv .notes a { color: var(--r); }
.inv .foot { margin-top: 30px; padding-top: 14px; border-top: 2px solid var(--r); display: flex; justify-content: space-between; gap: 12px; flex-wrap: wrap; font-size: 11.5px; color: var(--mut); }
.inv .sum { position: relative; }
.inv .stamp { position: absolute; top: 50%; right: 300px; margin-top: -36px; transform: rotate(-14deg); border: 4px solid currentColor; border-radius: 12px; padding: 6px 18px 8px; text-align: center;
  font: 800 44px/1 Manrope, Arial, sans-serif; letter-spacing: .08em; color: #1f7a3d; opacity: .82; pointer-events: none; background: rgba(255,255,255,.6); }
.inv .stamp small { display: block; font-size: 13px; letter-spacing: .04em; margin-top: 4px; font-weight: 700; }
.inv .stamp.void { color: #7a716b; }
@media (max-width: 640px) {
  .inv { padding: 26px 18px 22px; font-size: 14px; }
  .inv .top { flex-direction: column; gap: 18px; }
  .inv .meta { text-align: left; }
  .inv .meta table { margin-left: 0; }
  .inv .meta td { padding: 2px 18px 2px 0; }
  .inv .meta td:last-child { text-align: left; }
  .inv h1 { font-size: 32px; }
  .inv-logo { height: 58px; }
  .inv .parties, .inv .notes { grid-template-columns: 1fr; gap: 18px; }
  .inv .inv-lines { font-size: 13px; }
  .inv .inv-lines th { font-size: 10px; letter-spacing: .04em; }
  .inv .inv-lines th + th, .inv .inv-lines td + td { padding-left: 8px; }
  .inv .sum { flex-direction: column-reverse; }
  .inv .due { min-width: 0; }
  .inv .stamp { top: auto; bottom: 8px; right: 12px; margin-top: 0; font-size: 28px; }
}
@media print { .inv { max-width: none; } }
`;

  // inv: the object returned by invoice_by_token()
  function render(inv) {
    const b = inv.bill_to || {};
    const paid = inv.status === "paid", isVoid = inv.status === "void";
    const payable = Number(inv.total_k) - Number(inv.discount_k || 0);
    const lines = (inv.lines || []).map(l => `<tr><td>${esc(l.cut)}</td><td>${kg(l.kg)}</td><td>${kw(l.price_per_kg_k)}</td><td>${kw(l.amount_k)}</td></tr>`).join("");
    const delivered = inv.signed_by || inv.delivered_to || inv.delivery_note_url;
    let dueBox;
    if (paid) dueBox = `<div class="due settled"><span>Amount due</span><b>${kw(0)}</b><small>Paid ${esc(day(inv.paid_at))}${inv.paid_method ? " · " + esc(METHOD[inv.paid_method] || inv.paid_method) : ""}</small></div>`;
    else if (isVoid) dueBox = `<div class="due settled"><span>Amount due</span><b>${kw(0)}</b><small>Void</small></div>`;
    else dueBox = `<div class="due"><span>Amount due</span><b>${kw(inv.total_k)}</b><small>Due on delivery, ${esc(day(inv.due_date))}</small></div>`;
    return `<article class="inv" data-status="${esc(inv.status)}">
  <header class="top">
    <div class="co">
      ${logo()}
      <p class="nm"><b>${COMPANY.name}</b> · TPIN ${COMPANY.tpin}</p>
    </div>
    <div class="meta">
      <h1>Invoice</h1>
      <table>
        <tr><td>Number</td><td class="num">${esc(inv.number)}</td></tr>
        <tr><td>Date</td><td>${esc(day(inv.invoice_date))}</td></tr>
        <tr><td>Due</td><td>On delivery</td></tr>
      </table>
    </div>
  </header>
  <section class="parties">
    <div class="who">
      <div class="lbl">Bill to</div>
      <b>${esc(b.name || "")}</b>
      ${b.attn ? `<p>Attn: ${esc(b.attn)}</p>` : ""}
      ${b.phone ? `<p>${esc(fmtPhone(b.phone))}</p>` : ""}
      ${b.address ? `<p>${esc(b.address)}</p>` : ""}
      ${b.tpin ? `<p>TPIN ${esc(b.tpin)}</p>` : ""}
      ${b.account ? `<p>Account ${esc(b.account)}</p>` : ""}
    </div>
    <div class="who">
      <div class="lbl">Delivery</div>
      ${delivered ? `<b>${esc(day(inv.delivered_at || inv.invoice_date))}</b>
      ${inv.delivered_to ? `<p>${esc(inv.delivered_to)}</p>` : ""}
      ${inv.signed_by ? `<p>Signed for by ${esc(inv.signed_by)}</p>` : ""}` : `<b>${esc(day(inv.invoice_date))}</b><p>Delivered chilled by Mutambo Beef</p>`}
    </div>
  </section>
  <table class="inv-lines">
    <thead><tr><th>Cut</th><th>Qty (kg)</th><th>Price/kg</th><th>Amount</th></tr></thead>
    <tbody>${lines}</tbody>
    <tfoot><tr><td>Total</td><td>${kg(inv.total_kg)}</td><td></td><td>${kw(inv.total_k)}</td></tr></tfoot>
  </table>
  <section class="sum">
    <div class="pay">
      ${paid
        ? `<p><b>Paid with thanks.</b> ${inv.paid_method === "balance" && Number(inv.discount_k) > 0 ? `Settled from the account balance: ${kw(payable)} after ${kw(inv.discount_k)} balance discount.` : `${kw(inv.total_k)} received${inv.paid_method ? " by " + esc(METHOD[inv.paid_method] || inv.paid_method) : ""}${inv.paid_ref ? ", ref " + esc(inv.paid_ref) : ""}.`}</p>`
        : isVoid ? `<p><b>This invoice is void.</b>${inv.void_reason ? " " + esc(inv.void_reason) : ""} Nothing is owed on it.</p>`
        : `<p>Pay by <b>MTN MoMo</b> to <b>${COMPANY.momo}</b></p><p>Reference: <b>${esc(inv.number)}</b></p>`}
    </div>
    ${dueBox}
    ${paid ? `<div class="stamp">PAID<small>${esc(day(inv.paid_at))}</small></div>` : ""}
    ${isVoid ? `<div class="stamp void">VOID<small>${esc(day(inv.voided_at))}</small></div>` : ""}
  </section>
  <section class="notes">
    <div><h3>Payment</h3><p>MTN MoMo ${COMPANY.momo}, reference ${esc(inv.number)}. Cash or bank transfer on delivery also accepted. Due on delivery.</p></div>
    <div><h3>Delivery</h3><p>${inv.signed_by ? `Delivered ${esc(day(inv.delivered_at || inv.invoice_date))}${inv.delivered_to ? " to " + esc(inv.delivered_to) : ""}, signed for by ${esc(inv.signed_by)}.` : `Delivered ${esc(day(inv.invoice_date))}.`}${inv.delivery_note_url ? ` <a href="${esc(inv.delivery_note_url)}">Signed delivery note</a>.` : ""}</p></div>
    <div><h3>Product</h3><p>Chilled Zambian beef, vacuum packed and labelled by cut and date. Keep at 0 to 4 °C.</p></div>
    <div><h3>Prices</h3><p>Kwacha per kg, weighed at dispatch. ${COMPANY.name} is not registered for VAT; no VAT charged.</p></div>
  </section>
  <footer class="foot"><span>${COMPANY.name} · TPIN ${COMPANY.tpin} · ${COMPANY.city}</span><span>${COMPANY.momo} · ${COMPANY.site}</span></footer>
</article>`;
  }

  function fmtPhone(p) {
    const d = String(p || "").replace(/\D/g, "");
    if (/^260\d{9}$/.test(d)) return `+260 ${d.slice(3, 5)} ${d.slice(5, 8)} ${d.slice(8)}`;
    return p;
  }

  // Full HTML document for the PDF renderer.
  function page(inv) {
    return `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>${esc(inv.number)}</title>
<link rel="stylesheet" href="${FONTS}"><style>@page { size: A4; margin: 0; } html, body { margin: 0; background: #fff; } ${css}</style></head>
<body>${render(inv)}</body></html>`;
  }

  return { render, page, css, FONTS, COMPANY, kw, kg, day, fmtPhone, METHOD };
});
