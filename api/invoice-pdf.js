// GET /api/invoice-pdf?t=<public token> -> the invoice as an A4 PDF.
// Rendered in headless Chromium from the same template as the web page (assets/invoice.js), so the PDF matches it.
const chromium = require("@sparticuz/chromium");
const puppeteer = require("puppeteer-core");
const T = require("../assets/invoice.js");

const SUPABASE_URL = "https://rbyuketcqhrziqozgtmh.supabase.co";
const SUPABASE_KEY = "sb_publishable_-Qubn6ir9MZbvYswW9t_tg_N9T6FvGC"; // publishable; invoice_by_token returns one invoice by exact token

async function fetchInvoice(token) {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/invoice_by_token`, {
    method: "POST",
    headers: { apikey: SUPABASE_KEY, "Content-Type": "application/json" },
    body: JSON.stringify({ p_token: token }),
  });
  if (!r.ok) throw new Error(`Supabase ${r.status}`);
  return r.json();
}

async function renderPdf(inv) {
  const browser = await puppeteer.launch({
    args: chromium.args,
    executablePath: process.env.CHROME_PATH || (await chromium.executablePath()),
    headless: true,
    defaultViewport: { width: 794, height: 1123 },
  });
  try {
    const page = await browser.newPage();
    await page.setContent(T.page(inv), { waitUntil: "networkidle0", timeout: 15000 });
    await page.evaluate(() => document.fonts.ready);
    return await page.pdf({ format: "A4", printBackground: true, margin: { top: 0, right: 0, bottom: 0, left: 0 } });
  } finally {
    await browser.close();
  }
}

module.exports = async (req, res) => {
  const token = String((req.query && req.query.t) || "");
  if (!/^MB-INV-\d{4}-\d{3,}-[a-z0-9]{10}$/.test(token)) { res.status(404).send("Invoice not found"); return; }
  try {
    const inv = await fetchInvoice(token);
    if (!inv) { res.status(404).send("Invoice not found"); return; }
    const pdf = await renderPdf(inv);
    res.setHeader("Content-Type", "application/pdf");
    res.setHeader("Content-Disposition", `attachment; filename="${inv.number}.pdf"`);
    res.setHeader("Cache-Control", "private, no-store");
    res.setHeader("X-Robots-Tag", "noindex");
    res.status(200).send(Buffer.from(pdf));
  } catch (e) {
    console.error(e);
    res.status(500).send("Couldn't make the PDF. Try again, or print the invoice page.");
  }
};

module.exports.renderPdf = renderPdf;
