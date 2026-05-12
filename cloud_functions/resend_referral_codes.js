#!/usr/bin/env node
/**
 * One-off script: resend each approved user their individual referral code.
 *
 * Usage:
 *   node resend_referral_codes.js              # dry-run (no emails sent)
 *   node resend_referral_codes.js --send       # actually send emails
 *
 * Requires:
 *   - GOOGLE_APPLICATION_CREDENTIALS or default Firebase credentials
 *   - MAIL_SENDER_EMAIL and MAIL_SENDER_PASSWORD env vars (or will read from Firebase secrets)
 */

const admin = require("firebase-admin");
const nodemailer = require("nodemailer");

// ── Firebase init ──────────────────────────────────────────────────────
const serviceAccountPath = process.env.GOOGLE_APPLICATION_CREDENTIALS;
if (serviceAccountPath) {
  admin.initializeApp({credential: admin.credential.cert(require(serviceAccountPath))});
} else {
  admin.initializeApp();
}
const db = admin.firestore();

// ── Args ───────────────────────────────────────────────────────────────
const ACTUALLY_SEND = process.argv.includes("--send");

// ── Mail credentials (set these or export them before running) ────────
const SENDER_EMAIL = process.env.MAIL_SENDER_EMAIL || "";
const SENDER_PASS = process.env.MAIL_SENDER_PASSWORD || "";
const BREVO_LOGIN = process.env.BREVO_SMTP_LOGIN || "";
const BREVO_KEY = process.env.BREVO_SMTP_KEY || "";

function createTransporter(email, pass) {
  // Use Brevo SMTP when credentials are provided (designed for bulk)
  if (BREVO_LOGIN && BREVO_KEY) {
    console.log("📬 Using Brevo SMTP for bulk sending");
    return nodemailer.createTransport({
      host: "smtp-relay.brevo.com",
      port: 587,
      secure: false,
      auth: {user: BREVO_LOGIN, pass: BREVO_KEY},
      pool: true,
      maxConnections: 2,
      maxMessages: 50,
      connectionTimeout: 30000,
      greetingTimeout: 15000,
      socketTimeout: 60000,
    });
  }

  if (/@(gmail|googlemail)\.com$/i.test(email)) {
    return nodemailer.createTransport({service: "gmail", auth: {user: email, pass}});
  }
  // Zoho dual-host fallback
  const zohoHosts = ["smtp.zoho.eu", "smtp.zoho.com"];
  return {
    async sendMail(opts) {
      let lastErr;
      for (const host of zohoHosts) {
        try {
          const t = nodemailer.createTransport({host, port: 465, secure: true, auth: {user: email, pass}});
          return await t.sendMail(opts);
        } catch (err) {
          lastErr = err;
          const msg = String(err?.message || "");
          const tryNext = err?.code === "EAUTH" || err?.responseCode === 535 || msg.includes("535");
          if (!tryNext || host === zohoHosts[zohoHosts.length - 1]) throw err;
        }
      }
      throw lastErr;
    },
  };
}

function escapeHtml(str) {
  return String(str)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

const TEK_EMAIL_LOGO_URL = "https://tek-landing.vercel.app/tek-logo-email.svg";
const TEK_MEMBERSHIP_URL = "https://tek-landing.vercel.app/membership";
const TEK_SUPPORT_EMAIL = "support@tek-landing.vercel.app";

function buildReferralCodeEmail({name, referralCode}) {
  const safeName = escapeHtml(name || "there");
  const safeCode = escapeHtml(referralCode || "");

  const subject = "Your TEK Referral Code";

  const text = [
    `Hi ${name || "there"},`,
    "",
    `Your TEK referral code: ${referralCode}`,
    "",
    "Important:",
    "- This referral code is your ONLY way to log in to the TEK app.",
    "- We do not use passwords, and there is no password reset.",
    "- Keep this code safe. If you lose it, reply to this email for help.",
    "",
    "Best regards,",
    "The TEK Team",
  ].join("\n");

  const html = `<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <meta name="color-scheme" content="dark">
  <meta name="supported-color-schemes" content="dark">
  <title>${escapeHtml(subject)}</title>
  <style>
    body, html { background-color: #000000 !important; }
    .outer-wrap { background-color: #000000 !important; }
    .inner-card { background-color: #050505 !important; }
    [data-ogsc] body, [data-ogsc] .outer-wrap { background-color: #000000 !important; }
    [data-ogsc] .inner-card { background-color: #050505 !important; }
  </style>
</head>
<body bgcolor="#000000" style="margin:0;padding:0;background-color:#000000;background:#000000;font-family:'Helvetica Neue',Arial,sans-serif;-webkit-text-size-adjust:none;">
  <div class="outer-wrap" style="background-color:#000000;background:#000000;width:100%;">
  <table width="100%" bgcolor="#000000" cellpadding="0" cellspacing="0" role="presentation" style="background-color:#000000;background:#000000;padding:32px 16px;">
    <tr>
      <td align="center" bgcolor="#000000" style="background-color:#000000;">
        <table class="inner-card" width="100%" bgcolor="#050505" cellpadding="0" cellspacing="0" role="presentation" style="max-width:620px;background-color:#050505;background:#050505;border:1px solid rgba(0,255,65,0.16);border-radius:14px;overflow:hidden;">
          <tr>
            <td style="padding:18px 36px 0;">
              <div style="height:2px;background:linear-gradient(90deg, rgba(0,255,65,0), rgba(0,255,65,0.9), rgba(0,255,65,0));"></div>
            </td>
          </tr>
          <tr>
            <td style="padding:30px 36px 14px;text-align:center;">
              <img src="${TEK_EMAIL_LOGO_URL}" alt="TEK" width="220" style="display:block;margin:0 auto 18px;max-width:220px;width:100%;height:auto;border:0;outline:none;text-decoration:none;">
              <div style="color:#ffe9a7;font-size:12px;letter-spacing:4px;text-transform:uppercase;margin-bottom:14px;">Your Referral Code</div>
              <div style="margin:0;font-size:34px;font-weight:900;letter-spacing:8px;color:#00FF41;">TEK</div>
            </td>
          </tr>
          <tr>
            <td style="padding:0 36px 14px;">
              <h1 style="margin:0;color:#ffffff;font-size:28px;line-height:1.2;font-weight:800;letter-spacing:1px;">Hi ${safeName} 👋</h1>
            </td>
          </tr>
          <tr>
            <td style="padding:0 36px 8px;">
              <div style="color:#d4d8c8;font-size:16px;line-height:1.8;">Here's your personal TEK referral code. Keep it safe — this is your <strong style="color:#ffffff;">only</strong> way to log in to the TEK app.</div>
            </td>
          </tr>
          <tr>
            <td style="padding:18px 36px 24px;text-align:center;">
              <div style="display:inline-block;background:rgba(0,255,65,0.06);border:2px solid rgba(0,255,65,0.35);border-radius:12px;padding:20px 36px;">
                <div style="font-size:32px;font-weight:900;letter-spacing:6px;color:#00FF41;font-family:'Courier New',monospace;">${safeCode}</div>
              </div>
            </td>
          </tr>
          <tr>
            <td style="padding:0 36px 24px;">
              <div style="background:rgba(255,233,167,0.04);border:1px solid rgba(255,233,167,0.12);border-radius:10px;padding:16px 18px;">
                <div style="color:#ffe9a7;font-size:13px;font-weight:700;margin-bottom:10px;letter-spacing:1px;">⚠️ IMPORTANT</div>
                <ul style="margin:0;padding-left:18px;color:#d4d8c8;font-size:14px;line-height:1.8;">
                  <li>This referral code is your <strong style="color:#ffffff;">only</strong> way to log in.</li>
                  <li>We do <strong style="color:#ffffff;">not</strong> use passwords, and there is <strong style="color:#ffffff;">no</strong> password reset.</li>
                  <li>Keep this code safe. If you lose it, reply to this email for help.</li>
                </ul>
              </div>
            </td>
          </tr>
          <tr>
            <td style="padding:0 36px 30px;">
              <div style="border-top:1px solid rgba(255,255,255,0.08);padding-top:18px;color:#8f9485;font-size:12px;line-height:1.7;letter-spacing:0.2px;">
                TEK — Stockholm's members-only community for electronic music, art, and culture.
              </div>
            </td>
          </tr>
          <tr>
            <td style="padding:0 36px 32px;">
              <div style="background:rgba(255,233,167,0.04);border:1px solid rgba(255,233,167,0.08);border-radius:10px;padding:14px 16px;color:#7c816f;font-size:11px;line-height:1.7;text-align:center;letter-spacing:0.6px;">
                You are receiving this because your address is on the TEK list.<br>
                Need help? Contact <a href="mailto:${TEK_SUPPORT_EMAIL}" style="color:#ffe9a7;text-decoration:none;">${TEK_SUPPORT_EMAIL}</a> or visit <a href="${TEK_MEMBERSHIP_URL}" style="color:#00FF41;text-decoration:none;">tek-landing.vercel.app</a>.
              </div>
            </td>
          </tr>
          <tr>
            <td style="padding:0 36px 18px;">
              <div style="height:2px;background:linear-gradient(90deg, rgba(0,255,65,0), rgba(0,255,65,0.9), rgba(0,255,65,0));"></div>
            </td>
          </tr>
        </table>
      </td>
    </tr>
  </table>
  </div>
</body>
</html>`;

  return {subject, text, html};
}

// ── Main ───────────────────────────────────────────────────────────────
(async () => {
  console.log(ACTUALLY_SEND ? "🚀 LIVE MODE — emails WILL be sent" : "🔍 DRY RUN — no emails will be sent (use --send to send)");
  console.log("");

  // 1. Fetch all approved applications that have a referral code
  const snap = await db
    .collection("applications")
    .where("status", "==", "approved")
    .get();

  const users = [];
  snap.forEach((doc) => {
    const d = doc.data() || {};
    const email = (d.email || "").trim();
    const name = (d.name || "").trim();
    const referralCode = (d.referralCode || "").trim();
    if (email && referralCode) {
      users.push({id: doc.id, email, name, referralCode});
    }
  });

  console.log(`Found ${snap.size} approved applications, ${users.length} have email + referralCode\n`);

  if (users.length === 0) {
    console.log("Nothing to send.");
    process.exit(0);
  }

  // Print summary
  for (const u of users) {
    console.log(`  ${u.name || "(no name)"} — ${u.email} — code: ${u.referralCode}`);
  }
  console.log("");

  if (!ACTUALLY_SEND) {
    console.log("Dry run complete. Run with --send to actually send emails.");
    process.exit(0);
  }

  // 2. Validate credentials
  if (!BREVO_LOGIN && !BREVO_KEY && (!SENDER_EMAIL || !SENDER_PASS)) {
    console.error("❌ Set BREVO_SMTP_LOGIN+BREVO_SMTP_KEY or MAIL_SENDER_EMAIL+MAIL_SENDER_PASSWORD env vars before running with --send");
    process.exit(1);
  }

  const transporter = createTransporter(SENDER_EMAIL, SENDER_PASS);
  const from = `TEK <${SENDER_EMAIL}>`;

  // Load already-sent list (so we can resume after partial sends)
  const sentFile = require("path").join(__dirname, ".sent_referral_emails.json");
  let alreadySent = new Set();
  try {
    alreadySent = new Set(JSON.parse(require("fs").readFileSync(sentFile, "utf8")));
    console.log(`Resuming — ${alreadySent.size} already sent, skipping those.\n`);
  } catch { /* first run */ }

  const toSend = users.filter((u) => !alreadySent.has(u.email));
  if (toSend.length === 0) {
    console.log("All emails already sent! Nothing to do.");
    process.exit(0);
  }
  console.log(`Sending to ${toSend.length} users (${alreadySent.size} already done)...\n`);

  let sent = 0;
  let failed = 0;
  const failures = [];

  for (const u of toSend) {
    const {subject, text, html} = buildReferralCodeEmail({name: u.name, referralCode: u.referralCode});
    try {
      await transporter.sendMail({from, to: u.email, subject, text, html});
      sent++;
      alreadySent.add(u.email);
      // Save progress after each successful send
      require("fs").writeFileSync(sentFile, JSON.stringify([...alreadySent]));
      console.log(`  ✅ ${u.email} (${u.referralCode})`);
    } catch (err) {
      failed++;
      failures.push({email: u.email, error: err.message});
      console.error(`  ❌ ${u.email}: ${err.message}`);
    }
    // 500ms delay between sends to stay under rate limits
    await new Promise((r) => setTimeout(r, 500));
  }

  console.log(`\nDone. Sent: ${sent}, Failed: ${failed}`);
  if (failures.length) {
    console.log("Failures:");
    failures.forEach((f) => console.log(`  ${f.email}: ${f.error}`));
  }
  process.exit(0);
})();
