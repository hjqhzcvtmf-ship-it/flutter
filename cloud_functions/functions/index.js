// Firebase Cloud Function for sending membership application emails
const {onCall, onRequest, HttpsError} = require("firebase-functions/v2/https");
const {onDocumentCreated, onDocumentUpdated} = require("firebase-functions/v2/firestore");
const {defineSecret} = require("firebase-functions/params");
const nodemailer = require("nodemailer");
const crypto = require("crypto");
const admin = require("firebase-admin");
const Stripe = require("stripe");

admin.initializeApp();

// Get default Firestore instance
const db = admin.firestore();

const MAIL_SENDER_EMAIL = defineSecret("MAIL_SENDER_EMAIL");
const MAIL_SENDER_PASSWORD = defineSecret("MAIL_SENDER_PASSWORD");
const BREVO_SMTP_LOGIN = defineSecret("BREVO_SMTP_LOGIN");
const BREVO_SMTP_KEY = defineSecret("BREVO_SMTP_KEY");
const ANTHROPIC_API_KEY = defineSecret("ANTHROPIC_API_KEY");
const TEK_MEMBERSHIP_URL = "https://tek-landing.vercel.app/membership";
const TEK_TICKETS_URL = "https://tek-landing.vercel.app/tickets.html";
const TEK_SUPPORT_EMAIL = "support@tek-landing.vercel.app";
const TEK_EMAIL_LOGO_URL = "https://tek-landing.vercel.app/tek-logo-email.svg";

function createMailTransporter() {
  const senderEmail = String(MAIL_SENDER_EMAIL.value() || "").trim();
  const auth = {user: senderEmail, pass: MAIL_SENDER_PASSWORD.value()};

  if (/@(gmail|googlemail)\.com$/i.test(senderEmail)) {
    return nodemailer.createTransport({service: "gmail", auth});
  }

  const zohoHosts = ["smtp.zoho.eu", "smtp.zoho.com"];

  return {
    async sendMail(mailOptions) {
      let lastError = null;

      for (const host of zohoHosts) {
        try {
          const transporter = nodemailer.createTransport({
            host,
            port: 465,
            secure: true,
            auth,
          });
          return await transporter.sendMail(mailOptions);
        } catch (error) {
          lastError = error;
          const errorMessage = String(error?.message || "");
          const shouldTryNextHost =
            error?.code === "EAUTH" ||
            error?.responseCode === 535 ||
            errorMessage.includes("535 Authentication Failed");

          if (!shouldTryNextHost || host === zohoHosts[zohoHosts.length - 1]) {
            throw error;
          }
        }
      }

      throw lastError;
    },
  };
}

function buildMailFromHeader() {
  const senderEmail = String(MAIL_SENDER_EMAIL.value() || "").trim();
  return senderEmail ? `TEK <${senderEmail}>` : senderEmail;
}

function createBroadcastTransporter() {
  const brevoLogin = String(BREVO_SMTP_LOGIN.value() || "").trim();
  const brevoKey = String(BREVO_SMTP_KEY.value() || "").trim();
  if (!brevoLogin || !brevoKey) {
    console.warn("[Broadcast] Brevo credentials not set, falling back to default transporter");
    return null;
  }
  return nodemailer.createTransport({
    host: "smtp-relay.brevo.com",
    port: 587,
    secure: false,
    auth: {
      user: brevoLogin,
      pass: brevoKey,
    },
    pool: true,
    maxConnections: 3,
    maxMessages: 50,
    connectionTimeout: 30000,
    greetingTimeout: 15000,
    socketTimeout: 60000,
  });
}

function buildBroadcastEmailHtml({
  subject,
  safeMessage,
  previewOnly = false,
  audienceLabel = "all users",
  audienceSize = 0,
}) {
  const previewBlock = previewOnly ? `
    <tr>
      <td style="padding:0 36px 18px;">
        <div style="display:inline-block;padding:8px 12px;border:1px solid rgba(0,255,65,0.35);border-radius:999px;color:#00FF41;font-size:11px;font-weight:700;letter-spacing:1.8px;text-transform:uppercase;">
          Preview only
        </div>
      </td>
    </tr>
    <tr>
      <td style="padding:0 36px 24px;">
        <div style="background:rgba(0,255,65,0.06);border:1px solid rgba(0,255,65,0.16);border-radius:10px;padding:14px 16px;color:#b7bea8;font-size:13px;line-height:1.6;">
          <strong style="color:#ffffff;">Audience:</strong> ${escapeHtml(audienceLabel)}
        </div>
      </td>
    </tr>` : "";

  return `<!DOCTYPE html>
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
              <div style="color:#ffe9a7;font-size:12px;letter-spacing:4px;text-transform:uppercase;margin-bottom:14px;">Members Update</div>
              <div style="margin:0;font-size:34px;font-weight:900;letter-spacing:8px;color:#00FF41;">TEK</div>
            </td>
          </tr>
          ${previewBlock}
          <tr>
            <td style="padding:0 36px 14px;">
              <h1 style="margin:0;color:#ffffff;font-size:28px;line-height:1.2;font-weight:800;letter-spacing:1px;">${escapeHtml(subject)}</h1>
            </td>
          </tr>
          <tr>
            <td style="padding:0 36px 28px;">
              <div style="color:#d4d8c8;font-size:16px;line-height:1.8;">${safeMessage}</div>
            </td>
          </tr>
          <tr>
            <td style="padding:0 36px 30px;text-align:center;">
              <a href="${TEK_TICKETS_URL}" style="display:inline-block;background:#00FF41;color:#000000;font-size:13px;font-weight:800;letter-spacing:2.4px;text-transform:uppercase;padding:15px 34px;border-radius:6px;text-decoration:none;box-shadow:0 0 24px rgba(0,255,65,0.18);">Get Ticket</a>
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
                Access is curated. Entry is intentional. Presence matters.<br>
                Need help? Contact <a href="mailto:${TEK_SUPPORT_EMAIL}" style="color:#ffe9a7;text-decoration:none;">${TEK_SUPPORT_EMAIL}</a> or visit <a href="${TEK_MEMBERSHIP_URL}" style="color:#00FF41;text-decoration:none;">tek-landing.vercel.app</a>.
              </div>
            </td>
          </tr>
        </table>
      </td>
    </tr>
  </table>
  </div>
</body>
</html>`;
}

async function getAdminNotificationEmail(fallbackEmail = "") {
  try {
    const snap = await db.doc("config/admin_settings").get();
    const configured = snap.exists ? snap.data()?.notificationEmail : "";
    if (typeof configured === "string" && configured.trim().includes("@")) {
      return configured.trim();
    }
  } catch (error) {
    console.warn("Unable to read admin notification email config:", error);
  }

  if (typeof fallbackEmail === "string" && fallbackEmail.trim().includes("@")) {
    return fallbackEmail.trim();
  }

  return String(MAIL_SENDER_EMAIL.value() || "").trim();
}

/**
 * Award 150 XP to a user for purchasing a ticket.
 * Idempotent: uses an xp_transactions document keyed by uid+eventId
 * so the same purchase never awards XP twice, even if both the
 * Stripe webhook and the finalize callable run.
 *
 * If the user hasn't claimed their application yet (no ownerUid link),
 * the transaction is saved as pending and will be applied automatically
 * when they claim via referral code.
 */
async function awardTicketPurchaseXp(uid, eventId) {
  const xpDocId = `ticket_purchase_${uid}_${eventId}`;
  const xpRef = db.collection("xp_transactions").doc(xpDocId);

  const xpSnap = await xpRef.get();
  if (xpSnap.exists) {
    console.log(`XP already recorded for user ${uid}, event ${eventId} — skipping`);
    return;
  }

  // Try to find the user's application via ownerUid
  const appSnap = await db
    .collection("applications")
    .where("ownerUid", "==", uid)
    .limit(1)
    .get();

  if (appSnap.empty) {
    // Application not claimed yet — save as pending, will be applied on claim
    await xpRef.set({
      uid,
      eventId,
      xpAwarded: 150,
      reason: "ticket_purchase",
      applied: false,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    console.log(`Saved pending 150 XP for user ${uid}, event ${eventId} (no claimed app yet)`);
    return;
  }

  // Application found — record and apply immediately
  await xpRef.set({
    uid,
    eventId,
    xpAwarded: 150,
    reason: "ticket_purchase",
    applied: true,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  await appSnap.docs[0].ref.update({
    xpPoints: admin.firestore.FieldValue.increment(150),
  });

  console.log(`Awarded 150 XP to user ${uid} for ticket purchase (event ${eventId})`);
}

function toIsoString(value) {
  if (!value) return null;
  if (typeof value.toDate === "function") {
    return value.toDate().toISOString();
  }
  if (value instanceof Date) {
    return value.toISOString();
  }
  return null;
}

function serializeApplicationDoc(doc) {
  const data = doc.data() || {};
  const normalizedStatus = typeof data.status === "string" && data.status.trim()
    ? data.status.trim().toLowerCase()
    : "unknown";
  return {
    id: doc.id,
    name: typeof data.name === "string" ? data.name : "",
    email: typeof data.email === "string" ? data.email : "",
    phone: typeof data.phone === "string" ? data.phone : "",
    instagram: typeof data.instagram === "string" ? data.instagram : "",
    bio: typeof data.bio === "string" ? data.bio : "",
    status: normalizedStatus,
    referralCode: typeof data.referralCode === "string" ? data.referralCode : "",
    inviteCode: typeof data.inviteCode === "string" ? data.inviteCode : "",
    invitedByInviteCode: typeof data.invitedByInviteCode === "string" ? data.invitedByInviteCode : "",
    inviteStats: data.inviteStats || null,
    profileImageUrl:
      typeof data.profileImageUrl === "string" ? data.profileImageUrl : "",
    submittedAt: toIsoString(data.submittedAt),
    approvedAt: toIsoString(data.approvedAt),
    rejectedAt: toIsoString(data.rejectedAt),
  };
}

async function findUserEmailForUid(uid) {
  if (!uid) return null;

  // 1. Prefer ownerUid in applications (has name + email together)
  const snap = await db
    .collection("applications")
    .where("ownerUid", "==", uid)
    .limit(1)
    .get();
  if (!snap.empty) {
    const data = snap.docs[0].data() || {};
    const email = typeof data.email === "string" ? data.email.trim() : "";
    const name = typeof data.name === "string" ? data.name.trim() : "";
    if (email) return {email, name};
  }

  // 2. Fallback: look up Firebase Auth user record
  try {
    const userRecord = await admin.auth().getUser(uid);
    const email = userRecord.email || "";
    const name = userRecord.displayName || "";
    if (email) {
      console.log("findUserEmailForUid: resolved via Firebase Auth for uid", uid);
      return {email, name};
    }
  } catch (authErr) {
    console.warn("findUserEmailForUid: Firebase Auth lookup failed for uid", uid, authErr.message);
  }

  return null;
}

async function maybeSendTicketConfirmationEmail({
  uid,
  eventId,
  ticketRef,
  ticketData,
  source,
}) {
  try {
    // Strong idempotency: acquire a short lease on the ticket doc.
    const canSend = await db.runTransaction(async (txn) => {
      const snap = await txn.get(ticketRef);
      const data = snap.exists ? snap.data() || {} : (ticketData || {});
      if (data.confirmationEmailSentAt || data.confirmationEmailSent === true) return false;

      const nowMs = Date.now();
      const sendingUntil = data.confirmationEmailSendingUntil;
      const sendingUntilMs =
        sendingUntil && typeof sendingUntil.toMillis === "function"
          ? sendingUntil.toMillis()
          : null;

      if (sendingUntilMs && sendingUntilMs > nowMs) return false;

      txn.set(
        ticketRef,
        {
          confirmationEmailSendingUntil: admin.firestore.Timestamp.fromMillis(
            nowMs + 5 * 60 * 1000
          ),
          confirmationEmailSource: source || "unknown",
        },
        {merge: true}
      );
      return true;
    });

    if (!canSend) return;

    const user = await findUserEmailForUid(uid);
    if (!user) {
      console.log("Ticket email: no user email for uid", uid);
      return;
    }

    const eventSnap = await db.collection("events").doc(eventId).get();
    const event = eventSnap.exists ? eventSnap.data() || {} : {};
    const title = typeof event.title === "string" && event.title.trim()
      ? event.title.trim()
      : "TEK Event";
    const location = typeof event.location === "string" ? event.location.trim() : "";
    const startAt = event.startAt && typeof event.startAt.toDate === "function"
      ? event.startAt.toDate()
      : null;

    const qty = Number.isFinite(ticketData.quantity) ? Number(ticketData.quantity) : 1;
    const currency = typeof ticketData.currency === "string" ? ticketData.currency.toUpperCase() : "";
    const amount = Number.isFinite(ticketData.amount) ? Number(ticketData.amount) : null;
    const amountText = amount != null
      ? `${(amount / 100).toFixed(2)}${currency ? ` ${currency}` : ""}`
      : "";

    const whenText = startAt
      ? new Intl.DateTimeFormat("en-US", {
          weekday: "short",
          month: "short",
          day: "numeric",
          year: "numeric",
          hour: "numeric",
          minute: "2-digit",
        }).format(startAt)
      : "";

    const transporter = createMailTransporter();
    const greetingName = user.name || "there";

    const subject = `Your ticket for ${title}`;
    const lines = [
      `<p>Hi ${escapeHtml(greetingName)},</p>`,
      `<p>Thanks for your purchase. Your ticket is confirmed.</p>`,
      `<p><strong>Event:</strong> ${escapeHtml(title)}</p>`,
      ...(whenText ? [`<p><strong>When:</strong> ${escapeHtml(whenText)}</p>`] : []),
      ...(location ? [`<p><strong>Where:</strong> ${escapeHtml(location)}</p>`] : []),
      `<p><strong>Quantity:</strong> ${qty}</p>`,
      ...(amountText ? [`<p><strong>Paid:</strong> ${escapeHtml(amountText)}</p>`] : []),
      `<p>You can also see your ticket inside the app under <strong>My Tickets</strong>.</p>`,
      `<p>— TEK</p>`,
    ];

    await transporter.sendMail({
      from: buildMailFromHeader(),
      to: user.email,
      subject,
      html: lines.join("\n"),
    });

    await ticketRef.set(
      {
        confirmationEmailSentAt: admin.firestore.FieldValue.serverTimestamp(),
        confirmationEmailSource: source || "unknown",
        confirmationEmailSendingUntil: admin.firestore.FieldValue.delete(),
      },
      {merge: true}
    );
  } catch (err) {
    // Never fail fulfillment if email fails.
    console.error("Ticket confirmation email failed:", err);
  }
}
const ADMIN_BOOTSTRAP_TOKEN = defineSecret("ADMIN_BOOTSTRAP_TOKEN");

function generateReferralCode() {
  return Math.random().toString(36).substring(2, 8).toUpperCase();
}

/**
 * Generate a unique invite code (prefixed TEK- to distinguish from referral codes).
 * Format: TEK-XXXXXX (6 random alphanumeric chars).
 */
function generateInviteCode() {
  return "TEK-" + Math.random().toString(36).substring(2, 8).toUpperCase();
}

/**
 * Award XP to an inviter when their invited friend gets approved.
 * Also checks milestone rewards: 5 approved invitees → free drink ticket.
 */
async function awardInviterOnApproval(invitedByInviteCode, approvedAppId) {
  if (!invitedByInviteCode) return;

  // Find the inviter's application by their inviteCode
  const inviterSnap = await db
    .collection("applications")
    .where("inviteCode", "==", invitedByInviteCode)
    .limit(1)
    .get();

  if (inviterSnap.empty) {
    console.log(`Inviter not found for inviteCode ${invitedByInviteCode}`);
    return;
  }

  const inviterDoc = inviterSnap.docs[0];
  const inviterData = inviterDoc.data() || {};

  // Award 50 XP (idempotent via xp_transactions)
  const xpDocId = `invite_approved_${inviterDoc.id}_${approvedAppId}`;
  const xpRef = db.collection("xp_transactions").doc(xpDocId);
  const xpSnap = await xpRef.get();

  if (!xpSnap.exists) {
    await xpRef.set({
      uid: inviterData.ownerUid || null,
      inviterAppId: inviterDoc.id,
      inviteeAppId: approvedAppId,
      xpAwarded: 50,
      reason: "invite_friend_approved",
      applied: !!inviterData.ownerUid,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    // Apply XP immediately if inviter has ownerUid
    if (inviterData.ownerUid) {
      await inviterDoc.ref.update({
        xpPoints: admin.firestore.FieldValue.increment(50),
      });
    }
    console.log(`Awarded 50 XP to inviter ${inviterDoc.id} for approved invite ${approvedAppId}`);
  }

  // Count total approved invitees for milestone check
  const approvedInvitees = await db
    .collection("applications")
    .where("invitedByInviteCode", "==", invitedByInviteCode)
    .where("status", "==", "approved")
    .get();

  const inviteCount = approvedInvitees.size;
  console.log(`Inviter ${inviterDoc.id} now has ${inviteCount} approved invitees`);

  // Update invite stats on inviter's application
  await inviterDoc.ref.update({
    inviteStats: {
      approvedCount: inviteCount,
      drinkRewardEarned: inviteCount >= 5,
    },
  });

  // Milestone: 5 approved invitees → award free drink reward (idempotent)
  if (inviteCount >= 5) {
    const rewardDocId = `invite_drink_reward_${inviterDoc.id}`;
    const rewardRef = db.collection("rewards").doc(rewardDocId);
    const rewardSnap = await rewardRef.get();
    if (!rewardSnap.exists) {
      await rewardRef.set({
        appId: inviterDoc.id,
        ownerUid: inviterData.ownerUid || null,
        type: "free_drink",
        reason: "invited_5_friends",
        redeemed: false,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      console.log(`Free drink reward created for inviter ${inviterDoc.id} (5 invitees milestone)`);
    }
  }
}

/**
 * Check if an inviter has earned a free ticket
 * (all 5 of their invited friends bought event tickets).
 */
async function checkInviterFreeTicketMilestone(invitedByInviteCode) {
  if (!invitedByInviteCode) return;

  // Find inviter
  const inviterSnap = await db
    .collection("applications")
    .where("inviteCode", "==", invitedByInviteCode)
    .limit(1)
    .get();

  if (inviterSnap.empty) return;

  const inviterDoc = inviterSnap.docs[0];
  const inviterData = inviterDoc.data() || {};

  // Find all approved invitees
  const inviteesSnap = await db
    .collection("applications")
    .where("invitedByInviteCode", "==", invitedByInviteCode)
    .where("status", "==", "approved")
    .get();

  if (inviteesSnap.size < 5) return;

  // Check how many invitees have bought tickets (have ownerUid with tickets)
  let ticketBuyerCount = 0;
  for (const inviteeDoc of inviteesSnap.docs) {
    const inviteeData = inviteeDoc.data() || {};
    if (!inviteeData.ownerUid) continue;

    // Check if this invitee has any ticket purchase xp_transactions
    const ticketXp = await db
      .collection("xp_transactions")
      .where("uid", "==", inviteeData.ownerUid)
      .where("reason", "==", "ticket_purchase")
      .limit(1)
      .get();

    if (!ticketXp.empty) ticketBuyerCount++;
    if (ticketBuyerCount >= 5) break; // No need to check more
  }

  // Update stats
  await inviterDoc.ref.update({
    "inviteStats.ticketBuyerCount": ticketBuyerCount,
    "inviteStats.freeTicketEarned": ticketBuyerCount >= 5,
  });

  // Milestone: 5 invitees bought tickets → award free ticket
  if (ticketBuyerCount >= 5) {
    const rewardDocId = `invite_ticket_reward_${inviterDoc.id}`;
    const rewardRef = db.collection("rewards").doc(rewardDocId);
    const rewardSnap = await rewardRef.get();
    if (!rewardSnap.exists) {
      await rewardRef.set({
        appId: inviterDoc.id,
        ownerUid: inviterData.ownerUid || null,
        type: "free_ticket",
        reason: "5_invitees_bought_tickets",
        redeemed: false,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      console.log(`Free ticket reward created for inviter ${inviterDoc.id} (5 invitees bought tickets milestone)`);
    }
  }
}

const STRIPE_SECRET_KEY = defineSecret("STRIPE_SECRET_KEY");
const STRIPE_WEBHOOK_SECRET = defineSecret("STRIPE_WEBHOOK_SECRET");
const ALLOWED_CURRENCIES = new Set(["usd", "eur", "gbp", "sek"]);

async function isAdminUid(uid) {
  if (!uid) return false;
  const snap = await db.doc("config/admins").get();
  const uids = snap.exists ? snap.data()?.uids : null;
  return Array.isArray(uids) && uids.includes(uid);
}

// Callable: return whether the current authenticated uid is an admin.
// Client: no args. Response: { isAdmin: boolean }
exports.getAdminStatus = onCall(
  {
    region: "us-central1",
    enforceAppCheck: false,
  },
  async (request) => {
    const uid = request.auth && request.auth.uid ? request.auth.uid : "";
    if (!uid) {
      throw new HttpsError("unauthenticated", "Unauthenticated");
    }
    const isAdmin = await isAdminUid(uid);
    return {isAdmin};
  }
);

// Admin-only helper for testing: delete a user's event tickets so they can repurchase.
exports.adminResetTicketsForEvent = onCall(
  {
    region: "us-central1",
    enforceAppCheck: false,
  },
  async (request) => {
    if (!request.auth || !request.auth.uid) {
      throw new Error("Unauthenticated");
    }
    const callerUid = request.auth.uid;
    if (!(await isAdminUid(callerUid))) {
      throw new Error("Permission denied");
    }

    const data = request.data || {};
    const eventId = typeof data.eventId === "string" ? data.eventId.trim() : "";
    const targetUid =
      typeof data.uid === "string" && data.uid.trim() ? data.uid.trim() : callerUid;

    if (!eventId) {
      throw new Error("Missing eventId");
    }

    const eventRef = db.collection("events").doc(eventId);
    const ticketsSnap = await eventRef
      .collection("tickets")
      .where("userUid", "==", targetUid)
      .limit(50)
      .get();

    if (ticketsSnap.empty) {
      return { deleted: 0, decrementedBy: 0 };
    }

    let qtySum = 0;
    const ticketRefs = [];
    const mirrorRefs = [];
    for (const doc of ticketsSnap.docs) {
      const t = doc.data() || {};
      const q = Number.isFinite(t.quantity) ? Number(t.quantity) : 1;
      qtySum += q;
      ticketRefs.push(doc.ref);
      mirrorRefs.push(
        db.collection("users").doc(targetUid).collection("tickets").doc(doc.id)
      );
    }

    const ownershipRef = db
      .collection("users")
      .doc(targetUid)
      .collection("eventTickets")
      .doc(eventId);
    const lockRef = db
      .collection("users")
      .doc(targetUid)
      .collection("ticketLocks")
      .doc(eventId);

    await db.runTransaction(async (txn) => {
      const eventSnap = await txn.get(eventRef);
      const sold = eventSnap.exists
        ? Number.isFinite(eventSnap.data()?.ticketsSold)
          ? Number(eventSnap.data().ticketsSold)
          : 0
        : 0;
      const nextSold = Math.max(0, sold - qtySum);
      if (eventSnap.exists) {
        txn.update(eventRef, { ticketsSold: nextSold });
      }
      for (const ref of ticketRefs) txn.delete(ref);
      for (const ref of mirrorRefs) txn.delete(ref);
      txn.delete(ownershipRef);
      txn.delete(lockRef);
    });

    return { deleted: ticketRefs.length, decrementedBy: qtySum };
  }
);

// ==================== APPLICATION CLAIMING ====================
// Callable: link an application (by referralCode) to the current Firebase Auth user.
// This enables Firestore rules like: request.auth.uid == resource.data.ownerUid
exports.claimApplicationByReferralCode = onCall(
  {
    region: "us-central1",
    // TEMP: App Check enforcement disabled until iOS App Check is registered.
    enforceAppCheck: false,
  },
  async (request) => {
    try {
      if (!request.auth || !request.auth.uid) {
        throw new Error("Unauthenticated");
      }
      const uid = request.auth.uid;
      const data = request.data || {};
      const referralCode =
        typeof data.referralCode === "string" ? data.referralCode.trim() : "";

      if (!referralCode) {
        throw new Error("Missing referralCode");
      }

      const snap = await db
        .collection("applications")
        .where("referralCode", "==", referralCode)
        .limit(1)
        .get();

      if (snap.empty) {
        throw new Error("Application not found");
      }

      const doc = snap.docs[0];
      const appData = doc.data() || {};
      const ownerUid = typeof appData.ownerUid === "string" ? appData.ownerUid : null;

      if (ownerUid && ownerUid !== uid) {
        throw new Error("Already claimed by another user");
      }

      if (!ownerUid) {
        await doc.ref.set(
          {
            ownerUid: uid,
            ownerClaimedAt: admin.firestore.FieldValue.serverTimestamp(),
          },
          { merge: true }
        );

        // Apply any pending XP transactions for this user
        try {
          const pendingXp = await db
            .collection("xp_transactions")
            .where("uid", "==", uid)
            .where("applied", "==", false)
            .get();

          if (!pendingXp.empty) {
            let totalXp = 0;
            for (const xpDoc of pendingXp.docs) {
              const xpData = xpDoc.data() || {};
              const amount = Number(xpData.xpAwarded) || 0;
              totalXp += amount;
              await xpDoc.ref.update({ applied: true });
            }
            if (totalXp > 0) {
              await doc.ref.update({
                xpPoints: admin.firestore.FieldValue.increment(totalXp),
              });
              console.log(`Applied ${totalXp} pending XP (${pendingXp.size} transactions) to ${uid}`);
            }
          }
        } catch (xpError) {
          console.error("Failed to apply pending XP on claim:", xpError);
          // Non-fatal: the claim itself succeeded
        }
      }

      // Attach referralCode as a custom claim on the auth token so Firestore
      // rules can gate writes on `request.auth.token.referralCode`.
      try {
        await admin.auth().setCustomUserClaims(uid, { referralCode });
      } catch (claimErr) {
        console.error("Failed to set referralCode custom claim:", claimErr);
        // Non-fatal: caller can retry via syncReferralClaim.
      }

      return { success: true, docId: doc.id };
    } catch (error) {
      console.error("claimApplicationByReferralCode error:", error);
      throw new Error("Unable to claim application");
    }
  }
);

// Idempotent claim-syncing callable. Looks up the caller's application doc by
// ownerUid, then ensures `referralCode` is attached as a custom auth-token
// claim. Used by the client on app start as a safety net for existing users
// whose claim was never set (or got cleared by an Auth migration).
exports.syncReferralClaim = onCall(
  {
    region: "us-central1",
    enforceAppCheck: false,
  },
  async (request) => {
    if (!request.auth || !request.auth.uid) {
      throw new HttpsError("unauthenticated", "Sign in required");
    }
    const uid = request.auth.uid;

    try {
      // Find the user's claimed application doc.
      const snap = await db
        .collection("applications")
        .where("ownerUid", "==", uid)
        .limit(1)
        .get();

      if (snap.empty) {
        // No claimed application yet — nothing to sync. Not an error.
        return { synced: false, reason: "no_application" };
      }

      const data = snap.docs[0].data() || {};
      const referralCode = typeof data.referralCode === "string"
        ? data.referralCode.trim()
        : "";

      if (!referralCode) {
        return { synced: false, reason: "no_referral_code" };
      }

      // Read the existing claim. Skip the write if it's already correct —
      // setCustomUserClaims forces a token-refresh requirement, so avoid it
      // when nothing changes.
      const userRecord = await admin.auth().getUser(uid);
      const existing = userRecord.customClaims || {};
      if (existing.referralCode === referralCode) {
        return { synced: true, referralCode, changed: false };
      }

      // Merge with any existing claims (admin flag, etc.) so we don't clobber.
      await admin.auth().setCustomUserClaims(uid, {
        ...existing,
        referralCode,
      });

      return { synced: true, referralCode, changed: true };
    } catch (e) {
      console.error("syncReferralClaim error:", e);
      throw new HttpsError("internal", `Failed to sync claim: ${e.message || e}`);
    }
  }
);

// ==================== SEND INVITE EMAIL (from app) ====================
exports.sendInviteEmail = onCall(
  {
    region: "us-central1",
    enforceAppCheck: false,
    secrets: [MAIL_SENDER_EMAIL, MAIL_SENDER_PASSWORD],
  },
  async (request) => {
    if (!request.auth || !request.auth.uid) {
      throw new HttpsError("unauthenticated", "Unauthenticated");
    }
    const uid = request.auth.uid;
    const friendEmail = (request.data && typeof request.data.friendEmail === "string")
      ? request.data.friendEmail.trim().toLowerCase()
      : "";

    if (!friendEmail || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(friendEmail)) {
      throw new HttpsError("invalid-argument", "Please enter a valid email address.");
    }

    // Find user's application
    const appSnap = await db
      .collection("applications")
      .where("ownerUid", "==", uid)
      .limit(1)
      .get();

    if (appSnap.empty) {
      throw new HttpsError("not-found", "No application found");
    }

    const appData = appSnap.docs[0].data() || {};
    let inviteCode = appData.inviteCode || null;
    if (!inviteCode) {
      throw new HttpsError("failed-precondition", "No invite code available");
    }

    // Rate limit: max 5 per user per day
    const today = new Date().toISOString().slice(0, 10);
    const rateLimitRef = db.collection("referral_rate_limits").doc(`${uid}_${today}`);
    const rateLimitDoc = await rateLimitRef.get();
    const currentCount = rateLimitDoc.exists ? (rateLimitDoc.data().count || 0) : 0;

    if (currentCount >= 5) {
      throw new HttpsError("resource-exhausted", "You have reached the daily referral limit (5). Try again tomorrow.");
    }

    // Check if this email was already invited by this user
    const existingSnap = await db
      .collection("website_referrals")
      .where("friendEmail", "==", friendEmail)
      .where("inviterUid", "==", uid)
      .limit(1)
      .get();

    if (!existingSnap.empty) {
      throw new HttpsError("already-exists", "You have already sent an invitation to this email.");
    }

    const membershipUrl = `https://tek-landing.vercel.app/membership.html?invite=${inviteCode}`;
    const inviterName = appData.name || "A TEK member";

    const transporter = createMailTransporter();
    await transporter.sendMail({
      from: `"TEK" <${MAIL_SENDER_EMAIL.value()}>`,
      to: friendEmail,
      subject: `${inviterName} invited you to join TEK`,
      html: `
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head>
<body style="margin:0;padding:0;background:#000;font-family:'Helvetica Neue',Arial,sans-serif;">
  <table width="100%" cellpadding="0" cellspacing="0" style="background:#000;padding:40px 20px;">
    <tr><td align="center">
      <table width="100%" style="max-width:520px;background:#0a0a0a;border:1px solid rgba(0,255,65,0.15);border-radius:8px;overflow:hidden;">
        <tr><td style="padding:48px 40px 24px;text-align:center;">
          <h1 style="margin:0;font-size:28px;font-weight:800;letter-spacing:6px;color:#00FF41;">TEK</h1>
        </td></tr>
        <tr><td style="padding:0 40px 32px;">
          <p style="color:#ffffff;font-size:16px;line-height:1.7;margin:0 0 20px;">
            <strong>${inviterName}</strong> wants you to join TEK — Stockholm's members-only community for electronic music, art, and culture.
          </p>
          <p style="color:#999;font-size:14px;line-height:1.6;margin:0 0 32px;">
            TEK is an invite-based collective. Membership gives you access to exclusive events, a private community, and rewards. Apply now — spots are limited.
          </p>
        </td></tr>
        <tr><td style="padding:0 40px 40px;text-align:center;">
          <a href="${membershipUrl}" style="display:inline-block;background:#00FF41;color:#000;font-size:13px;font-weight:700;letter-spacing:2px;padding:14px 36px;border-radius:4px;text-decoration:none;">APPLY FOR MEMBERSHIP</a>
        </td></tr>
        <tr><td style="padding:24px 40px;border-top:1px solid rgba(255,255,255,0.06);text-align:center;">
          <p style="color:#555;font-size:11px;margin:0;letter-spacing:0.5px;">
            You received this because ${inviterName} referred you to TEK.<br>
            If this was not intended for you, you can ignore this email.
          </p>
        </td></tr>
      </table>
    </td></tr>
  </table>
</body>
</html>`,
    });

    // Increment rate limit
    await rateLimitRef.set({
      count: currentCount + 1,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, {merge: true});

    // Log the referral
    await db.collection("website_referrals").add({
      friendEmail,
      inviterUid: uid,
      inviterAppId: appSnap.docs[0].id,
      inviteCode,
      sentAt: admin.firestore.FieldValue.serverTimestamp(),
      source: "app",
    });

    return { success: true };
  }
);

// ==================== INVITE / REFERRAL STATS ====================
// Callable: get the current user's invite stats (inviteCode, invited friends, rewards).
exports.getInviteStats = onCall(
  {
    region: "us-central1",
    enforceAppCheck: false,
  },
  async (request) => {
    if (!request.auth || !request.auth.uid) {
      throw new HttpsError("unauthenticated", "Unauthenticated");
    }
    const uid = request.auth.uid;

    // Find user's application
    const appSnap = await db
      .collection("applications")
      .where("ownerUid", "==", uid)
      .limit(1)
      .get();

    if (appSnap.empty) {
      throw new HttpsError("not-found", "No application found for this user");
    }

    const appDoc = appSnap.docs[0];
    const appData = appDoc.data() || {};
    let inviteCode = appData.inviteCode || null;
    let referralCode = appData.referralCode || null;

    // Auto-generate inviteCode and/or referralCode for approved users missing them
    if (appData.status === "approved") {
      const updates = {};
      if (!referralCode) {
        referralCode = generateReferralCode();
        updates.referralCode = referralCode;
      }
      if (!inviteCode) {
        inviteCode = generateInviteCode();
        updates.inviteCode = inviteCode;
      }
      if (Object.keys(updates).length > 0) {
        await appDoc.ref.update(updates);
        console.log(`Auto-generated codes for app ${appDoc.id}:`, updates);
      }
    }

    if (!inviteCode) {
      return {
        inviteCode: null,
        inviteLink: null,
        invitedFriends: [],
        approvedCount: 0,
        ticketBuyerCount: 0,
        drinkRewardEarned: false,
        freeTicketEarned: false,
        rewards: [],
      };
    }

    // Get all people invited by this user
    const inviteesSnap = await db
      .collection("applications")
      .where("invitedByInviteCode", "==", inviteCode)
      .get();

    const invitedFriends = [];
    let approvedCount = 0;
    let ticketBuyerCount = 0;

    for (const inviteeDoc of inviteesSnap.docs) {
      const d = inviteeDoc.data() || {};
      const isApproved = d.status === "approved";
      if (isApproved) approvedCount++;

      let boughtTicket = false;
      if (isApproved && d.ownerUid) {
        const txSnap = await db
          .collection("xp_transactions")
          .where("uid", "==", d.ownerUid)
          .where("reason", "==", "ticket_purchase")
          .limit(1)
          .get();
        boughtTicket = !txSnap.empty;
        if (boughtTicket) ticketBuyerCount++;
      }

      invitedFriends.push({
        name: d.name || "Unknown",
        status: d.status || "pending",
        profileImageUrl: d.profileImageUrl || null,
        boughtTicket,
      });
    }

    // Get rewards
    const rewardsSnap = await db
      .collection("rewards")
      .where("appId", "==", appDoc.id)
      .get();

    const rewards = rewardsSnap.docs.map((r) => {
      const rd = r.data() || {};
      return {
        id: r.id,
        type: rd.type || "",
        reason: rd.reason || "",
        redeemed: rd.redeemed || false,
      };
    });

    return {
      inviteCode,
      inviteLink: `https://tek-landing.vercel.app/membership.html?invite=${inviteCode}`,
      invitedFriends,
      approvedCount,
      ticketBuyerCount,
      drinkRewardEarned: approvedCount >= 5,
      freeTicketEarned: ticketBuyerCount >= 5,
      rewards,
    };
  }
);

// ==================== SINGLE-DEVICE (REFERRAL CODE) SESSION ====================
// Callable: mark this referralCode as "active" on the current device.
// When the same referral code is used on another device, the previous device can
// observe the session change (by watching the application doc) and log out.
//
// Client data: { referralCode: string, deviceId: string }
// Returns: { appId: string, sessionId: string }
exports.activateApplicationSessionByReferralCode = onCall(
  {
    region: "us-central1",
    // TEMP: App Check enforcement disabled until iOS App Check is registered.
    enforceAppCheck: false,
    // Ensure Cloud Run invoker doesn't block requests before our handler runs.
    // Auth is enforced inside the callable.
    invoker: "public",
  },
  async (request) => {
    try {
      // In rare cases, `request.auth` can be null even when the client is signed in.
      // As a fallback, manually verify the Firebase ID token from the Authorization header.
      const authHeader = request?.rawRequest?.headers?.authorization;
      const hasAuthHeader = typeof authHeader === "string" && authHeader.trim().length > 0;
      let uid = request.auth && request.auth.uid ? request.auth.uid : null;

      if (!uid && hasAuthHeader) {
        const m = authHeader.match(/^Bearer\s+(.+)$/i);
        if (m && m[1]) {
          try {
            const decoded = await admin.auth().verifyIdToken(m[1]);
            uid = decoded && decoded.uid ? decoded.uid : null;
          } catch (err) {
            console.warn(
              "activateApplicationSessionByReferralCode: token present but verify failed",
              {
                code: err && err.code ? err.code : undefined,
                message: err && err.message ? err.message : String(err),
              }
            );
          }
        }
      }

      console.log("activateApplicationSessionByReferralCode auth context", {
        requestAuthPresent: !!(request.auth && request.auth.uid),
        hasAuthHeader,
        uidPresent: !!uid,
      });

      if (!uid) {
        throw new HttpsError("unauthenticated", "Unauthenticated");
      }

      const data = request.data || {};

      const referralCode =
        typeof data.referralCode === "string" ? data.referralCode.trim().toUpperCase() : "";
      const deviceId = typeof data.deviceId === "string" ? data.deviceId.trim() : "";

      if (!referralCode) {
        throw new HttpsError("invalid-argument", "Missing referralCode");
      }
      if (!deviceId) {
        throw new HttpsError("invalid-argument", "Missing deviceId");
      }

      const snap = await db
        .collection("applications")
        .where("referralCode", "==", referralCode)
        .limit(1)
        .get();

      if (snap.empty) {
        throw new HttpsError("not-found", "Application not found");
      }

      const doc = snap.docs[0];
      const appId = doc.id;

      const sessionId = `${Date.now()}_${Math.random().toString(36).slice(2, 10)}`;

      // Store the web anonymous UID so getWebTickets can find tickets
      // purchased under this UID even after the anonymous session expires.
      const updateData = {
        activeSessionId: sessionId,
        activeSessionAt: admin.firestore.FieldValue.serverTimestamp(),
        webUid: uid,
      };

      // Also track historical web UIDs so tickets from previous sessions are findable.
      const existingData = doc.data() || {};
      if (existingData.webUid && existingData.webUid !== uid) {
        updateData.webUids = admin.firestore.FieldValue.arrayUnion(
          existingData.webUid,
          uid
        );
      } else {
        updateData.webUids = admin.firestore.FieldValue.arrayUnion(uid);
      }

      await doc.ref.set(updateData, { merge: true });

      return { appId, sessionId, ownerUid: existingData.ownerUid || null };
    } catch (error) {
      console.error("activateApplicationSessionByReferralCode error:", error);
      if (error instanceof HttpsError) throw error;
      throw new HttpsError("internal", "Unable to activate session");
    }
  }
);

// ==================== ADMIN BOOTSTRAP ====================
// Callable: add the current user's uid to /config/admins.uids (array) using a shared bootstrap token.
// Usage (debug only): call this once after signing in, passing { token: "..." }.
exports.bootstrapAdmin = onCall(
  {
    region: "us-central1",
    enforceAppCheck: false,
    secrets: [ADMIN_BOOTSTRAP_TOKEN],
  },
  async (request) => {
    try {
      if (!request.auth || !request.auth.uid) {
        throw new Error("Unauthenticated");
      }
      const uid = request.auth.uid;

      const data = request.data || {};
      const token = typeof data.token === "string" ? data.token.trim() : "";
      if (!token) {
        throw new Error("Missing token");
      }
      if (token !== ADMIN_BOOTSTRAP_TOKEN.value()) {
        throw new Error("Invalid token");
      }

      await db
        .doc("config/admins")
        .set({ uids: admin.firestore.FieldValue.arrayUnion(uid) }, { merge: true });

      return { success: true, uid };
    } catch (error) {
      console.error("bootstrapAdmin error:", error);
      throw new Error("Unable to bootstrap admin");
    }
  }
);

function escapeHtml(text) {
  return String(text)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/\"/g, "&quot;")
    .replace(/'/g, "&#039;");
}

function isAllowedCheckoutReturnUrl(rawUrl) {
  try {
    const parsed = new URL(rawUrl);
    if (parsed.protocol === "https:") return true;
    return (
      parsed.protocol === "http:" &&
      ["localhost", "127.0.0.1"].includes(parsed.hostname)
    );
  } catch (_) {
    return false;
  }
}

function buildCheckoutReturnUrl(pageUrl, checkoutState, extraParams = {}) {
  const url = new URL(pageUrl);
  ["checkout", "session_id", "event_id"].forEach((key) => {
    url.searchParams.delete(key);
  });
  url.searchParams.set("checkout", checkoutState);

  // Stripe template variables like {CHECKOUT_SESSION_ID} must NOT be
  // URL-encoded.  Build those parts as a raw query-string suffix so
  // Stripe can recognise and replace them at redirect time.
  let rawSuffix = "";
  Object.entries(extraParams).forEach(([key, value]) => {
    if (typeof value === "string" && value) {
      if (value.startsWith("{") && value.endsWith("}")) {
        // Stripe template placeholder – append raw so curly braces stay literal
        rawSuffix += `&${encodeURIComponent(key)}=${value}`;
      } else {
        url.searchParams.set(key, value);
      }
    }
  });

  let result = url.toString();
  if (rawSuffix) {
    result += (result.includes("?") ? "" : "?") + rawSuffix;
  }
  return result;
}

function buildReferralCodeEmail({name, referralCode}) {
  const safeName = escapeHtml(name || "there");
  const safeCode = escapeHtml(referralCode || "");

  const subject = "Your TEK referral code (keep it safe)";

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

  const html = `
    <div style="font-family:Arial,sans-serif;line-height:1.55;color:#111">
      <h2 style="margin:0 0 12px">Welcome to TEK</h2>
      <p style="margin:0 0 12px">Hi ${safeName},</p>
      <p style="margin:0 0 12px">Your TEK referral code is:</p>
      <p style="margin:0 0 16px">
        <span style="display:inline-block;padding:10px 14px;border:1px solid #ddd;border-radius:8px;font-size:18px;letter-spacing:2px">
          <strong>${safeCode}</strong>
        </span>
      </p>

      <div style="padding:12px 14px;border-left:4px solid #00c853;background:#f6fff8;border-radius:6px">
        <p style="margin:0 0 8px"><strong>Important</strong></p>
        <ul style="margin:0;padding-left:18px">
          <li>This referral code is your <strong>only</strong> way to log in to the TEK app.</li>
          <li>We do <strong>not</strong> use passwords, and there is <strong>no</strong> password reset.</li>
          <li>Keep this code safe. If you lose it, reply to this email for help.</li>
        </ul>
      </div>

      <p style="margin:16px 0 0">Best regards,<br/>The TEK Team</p>
    </div>
  `;

  return {subject, text, html};
}

function buildRejectionEmail(name) {
  const safeName = escapeHtml(name || "there");
  return {
    subject: "TEK Application Update",
    html: `
      <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto;">
        <h2>Thank you for your interest in TEK</h2>
        <p>Hi ${safeName},</p>
        <p>Thank you for applying to TEK. Unfortunately, we are unable to approve your application at this time.</p>
        <p>We wish you all the best!</p>
        <p style="margin-top: 30px;">Best regards,<br/>The TEK Team</p>
      </div>
    `,
  };
}

async function processApplicationReview({appId, action}) {
  if (!appId || !action) {
    throw new HttpsError("invalid-argument", "Missing appId or action");
  }
  if (action !== "approve" && action !== "reject") {
    throw new HttpsError("invalid-argument", "Invalid action");
  }

  const appRef = db.collection("applications").doc(appId);
  const appDoc = await appRef.get();

  if (!appDoc.exists) {
    throw new HttpsError("not-found", "Application not found");
  }

  const appData = appDoc.data() || {};
  if (appData.status !== "pending") {
    throw new HttpsError(
      "failed-precondition",
      `Application already ${appData.status || "processed"}`
    );
  }

  const transporter = createMailTransporter();
  const fromHeader = buildMailFromHeader();

  if (action === "approve") {
    const referralCode = generateReferralCode();
    const inviteCode = generateInviteCode();

    await appRef.update({
      referralCode,
      inviteCode,
      status: "approved",
      approvedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    const referralEmail = buildReferralCodeEmail({
      name: appData.name,
      referralCode,
    });

    await transporter.sendMail({
      from: fromHeader,
      to: appData.email,
      subject: referralEmail.subject,
      text: referralEmail.text,
      html: referralEmail.html,
    });

    // If this applicant was invited by someone, award the inviter
    if (appData.invitedByInviteCode) {
      try {
        await awardInviterOnApproval(appData.invitedByInviteCode, appId);
      } catch (err) {
        console.error("Failed to award inviter:", err);
        // Non-fatal: the approval itself succeeded
      }
    }

    return {
      success: true,
      action,
      referralCode,
      application: {
        id: appId,
        name: appData.name || "",
        email: appData.email || "",
      },
      message: "Application approved and welcome email sent",
    };
  }

  await appRef.update({
    status: "rejected",
    rejectedAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  const rejectionEmail = buildRejectionEmail(appData.name);
  await transporter.sendMail({
    from: fromHeader,
    to: appData.email,
    subject: rejectionEmail.subject,
    html: rejectionEmail.html,
  });

  return {
    success: true,
    action,
    application: {
      id: appId,
      name: appData.name || "",
      email: appData.email || "",
    },
    message: "Application rejected",
  };
}

// Notify admin about new application
exports.notifyAdminNewApplication = onCall(
  {
    region: "us-central1",
    secrets: [MAIL_SENDER_EMAIL, MAIL_SENDER_PASSWORD],
  },
  async (request) => {
    console.log("notifyAdminNewApplication called");
    
    try {
      const { name, email, phone, instagram, bio, adminEmail, profileImageUrl } = request.data;

      if (!name || !email || !phone || !instagram || !bio) {
        throw new Error("Missing required fields");
      }

      const transporter = createMailTransporter();
      const notificationEmail = await getAdminNotificationEmail(adminEmail);

      // Find the actual Firestore application document
      const snapshot = await db.collection("applications")
        .where("email", "==", email)
        .where("status", "==", "pending")
        .limit(1)
        .get();

      let appId = "UNKNOWN";
      if (!snapshot.empty) {
        appId = snapshot.docs[0].id;
        console.log("Found application document:", appId);
      } else {
        console.log("No pending application found for email:", email);
      }

      // Build clickable approve/reject URLs
      const baseUrl = "https://us-central1-tek-nightclub-app.cloudfunctions.net/handleApplicationAction";
      const approveUrl = `${baseUrl}?appId=${appId}&action=approve`;
      const rejectUrl = `${baseUrl}?appId=${appId}&action=reject`;

      const adminEmailHtml = `
        <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto;">
          <h2 style="color: #00FF41;">New TEK Application</h2>
          <div style="background: #f5f5f5; padding: 20px; border-radius: 8px; margin: 20px 0;">
            <p><strong>Name:</strong> ${name}</p>
            <p><strong>Email:</strong> ${email}</p>
            <p><strong>Phone:</strong> ${phone}</p>
            <p><strong>Instagram:</strong> @${instagram}</p>
            <p><strong>Bio:</strong> ${bio}</p>
            ${profileImageUrl ? `<p><strong>Profile Image:</strong> <a href="${profileImageUrl}">View Image</a></p>` : ""}
          </div>
          <div style="margin: 30px 0; text-align: center;">
            <a href="${approveUrl}" style="display: inline-block; padding: 15px 40px; background-color: #00FF41; color: #000; font-size: 18px; font-weight: bold; text-decoration: none; border-radius: 8px; margin: 10px;">✅ APPROVE</a>
            <br/><br/>
            <a href="${rejectUrl}" style="display: inline-block; padding: 15px 40px; background-color: #FF0000; color: #FFF; font-size: 18px; font-weight: bold; text-decoration: none; border-radius: 8px; margin: 10px;">❌ REJECT</a>
          </div>
          <p style="color: #666; font-size: 12px; text-align: center;">Application ID: ${appId}</p>
        </div>
      `;

      await transporter.sendMail({
        from: buildMailFromHeader(),
        to: notificationEmail,
        subject: `New TEK Application: ${name}`,
        html: adminEmailHtml,
      });
      console.log("Notification email sent successfully to admin");

      return { 
        success: true, 
        message: "Admin notified",
        appId: appId 
      };
    } catch (error) {
      console.error("notifyAdminNewApplication error:", error);
      if (
        error &&
        typeof error === "object" &&
        (error.code === "EAUTH" || error.responseCode === 534)
      ) {
        throw new HttpsError(
          "failed-precondition",
          "Email sending failed: Gmail requires an App Password. Update the MAIL_SENDER_PASSWORD secret to a Google App Password (2FA required)."
        );
      }
      throw new HttpsError(
        "internal",
        `Email error: ${error.message}`
      );
    }
  }
);

// Approve or reject application (called manually by admin)
exports.approveApplication = onCall(
  {
    region: "us-central1",
    secrets: [MAIL_SENDER_EMAIL, MAIL_SENDER_PASSWORD],
  },
  async (request) => {
    console.log("approveApplication called");
    
    try {
      const callerUid = request.auth && request.auth.uid ? request.auth.uid : "";
      if (!callerUid) {
        throw new HttpsError("unauthenticated", "Unauthenticated");
      }
      if (!(await isAdminUid(callerUid))) {
        throw new HttpsError("permission-denied", "Permission denied");
      }

      return await processApplicationReview(request.data || {});
    } catch (error) {
      console.error("Error:", error);
      if (error instanceof HttpsError) {
        throw error;
      }
      throw new HttpsError("internal", error.message || "Unable to review application");
    }
  }
);

// HTTP endpoint for one-click approve/reject from admin email
exports.handleApplicationAction = onRequest(
  {
    region: "us-central1",
    cors: true,
    secrets: [MAIL_SENDER_EMAIL, MAIL_SENDER_PASSWORD],
  },
  async (req, res) => {
    console.log("handleApplicationAction called");
    
    try {
      const { appId, action } = req.query;

      if (!appId || !action) {
        res.status(400).send("<h1>Missing appId or action</h1>");
        return;
      }

      if (action !== "approve" && action !== "reject") {
        res.status(400).send("<h1>Invalid action. Must be 'approve' or 'reject'</h1>");
        return;
      }

      const appRef = db.collection("applications").doc(appId);
      const appDoc = await appRef.get();

      if (!appDoc.exists) {
        res.status(404).send(`
          <html><body style="font-family:Arial;text-align:center;padding:50px;">
            <h1 style="color:red;">❌ Application not found</h1>
            <p>ID: ${appId}</p>
          </body></html>
        `);
        return;
      }

      const appData = appDoc.data();

      if (appData.status !== "pending") {
        res.status(200).send(`
          <html><body style="font-family:Arial;text-align:center;padding:50px;">
            <h1 style="color:orange;">⚠️ Already processed</h1>
            <p>This application was already <strong>${appData.status}</strong>.</p>
          </body></html>
        `);
        return;
      }

      if (action === "approve") {
        const result = await processApplicationReview({appId, action});
        res.status(200).send(`
          <html><body style="font-family:Arial;text-align:center;padding:50px;">
            <h1 style="color:#00FF41;">✅ Application APPROVED</h1>
            <p><strong>${appData.name}</strong> has been approved!</p>
            <p>Referral code: <strong>${result.referralCode}</strong></p>
            <p>Welcome email sent to: ${appData.email}</p>
          </body></html>
        `);
      } else {
        await processApplicationReview({appId, action});

        res.status(200).send(`
          <html><body style="font-family:Arial;text-align:center;padding:50px;">
            <h1 style="color:red;">❌ Application REJECTED</h1>
            <p><strong>${appData.name}</strong> has been rejected.</p>
            <p>Rejection email sent to: ${appData.email}</p>
          </body></html>
        `);
      }
    } catch (error) {
      console.error("handleApplicationAction error:", error);
      res.status(500).send(`
        <html><body style="font-family:Arial;text-align:center;padding:50px;">
          <h1 style="color:red;">Error</h1>
          <p>${error.message}</p>
        </body></html>
      `);
    }
  }
);

exports.sendMembershipEmail = onCall(
  {
    region: "us-central1",
    secrets: [MAIL_SENDER_EMAIL, MAIL_SENDER_PASSWORD],
  },
  async (request) => {
  console.log("sendMembershipEmail called (legacy)");
  
  try {
    const { name, email, phone, instagram, bio, adminEmail, profileImageUrl } = request.data;

    if (!name || !email || !phone || !instagram || !bio || !adminEmail) {
      throw new Error("Missing required fields");
    }

    const transporter = createMailTransporter();

    const referralCode = generateReferralCode();
    console.log("Referral code:", referralCode);

    const referralEmail = buildReferralCodeEmail({name, referralCode});

    await transporter.sendMail({
      from: buildMailFromHeader(),
      to: email,
      subject: referralEmail.subject,
      text: referralEmail.text,
      html: referralEmail.html,
    });
    console.log("Email sent to applicant");

    await transporter.sendMail({
      from: buildMailFromHeader(),
      to: adminEmail,
      subject: `New TEK Application: ${name}`,
      html: `<h2>New Application</h2><p>${name} | ${email} | ${phone} | @${instagram}</p><p>Code: ${referralCode}</p>`,
    });
    console.log("Email sent to admin");

    const applicationData = {
      name, email, phone, instagram, bio, referralCode,
      submittedAt: admin.firestore.FieldValue.serverTimestamp(),
      status: "approved",
      friendRequests: [],
      friends: [],
      xpPoints: 0,
    };

    // Add profileImageUrl if provided
    if (profileImageUrl && typeof profileImageUrl === 'string') {
      applicationData.profileImageUrl = profileImageUrl;
    }

    await db.collection("applications").add(applicationData);
    console.log("Application saved to Firestore");

    return { 
      success: true, 
      message: "Emails sent", 
      referralCode: referralCode 
    };
  } catch (error) {
    console.error("Error:", error);
    if (
      error &&
      typeof error === "object" &&
      (error.code === "EAUTH" || error.responseCode === 534)
    ) {
      throw new HttpsError(
        "failed-precondition",
        "Email sending failed: Gmail requires an App Password. Update the MAIL_SENDER_PASSWORD secret to a Google App Password (2FA required)."
      );
    }
    throw error;
  }
});

// Admin-only helper: send a test referral-code email (preview) to any address.
// Client data: { toEmail: string, name?: string, referralCode?: string }
exports.adminSendTestReferralCodeEmail = onCall(
  {
    region: "us-central1",
    enforceAppCheck: false,
    secrets: [MAIL_SENDER_EMAIL, MAIL_SENDER_PASSWORD],
  },
  async (request) => {
    try {
      const data = request.data || {};

      const callerUid = request.auth && request.auth.uid ? request.auth.uid : "";
      if (!callerUid) {
        throw new HttpsError("unauthenticated", "Unauthenticated");
      }
      const isUidAdmin = await isAdminUid(callerUid);
      if (!isUidAdmin) {
        throw new HttpsError("permission-denied", "Permission denied");
      }

      const toEmail =
        typeof data.toEmail === "string" ? data.toEmail.trim() : "";
      const name = typeof data.name === "string" ? data.name.trim() : "";
      const referralCode =
        typeof data.referralCode === "string" && data.referralCode.trim()
          ? data.referralCode.trim().toUpperCase()
          : generateReferralCode();

      if (!toEmail || !toEmail.includes("@")) {
        throw new HttpsError("invalid-argument", "Invalid toEmail");
      }

      const transporter = createMailTransporter();

      const referralEmail = buildReferralCodeEmail({
        name: name || "there",
        referralCode,
      });

      await transporter.sendMail({
        from: buildMailFromHeader(),
        to: toEmail,
        subject: `[TEST] ${referralEmail.subject}`,
        text: referralEmail.text,
        html: referralEmail.html,
      });

      return {success: true, toEmail, referralCode};
    } catch (error) {
      console.error("adminSendTestReferralCodeEmail error:", error);

      if (error instanceof HttpsError) {
        throw error;
      }
      if (
        error &&
        typeof error === "object" &&
        (error.code === "EAUTH" || error.responseCode === 534)
      ) {
        throw new HttpsError(
          "failed-precondition",
          "Email sending failed: Gmail requires an App Password. Update the MAIL_SENDER_PASSWORD secret to a Google App Password (2FA required)."
        );
      }
      throw new HttpsError("internal", "Unable to send test email");
    }
  }
);

exports.adminReviewApplication = onCall(
  {
    region: "us-central1",
    enforceAppCheck: false,
    secrets: [MAIL_SENDER_EMAIL, MAIL_SENDER_PASSWORD],
  },
  async (request) => {
    const callerUid = request.auth && request.auth.uid ? request.auth.uid : "";
    if (!callerUid) {
      throw new HttpsError("unauthenticated", "Unauthenticated");
    }
    if (!(await isAdminUid(callerUid))) {
      throw new HttpsError("permission-denied", "Permission denied");
    }

    return processApplicationReview(request.data || {});
  }
);

exports.adminGetDashboardData = onCall(
  {
    region: "us-central1",
    enforceAppCheck: false,
    secrets: [MAIL_SENDER_EMAIL, MAIL_SENDER_PASSWORD, STRIPE_SECRET_KEY],
  },
  async (request) => {
    const callerUid = request.auth && request.auth.uid ? request.auth.uid : "";
    if (!callerUid) {
      throw new HttpsError("unauthenticated", "Unauthenticated");
    }
    if (!(await isAdminUid(callerUid))) {
      throw new HttpsError("permission-denied", "Permission denied");
    }

    const allAppsSnap = await db.collection("applications").get();

    const now = Date.now();
    const dayAgo = now - 24 * 60 * 60 * 1000;
    const weekAgo = now - 7 * 24 * 60 * 60 * 1000;

    const summary = {
      total: allAppsSnap.size,
      pending: 0,
      approved: 0,
      rejected: 0,
      submittedToday: 0,
      submittedLast7Days: 0,
    };

    allAppsSnap.forEach((doc) => {
      const data = doc.data() || {};
      const status = typeof data.status === "string" ? data.status : "pending";
      if (status === "pending") summary.pending += 1;
      else if (status === "approved") summary.approved += 1;
      else if (status === "rejected") summary.rejected += 1;

      const submittedAt = data.submittedAt && typeof data.submittedAt.toMillis === "function"
        ? data.submittedAt.toMillis()
        : null;
      if (submittedAt && submittedAt >= dayAgo) summary.submittedToday += 1;
      if (submittedAt && submittedAt >= weekAgo) summary.submittedLast7Days += 1;
    });

    const analyticsCutoff = admin.firestore.Timestamp.fromMillis(weekAgo);
    const analyticsSnap = await db.collection("website_analytics_events")
      .where("createdAt", ">=", analyticsCutoff)
      .get();

    const eventCounts = {};
    analyticsSnap.forEach((doc) => {
      const data = doc.data() || {};
      const eventName = typeof data.eventName === "string" ? data.eventName : "unknown";
      eventCounts[eventName] = (eventCounts[eventName] || 0) + 1;
    });

    const allApplications = allAppsSnap.docs.map(serializeApplicationDoc);
    const sortBySubmittedAtDesc = (a, b) => {
      const aMs = a.submittedAt ? Date.parse(a.submittedAt) : 0;
      const bMs = b.submittedAt ? Date.parse(b.submittedAt) : 0;
      return bMs - aMs;
    };

    const pendingApplications = allApplications
      .filter((app) => app.status === "pending")
      .sort(sortBySubmittedAtDesc)
      .slice(0, 100);

    const recentApplications = allApplications
      .slice()
      .sort(sortBySubmittedAtDesc)
      .slice(0, 100);

    const emailDirectory = allApplications
      .filter((app) => typeof app.email === "string" && app.email.trim().includes("@"))
      .sort((a, b) => {
        const aName = typeof a.name === "string" ? a.name.toLowerCase() : "";
        const bName = typeof b.name === "string" ? b.name.toLowerCase() : "";
        if (aName && bName && aName !== bName) {
          return aName.localeCompare(bName);
        }
        return sortBySubmittedAtDesc(a, b);
      })
      .map((app) => ({
        id: app.id,
        name: app.name || "Unnamed",
        email: app.email || "",
        status: typeof app.status === "string" && app.status.trim()
          ? app.status.trim().toLowerCase()
          : "pending",
        referralCode: app.referralCode || "",
        submittedAt: app.submittedAt || null,
      }));

    // ── Ticket Sales stats ──
    const eventsSnap = await db.collection("events").get();
    const ticketStats = [];
    let totalRevenue = 0;
    let totalTicketsSold = 0;

    for (const eventDoc of eventsSnap.docs) {
      const ev = eventDoc.data() || {};
      const title =
        typeof ev.title === "string" && ev.title.trim() ? ev.title.trim() : eventDoc.id;
      const capacity = Number.isFinite(ev.capacity) ? Number(ev.capacity) : 0;
      const sold = Number.isFinite(ev.ticketsSold) ? Number(ev.ticketsSold) : 0;
      const price = Number.isFinite(ev.price) ? Number(ev.price) : 0;
      const currency =
        typeof ev.currency === "string" && ev.currency.trim()
          ? ev.currency.trim().toUpperCase()
          : "SEK";
      const eventDate = ev.date && typeof ev.date.toMillis === "function"
        ? new Date(ev.date.toMillis()).toISOString()
        : typeof ev.date === "string" ? ev.date : null;
      const revenue = sold * price;
      totalRevenue += revenue;
      totalTicketsSold += sold;

      ticketStats.push({
        eventId: eventDoc.id,
        title,
        capacity,
        sold,
        price,
        currency,
        revenue,
        eventDate,
      });
    }

    // ── Ticket Buyers list (cross-reference with applications for name/email) ──
    const uidToApp = {};
    allAppsSnap.forEach((doc) => {
      const d = doc.data() || {};
      const webUid = typeof d.webUid === "string" ? d.webUid.trim() : "";
      const ownerUid = typeof d.ownerUid === "string" ? d.ownerUid.trim() : "";
      const info = {
        name: typeof d.name === "string" ? d.name.trim() : "",
        email: typeof d.email === "string" ? d.email.trim() : "",
      };
      if (webUid) uidToApp[webUid] = info;
      if (ownerUid && !uidToApp[ownerUid]) uidToApp[ownerUid] = info;
    });

    const ticketBuyers = [];
    for (const eventDoc of eventsSnap.docs) {
      const ev = eventDoc.data() || {};
      const eventTitle = typeof ev.title === "string" && ev.title.trim() ? ev.title.trim() : eventDoc.id;
      const allTicketsSnap = await eventDoc.ref.collection("tickets").get();
      for (const tDoc of allTicketsSnap.docs) {
        const t = tDoc.data() || {};
        const userUid = typeof t.userUid === "string" ? t.userUid.trim() : "";
        const app = uidToApp[userUid] || {};
        const purchasedAt = t.purchasedAt && typeof t.purchasedAt.toMillis === "function"
          ? new Date(t.purchasedAt.toMillis()).toISOString()
          : null;
        ticketBuyers.push({
          eventId: eventDoc.id,
          eventTitle,
          ticketId: tDoc.id,
          userUid,
          name: app.name || "",
          email: app.email || "",
          quantity: Number.isFinite(t.quantity) ? Number(t.quantity) : 1,
          amount: Number.isFinite(t.amount) ? Number(t.amount) : 0,
          currency: typeof t.currency === "string" ? t.currency.toUpperCase() : "SEK",
          purchasedAt,
          source: typeof t.source === "string" ? t.source : "",
        });
      }
    }
    // Fill in missing buyer info from Stripe payment intents
    const unmatchedBuyers = ticketBuyers.filter((b) => !b.name && !b.email && b.ticketId);
    if (unmatchedBuyers.length > 0) {
      try {
        const stripe = new Stripe(STRIPE_SECRET_KEY.value(), {apiVersion: "2024-04-10"});
        await Promise.all(
          unmatchedBuyers.map(async (buyer) => {
            try {
              const pi = await stripe.paymentIntents.retrieve(buyer.ticketId, {expand: ["latest_charge"]});
              const email = pi.receipt_email || (pi.latest_charge && pi.latest_charge.billing_details && pi.latest_charge.billing_details.email) || "";
              const name = (pi.latest_charge && pi.latest_charge.billing_details && pi.latest_charge.billing_details.name) || "";
              if (email) buyer.email = email;
              if (name) buyer.name = name;
            } catch (stripeErr) {
              // skip — payment intent may not exist
            }
          })
        );
      } catch (stripeInitErr) {
        console.warn("[Dashboard] Stripe lookup skipped:", stripeInitErr.message);
      }
    }

    // Sort by purchase date descending
    ticketBuyers.sort((a, b) => {
      const aMs = a.purchasedAt ? Date.parse(a.purchasedAt) : 0;
      const bMs = b.purchasedAt ? Date.parse(b.purchasedAt) : 0;
      return bMs - aMs;
    });

    // Sort by event date descending (newest first), null dates last
    ticketStats.sort((a, b) => {
      const aMs = a.eventDate ? Date.parse(a.eventDate) : 0;
      const bMs = b.eventDate ? Date.parse(b.eventDate) : 0;
      return bMs - aMs;
    });

    // All applications sorted alphabetically for user search
    const allApplicationsSorted = allApplications.slice().sort((a, b) => {
      const aName = typeof a.name === "string" ? a.name.toLowerCase() : "";
      const bName = typeof b.name === "string" ? b.name.toLowerCase() : "";
      return aName.localeCompare(bName);
    });

    return {
      summary,
      pendingApplications,
      recentApplications,
      allApplications: allApplicationsSorted,
      analytics: {
        last7Days: eventCounts,
      },
      emailDirectory,
      email: {
        senderEmail: String(MAIL_SENDER_EMAIL.value() || "").trim(),
        adminNotificationEmail: await getAdminNotificationEmail(),
        transport: /@(gmail|googlemail)\.com$/i.test(String(MAIL_SENDER_EMAIL.value() || "")) ? "gmail" : "zoho-smtp",
      },
      ticketStats: {
        events: ticketStats,
        totalRevenue,
        totalTicketsSold,
        totalEvents: ticketStats.length,
        ticketBuyers,
      },
    };
  }
);

exports.adminUpdateNotificationEmail = onCall(
  {
    region: "us-central1",
    enforceAppCheck: false,
  },
  async (request) => {
    const callerUid = request.auth && request.auth.uid ? request.auth.uid : "";
    if (!callerUid) {
      throw new HttpsError("unauthenticated", "Unauthenticated");
    }
    if (!(await isAdminUid(callerUid))) {
      throw new HttpsError("permission-denied", "Permission denied");
    }

    const notificationEmail =
      typeof request.data?.notificationEmail === "string"
        ? request.data.notificationEmail.trim()
        : "";

    if (!notificationEmail || !notificationEmail.includes("@")) {
      throw new HttpsError("invalid-argument", "Invalid notificationEmail");
    }

    await db.doc("config/admin_settings").set(
      {
        notificationEmail,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedBy: callerUid,
      },
      {merge: true}
    );

    return {
      success: true,
      notificationEmail,
    };
  }
);

exports.trackWebsiteEvent = onRequest(
  {
    region: "us-central1",
    cors: true,
  },
  async (req, res) => {
    if (req.method === "OPTIONS") {
      res.set("Access-Control-Allow-Origin", "*");
      res.set("Access-Control-Allow-Methods", "POST, OPTIONS");
      res.set("Access-Control-Allow-Headers", "Content-Type");
      return res.status(204).send("");
    }

    if (req.method !== "POST") {
      return res.status(400).json({error: "POST request required"});
    }

    try {
      const data = req.body || {};
      const eventName = typeof data.eventName === "string" ? data.eventName.trim().slice(0, 80) : "";
      const page = typeof data.page === "string" ? data.page.trim().slice(0, 80) : "";
      const path = typeof data.path === "string" ? data.path.trim().slice(0, 200) : "";
      const visitorId = typeof data.visitorId === "string" ? data.visitorId.trim().slice(0, 120) : "";
      const userId = typeof data.userId === "string" ? data.userId.trim().slice(0, 120) : "";
      const sessionId = typeof data.sessionId === "string" ? data.sessionId.trim().slice(0, 120) : "";
      const referrer = typeof data.referrer === "string" ? data.referrer.trim().slice(0, 300) : "";
      const properties = data.properties && typeof data.properties === "object" ? data.properties : {};

      if (!eventName) {
        return res.status(400).json({error: "Missing eventName"});
      }

      await db.collection("website_analytics_events").add({
        eventName,
        page,
        path,
        visitorId,
        userId,
        sessionId,
        referrer,
        properties,
        userAgent: typeof req.headers["user-agent"] === "string" ? req.headers["user-agent"].slice(0, 400) : "",
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        clientTimestamp: typeof data.clientTimestamp === "number" ? data.clientTimestamp : null,
      });

      return res.json({success: true});
    } catch (error) {
      console.error("trackWebsiteEvent error:", error);
      return res.status(500).json({error: "Unable to track event"});
    }
  }
);


// ==================== STRIPE PAYMENTS ====================
// Callable: create a PaymentIntent and return client_secret
// Client data: { amount: number (integer, smallest unit), currency: string, idempotencyKey?: string, metadata?: object }
exports.createPaymentIntent = onCall(
  {
    region: "us-central1",
    // TEMP: App Check enforcement disabled until iOS App Check is registered.
    enforceAppCheck: false,
    secrets: [STRIPE_SECRET_KEY],
  },
  async (request) => {
    try {
      const data = request.data || {};
      const amount = data.amount;
      const currencyRaw = data.currency;

      if (typeof amount !== "number" || !Number.isInteger(amount)) {
        throw new Error("Invalid amount: must be an integer in the smallest currency unit");
      }
      // Basic guardrails (adjust to your business rules)
      if (amount < 50) {
        throw new Error("Invalid amount: must be at least 50 (e.g., $0.50 in cents)");
      }
      if (amount > 5_000_000) {
        throw new Error("Invalid amount: exceeds maximum allowed");
      }

      if (typeof currencyRaw !== "string") {
        throw new Error("Invalid currency: must be a string");
      }
      const currency = currencyRaw.trim().toLowerCase();
      if (!/^[a-z]{3}$/.test(currency)) {
        throw new Error("Invalid currency: must be a 3-letter ISO currency code");
      }
      if (!ALLOWED_CURRENCIES.has(currency)) {
        throw new Error(
          `Unsupported currency. Allowed: ${Array.from(ALLOWED_CURRENCIES).join(", ")}`
        );
      }

      const stripe = new Stripe(STRIPE_SECRET_KEY.value(), {
        // Pin API version for predictable behavior in production
        apiVersion: "2024-06-20",
      });

      const uid = request.auth && request.auth.uid ? request.auth.uid : null;
      const clientMetadata =
        data.metadata && typeof data.metadata === "object" && !Array.isArray(data.metadata)
          ? data.metadata
          : {};

      const idempotencyKey =
        typeof data.idempotencyKey === "string" && data.idempotencyKey.trim()
          ? data.idempotencyKey.trim()
          : undefined;

      const paymentIntent = await stripe.paymentIntents.create(
        {
          amount,
          currency,
          automatic_payment_methods: { enabled: true },
          metadata: {
            ...(uid ? { firebaseUid: uid } : {}),
            ...clientMetadata,
          },
        },
        idempotencyKey ? { idempotencyKey } : undefined
      );

      return { clientSecret: paymentIntent.client_secret };
    } catch (error) {
      console.error("createPaymentIntent error:", error);
      // Avoid leaking internal details; return a generic error message
      throw new Error("Unable to create PaymentIntent");
    }
  }
);

// Callable: create a PaymentIntent for an event ticket purchase.
// Client data: { eventId: string, quantity: number }
// Amount is computed server-side from the event document.
exports.createEventTicketPaymentIntent = onCall(
  {
    region: "us-central1",
    // TEMP: App Check enforcement disabled until iOS App Check is registered.
    enforceAppCheck: false,
    secrets: [STRIPE_SECRET_KEY],
  },
  async (request) => {
    try {
      if (!request.auth || !request.auth.uid) {
        throw new HttpsError("unauthenticated", "Unauthenticated");
      }
      const uid = request.auth.uid;

      const data = request.data || {};
      const eventId = typeof data.eventId === "string" ? data.eventId.trim() : "";
      const quantity = data.quantity;

      if (!eventId) {
        throw new HttpsError("invalid-argument", "Missing eventId");
      }

      // Business rule: 1 ticket per user per event.
      // (We still accept a quantity field for backward compatibility, but force it to 1.)
      if (typeof quantity !== "number" || !Number.isInteger(quantity)) {
        throw new HttpsError("invalid-argument", "Invalid quantity");
      }
      if (quantity !== 1) {
        throw new HttpsError(
          "invalid-argument",
          "Only 1 ticket per user is allowed for this event"
        );
      }

      const eventRef = db.collection("events").doc(eventId);

      const eventSnap = await eventRef.get();
      if (!eventSnap.exists) {
        throw new HttpsError("not-found", "Event not found");
      }
      const event = eventSnap.data() || {};

      const capacity = Number.isFinite(event.capacity) ? Number(event.capacity) : 0;
      const sold = Number.isFinite(event.ticketsSold) ? Number(event.ticketsSold) : 0;
      if (capacity > 0 && sold + quantity > capacity) {
        throw new HttpsError("failed-precondition", "Sold out");
      }

      // Fast ownership marker: prevents duplicates across Stripe/webhook/callable paths.
      const ownershipRef = db
        .collection("users")
        .doc(uid)
        .collection("eventTickets")
        .doc(eventId);

      // Legacy/visibility check: if a ticket already exists in the user's mirror, block.
      // This protects users who bought tickets before the ownership marker existed.
      const existingMirror = await db
        .collection("users")
        .doc(uid)
        .collection("tickets")
        .where("eventId", "==", eventId)
        .limit(1)
        .get();
      if (!existingMirror.empty) {
        throw new HttpsError(
          "already-exists",
          "You already have a ticket for this event"
        );
      }

      // Secondary check: some older tickets may not have been mirrored.
      const existingEventTicket = await eventRef
        .collection("tickets")
        .where("userUid", "==", uid)
        .limit(1)
        .get();
      if (!existingEventTicket.empty) {
        throw new HttpsError(
          "already-exists",
          "You already have a ticket for this event"
        );
      }

      // Short-lived purchase lock to prevent double-taps creating multiple PaymentIntents.
      const lockRef = db
        .collection("users")
        .doc(uid)
        .collection("ticketLocks")
        .doc(eventId);

      const nowMs = Date.now();
      const lockExpiresAt = admin.firestore.Timestamp.fromMillis(
        nowMs + 5 * 60 * 1000  // 5 minutes (shorter than before)
      );

      await db.runTransaction(async (txn) => {
        const [ownershipSnap, lockSnap] = await Promise.all([
          txn.get(ownershipRef),
          txn.get(lockRef),
        ]);

        if (ownershipSnap.exists) {
          throw new HttpsError(
            "already-exists",
            "You already have a ticket for this event"
          );
        }

        // Only block if lock is VERY recent (less than 30 seconds old)
        // This allows retries if the payment fails
        if (lockSnap.exists) {
          const lock = lockSnap.data() || {};
          const createdAt = lock.createdAt;
          const createdAtMs =
            createdAt && typeof createdAt.toMillis === "function"
              ? createdAt.toMillis()
              : 0;
          const ageMs = nowMs - createdAtMs;
          
          // Only block if lock is very fresh (less than 30 seconds old)
          // Otherwise allow the user to retry
          if (ageMs < 30 * 1000) {
            throw new HttpsError(
              "failed-precondition",
              "A purchase is already in progress. Try again in a moment."
            );
          }
        }

        txn.set(
          lockRef,
          {
            status: "creating",
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
            expiresAt: lockExpiresAt,
          },
          { merge: true }
        );
      });

      const price = Number(event.price || 0);
      if (!Number.isFinite(price) || price < 0) {
        throw new HttpsError("failed-precondition", "Invalid event price");
      }

      const currency =
        typeof event.currency === "string" && event.currency.trim()
          ? event.currency.trim().toLowerCase()
          : "sek";
      if (!ALLOWED_CURRENCIES.has(currency)) {
        throw new HttpsError(
          "failed-precondition",
          `Unsupported currency. Allowed: ${Array.from(ALLOWED_CURRENCIES).join(", ")}`
        );
      }

      const unitAmount = Math.round(price * 100);
      const amount = unitAmount * quantity;

      // Free event: skip Stripe
      if (amount === 0) {
        return { free: true, amount: 0, currency, unitAmount };
      }
      // Stripe minimum for most currencies is typically >= 50 (e.g. $0.50)
      if (amount < 50) {
        throw new HttpsError("failed-precondition", "Amount below minimum");
      }

      const stripe = new Stripe(STRIPE_SECRET_KEY.value(), {
        apiVersion: "2024-06-20",
      });

      let paymentIntent;
      try {
        paymentIntent = await stripe.paymentIntents.create({
          amount,
          currency,
          automatic_payment_methods: { enabled: true },
          metadata: {
            eventId,
            quantity: "1",
            firebaseUid: uid,
          },
        });
      } catch (e) {
        // Release lock if Stripe call fails.
        try {
          await lockRef.delete();
        } catch (_) {}
        throw e;
      }

      await lockRef.set(
        {
          status: "pending",
          paymentIntentId: paymentIntent.id,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true }
      );

      return {
        clientSecret: paymentIntent.client_secret,
        paymentIntentId: paymentIntent.id,
        amount,
        currency,
        unitAmount,
      };
    } catch (error) {
      console.error("createEventTicketPaymentIntent error:", error);

      if (error instanceof HttpsError) {
        throw error;
      }
      throw new HttpsError("internal", "Unable to create event ticket PaymentIntent");
    }
  }
);

exports.createEventTicketCheckoutSession = onCall(
  {
    region: "us-central1",
    enforceAppCheck: false,
    secrets: [STRIPE_SECRET_KEY],
  },
  async (request) => {
    try {
      if (!request.auth || !request.auth.uid) {
        throw new HttpsError("unauthenticated", "Unauthenticated");
      }
      const uid = request.auth.uid;

      const data = request.data || {};
      const eventId = typeof data.eventId === "string" ? data.eventId.trim() : "";
      const quantity = data.quantity;
      const pageUrl = typeof data.pageUrl === "string" ? data.pageUrl.trim() : "";
      const appId = typeof data.appId === "string" ? data.appId.trim() : "";

      if (!eventId) {
        throw new HttpsError("invalid-argument", "Missing eventId");
      }
      if (typeof quantity !== "number" || !Number.isInteger(quantity)) {
        throw new HttpsError("invalid-argument", "Invalid quantity");
      }
      if (quantity !== 1) {
        throw new HttpsError(
          "invalid-argument",
          "Only 1 ticket per user is allowed for this event"
        );
      }
      if (!pageUrl || !isAllowedCheckoutReturnUrl(pageUrl)) {
        throw new HttpsError("invalid-argument", "Invalid checkout return URL");
      }

      // Resolve a stable UID: prefer the app's ownerUid over the ephemeral anonymous UID.
      // This ensures tickets are always findable even when anonymous sessions expire.
      let effectiveUid = uid;
      if (appId) {
        try {
          const appDoc = await db.collection("applications").doc(appId).get();
          if (appDoc.exists) {
            const appData = appDoc.data() || {};
            if (typeof appData.ownerUid === "string" && appData.ownerUid) {
              effectiveUid = appData.ownerUid;
            }
            // Store the anonymous UID on the application doc so getWebTickets
            // can find tickets purchased under this UID even after the session
            // changes.
            const webUidUpdate = { webUid: uid };
            if (appData.webUid && appData.webUid !== uid) {
              webUidUpdate.webUids = admin.firestore.FieldValue.arrayUnion(appData.webUid, uid);
            } else {
              webUidUpdate.webUids = admin.firestore.FieldValue.arrayUnion(uid);
            }
            await appDoc.ref.set(webUidUpdate, { merge: true });
          }
        } catch (e) {
          console.warn("createEventTicketCheckoutSession: could not resolve ownerUid", e);
        }
      }

      const eventRef = db.collection("events").doc(eventId);
      const eventSnap = await eventRef.get();
      if (!eventSnap.exists) {
        throw new HttpsError("not-found", "Event not found");
      }
      const event = eventSnap.data() || {};

      const capacity = Number.isFinite(event.capacity) ? Number(event.capacity) : 0;
      const sold = Number.isFinite(event.ticketsSold) ? Number(event.ticketsSold) : 0;
      if (capacity > 0 && sold + quantity > capacity) {
        throw new HttpsError("failed-precondition", "Sold out");
      }

      // Check ticket ownership under BOTH the anonymous UID and the effective (stable) UID.
      const ownershipRef = db
        .collection("users")
        .doc(effectiveUid)
        .collection("eventTickets")
        .doc(eventId);

      // Check for existing tickets under both the effective UID and the anonymous UID.
      const uidsToCheck = new Set([uid, effectiveUid]);
      for (const checkUid of uidsToCheck) {
        const existingMirror = await db
          .collection("users")
          .doc(checkUid)
          .collection("tickets")
          .where("eventId", "==", eventId)
          .limit(1)
          .get();
        if (!existingMirror.empty) {
          throw new HttpsError(
            "already-exists",
            "You already have a ticket for this event"
          );
        }

        const existingEventTicket = await eventRef
          .collection("tickets")
          .where("userUid", "==", checkUid)
          .limit(1)
          .get();
        if (!existingEventTicket.empty) {
          throw new HttpsError(
            "already-exists",
            "You already have a ticket for this event"
          );
        }
      }

      // Keep lock under the current anonymous UID (session-specific).
      const lockRef = db
        .collection("users")
        .doc(uid)
        .collection("ticketLocks")
        .doc(eventId);

      const nowMs = Date.now();
      const lockExpiresAt = admin.firestore.Timestamp.fromMillis(
        nowMs + 5 * 60 * 1000
      );

      await db.runTransaction(async (txn) => {
        const [ownershipSnap, lockSnap] = await Promise.all([
          txn.get(ownershipRef),
          txn.get(lockRef),
        ]);

        if (ownershipSnap.exists) {
          throw new HttpsError(
            "already-exists",
            "You already have a ticket for this event"
          );
        }

        if (lockSnap.exists) {
          const lock = lockSnap.data() || {};
          const createdAt = lock.createdAt;
          const createdAtMs =
            createdAt && typeof createdAt.toMillis === "function"
              ? createdAt.toMillis()
              : 0;
          const ageMs = nowMs - createdAtMs;

          if (ageMs < 30 * 1000) {
            throw new HttpsError(
              "failed-precondition",
              "A purchase is already in progress. Try again in a moment."
            );
          }
        }

        txn.set(
          lockRef,
          {
            status: "creating_checkout",
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
            expiresAt: lockExpiresAt,
          },
          {merge: true}
        );
      });

      const price = Number(event.price || 0);
      if (!Number.isFinite(price) || price < 0) {
        throw new HttpsError("failed-precondition", "Invalid event price");
      }

      const currency =
        typeof event.currency === "string" && event.currency.trim()
          ? event.currency.trim().toLowerCase()
          : "sek";
      if (!ALLOWED_CURRENCIES.has(currency)) {
        throw new HttpsError(
          "failed-precondition",
          `Unsupported currency. Allowed: ${Array.from(ALLOWED_CURRENCIES).join(", ")}`
        );
      }

      const unitAmount = Math.round(price * 100);
      const amount = unitAmount * quantity;

      if (amount === 0) {
        return {free: true, amount: 0, currency, unitAmount};
      }
      if (amount < 50) {
        throw new HttpsError("failed-precondition", "Amount below minimum");
      }

      const stripe = new Stripe(STRIPE_SECRET_KEY.value(), {
        apiVersion: "2024-06-20",
      });

      const eventTitle =
        typeof event.title === "string" && event.title.trim()
          ? event.title.trim()
          : "TEK Event";
      const lineItemName = `${eventTitle} Ticket`;
      const successUrl = buildCheckoutReturnUrl(pageUrl, "success", {
        session_id: "{CHECKOUT_SESSION_ID}",
        event_id: eventId,
      });
      const cancelUrl = buildCheckoutReturnUrl(pageUrl, "cancel", {
        event_id: eventId,
      });

      let session;
      try {
        const user = await findUserEmailForUid(uid);
        const sessionParams = {
          mode: "payment",
          client_reference_id: uid,
          success_url: successUrl,
          cancel_url: cancelUrl,
          ...(currency === "sek" ? {locale: "sv"} : {}),
          line_items: [
            {
              quantity,
              price_data: {
                currency,
                unit_amount: unitAmount,
                product_data: {
                  name: lineItemName,
                  description: "Event ticket",
                },
              },
            },
          ],
          ...(user && user.email ? {customer_email: user.email} : {}),
          payment_intent_data: {
            metadata: {
              eventId,
              quantity: "1",
              firebaseUid: effectiveUid,
              ...(appId ? { appId } : {}),
            },
          },
          metadata: {
            eventId,
            firebaseUid: effectiveUid,
            ...(appId ? { appId } : {}),
          },
        };

        if (currency === "sek") {
          try {
            session = await stripe.checkout.sessions.create({
              ...sessionParams,
              billing_address_collection: "required",
              payment_method_types: ["card", "klarna"],
            });
            console.log("Created Checkout session with Klarna enabled", {
              uid,
              eventId,
            });
          } catch (klarnaError) {
            const message =
              klarnaError && typeof klarnaError === "object" && "message" in klarnaError
                ? String(klarnaError.message)
                : String(klarnaError);
            console.warn("Klarna unavailable for Checkout session, falling back", {
              uid,
              eventId,
              message,
            });
            session = await stripe.checkout.sessions.create(sessionParams);
          }
        } else {
          session = await stripe.checkout.sessions.create(sessionParams);
        }
      } catch (e) {
        try {
          await lockRef.delete();
        } catch (_) {}
        throw e;
      }

      await lockRef.set(
        {
          status: "checkout_pending",
          checkoutSessionId: session.id,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        {merge: true}
      );

      console.log("Created event ticket Checkout session", {
        uid,
        eventId,
        sessionId: session.id,
      });

      return {
        sessionId: session.id,
        url: session.url,
        amount,
        currency,
        unitAmount,
      };
    } catch (error) {
      console.error("createEventTicketCheckoutSession error:", error);

      if (error instanceof HttpsError) {
        throw error;
      }
      throw new HttpsError("internal", "Unable to create event ticket checkout session");
    }
  }
);

exports.getEventTicketCheckoutStatus = onCall(
  {
    region: "us-central1",
    enforceAppCheck: false,
    secrets: [STRIPE_SECRET_KEY, MAIL_SENDER_EMAIL, MAIL_SENDER_PASSWORD],
  },
  async (request) => {
    try {
      if (!request.auth || !request.auth.uid) {
        throw new HttpsError("unauthenticated", "Unauthenticated");
      }
      const uid = request.auth.uid;

      const data = request.data || {};
      const sessionId = typeof data.sessionId === "string" ? data.sessionId.trim() : "";
      if (!sessionId) {
        throw new HttpsError("invalid-argument", "Missing sessionId");
      }

      const stripe = new Stripe(STRIPE_SECRET_KEY.value(), {
        apiVersion: "2024-06-20",
      });

      const session = await stripe.checkout.sessions.retrieve(sessionId, {
        expand: ["payment_intent"],
      });

      // Resolve all UIDs linked to this user's application (handles anonymous UID changes).
      const appId = typeof data.appId === "string" ? data.appId.trim() : "";
      const linkedUids = new Set([uid]);
      if (appId) {
        try {
          const appDoc = await db.collection("applications").doc(appId).get();
          if (appDoc.exists) {
            const ad = appDoc.data() || {};
            if (ad.ownerUid) linkedUids.add(ad.ownerUid);
            if (ad.webUid) linkedUids.add(ad.webUid);
            if (Array.isArray(ad.webUids)) {
              ad.webUids.forEach((w) => { if (typeof w === "string" && w) linkedUids.add(w); });
            }
          }
        } catch (e) {
          console.warn("getEventTicketCheckoutStatus: could not resolve linked UIDs", e);
        }
      }

      if (session.client_reference_id && !linkedUids.has(session.client_reference_id)) {
        throw new HttpsError("permission-denied", "Checkout session does not belong to user");
      }

      const paymentIntentId =
        typeof session.payment_intent === "string"
          ? session.payment_intent
          : session.payment_intent && typeof session.payment_intent.id === "string"
            ? session.payment_intent.id
            : "";

      let paymentIntent =
        session.payment_intent && typeof session.payment_intent === "object"
          ? session.payment_intent
          : null;

      if (!paymentIntent && paymentIntentId) {
        paymentIntent = await stripe.paymentIntents.retrieve(paymentIntentId);
      }

      const metadata = paymentIntent && paymentIntent.metadata ? paymentIntent.metadata : {};
      const eventId = typeof metadata.eventId === "string" ? metadata.eventId.trim() : "";

      if (metadata.firebaseUid && !linkedUids.has(metadata.firebaseUid)) {
        throw new HttpsError("permission-denied", "Payment does not belong to user");
      }

      let ticketReady = false;
      if (paymentIntent && paymentIntent.status === "succeeded") {
        await fulfillEventTicketFromPaymentIntent(paymentIntent);

        // Check ticket ownership under the UID used in the payment metadata.
        const ticketUid = metadata.firebaseUid || uid;
        if (eventId) {
          const ownershipSnap = await db
            .collection("users")
            .doc(ticketUid)
            .collection("eventTickets")
            .doc(eventId)
            .get();
          ticketReady = ownershipSnap.exists;
        }
      }

      return {
        sessionId: session.id,
        status:
          session.payment_status === "paid"
            ? "paid"
            : session.status === "expired"
              ? "expired"
              : session.status,
        paymentStatus: session.payment_status,
        paymentIntentId,
        eventId,
        ticketReady,
      };
    } catch (error) {
      console.error("getEventTicketCheckoutStatus error:", error);

      if (error instanceof HttpsError) {
        throw error;
      }
      throw new HttpsError("internal", "Unable to verify checkout status");
    }
  }
);

async function fulfillEventTicketFromPaymentIntent(paymentIntent) {
  const md = paymentIntent.metadata || {};
  const eventId = typeof md.eventId === "string" ? md.eventId.trim() : "";
  const quantity = Number.parseInt(String(md.quantity || ""), 10);
  const uid = typeof md.firebaseUid === "string" ? md.firebaseUid.trim() : "";

  if (!eventId || !uid || !Number.isInteger(quantity) || quantity !== 1) {
    throw new Error("Invalid metadata");
  }

  const eventRef = db.collection("events").doc(eventId);
  const ticketRef = eventRef.collection("tickets").doc(paymentIntent.id);
  const userTicketRef = db
    .collection("users")
    .doc(uid)
    .collection("tickets")
    .doc(paymentIntent.id);

  const ownershipRef = db
    .collection("users")
    .doc(uid)
    .collection("eventTickets")
    .doc(eventId);
  const lockRef = db
    .collection("users")
    .doc(uid)
    .collection("ticketLocks")
    .doc(eventId);

  await db.runTransaction(async (txn) => {
    const ownershipSnap = await txn.get(ownershipRef);
    if (ownershipSnap.exists) {
      // Ticket already owned for this event; do not mint more tickets.
      return;
    }

    const existing = await txn.get(ticketRef);
    if (existing.exists) {
      txn.set(
        ownershipRef,
        {
          ticketId: ticketRef.id,
          eventId,
          status: "owned",
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true }
      );
      txn.delete(lockRef);
      return; // idempotent
    }

    const eventSnap = await txn.get(eventRef);
    if (!eventSnap.exists) {
      throw new Error("Event not found");
    }

    const event = eventSnap.data() || {};
    const capacity = Number.isFinite(event.capacity) ? Number(event.capacity) : 0;
    const sold = Number.isFinite(event.ticketsSold) ? Number(event.ticketsSold) : 0;
    if (capacity > 0 && sold + quantity > capacity) {
      // Note: without reservation holds, this can happen during race conditions.
      // Prefer adding reservations if you need strict anti-oversell.
      throw new Error("Sold out");
    }

    txn.set(ticketRef, {
      userUid: uid,
      quantity,
      purchasedAt: admin.firestore.FieldValue.serverTimestamp(),
      paymentProvider: "stripe",
      paymentIntentId: paymentIntent.id,
      amount: paymentIntent.amount,
      currency: paymentIntent.currency,
      source: "stripe_webhook",
    });

    // Mirror for fast, secure per-user reads.
    txn.set(userTicketRef, {
      userUid: uid,
      eventId,
      eventTitle: typeof event.title === "string" ? event.title : null,
      startAt: event.startAt || null,
      location: typeof event.location === "string" ? event.location : null,
      imageUrl: typeof event.imageUrl === "string" ? event.imageUrl : null,
      ticketCode: ticketRef.id,
      quantity,
      purchasedAt: admin.firestore.FieldValue.serverTimestamp(),
      paymentProvider: "stripe",
      paymentIntentId: paymentIntent.id,
      amount: paymentIntent.amount,
      currency: paymentIntent.currency,
      eventTicketPath: ticketRef.path,
    }, { merge: true });

    txn.set(
      ownershipRef,
      {
        ticketId: ticketRef.id,
        eventId,
        status: "owned",
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true }
    );

    txn.delete(lockRef);

    txn.update(eventRef, { ticketsSold: sold + quantity });
  });

  // Best-effort: link ticket UID to application doc so getWebTickets can find it.
  const metadataAppId = typeof md.appId === "string" ? md.appId.trim() : "";
  if (metadataAppId) {
    try {
      const appDocRef = db.collection("applications").doc(metadataAppId);
      const appDocSnap = await appDocRef.get();
      if (appDocSnap.exists) {
        const ad = appDocSnap.data() || {};
        const webUidUpdate = { webUid: uid };
        if (ad.webUid && ad.webUid !== uid) {
          webUidUpdate.webUids = admin.firestore.FieldValue.arrayUnion(ad.webUid, uid);
        } else {
          webUidUpdate.webUids = admin.firestore.FieldValue.arrayUnion(uid);
        }
        await appDocRef.set(webUidUpdate, { merge: true });
      }
    } catch (e) {
      console.warn("fulfillEventTicket: could not link UID to application", e);
    }
  }

  // Best-effort: award 150 XP for ticket purchase (idempotent).
  try {
    await awardTicketPurchaseXp(uid, eventId);
  } catch (e) {
    console.error("fulfillEventTicket XP award failed:", e);
  }

  // Best-effort: check if this buyer was invited and triggers the inviter's free ticket milestone.
  try {
    const buyerApp = await db.collection("applications").where("ownerUid", "==", uid).limit(1).get();
    if (!buyerApp.empty) {
      const buyerData = buyerApp.docs[0].data() || {};
      if (buyerData.invitedByInviteCode) {
        await checkInviterFreeTicketMilestone(buyerData.invitedByInviteCode);
      }
    }
  } catch (e) {
    console.error("fulfillEventTicket invite milestone check failed:", e);
  }

  // Send confirmation email (best-effort). Read the ticket we just created.
  try {
    const ticketSnap = await ticketRef.get();
    if (ticketSnap.exists) {
      await maybeSendTicketConfirmationEmail({
        uid,
        eventId,
        ticketRef,
        ticketData: ticketSnap.data() || {},
        source: "stripe_webhook",
      });
    }
  } catch (e) {
    console.error("Post-fulfillment email step failed:", e);
  }
}

// Callable: backfill /users/{uid}/tickets/* from existing event tickets.
// This helps users see past purchases after schema changes.
exports.backfillMyTickets = onCall(
  {
    region: "us-central1",
    enforceAppCheck: false,
  },
  async (request) => {
    try {
      if (!request.auth || !request.auth.uid) {
        throw new HttpsError("unauthenticated", "Unauthenticated");
      }
      const uid = request.auth.uid;
      const limit =
        request.data && Number.isInteger(request.data.limit) && request.data.limit > 0
          ? Math.min(request.data.limit, 200)
          : 200;

      // Avoid collectionGroup queries here; in this project they can fail with
      // FAILED_PRECONDITION (indexing/override issues). Instead, use the ownership
      // markers we maintain at /users/{uid}/eventTickets/{eventId}.
      const ownershipSnap = await db
        .collection("users")
        .doc(uid)
        .collection("eventTickets")
        .limit(limit)
        .get();

      if (ownershipSnap.empty) {
        return { backfilled: 0 };
      }

      const pairs = [];
      const eventIdSet = new Set();
      for (const doc of ownershipSnap.docs) {
        const eventId = doc.id;
        const d = doc.data() || {};
        const ticketId = typeof d.ticketId === "string" ? d.ticketId.trim() : "";
        if (!eventId || !ticketId) continue;
        pairs.push({ eventId, ticketId });
        eventIdSet.add(eventId);
      }

      if (pairs.length === 0) {
        return { backfilled: 0 };
      }

      // Fetch event docs in chunks.
      const eventById = new Map();
      const eventIds = Array.from(eventIdSet);
      for (let i = 0; i < eventIds.length; i += 50) {
        const chunk = eventIds.slice(i, i + 50);
        const refs = chunk.map((id) => db.collection("events").doc(id));
        const snaps = await db.getAll(...refs);
        for (let j = 0; j < snaps.length; j++) {
          const s = snaps[j];
          if (s.exists) eventById.set(chunk[j], s.data() || {});
        }
      }

      // Fetch ticket docs in chunks.
      const ticketKeyToData = new Map();
      for (let i = 0; i < pairs.length; i += 50) {
        const chunk = pairs.slice(i, i + 50);
        const refs = chunk.map((p) =>
          db.collection("events").doc(p.eventId).collection("tickets").doc(p.ticketId)
        );
        const snaps = await db.getAll(...refs);
        for (let j = 0; j < snaps.length; j++) {
          const s = snaps[j];
          if (!s.exists) continue;
          const key = `${chunk[j].eventId}/${chunk[j].ticketId}`;
          ticketKeyToData.set(key, s.data() || {});
        }
      }

      let count = 0;
      let batch = db.batch();
      let ops = 0;

      for (const p of pairs) {
        const key = `${p.eventId}/${p.ticketId}`;
        const ticketData = ticketKeyToData.get(key);
        if (!ticketData) continue;

        const event = eventById.get(p.eventId) || {};
        const eventTitle = typeof event.title === "string" ? event.title : null;
        const startAt = event.startAt || null;
        const location = typeof event.location === "string" ? event.location : null;
        const imageUrl = typeof event.imageUrl === "string" ? event.imageUrl : null;

        const ticketRef = db
          .collection("events")
          .doc(p.eventId)
          .collection("tickets")
          .doc(p.ticketId);

        const userTicketRef = db
          .collection("users")
          .doc(uid)
          .collection("tickets")
          .doc(p.ticketId);

        batch.set(
          userTicketRef,
          {
            userUid: uid,
            eventId: p.eventId,
            eventTitle,
            startAt,
            location,
            imageUrl,
            ticketCode: p.ticketId,
            quantity: Number.isFinite(ticketData.quantity) ? ticketData.quantity : 1,
            purchasedAt:
              ticketData.purchasedAt || admin.firestore.FieldValue.serverTimestamp(),
            paymentProvider: ticketData.paymentProvider || "ticket",
            paymentIntentId: ticketData.paymentIntentId || p.ticketId,
            amount: ticketData.amount || null,
            currency: ticketData.currency || null,
            eventTicketPath: ticketRef.path,
          },
          { merge: true }
        );
        ops += 1;
        count += 1;

        if (ops >= 450) {
          await batch.commit();
          batch = db.batch();
          ops = 0;
        }
      }

      if (ops > 0) {
        await batch.commit();
      }

      return { backfilled: count };
    } catch (error) {
      console.error("backfillMyTickets error:", error);
      if (error instanceof HttpsError) throw error;
      throw new HttpsError("internal", "Backfill failed");
    }
  }
);

// Callable: fetch tickets for a website user by looking up all UIDs linked to their
// application (current anonymous UID, ownerUid from app, historical webUids).
// This solves the problem where anonymous UID changes between sessions or where
// app-purchased tickets live under a different UID than the web anonymous UID.
exports.getWebTickets = onCall(
  {
    region: "us-central1",
    enforceAppCheck: false,
  },
  async (request) => {
    try {
      if (!request.auth || !request.auth.uid) {
        throw new HttpsError("unauthenticated", "Unauthenticated");
      }
      const uid = request.auth.uid;

      const data = request.data || {};
      const appId = typeof data.appId === "string" ? data.appId.trim() : "";
      const sessionId = typeof data.sessionId === "string" ? data.sessionId.trim() : "";

      if (!appId || !sessionId) {
        throw new HttpsError("invalid-argument", "Missing appId or sessionId");
      }

      const appDoc = await db.collection("applications").doc(appId).get();
      if (!appDoc.exists) {
        throw new HttpsError("not-found", "Application not found");
      }

      const appData = appDoc.data() || {};

      // Verify session is valid
      if (appData.activeSessionId !== sessionId) {
        throw new HttpsError("permission-denied", "Invalid or expired session");
      }

      // Ensure current anonymous UID is tracked on the application doc so
      // tickets purchased under this UID can be found in future sessions.
      try {
        const webUidUpdate = { webUid: uid };
        if (appData.webUid && appData.webUid !== uid) {
          webUidUpdate.webUids = admin.firestore.FieldValue.arrayUnion(appData.webUid, uid);
        } else {
          webUidUpdate.webUids = admin.firestore.FieldValue.arrayUnion(uid);
        }
        await appDoc.ref.set(webUidUpdate, { merge: true });
      } catch (e) {
        console.warn("getWebTickets: could not update webUid", e);
      }

      // Collect all UIDs associated with this user
      const uids = new Set();
      uids.add(uid); // current anonymous UID
      if (typeof appData.ownerUid === "string" && appData.ownerUid) {
        uids.add(appData.ownerUid); // app UID
      }
      if (typeof appData.webUid === "string" && appData.webUid) {
        uids.add(appData.webUid); // latest web UID
      }
      if (Array.isArray(appData.webUids)) {
        for (const wuid of appData.webUids) {
          if (typeof wuid === "string" && wuid) uids.add(wuid);
        }
      }

      // Fetch tickets from all UIDs using Admin SDK (bypasses Firestore rules)
      const allTickets = new Map();
      for (const searchUid of uids) {
        try {
          const snap = await db
            .collection("users")
            .doc(searchUid)
            .collection("tickets")
            .get();
          for (const doc of snap.docs) {
            if (!allTickets.has(doc.id)) {
              const d = doc.data() || {};
              allTickets.set(doc.id, {
                id: doc.id,
                eventId: d.eventId || null,
                eventTitle: d.eventTitle || null,
                startAt: d.startAt && typeof d.startAt.toMillis === "function"
                  ? d.startAt.toMillis()
                  : d.startAt || null,
                location: d.location || null,
                imageUrl: d.imageUrl || null,
                ticketCode: d.ticketCode || doc.id,
                quantity: d.quantity || 1,
                purchasedAt: d.purchasedAt && typeof d.purchasedAt.toMillis === "function"
                  ? d.purchasedAt.toMillis()
                  : d.purchasedAt || null,
                paymentProvider: d.paymentProvider || null,
                amount: d.amount || null,
                currency: d.currency || null,
              });
            }
          }
        } catch (e) {
          console.warn("getWebTickets: error fetching tickets for uid", searchUid, e);
        }
      }

      console.log("getWebTickets: found", allTickets.size, "tickets across", uids.size, "UIDs");
      return { tickets: Array.from(allTickets.values()) };
    } catch (error) {
      console.error("getWebTickets error:", error);
      if (error instanceof HttpsError) throw error;
      throw new HttpsError("internal", "Unable to fetch tickets");
    }
  }
);

// Callable: dedupe tickets so each user has at most one ticket per event.
// Deletes duplicate docs under /events/{eventId}/tickets and their mirrors under /users/{uid}/tickets,
// decrements events.ticketsSold accordingly, and repairs /users/{uid}/eventTickets/{eventId} marker.
exports.dedupeMyTickets = onCall(
  {
    region: "us-central1",
    enforceAppCheck: false,
  },
  async (request) => {
    try {
      if (!request.auth || !request.auth.uid) {
        throw new HttpsError("unauthenticated", "Unauthenticated");
      }

      const uid = request.auth.uid;
      const data = request.data || {};
      const requestedEventId =
        typeof data.eventId === "string" && data.eventId.trim() ? data.eventId.trim() : null;

      const maxEvents =
        Number.isInteger(data.maxEvents) && data.maxEvents > 0
          ? Math.min(data.maxEvents, 50)
          : 50;

      const limit =
        Number.isInteger(data.limit) && data.limit > 0 ? Math.min(data.limit, 500) : 500;

      const eventIds = new Set();

      if (requestedEventId) {
        eventIds.add(requestedEventId);
      } else {
        // Prefer ownership markers, then fall back to whatever is in the user's mirror.
        const ownershipSnap = await db
          .collection("users")
          .doc(uid)
          .collection("eventTickets")
          .limit(limit)
          .get();
        for (const doc of ownershipSnap.docs) {
          if (doc.id) eventIds.add(doc.id);
        }

        const mirrorSnap = await db
          .collection("users")
          .doc(uid)
          .collection("tickets")
          .limit(limit)
          .get();
        for (const doc of mirrorSnap.docs) {
          const d = doc.data() || {};
          const eventId = typeof d.eventId === "string" ? d.eventId.trim() : "";
          if (eventId) eventIds.add(eventId);
        }
      }

      const eventIdList = Array.from(eventIds).slice(0, maxEvents);
      if (eventIdList.length === 0) {
        return { dedupedEvents: 0, deletedTickets: 0 };
      }

      let dedupedEvents = 0;
      let deletedTickets = 0;
      let deletedMirrors = 0;

      for (const eventId of eventIdList) {
        const eventRef = db.collection("events").doc(eventId);
        const [ticketsSnap, mirrorSnap, ownershipSnap] = await Promise.all([
          eventRef
            .collection("tickets")
            .where("userUid", "==", uid)
            .limit(50)
            .get(),
          db
            .collection("users")
            .doc(uid)
            .collection("tickets")
            .where("eventId", "==", eventId)
            .limit(50)
            .get(),
          db
            .collection("users")
            .doc(uid)
            .collection("eventTickets")
            .doc(eventId)
            .get(),
        ]);

        const eventTickets = ticketsSnap.docs.map((d) => ({
          ref: d.ref,
          id: d.id,
          data: d.data() || {},
        }));

        const mirrorTickets = mirrorSnap.docs.map((d) => ({
          ref: d.ref,
          id: d.id,
          data: d.data() || {},
        }));

        // No duplicates anywhere.
        if (eventTickets.length <= 1 && mirrorTickets.length <= 1) continue;

        const ownedTicketId = ownershipSnap.exists
          ? typeof (ownershipSnap.data() || {}).ticketId === "string"
            ? (ownershipSnap.data() || {}).ticketId.trim()
            : ""
          : "";

        const pickNewestId = (arr) => {
          if (!Array.isArray(arr) || arr.length === 0) return "";
          const copy = arr.slice();
          copy.sort((a, b) => {
            const aAt =
              a.data && a.data.purchasedAt && typeof a.data.purchasedAt.toMillis === "function"
                ? a.data.purchasedAt.toMillis()
                : 0;
            const bAt =
              b.data && b.data.purchasedAt && typeof b.data.purchasedAt.toMillis === "function"
                ? b.data.purchasedAt.toMillis()
                : 0;
            if (aAt !== bAt) return bAt - aAt;
            return String(b.id).localeCompare(String(a.id));
          });
          return copy[0].id;
        };

        let keepId = "";
        if (ownedTicketId) {
          keepId = ownedTicketId;
        } else {
          keepId = pickNewestId(eventTickets) || pickNewestId(mirrorTickets);
        }
        if (!keepId) continue;

        const toDeleteEvent = eventTickets.filter((t) => t.id !== keepId);
        const toDeleteMirror = mirrorTickets.filter((t) => t.id !== keepId);
        if (toDeleteEvent.length === 0 && toDeleteMirror.length === 0) {
          // Still ensure ownership marker exists.
          if (!ownedTicketId) {
            await db
              .collection("users")
              .doc(uid)
              .collection("eventTickets")
              .doc(eventId)
              .set(
                {
                  ticketId: keepId,
                  eventId,
                  status: "owned",
                  updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                },
                { merge: true }
              );
          }
          continue;
        }

        const ownershipRef = db
          .collection("users")
          .doc(uid)
          .collection("eventTickets")
          .doc(eventId);
        const lockRef = db
          .collection("users")
          .doc(uid)
          .collection("ticketLocks")
          .doc(eventId);

        await db.runTransaction(async (txn) => {
          const eventSnap = await txn.get(eventRef);
          const sold = eventSnap.exists
            ? Number.isFinite(eventSnap.data()?.ticketsSold)
              ? Number(eventSnap.data().ticketsSold)
              : 0
            : 0;

          let decrementBy = 0;
          for (const t of toDeleteEvent) {
            const q = t.data && Number.isFinite(t.data.quantity) ? Number(t.data.quantity) : 1;
            decrementBy += q;
          }

          if (eventSnap.exists && decrementBy > 0) {
            txn.update(eventRef, { ticketsSold: Math.max(0, sold - decrementBy) });
          }

          for (const t of toDeleteEvent) {
            txn.delete(t.ref);
          }

          for (const t of toDeleteMirror) {
            txn.delete(t.ref);
          }

          txn.set(
            ownershipRef,
            {
              ticketId: keepId,
              eventId,
              status: "owned",
              updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            },
            { merge: true }
          );

          // Ensure mirror exists for keepId.
          const keepEventTicket = eventTickets.find((t) => t.id === keepId) || null;
          const keepMirror = mirrorTickets.find((t) => t.id === keepId) || null;

          if (keepEventTicket) {
            txn.set(
              db.collection("users").doc(uid).collection("tickets").doc(keepId),
              {
                userUid: uid,
                eventId,
                ticketCode: keepId,
                quantity:
                  keepEventTicket.data && Number.isFinite(keepEventTicket.data.quantity)
                    ? keepEventTicket.data.quantity
                    : 1,
                purchasedAt:
                  (keepEventTicket.data && keepEventTicket.data.purchasedAt) ||
                  admin.firestore.FieldValue.serverTimestamp(),
                paymentProvider:
                  keepEventTicket.data ? keepEventTicket.data.paymentProvider || "ticket" : "ticket",
                paymentIntentId:
                  keepEventTicket.data ? keepEventTicket.data.paymentIntentId || keepId : keepId,
                amount: keepEventTicket.data ? keepEventTicket.data.amount || null : null,
                currency: keepEventTicket.data ? keepEventTicket.data.currency || null : null,
                eventTicketPath: keepEventTicket.ref.path,
              },
              { merge: true }
            );
          } else if (keepMirror) {
            txn.set(
              db.collection("users").doc(uid).collection("tickets").doc(keepId),
              {
                userUid: uid,
                eventId,
                ticketCode: keepId,
                quantity:
                  keepMirror.data && Number.isFinite(keepMirror.data.quantity)
                    ? keepMirror.data.quantity
                    : 1,
                purchasedAt:
                  (keepMirror.data && keepMirror.data.purchasedAt) ||
                  admin.firestore.FieldValue.serverTimestamp(),
              },
              { merge: true }
            );
          }

          txn.delete(lockRef);
        });

        dedupedEvents += 1;
        deletedTickets += toDeleteEvent.length;
        deletedMirrors += toDeleteMirror.length;
      }

      return { dedupedEvents, deletedTickets, deletedMirrors };
    } catch (error) {
      console.error("dedupeMyTickets error:", error);
      if (error instanceof HttpsError) throw error;
      throw new HttpsError("internal", "Dedupe failed");
    }
  }
);

// Callable: finalize a ticket purchase.
// Validates the PaymentIntent succeeded (or free=true), then writes ticket and increments ticketsSold.
// Client data: { eventId: string, quantity: number, paymentIntentId?: string, free?: boolean }
exports.finalizeEventTicketPurchase = onCall(
  {
    region: "us-central1",
    // TEMP: App Check enforcement disabled until iOS App Check is registered.
    enforceAppCheck: false,
    secrets: [STRIPE_SECRET_KEY, MAIL_SENDER_EMAIL, MAIL_SENDER_PASSWORD],
  },
  async (request) => {
    try {
      if (!request.auth || !request.auth.uid) {
        throw new HttpsError("unauthenticated", "Unauthenticated");
      }
      const uid = request.auth.uid;

      const data = request.data || {};
      const eventId = typeof data.eventId === "string" ? data.eventId.trim() : "";
      const quantity = data.quantity;
      const isFree = data.free === true;
      const paymentIntentId =
        typeof data.paymentIntentId === "string" ? data.paymentIntentId.trim() : "";
      const appId = typeof data.appId === "string" ? data.appId.trim() : "";

      if (!eventId) throw new HttpsError("invalid-argument", "Missing eventId");
      if (typeof quantity !== "number" || !Number.isInteger(quantity)) {
        throw new HttpsError("invalid-argument", "Invalid quantity");
      }
      if (quantity !== 1) {
        throw new HttpsError(
          "invalid-argument",
          "Only 1 ticket per user is allowed for this event"
        );
      }

      // Resolve stable UID: prefer ownerUid from application over ephemeral anonymous UID.
      let effectiveUid = uid;
      if (appId) {
        try {
          const appDoc = await db.collection("applications").doc(appId).get();
          if (appDoc.exists) {
            const appData = appDoc.data() || {};
            if (typeof appData.ownerUid === "string" && appData.ownerUid) {
              effectiveUid = appData.ownerUid;
            }
          }
        } catch (e) {
          console.warn("finalizeEventTicketPurchase: could not resolve ownerUid", e);
        }
      }
      const linkedUids = new Set([uid, effectiveUid]);

      let paymentIntent = null;
      if (!isFree) {
        if (!paymentIntentId) {
          throw new HttpsError("invalid-argument", "Missing paymentIntentId");
        }
        const stripe = new Stripe(STRIPE_SECRET_KEY.value(), {
          apiVersion: "2024-06-20",
        });
        paymentIntent = await stripe.paymentIntents.retrieve(paymentIntentId);

        if (!paymentIntent || paymentIntent.status !== "succeeded") {
          throw new HttpsError("failed-precondition", "Payment not completed");
        }
        const md = paymentIntent.metadata || {};
        if (md.eventId !== eventId) {
          throw new HttpsError("failed-precondition", "Payment mismatch");
        }
        if (String(md.quantity) !== "1") {
          throw new HttpsError("failed-precondition", "Quantity mismatch");
        }
        if (md.firebaseUid && !linkedUids.has(md.firebaseUid)) {
          throw new HttpsError("failed-precondition", "User mismatch");
        }
        // Use the UID from payment metadata if it differs (it may be the stable ownerUid).
        if (md.firebaseUid && md.firebaseUid !== uid) {
          effectiveUid = md.firebaseUid;
        }
      }

      const eventRef = db.collection("events").doc(eventId);
      const ticketId = isFree ? `free_${effectiveUid}` : paymentIntentId;

      const ownershipRef = db
        .collection("users")
        .doc(effectiveUid)
        .collection("eventTickets")
        .doc(eventId);
      // Keep lock under the caller's anonymous UID (session-specific).
      const lockRef = db
        .collection("users")
        .doc(uid)
        .collection("ticketLocks")
        .doc(eventId);

      let createdTicketRef = null;

      await db.runTransaction(async (txn) => {
        const snap = await txn.get(eventRef);
        if (!snap.exists) throw new Error("Event not found");
        const event = snap.data() || {};
        const capacity = Number.isFinite(event.capacity) ? Number(event.capacity) : 0;
        const sold = Number.isFinite(event.ticketsSold) ? Number(event.ticketsSold) : 0;
        if (capacity > 0 && sold + quantity > capacity) {
          throw new Error("Sold out");
        }

        const ownedSnap = await txn.get(ownershipRef);
        if (ownedSnap.exists) {
          const owned = ownedSnap.data() || {};
          if (owned.ticketId && String(owned.ticketId) === String(ticketId)) {
            // Idempotent finalize call.
            createdTicketRef = eventRef.collection("tickets").doc(ticketId);
            txn.delete(lockRef);
            return;
          }
          throw new HttpsError(
            "already-exists",
            "You already have a ticket for this event"
          );
        }

        const ticketRef = eventRef.collection("tickets").doc(ticketId);
        const existing = await txn.get(ticketRef);
        if (existing.exists) {
          createdTicketRef = ticketRef;
        } else if (!isFree) {
          txn.set(ticketRef, {
            userUid: effectiveUid,
            quantity,
            purchasedAt: admin.firestore.FieldValue.serverTimestamp(),
            paymentProvider: "stripe",
            paymentIntentId: ticketId,
            amount: paymentIntent.amount,
            currency: paymentIntent.currency,
          });
          createdTicketRef = ticketRef;
        } else {
          txn.set(ticketRef, {
            userUid: effectiveUid,
            quantity,
            purchasedAt: admin.firestore.FieldValue.serverTimestamp(),
            paymentProvider: "free",
          });
          createdTicketRef = ticketRef;
        }

        const userTicketRef = db
          .collection("users")
          .doc(effectiveUid)
          .collection("tickets")
          .doc(ticketId);

        const eventTitle =
          typeof event.title === "string" && event.title.trim()
            ? event.title.trim()
            : "Event";
        const eventLocation =
          typeof event.location === "string" ? event.location.trim() : "";
        const eventStartAt = event.startAt || null;
        const eventImageUrl =
          typeof event.imageUrl === "string" ? event.imageUrl.trim() : "";

        if (!existing.exists) {
          txn.set(userTicketRef, {
            userUid: effectiveUid,
            eventId,
            eventTitle,
            startAt: eventStartAt,
            location: eventLocation,
            imageUrl: eventImageUrl,
            quantity,
            purchasedAt: admin.firestore.FieldValue.serverTimestamp(),
            paymentProvider: isFree ? "free" : "stripe",
            ...(isFree ? {} : { paymentIntentId: ticketId }),
            ...(isFree
              ? {}
              : { amount: paymentIntent.amount, currency: paymentIntent.currency }),
            eventTicketPath: ticketRef.path,
          });
          txn.update(eventRef, { ticketsSold: sold + quantity });
        } else {
          // Ticket already exists (idempotent), ensure mirror exists.
          txn.set(
            userTicketRef,
            {
              userUid: effectiveUid,
              eventId,
              eventTitle,
              startAt: eventStartAt,
              location: eventLocation,
              imageUrl: eventImageUrl,
              quantity,
              purchasedAt:
                existing.data()?.purchasedAt ||
                admin.firestore.FieldValue.serverTimestamp(),
              paymentProvider: existing.data()?.paymentProvider || (isFree ? "free" : "stripe"),
              paymentIntentId: existing.data()?.paymentIntentId || ticketId,
              amount: existing.data()?.amount || (paymentIntent ? paymentIntent.amount : null),
              currency:
                existing.data()?.currency ||
                (paymentIntent ? paymentIntent.currency : null),
              eventTicketPath: ticketRef.path,
            },
            { merge: true }
          );
        }

        txn.set(
          ownershipRef,
          {
            ticketId,
            eventId,
            status: "owned",
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          },
          { merge: true }
        );

        txn.delete(lockRef);
      });

      // Best-effort: award 150 XP for ticket purchase (idempotent).
      try {
        await awardTicketPurchaseXp(effectiveUid, eventId);
      } catch (e) {
        console.error("finalizeEventTicketPurchase XP award failed:", e);
      }

      // Best-effort: check if this buyer was invited and triggers the inviter's free ticket milestone.
      try {
        const buyerApp = await db.collection("applications").where("ownerUid", "==", effectiveUid).limit(1).get();
        if (!buyerApp.empty) {
          const buyerData = buyerApp.docs[0].data() || {};
          if (buyerData.invitedByInviteCode) {
            await checkInviterFreeTicketMilestone(buyerData.invitedByInviteCode);
          }
        }
      } catch (e) {
        console.error("finalizeEventTicketPurchase invite milestone check failed:", e);
      }

      // Best-effort confirmation email.
      if (createdTicketRef) {
        try {
          const ticketSnap = await createdTicketRef.get();
          if (ticketSnap.exists) {
            await maybeSendTicketConfirmationEmail({
              uid: effectiveUid,
              eventId,
              ticketRef: createdTicketRef,
              ticketData: ticketSnap.data() || {},
              source: "finalize_callable",
            });
          }
        } catch (e) {
          console.error("finalizeEventTicketPurchase email step failed:", e);
        }
      }

      return { success: true };
    } catch (error) {
      console.error("finalizeEventTicketPurchase error:", error);

      if (error instanceof HttpsError) {
        throw error;
      }
      throw new HttpsError("internal", "Unable to finalize purchase");
    }
  }
);

// Stripe webhook (HTTP) - source of truth for payment success.
// Configure this endpoint in Stripe Dashboard -> Developers -> Webhooks.
// IMPORTANT: this is an HTTP endpoint and must verify Stripe signatures.
exports.stripeWebhook = onRequest(
  {
    region: "us-central1",
    secrets: [
      STRIPE_SECRET_KEY,
      STRIPE_WEBHOOK_SECRET,
      MAIL_SENDER_EMAIL,
      MAIL_SENDER_PASSWORD,
    ],
  },
  async (req, res) => {
    try {
      if (req.method !== "POST") {
        res.set("Allow", "POST");
        return res.status(405).send("Method Not Allowed");
      }

      const signature = req.headers["stripe-signature"];
      if (!signature || typeof signature !== "string") {
        return res.status(400).send("Missing Stripe signature");
      }

      const stripe = new Stripe(STRIPE_SECRET_KEY.value(), {
        apiVersion: "2024-06-20",
      });

      let event;
      try {
        // Firebase Functions provides raw body for signature verification.
        event = stripe.webhooks.constructEvent(
          req.rawBody,
          signature,
          STRIPE_WEBHOOK_SECRET.value()
        );
      } catch (err) {
        console.error("Webhook signature verification failed:", err);
        return res.status(400).send("Invalid signature");
      }

      if (event.type === "payment_intent.succeeded") {
        const paymentIntent = event.data.object;
        try {
          await fulfillEventTicketFromPaymentIntent(paymentIntent);
        } catch (e) {
          const message =
            e && typeof e === "object" && "message" in e ? String(e.message) : String(e);
          console.error("fulfillEventTicketFromPaymentIntent failed:", message);

          // If this PI wasn't created by our app (missing metadata), don't ask Stripe to retry.
          // This also makes Stripe Dashboard "Send test webhook" safe.
          if (message.includes("Invalid metadata")) {
            return res.status(200).json({received: true, ignored: true});
          }

          // For transient errors (Firestore, etc.), return 500 so Stripe retries.
          throw e;
        }
      }

      // Always return 200 so Stripe doesn't keep retrying for non-actionable events.
      return res.status(200).json({ received: true });
    } catch (error) {
      console.error("stripeWebhook error:", error);
      // Return 500 to let Stripe retry transient failures.
      return res.status(500).send("Webhook handler failed");
    }
  }
);

// Callable: send a broadcast email to a list of users.
// Client data: { users: [{email, name?}], message: string }
exports.sendBroadcastEmail = onCall(
  {
    region: "us-central1",
    // TEMP: App Check enforcement disabled until iOS App Check is registered.
    enforceAppCheck: false,
    secrets: [MAIL_SENDER_EMAIL, MAIL_SENDER_PASSWORD],
  },
  async (request) => {
    try {
      const data = request.data || {};
      const users = Array.isArray(data.users) ? data.users : [];
      const message = typeof data.message === "string" ? data.message.trim() : "";

      if (!message) {
        throw new Error("Missing message");
      }
      if (message.length > 2000) {
        throw new Error("Message too long");
      }
      if (users.length === 0) {
        throw new Error("No users provided");
      }
      if (users.length > 500) {
        throw new Error("Too many recipients");
      }

      const emails = users
        .map((u) => (u && typeof u.email === "string" ? u.email.trim() : ""))
        .filter((e) => e && e.includes("@"));

      const uniqueEmails = Array.from(new Set(emails));
      if (uniqueEmails.length === 0) {
        throw new Error("No valid emails provided");
      }

      const transporter = createMailTransporter();

      const safeMessage = escapeHtml(message).replace(/\n/g, "<br/>");

      // Gmail has practical recipient limits; chunk to keep sends reliable.
      const chunkSize = 50;
      let sentTo = 0;
      for (let i = 0; i < uniqueEmails.length; i += chunkSize) {
        const bccChunk = uniqueEmails.slice(i, i + chunkSize);

        await transporter.sendMail({
          from: buildMailFromHeader(),
          to: MAIL_SENDER_EMAIL.value(),
          bcc: bccChunk,
          subject: "TEK Update",
          text: message,
          html: `<div style="font-family:Arial,sans-serif;line-height:1.5">
            <h2>TEK</h2>
            <p>${safeMessage}</p>
          </div>`,
        });
        sentTo += bccChunk.length;
      }

      return { success: true, sentTo };
    } catch (error) {
      console.error("sendBroadcastEmail error:", error);
      throw new Error("Unable to send broadcast email");
    }
  }
);

exports.adminSendBroadcastEmail = onCall(
  {
    region: "us-central1",
    enforceAppCheck: false,
    timeoutSeconds: 540,
    secrets: [MAIL_SENDER_EMAIL, MAIL_SENDER_PASSWORD, BREVO_SMTP_LOGIN, BREVO_SMTP_KEY],
  },
  async (request) => {
    const callerUid = request.auth && request.auth.uid ? request.auth.uid : "";
    if (!callerUid) {
      throw new HttpsError("unauthenticated", "Unauthenticated");
    }
    if (!(await isAdminUid(callerUid))) {
      throw new HttpsError("permission-denied", "Permission denied");
    }

    try {
      const data = request.data || {};
      const subject = typeof data.subject === "string" ? data.subject.trim() : "";
      const message = typeof data.message === "string" ? data.message.trim() : "";
      const previewOnly = data.previewOnly === true;
      const previewEmail = typeof data.previewEmail === "string" ? data.previewEmail.trim().toLowerCase() : "";
      const recipientFilter = typeof data.recipientFilter === "string" ? data.recipientFilter.trim().toLowerCase() : "all";
      const allowedFilters = new Set(["all", "approved", "pending", "rejected"]);

      console.log(`[Broadcast] Start — preview=${previewOnly}, filter=${recipientFilter}, subject="${subject.slice(0, 50)}"`);

      if (!subject) {
        throw new HttpsError("invalid-argument", "Missing subject");
      }
      if (subject.length > 120) {
        throw new HttpsError("invalid-argument", "Subject too long");
      }
      if (!message) {
        throw new HttpsError("invalid-argument", "Missing message");
      }
      if (message.length > 4000) {
        throw new HttpsError("invalid-argument", "Message too long");
      }
      if (!allowedFilters.has(recipientFilter)) {
        throw new HttpsError("invalid-argument", "Invalid recipient filter");
      }
      if (previewOnly && (!previewEmail || !previewEmail.includes("@"))) {
        throw new HttpsError("invalid-argument", "Valid preview email required");
      }

      const allAppsSnap = await db.collection("applications").get();
      const uniqueEmails = Array.from(new Set(
        allAppsSnap.docs
          .map((doc) => {
            const docData = doc.data() || {};
            const email = typeof docData.email === "string" ? docData.email.trim().toLowerCase() : "";
            const status = typeof docData.status === "string" ? docData.status.trim().toLowerCase() : "pending";
            if (!email || !email.includes("@")) {
              return "";
            }
            if (recipientFilter !== "all" && status !== recipientFilter) {
              return "";
            }
            return email;
          })
          .filter((email) => email && email.includes("@"))
      ));

      console.log(`[Broadcast] Found ${uniqueEmails.length} recipients for filter "${recipientFilter}"`);

      if (uniqueEmails.length === 0) {
        throw new HttpsError("failed-precondition", "No user emails available");
      }

      // In-memory lock: prevent concurrent broadcast execution (auto-expires after 10 min)
      if (!previewOnly) {
        const lockAge = global._broadcastStartedAt ? Date.now() - global._broadcastStartedAt : Infinity;
        if (global._broadcastInProgress && lockAge < 10 * 60 * 1000) {
          const minutesLeft = Math.ceil((10 * 60 * 1000 - lockAge) / 60000);
          console.warn(`[Broadcast] BLOCKED — another broadcast is in progress (started ${Math.round(lockAge / 1000)}s ago)`);
          throw new HttpsError("already-exists", `A broadcast is already being sent. Try again in ~${minutesLeft} min.`);
        }
        if (global._broadcastInProgress && lockAge >= 10 * 60 * 1000) {
          console.warn("[Broadcast] Stale lock cleared (older than 10 min)");
        }
        global._broadcastInProgress = true;
        global._broadcastStartedAt = Date.now();

        // Firestore dedup guard: prevent resending same subject within 5 minutes
        try {
          const fiveMinAgo = new Date(Date.now() - 5 * 60 * 1000);
          const recentDups = await db.collection("broadcastLog")
            .where("subject", "==", subject)
            .where("sentAt", ">=", fiveMinAgo)
            .where("previewOnly", "==", false)
            .get();
          if (!recentDups.empty) {
            global._broadcastInProgress = false;
            console.warn(`[Broadcast] BLOCKED duplicate — same subject sent ${recentDups.size} time(s) in last 5 min`);
            throw new HttpsError("already-exists", `This broadcast was already sent ${recentDups.size} time(s) in the last 5 minutes. Wait before resending.`);
          }
        } catch (dedupErr) {
          if (dedupErr instanceof HttpsError) throw dedupErr;
          console.warn("[Broadcast] Dedup check skipped (index may be building):", dedupErr.message);
        }
      }

      const senderEmail = String(MAIL_SENDER_EMAIL.value() || "").trim();
      if (!senderEmail) {
        throw new HttpsError("failed-precondition", "Sender email is not configured");
      }

      const brevoTransporter = createBroadcastTransporter();
      const transporter = brevoTransporter || createMailTransporter();
      console.log(`[Broadcast] Using ${brevoTransporter ? "Brevo" : "Zoho (fallback)"} transporter`);
      const safeMessage = escapeHtml(message).replace(/\n/g, "<br/>");
      const filterLabel = recipientFilter === "all" ? "all users" : `${recipientFilter} users`;
      const broadcastHtml = buildBroadcastEmailHtml({
        subject,
        safeMessage,
        audienceLabel: filterLabel,
        audienceSize: uniqueEmails.length,
      });

      if (previewOnly) {
        await transporter.sendMail({
          from: buildMailFromHeader(),
          to: previewEmail,
          subject: `[Preview] ${subject}`,
          text: `Preview audience: ${filterLabel} (${uniqueEmails.length} recipients)\n\n${message}`,
          html: buildBroadcastEmailHtml({
            subject,
            safeMessage,
            previewOnly: true,
            audienceLabel: filterLabel,
            audienceSize: uniqueEmails.length,
          }),
        });
        console.log(`[Broadcast] Preview sent to ${previewEmail} (audience: ${uniqueEmails.length} ${recipientFilter})`);
        await db.collection("broadcastLog").add({
          subject,
          recipientFilter,
          previewOnly: true,
          previewEmail,
          audienceSize: uniqueEmails.length,
          sentBy: callerUid,
          sentAt: new Date(),
        });
        return {success: true, previewOnly: true, audienceSize: uniqueEmails.length, previewEmail};
      }

      const chunkSize = 10;
      let sentTo = 0;
      let failures = 0;
      const failedEmails = [];
      const senderDomain = senderEmail.split("@")[1] || "tek001.com";
      const plainText = `${subject}\n\n${message}\n\n---\nGet your ticket: ${TEK_TICKETS_URL}\n\nTEK — Stockholm's members-only community for electronic music, art, and culture.\nTo unsubscribe, reply with "Unsubscribe" or contact ${TEK_SUPPORT_EMAIL}`;

      // Helper: send one email with retry (up to 2 retries)
      async function sendWithRetry(recipientEmail, attempt = 1) {
        const msgId = `<${crypto.randomUUID()}@${senderDomain}>`;
        try {
          await transporter.sendMail({
            from: buildMailFromHeader(),
            to: recipientEmail,
            subject,
            text: plainText,
            html: broadcastHtml,
            replyTo: senderEmail,
            headers: {
              "Message-ID": msgId,
              "List-Unsubscribe": `<mailto:${senderEmail}?subject=Unsubscribe>`,
              "List-Unsubscribe-Post": "List-Unsubscribe=One-Click",
            },
          });
          sentTo++;
        } catch (err) {
          if (attempt < 3) {
            const backoff = attempt * 2000;
            console.warn(`[Broadcast] Retry ${attempt}/2 for ${recipientEmail} in ${backoff}ms: ${err.message}`);
            await new Promise((r) => setTimeout(r, backoff));
            return sendWithRetry(recipientEmail, attempt + 1);
          }
          console.warn(`[Broadcast] FAILED after ${attempt} attempts — ${recipientEmail}: ${err.message}`);
          failures++;
          failedEmails.push(recipientEmail);
        }
      }

      // Send in small chunks, sequentially within each chunk, with delays
      for (let i = 0; i < uniqueEmails.length; i += chunkSize) {
        const chunk = uniqueEmails.slice(i, i + chunkSize);
        for (const recipientEmail of chunk) {
          await sendWithRetry(recipientEmail);
          // 100ms delay between individual sends
          await new Promise((r) => setTimeout(r, 100));
        }
        console.log(`[Broadcast] Progress: ${Math.min(i + chunkSize, uniqueEmails.length)}/${uniqueEmails.length} (sent: ${sentTo}, failed: ${failures})`);
        // 1s pause between chunks
        if (i + chunkSize < uniqueEmails.length) {
          await new Promise((r) => setTimeout(r, 1000));
        }
      }

      global._broadcastInProgress = false;
      console.log(`[Broadcast] COMPLETE — sent: ${sentTo}, failed: ${failures}, subject="${subject.slice(0, 50)}"`);
      if (failedEmails.length > 0) {
        console.warn(`[Broadcast] Failed emails: ${failedEmails.join(", ")}`);
      }
      await db.collection("broadcastLog").add({
        subject,
        recipientFilter,
        previewOnly: false,
        sentTo,
        failures,
        failedEmails: failedEmails.slice(0, 50),
        sentBy: callerUid,
        sentAt: new Date(),
      });
      return {success: true, sentTo, failures};
    } catch (error) {
      global._broadcastInProgress = false;
      if (error instanceof HttpsError) {
        throw error;
      }
      console.error("adminSendBroadcastEmail error:", error);
      throw new HttpsError("internal", "Unable to send broadcast email");
    }
  }
);

// Clear expired purchase locks for the current user
exports.clearExpiredTicketLocks = onCall(
  {
    region: "us-central1",
    enforceAppCheck: false,
  },
  async (request) => {
    try {
      if (!request.auth || !request.auth.uid) {
        throw new HttpsError("unauthenticated", "Unauthenticated");
      }
      const uid = request.auth.uid;

      const locksCollection = db
        .collection("users")
        .doc(uid)
        .collection("ticketLocks");

      const allLocks = await locksCollection.get();
      const now = Date.now();
      let cleared = 0;

      for (const lockDoc of allLocks.docs) {
        const lockData = lockDoc.data() || {};
        const expiresAt = lockData.expiresAt;
        const expiresAtMs =
          expiresAt && typeof expiresAt.toMillis === "function"
            ? expiresAt.toMillis()
            : 0;

        // Clear locks that are expired OR stuck in 'creating' state (failed attempt)
        if (expiresAtMs <= now || lockData.status === "creating") {
          await lockDoc.ref.delete();
          cleared++;
          console.log(`Cleared ticket lock for event ${lockDoc.id}`);
        }
      }

      return { success: true, cleared };
    } catch (error) {
      console.error("clearExpiredTicketLocks error:", error);
      if (error instanceof HttpsError) {
        throw error;
      }
      throw new HttpsError("internal", "Unable to clear ticket locks");
    }
  }
);


// HTTP Cloud Function for uploading membership images
exports.uploadMembershipImage = onRequest({ cors: true }, async (req, res) => {
  if (req.method === "OPTIONS") {
    res.set("Access-Control-Allow-Origin", "*");
    res.set("Access-Control-Allow-Methods", "POST, OPTIONS");
    res.set("Access-Control-Allow-Headers", "Content-Type");
    return res.status(204).send("");
  }

  if (req.method !== "POST") {
    return res.status(400).json({ error: "POST request required" });
  }

  try {
    const { imageData, fileName, mimeType } = req.body;
    
    if (!imageData || !fileName) {
      return res.status(400).json({ error: "Missing imageData or fileName" });
    }

    // Convert base64 to buffer
    const base64Data = imageData.replace(/^data:[^;]+;base64,/, "");
    const imageBuffer = Buffer.from(base64Data, "base64");

    const resolvedMimeType =
      typeof mimeType === "string" && mimeType.startsWith("image/")
        ? mimeType
        : "image/jpeg";

    // Generate timestamp and path
    const timestamp = Date.now();
    const sanitizedName = fileName.replace(/[^a-zA-Z0-9._-]/g, "_");
    const filePath = `membership_applications/${timestamp}_${sanitizedName}`;

    // Upload to Firebase Storage using admin SDK
    const bucket = admin.storage().bucket();
    const file = bucket.file(filePath);

    await file.save(imageBuffer, {
      metadata: {
        contentType: resolvedMimeType,
        cacheControl: "public, max-age=31536000",
      },
    });

    // Make file public and get download URL
    await file.makePublic();
    const publicUrl = file.publicUrl();

    res.json({ 
      success: true, 
      url: publicUrl,
      path: filePath 
    });
  } catch (error) {
    console.error("uploadMembershipImage error:", error);
    res.status(500).json({ 
      error: "Image upload failed",
      details: error.message 
    });
  }
});

exports.uploadWebsiteProfileImage = onRequest({ cors: true }, async (req, res) => {
  if (req.method === "OPTIONS") {
    res.set("Access-Control-Allow-Origin", "*");
    res.set("Access-Control-Allow-Methods", "POST, OPTIONS");
    res.set("Access-Control-Allow-Headers", "Content-Type");
    return res.status(204).send("");
  }

  if (req.method !== "POST") {
    return res.status(400).json({ error: "POST request required" });
  }

  try {
    const { imageData, fileName, mimeType, userId } = req.body || {};

    if (!imageData || !fileName || !userId) {
      return res.status(400).json({ error: "Missing imageData, fileName, or userId" });
    }

    const base64Data = imageData.replace(/^data:[^;]+;base64,/, "");
    const imageBuffer = Buffer.from(base64Data, "base64");

    const resolvedMimeType =
      typeof mimeType === "string" && mimeType.startsWith("image/")
        ? mimeType
        : "image/jpeg";

    const timestamp = Date.now();
    const sanitizedName = fileName.replace(/[^a-zA-Z0-9._-]/g, "_");
    const sanitizedUserId = String(userId).replace(/[^a-zA-Z0-9_-]/g, "_");
    const filePath = `profile_images/${sanitizedUserId}_${timestamp}_${sanitizedName}`;

    const bucket = admin.storage().bucket();
    const file = bucket.file(filePath);

    await file.save(imageBuffer, {
      metadata: {
        contentType: resolvedMimeType,
        cacheControl: "public, max-age=31536000",
      },
    });

    await file.makePublic();
    const publicUrl = file.publicUrl();

    return res.json({
      success: true,
      url: publicUrl,
      path: filePath,
    });
  } catch (error) {
    console.error("uploadWebsiteProfileImage error:", error);
    return res.status(500).json({
      error: "Image upload failed",
      details: error.message,
    });
  }
});

// ──────────────────────────────────────────────────────────
//  sendWebsiteReferral – public HTTP endpoint
//  Accepts { friendEmail } via POST, sends invitation email
// ──────────────────────────────────────────────────────────
exports.sendWebsiteReferral = onRequest(
  {
    region: "us-central1",
    cors: true,
    secrets: [MAIL_SENDER_EMAIL, MAIL_SENDER_PASSWORD],
  },
  async (req, res) => {
    if (req.method === "OPTIONS") {
      res.set("Access-Control-Allow-Origin", "*");
      res.set("Access-Control-Allow-Methods", "POST, OPTIONS");
      res.set("Access-Control-Allow-Headers", "Content-Type");
      return res.status(204).send("");
    }

    if (req.method !== "POST") {
      return res.status(400).json({error: "POST request required"});
    }

    try {
      const data = req.body || {};
      const friendEmail = typeof data.friendEmail === "string" ? data.friendEmail.trim().toLowerCase() : "";

      // Validate email
      if (!friendEmail || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(friendEmail)) {
        return res.status(400).json({error: "Please enter a valid email address."});
      }

      // Rate-limit: max 5 referrals per IP per day
      const ip = req.headers["x-forwarded-for"] || req.ip || "unknown";
      const ipHash = Buffer.from(String(ip)).toString("base64").replace(/[^a-zA-Z0-9]/g, "").slice(0, 40);
      const today = new Date().toISOString().slice(0, 10);
      const rateLimitRef = db.collection("referral_rate_limits").doc(`${ipHash}_${today}`);
      const rateLimitDoc = await rateLimitRef.get();
      const currentCount = rateLimitDoc.exists ? (rateLimitDoc.data().count || 0) : 0;

      if (currentCount >= 5) {
        return res.status(429).json({error: "You have reached the daily referral limit. Try again tomorrow."});
      }

      // Send the email
      const transporter = createMailTransporter();
      const membershipUrl = "https://tek-landing.vercel.app/membership.html";

      await transporter.sendMail({
        from: `"TEK" <${MAIL_SENDER_EMAIL.value()}>`,
        to: friendEmail,
        subject: "You have been invited to join TEK",
        html: `
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head>
<body style="margin:0;padding:0;background:#000;font-family:'Helvetica Neue',Arial,sans-serif;">
  <table width="100%" cellpadding="0" cellspacing="0" style="background:#000;padding:40px 20px;">
    <tr><td align="center">
      <table width="100%" style="max-width:520px;background:#0a0a0a;border:1px solid rgba(0,255,65,0.15);border-radius:8px;overflow:hidden;">

        <!-- Header -->
        <tr><td style="padding:48px 40px 24px;text-align:center;">
          <h1 style="margin:0;font-size:28px;font-weight:800;letter-spacing:6px;color:#00FF41;">TEK</h1>
        </td></tr>

        <!-- Body -->
        <tr><td style="padding:0 40px 32px;">
          <p style="color:#ffffff;font-size:16px;line-height:1.7;margin:0 0 20px;">
            Your friend wants you to join TEK — Stockholm's members-only community for electronic music, art, and culture.
          </p>
          <p style="color:#999;font-size:14px;line-height:1.6;margin:0 0 32px;">
            TEK is an invite-based collective. Membership gives you access to exclusive events, a private community, and rewards. Apply now — spots are limited.
          </p>
        </td></tr>

        <!-- CTA -->
        <tr><td style="padding:0 40px 40px;text-align:center;">
          <a href="${membershipUrl}" style="display:inline-block;background:#00FF41;color:#000;font-size:13px;font-weight:700;letter-spacing:2px;padding:14px 36px;border-radius:4px;text-decoration:none;">APPLY FOR MEMBERSHIP</a>
        </td></tr>

        <!-- Footer -->
        <tr><td style="padding:24px 40px;border-top:1px solid rgba(255,255,255,0.06);text-align:center;">
          <p style="color:#555;font-size:11px;margin:0;letter-spacing:0.5px;">
            You received this because someone referred you to TEK.<br>
            If this was not intended for you, you can ignore this email.
          </p>
        </td></tr>

      </table>
    </td></tr>
  </table>
</body>
</html>`,
      });

      // Increment rate limit
      await rateLimitRef.set({
        count: currentCount + 1,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, {merge: true});

      // Log the referral
      await db.collection("website_referrals").add({
        friendEmail,
        ipHash,
        sentAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      return res.json({success: true});
    } catch (error) {
      console.error("sendWebsiteReferral error:", error);
      return res.status(500).json({error: "Unable to send invitation. Please try again."});
    }
  }
);

exports.sendPerformerApplication = onRequest(
  {
    region: "us-central1",
    cors: true,
    secrets: [MAIL_SENDER_EMAIL, MAIL_SENDER_PASSWORD],
  },
  async (req, res) => {
    if (req.method === "OPTIONS") {
      res.set("Access-Control-Allow-Origin", "*");
      res.set("Access-Control-Allow-Methods", "POST, OPTIONS");
      res.set("Access-Control-Allow-Headers", "Content-Type");
      return res.status(204).send("");
    }

    if (req.method !== "POST") {
      return res.status(400).json({error: "POST request required"});
    }

    try {
      const data = req.body || {};
      const name = typeof data.name === "string" ? data.name.trim().slice(0, 120) : "";
      const email = typeof data.email === "string" ? data.email.trim().toLowerCase() : "";
      const instagram = typeof data.instagram === "string" ? data.instagram.trim().replace(/^@/, "").slice(0, 80) : "";
      const links = typeof data.links === "string" ? data.links.trim().slice(0, 500) : "";
      const pitch = typeof data.pitch === "string" ? data.pitch.trim().slice(0, 4000) : "";
      const userId = typeof data.userId === "string" ? data.userId.trim().slice(0, 120) : "";

      if (!name) {
        return res.status(400).json({error: "Please enter your name."});
      }

      if (!email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
        return res.status(400).json({error: "Please enter a valid email address."});
      }

      if (!pitch || pitch.length < 40) {
        return res.status(400).json({error: "Please tell us a bit more about your sound and what you want to bring to TEK."});
      }

      const transporter = createMailTransporter();
      const adminEmail = await getAdminNotificationEmail();

      await transporter.sendMail({
        from: buildMailFromHeader(),
        to: adminEmail,
        replyTo: email,
        subject: `TEK Performer Application — ${name}`,
        html: `
          <div style="background:#000;padding:32px;font-family:Arial,sans-serif;color:#fff;">
            <div style="max-width:640px;margin:0 auto;background:#0d0d0d;border:1px solid rgba(0,255,65,0.16);border-radius:8px;padding:32px;">
              <h1 style="margin:0 0 24px;color:#00FF41;letter-spacing:3px;font-size:24px;">TEK PERFORMER APPLICATION</h1>
              <p style="margin:0 0 12px;"><strong>Name:</strong> ${escapeHtml(name)}</p>
              <p style="margin:0 0 12px;"><strong>Email:</strong> ${escapeHtml(email)}</p>
              <p style="margin:0 0 12px;"><strong>Instagram:</strong> ${escapeHtml(instagram ? `@${instagram}` : "—")}</p>
              <p style="margin:0 0 12px;"><strong>Links:</strong> ${escapeHtml(links || "—")}</p>
              <p style="margin:24px 0 8px;"><strong>Pitch</strong></p>
              <div style="white-space:pre-wrap;line-height:1.7;color:#d6d6d6;">${escapeHtml(pitch)}</div>
              <p style="margin:24px 0 0;color:#7b7b7b;font-size:12px;">Website userId: ${escapeHtml(userId || "unknown")}</p>
            </div>
          </div>
        `,
      });

      await db.collection("performer_applications").add({
        name,
        email,
        instagram,
        links,
        pitch,
        userId: userId || null,
        source: "website_profile",
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      return res.json({success: true});
    } catch (error) {
      console.error("sendPerformerApplication error:", error);
      return res.status(500).json({error: "Unable to send performer application right now."});
    }
  }
);

// ─────────────────────────────────────────────────────────────────────────────
// PUSH NOTIFICATIONS
// ─────────────────────────────────────────────────────────────────────────────

async function getFcmToken(referralCode) {
  if (!referralCode) return null;
  const snap = await db.collection("applications")
    .where("referralCode", "==", referralCode)
    .limit(1)
    .get();
  if (snap.empty) return null;
  return snap.docs[0].data().fcmToken || null;
}

async function sendPush(token, title, body, data = {}) {
  if (!token) return;
  try {
    await admin.messaging().send({
      token,
      notification: {title, body},
      data: Object.fromEntries(Object.entries(data).map(([k, v]) => [k, String(v)])),
      apns: {payload: {aps: {sound: "default", badge: 1}}},
      android: {notification: {sound: "default"}},
    });
  } catch (e) {
    console.log("Push send failed:", e.message);
  }
}

// Mirrors a notification into Firestore so it appears in the in-app inbox.
async function writeTekNotif(recipientCode, type, title, body, extra = {}) {
  if (!recipientCode) return;
  try {
    await db.collection("tek_notifications").add({
      recipientCode,
      type,
      title,
      body,
      read: false,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      ...extra,
    });
  } catch (e) {
    console.log("Tek notif write failed:", e.message);
  }
}

// 1. New chat message → notify recipient
exports.onNewChatMessage = onDocumentCreated(
  "chats/{chatId}/messages/{messageId}",
  async (event) => {
    const data = event.data.data();
    const chatId = event.params.chatId;
    const senderCode = data.senderCode;
    const messageText = data.message || "";

    // chatId is sorted(code1, code2) joined by _
    const parts = chatId.split("_");
    if (parts.length < 2) return;
    const recipientCode = parts[0] === senderCode ? parts.slice(1).join("_") : parts[0];
    if (!recipientCode || recipientCode === senderCode) return;

    const token = await getFcmToken(recipientCode);
    await sendPush(token, `New message from ${senderCode}`,
      messageText.substring(0, 120) || "...",
      {type: "chat", chatId, senderCode});
    await writeTekNotif(recipientCode, "chat",
      `New message from ${senderCode}`,
      messageText.substring(0, 120) || "Sent a photo",
      {chatId, senderCode});
  }
);

// 2. New challenge → notify challenged user
exports.onChallengeCreated = onDocumentCreated(
  "challenges/{id}",
  async (event) => {
    const data = event.data.data();
    const challengedCode = data.challengedCode;
    const challengerCode = data.challengerCode;
    const questTitle = data.questTitle || "a mission";

    const token = await getFcmToken(challengedCode);
    await sendPush(token, "Challenge received",
      `${challengerCode} challenged you to: ${questTitle}`,
      {type: "challenge", challengeId: event.params.id});
    await writeTekNotif(challengedCode, "challenge_received",
      "CHALLENGE RECEIVED",
      `${challengerCode} challenged you to "${questTitle}"`,
      {challengeId: event.params.id});
  }
);

// 3. Challenge accepted/declined → notify challenger
exports.onChallengeUpdated = onDocumentUpdated(
  "challenges/{id}",
  async (event) => {
    const before = event.data.before.data();
    const after = event.data.after.data();
    if (before.status === after.status) return;

    const challengerCode = after.challengerCode;
    const challengedCode = after.challengedCode;
    const questTitle = after.questTitle || "a mission";
    const token = await getFcmToken(challengerCode);

    if (after.status === "accepted") {
      await sendPush(token, "Challenge accepted!",
        `${challengedCode} accepted your challenge: ${questTitle}`,
        {type: "challenge_update", challengeId: event.params.id, status: "accepted"});
    } else if (after.status === "declined") {
      await sendPush(token, "Challenge declined",
        `${challengedCode} declined your challenge: ${questTitle}`,
        {type: "challenge_update", challengeId: event.params.id, status: "declined"});
    }
  }
);

// 4. New friend request or friend accepted → notify recipient
exports.onApplicationUpdated = onDocumentUpdated(
  "applications/{appId}",
  async (event) => {
    const before = event.data.before.data();
    const after = event.data.after.data();
    const token = after.fcmToken;
    if (!token) return;

    // New friend request received
    const beforeRequests = before.friendRequests || [];
    const afterRequests = after.friendRequests || [];
    if (afterRequests.length > beforeRequests.length) {
      const newRequests = afterRequests.filter((r) => !beforeRequests.includes(r));
      if (newRequests.length > 0) {
        await sendPush(token, "New friend request",
          `${newRequests[0]} wants to connect with you on TEK`,
          {type: "friend_request", senderCode: newRequests[0]});
        await writeTekNotif(after.referralCode, "friend_request",
          "FRIEND REQUEST",
          `${newRequests[0]} wants to connect`,
          {senderCode: newRequests[0]});
      }
      return;
    }

    // Friend request accepted (friends array grew)
    const beforeFriends = before.friends || [];
    const afterFriends = after.friends || [];
    if (afterFriends.length > beforeFriends.length) {
      const newFriends = afterFriends.filter((f) => !beforeFriends.includes(f));
      if (newFriends.length > 0) {
        await sendPush(token, "New connection",
          `${newFriends[0]} accepted your friend request`,
          {type: "friend_accepted", friendCode: newFriends[0]});
        await writeTekNotif(after.referralCode, "friend_accepted",
          "NEW CONNECTION",
          `${newFriends[0]} accepted your friend request`,
          {friendCode: newFriends[0]});
      }
    }
  }
);

// 5. New active sidequest → notify all users
exports.onSidequestCreated = onDocumentCreated(
  "sidequests/{questId}",
  async (event) => {
    const data = event.data.data();
    if (!data.active) return;
    const title = data.title || "NEW MISSION";
    const xp = data.xpReward || 0;
    const appsSnap = await db.collection("applications")
      .where("fcmToken", "!=", null)
      .get();
    const tokens = appsSnap.docs
      .map((d) => d.data().fcmToken)
      .filter((t) => typeof t === "string" && t.length > 0);
    if (tokens.length === 0) return;
    const payload = {
      notification: {title: "NEW MISSION AVAILABLE", body: `${title} — +${xp} XP`},
      data: {type: "new_quest", questId: event.params.questId},
      apns: {payload: {aps: {sound: "default", badge: 1}}},
      android: {notification: {sound: "default"}},
    };
    // Send in batches of 500
    for (let i = 0; i < tokens.length; i += 500) {
      const batch = tokens.slice(i, i + 500);
      await admin.messaging().sendEachForMulticast({tokens: batch, ...payload});
    }

    // Mirror to in-app inbox for every active user, batches of 400
    let inboxBatch = db.batch();
    let count = 0;
    for (const userDoc of appsSnap.docs) {
      const userCode = userDoc.data().referralCode;
      if (!userCode) continue;
      const ref = db.collection("tek_notifications").doc();
      inboxBatch.set(ref, {
        recipientCode: userCode,
        type: "new_quest",
        title: "NEW MISSION AVAILABLE",
        body: `${title} — +${xp} XP`,
        questId: event.params.questId,
        read: false,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      count++;
      if (count % 400 === 0) {
        await inboxBatch.commit();
        inboxBatch = db.batch();
      }
    }
    if (count % 400 !== 0) {
      await inboxBatch.commit();
    }
  }
);

// ============================================================================
// QUESTS V2 — automation, server-authoritative claim, daily/weekly rotation,
// streaks, and AI-drafted quest copy.
// ============================================================================

const {onSchedule} = require("firebase-functions/v2/scheduler");

const QUESTS_CONFIG_DEFAULTS = {
  enabled: true,
  dailyRotationEnabled: true,
  dailyQuestCount: 3,
  weeklyQuestCount: 1,
  streaksEnabled: true,
  streakBonusXP: {3: 50, 7: 150, 30: 1000},
  aiGenerationEnabled: true,
};

async function getQuestsConfig() {
  try {
    const snap = await db.collection("config").doc("quests").get();
    if (!snap.exists) return {...QUESTS_CONFIG_DEFAULTS};
    return {...QUESTS_CONFIG_DEFAULTS, ...(snap.data() || {})};
  } catch (e) {
    console.error("getQuestsConfig failed:", e);
    return {...QUESTS_CONFIG_DEFAULTS};
  }
}

async function getUserAppByCode(referralCode) {
  if (!referralCode) return null;
  const snap = await db.collection("applications")
    .where("referralCode", "==", referralCode)
    .limit(1)
    .get();
  if (snap.empty) return null;
  return snap.docs[0];
}

async function getUserAppByUid(uid) {
  if (!uid) return null;
  const snap = await db.collection("applications")
    .where("ownerUid", "==", uid)
    .limit(1)
    .get();
  if (snap.empty) return null;
  return snap.docs[0];
}

// Snapshot today's date as a UTC YYYY-MM-DD string. Used for streak bookkeeping.
function utcDateKey(date) {
  const d = date || new Date();
  const yyyy = d.getUTCFullYear();
  const mm = String(d.getUTCMonth() + 1).padStart(2, "0");
  const dd = String(d.getUTCDate()).padStart(2, "0");
  return `${yyyy}-${mm}-${dd}`;
}

// Atomically award XP for a sidequest, mutating the user's app doc, the
// quest's totalCompletions, the user's crew xpTotal pool, the questProgress
// doc (if present), and writing an xp_transactions audit row. Returns a
// summary object the callable surfaces back to the client.
async function awardSidequestXP({appDocRef, questId, questDoc, userCode, uid, repeatable}) {
  const questData = questDoc.data() || {};
  const xpReward = Number(questData.xpReward) || 0;
  const questTitle = questData.title || "";

  const progressRef = appDocRef.collection("questProgress").doc(questId);

  const result = await db.runTransaction(async (tx) => {
    const appSnap = await tx.get(appDocRef);
    if (!appSnap.exists) throw new HttpsError("not-found", "User doc missing");
    const appData = appSnap.data() || {};
    const completedArr = Array.isArray(appData.completedSidequests) ? appData.completedSidequests : [];

    const progressSnap = await tx.get(progressRef);
    const progress = progressSnap.exists ? progressSnap.data() || {} : null;

    // Already claimed?  Two paths: (a) legacy completedSidequests array, or
    // (b) new questProgress doc with claimedAt set on a non-repeatable quest.
    if (!repeatable && completedArr.includes(questId)) {
      return {already: true};
    }
    if (progress && progress.claimedAt && !repeatable) {
      return {already: true};
    }
    // For progress-tracked quests, completion gate must be satisfied.
    if (progress && !progress.completedAt) {
      throw new HttpsError("failed-precondition", "Quest not yet complete");
    }

    const currentXP = Number(appData.xpPoints) || 0;
    const newXP = currentXP + xpReward;

    const appPatch = {xpPoints: newXP};
    if (!repeatable) {
      appPatch.completedSidequests = admin.firestore.FieldValue.arrayUnion(questId);
    }
    tx.update(appDocRef, appPatch);
    tx.update(questDoc.ref, {totalCompletions: admin.firestore.FieldValue.increment(1)});

    if (progressSnap.exists) {
      // Repeatable quests reset progress so the user can earn again next cycle.
      if (repeatable) {
        tx.update(progressRef, {
          progress: 0,
          completedAt: null,
          claimedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      } else {
        tx.update(progressRef, {claimedAt: admin.firestore.FieldValue.serverTimestamp()});
      }
    }

    return {already: false, currentXP, newXP, appName: appData.name || "", appEmail: appData.email || ""};
  });

  if (result.already) return {alreadyClaimed: true, xpAwarded: 0, previousXP: 0, newXP: 0};

  // Best-effort post-transaction side effects.
  try {
    const crewSnap = await db.collection("crews")
      .where("memberCodes", "array-contains", userCode)
      .get();
    const crewBatch = db.batch();
    for (const crew of crewSnap.docs) {
      crewBatch.update(crew.ref, {xpTotal: admin.firestore.FieldValue.increment(xpReward)});
    }
    if (!crewSnap.empty) await crewBatch.commit();
  } catch (e) {
    console.warn("crew XP increment failed:", e);
  }

  try {
    await db.collection("xp_transactions").add({
      source: "sidequest",
      questId,
      questTitle,
      userId: uid || "",
      userName: result.appName,
      userEmail: result.appEmail,
      amount: xpReward,
      previousXP: result.currentXP,
      newXP: result.newXP,
      timestamp: admin.firestore.FieldValue.serverTimestamp(),
    });
  } catch (e) {
    console.warn("xp_transactions write failed:", e);
  }

  return {
    alreadyClaimed: false,
    xpAwarded: xpReward,
    previousXP: result.currentXP,
    newXP: result.newXP,
  };
}

// Server-authoritative claim. Replaces the client-side batch in
// SidequestDetailPage._claimXP. The client is now trusted only to call this
// callable after passing the local verification gate (QR/timer/code/friend).
exports.claimQuestXP = onCall(
  {region: "us-central1", enforceAppCheck: false},
  async (request) => {
    if (!request.auth || !request.auth.uid) {
      throw new HttpsError("unauthenticated", "Sign in required");
    }
    const uid = request.auth.uid;
    const data = request.data || {};
    const questId = typeof data.questId === "string" ? data.questId : "";
    const userCode = typeof data.userCode === "string" ? data.userCode.trim() : "";
    if (!questId || !userCode) {
      throw new HttpsError("invalid-argument", "questId and userCode required");
    }

    const cfg = await getQuestsConfig();
    if (!cfg.enabled) {
      throw new HttpsError("failed-precondition", "Quests feature is disabled");
    }

    const appDoc = await getUserAppByCode(userCode);
    if (!appDoc) throw new HttpsError("not-found", "User not found");

    // Defense-in-depth: this caller must own the application doc.
    const appData = appDoc.data() || {};
    if (appData.ownerUid && appData.ownerUid !== uid) {
      throw new HttpsError("permission-denied", "Not the owner of this profile");
    }

    const questDoc = await db.collection("sidequests").doc(questId).get();
    if (!questDoc.exists) throw new HttpsError("not-found", "Quest not found");
    const questData = questDoc.data() || {};
    if (questData.active === false) {
      throw new HttpsError("failed-precondition", "Quest is inactive");
    }
    const repeatable = questData.repeatable === true || questData.questType === "daily" || questData.questType === "weekly";

    return awardSidequestXP({
      appDocRef: appDoc.ref,
      questId,
      questDoc,
      userCode,
      uid,
      repeatable,
    });
  }
);

// ---------------------------------------------------------------------------
// Action-triggered auto-progress
//
// `tickQuestProgress` is the single helper every action listener funnels into.
// It looks up active quests matching (actionType, optional eventId scope) and
// either creates a fresh questProgress doc or increments an existing one. When
// progress hits target, completedAt is stamped and a push notification fires —
// the user then opens the SIDEQUESTS tab and taps CLAIM, which routes through
// the existing claimQuestXP callable.
// ---------------------------------------------------------------------------

async function tickQuestProgress({appDoc, userCode, actionType, increment, scope}) {
  const cfg = await getQuestsConfig();
  if (!cfg.enabled) return;

  const appData = appDoc.data() || {};
  const completedArr = Array.isArray(appData.completedSidequests) ? appData.completedSidequests : [];

  // Pull all active auto/daily/weekly quests for this actionType. We can't
  // server-side filter by actionFilter, so we apply that in memory below.
  const questsSnap = await db.collection("sidequests")
    .where("active", "==", true)
    .where("actionType", "==", actionType)
    .get();

  if (questsSnap.empty) return;

  const now = admin.firestore.Timestamp.now();

  for (const questDocSnap of questsSnap.docs) {
    const quest = questDocSnap.data() || {};

    // Skip raw templates — they're cloned on rotation, not progressed against directly.
    if (quest.isTemplate === true) continue;

    // Only auto-progress on these quest types; manual quests keep their own gates.
    const qtype = quest.questType || "manual";
    if (!["auto_action", "daily", "weekly"].includes(qtype)) continue;

    // Already-completed (legacy) lock for non-repeatable quests.
    const repeatable = quest.repeatable === true || qtype === "daily" || qtype === "weekly";
    if (!repeatable && completedArr.includes(questDocSnap.id)) continue;

    // Apply optional action filter (e.g. only count check-ins to a specific event).
    const filter = (quest.actionFilter && typeof quest.actionFilter === "object") ? quest.actionFilter : null;
    if (filter) {
      let filterPass = true;
      for (const [k, v] of Object.entries(filter)) {
        if (scope && scope[k] !== v) {filterPass = false; break;}
      }
      if (!filterPass) continue;
    }

    const target = Number(quest.target) || 1;
    const progressRef = appDoc.ref.collection("questProgress").doc(questDocSnap.id);

    await db.runTransaction(async (tx) => {
      const progSnap = await tx.get(progressRef);
      const prog = progSnap.exists ? (progSnap.data() || {}) : null;

      // If a non-repeatable progress doc is already claimed, do nothing.
      if (prog && prog.claimedAt && !repeatable) return;
      // If repeatable and previously claimed, this is a fresh cycle — start over from 0.
      const baseProgress = (prog && prog.claimedAt && repeatable) ? 0 : Number(prog ? prog.progress : 0) || 0;

      const newProgress = Math.min(target, baseProgress + (Number(increment) || 1));
      const reachedTarget = newProgress >= target;

      const patch = {
        questId: questDocSnap.id,
        questType: qtype,
        progress: newProgress,
        target,
        xpReward: Number(quest.xpReward) || 0,
        actionType,
        // Don't overwrite existing startedAt
        startedAt: prog && prog.startedAt ? prog.startedAt : now,
      };
      if (quest.expiresAt) patch.expiresAt = quest.expiresAt;
      if (reachedTarget && (!prog || !prog.completedAt)) {
        patch.completedAt = now;
        patch.claimedAt = null;
      }
      if (prog && prog.claimedAt && repeatable) {
        // Reset claimedAt for a new cycle.
        patch.claimedAt = null;
        if (reachedTarget) patch.completedAt = now;
        else patch.completedAt = null;
      }

      if (progSnap.exists) {
        tx.update(progressRef, patch);
      } else {
        tx.set(progressRef, patch);
      }
    });

    // Send completion push (best-effort, outside the transaction).
    try {
      const fresh = await progressRef.get();
      const data = fresh.data() || {};
      const justCompleted = data.completedAt && !data.claimedAt;
      if (justCompleted && appData.fcmToken) {
        await sendPush(
          appData.fcmToken,
          "MISSION READY",
          `${quest.title || "Quest"} — claim +${quest.xpReward || 0} XP`,
          {type: "quest_complete", questId: questDocSnap.id},
        );
      }
    } catch (e) {
      console.warn("quest completion push failed:", e);
    }
  }
}

// 6. Application updates → tick friend_added quests when friend list grows.
exports.onApplicationUpdatedQuests = onDocumentUpdated(
  "applications/{appId}",
  async (event) => {
    const before = event.data.before.data() || {};
    const after = event.data.after.data() || {};
    const beforeFriends = Array.isArray(before.friends) ? before.friends : [];
    const afterFriends = Array.isArray(after.friends) ? after.friends : [];
    if (afterFriends.length <= beforeFriends.length) return;

    const userCode = after.referralCode || before.referralCode;
    if (!userCode) return;

    const increment = afterFriends.length - beforeFriends.length;
    await tickQuestProgress({
      appDoc: event.data.after.ref ? {ref: event.data.after.ref, data: () => after} : null,
      userCode,
      actionType: "friend_added",
      increment,
    });
  }
);

// 7. Event check-in → tick event_checkin quests (with optional eventId filter).
exports.onEventCheckinCreated = onDocumentCreated(
  "events/{eventId}/checkins/{checkInId}",
  async (event) => {
    const data = event.data.data() || {};
    const eventId = event.params.eventId;
    const userCode = data.userCode;
    if (!userCode) return;

    const appDoc = await getUserAppByCode(userCode);
    if (!appDoc) return;

    await tickQuestProgress({
      appDoc,
      userCode,
      actionType: "event_checkin",
      increment: 1,
      scope: {eventId},
    });
  }
);

// 8. New chat message → tick chat_message_sent quests for sender.
exports.onChatMessageQuests = onDocumentCreated(
  "chats/{chatId}/messages/{messageId}",
  async (event) => {
    const data = event.data.data() || {};
    const senderCode = data.senderCode;
    if (!senderCode) return;
    const appDoc = await getUserAppByCode(senderCode);
    if (!appDoc) return;
    await tickQuestProgress({
      appDoc,
      userCode: senderCode,
      actionType: "chat_message_sent",
      increment: 1,
    });
  }
);

// 9. Challenge accepted → tick challenge_won for the challenger when accepted.
//    (Wins are tracked the moment a challenge is accepted; richer "winner" state
//    can be layered on later via a winnerCode field.)
exports.onChallengeUpdatedQuests = onDocumentUpdated(
  "challenges/{id}",
  async (event) => {
    const before = event.data.before.data() || {};
    const after = event.data.after.data() || {};
    if (before.status === after.status) return;
    if (after.status !== "accepted") return;

    const code = after.challengerCode;
    if (!code) return;
    const appDoc = await getUserAppByCode(code);
    if (!appDoc) return;
    await tickQuestProgress({
      appDoc,
      userCode: code,
      actionType: "challenge_won",
      increment: 1,
    });
  }
);

// ---------------------------------------------------------------------------
// Daily / weekly quest rotation
//
// Templates are normal docs in `sidequests` flagged with isTemplate=true and
// questType in {daily, weekly}. The rotator picks N templates at random,
// stamps an expiresAt, and writes a fresh questProgress doc into each user's
// subcollection. Yesterday's expired clones are deleted in the same pass so
// the SIDEQUESTS list never grows unbounded.
// ---------------------------------------------------------------------------

async function pickRandomTemplates(questType, n) {
  const snap = await db.collection("sidequests")
    .where("isTemplate", "==", true)
    .where("questType", "==", questType)
    .where("active", "==", true)
    .get();
  const docs = snap.docs;
  if (docs.length === 0) return [];
  // Fisher-Yates shuffle, then slice. Cheap for small template pools.
  const arr = docs.slice();
  for (let i = arr.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [arr[i], arr[j]] = [arr[j], arr[i]];
  }
  return arr.slice(0, Math.min(n, arr.length));
}

async function rotateForUsers({questType, durationMs, count}) {
  const cfg = await getQuestsConfig();
  if (!cfg.enabled) {
    console.log(`rotate skipped: quests disabled`);
    return {skipped: true};
  }

  const templates = await pickRandomTemplates(questType, count);
  if (templates.length === 0) {
    console.log(`rotate ${questType}: no templates`);
    return {skipped: true, reason: "no templates"};
  }

  const now = admin.firestore.Timestamp.now();
  const expiresAt = admin.firestore.Timestamp.fromMillis(Date.now() + durationMs);

  const usersSnap = await db.collection("applications").get();
  let usersTouched = 0;

  for (const userDoc of usersSnap.docs) {
    const userData = userDoc.data() || {};
    // Skip applications without an owner — those are pending invites, not active members.
    if (!userData.ownerUid) continue;

    // Step 1: clean up the user's existing daily/weekly clones for this questType.
    const stale = await userDoc.ref.collection("questProgress")
      .where("questType", "==", questType)
      .get();
    const cleanupBatch = db.batch();
    for (const sd of stale.docs) {
      cleanupBatch.delete(sd.ref);
    }
    if (!stale.empty) await cleanupBatch.commit();

    // Step 2: seed fresh clones from picked templates.
    const seedBatch = db.batch();
    for (const tplDoc of templates) {
      const tpl = tplDoc.data() || {};
      const target = Number(tpl.target) || 1;
      const clone = {
        questId: tplDoc.id,
        questType,
        progress: 0,
        target,
        startedAt: now,
        completedAt: null,
        claimedAt: null,
        xpReward: Number(tpl.xpReward) || 0,
        actionType: tpl.actionType || null,
        expiresAt,
      };
      seedBatch.set(userDoc.ref.collection("questProgress").doc(tplDoc.id), clone);
    }
    await seedBatch.commit();

    // Step 3: best-effort push.
    if (userData.fcmToken) {
      try {
        await sendPush(
          userData.fcmToken,
          questType === "weekly" ? "WEEKLY OPS DROPPED" : "DAILY MISSIONS READY",
          `${templates.length} fresh ${questType === "weekly" ? "weekly" : "daily"} mission${templates.length === 1 ? "" : "s"} — open SIDEQUESTS`,
          {type: "quest_rotation", questType},
        );
      } catch (e) {
        console.warn("rotation push failed:", e);
      }
    }

    usersTouched++;
  }

  await db.collection("config").doc("quests").set(
    {[`last${questType[0].toUpperCase()}${questType.slice(1)}RotationAt`]: now},
    {merge: true},
  );

  return {usersTouched, templatesUsed: templates.length};
}

// 10. Daily rotation — runs at 04:00 Berlin every day.
exports.rotateDailyQuests = onSchedule(
  {schedule: "every day 04:00", timeZone: "Europe/Berlin", region: "us-central1"},
  async () => {
    const cfg = await getQuestsConfig();
    if (!cfg.enabled || !cfg.dailyRotationEnabled) {
      console.log("daily rotation skipped (disabled)");
      return;
    }
    const result = await rotateForUsers({
      questType: "daily",
      durationMs: 24 * 60 * 60 * 1000,
      count: cfg.dailyQuestCount || 3,
    });
    console.log("daily rotation:", JSON.stringify(result));
  }
);

// 11. Weekly rotation — Monday 04:00 Berlin.
exports.rotateWeeklyQuests = onSchedule(
  {schedule: "every monday 04:00", timeZone: "Europe/Berlin", region: "us-central1"},
  async () => {
    const cfg = await getQuestsConfig();
    if (!cfg.enabled || !cfg.dailyRotationEnabled) {
      console.log("weekly rotation skipped (disabled)");
      return;
    }
    const result = await rotateForUsers({
      questType: "weekly",
      durationMs: 7 * 24 * 60 * 60 * 1000,
      count: cfg.weeklyQuestCount || 1,
    });
    console.log("weekly rotation:", JSON.stringify(result));
  }
);

// Manual rotation trigger for admins — useful for testing without waiting for cron.
exports.adminTriggerQuestRotation = onCall(
  {region: "us-central1", enforceAppCheck: false},
  async (request) => {
    if (!request.auth || !request.auth.uid) {
      throw new HttpsError("unauthenticated", "Sign in required");
    }
    // Admin gate
    const adminsDoc = await db.collection("config").doc("admins").get();
    const adminUids = adminsDoc.exists ? (adminsDoc.data().uids || []) : [];
    if (!adminUids.includes(request.auth.uid)) {
      throw new HttpsError("permission-denied", "Admin only");
    }
    const data = request.data || {};
    const questType = data.questType === "weekly" ? "weekly" : "daily";
    const cfg = await getQuestsConfig();
    return rotateForUsers({
      questType,
      durationMs: questType === "weekly" ? 7 * 24 * 60 * 60 * 1000 : 24 * 60 * 60 * 1000,
      count: questType === "weekly" ? (cfg.weeklyQuestCount || 1) : (cfg.dailyQuestCount || 3),
    });
  }
);

// ---------------------------------------------------------------------------
// Streaks
//
// On each XP-awarding event the user's `streak.lastActiveDate` is bumped.
// A nightly scheduled job evaluates everyone in one pass: (a) increment
// currentDays for users active yesterday or today, (b) reset to 0 for users
// with a >1 day gap, (c) award milestone XP at 3/7/30 (idempotent — bonus
// timestamps are stored).
// ---------------------------------------------------------------------------

function dateAddDays(dateStr, days) {
  const [y, m, d] = dateStr.split("-").map((s) => parseInt(s, 10));
  const dt = new Date(Date.UTC(y, m - 1, d));
  dt.setUTCDate(dt.getUTCDate() + days);
  return utcDateKey(dt);
}

exports.evaluateStreaks = onSchedule(
  {schedule: "every day 03:30", timeZone: "Europe/Berlin", region: "us-central1"},
  async () => {
    const cfg = await getQuestsConfig();
    if (!cfg.enabled || !cfg.streaksEnabled) {
      console.log("streaks skipped (disabled)");
      return;
    }
    const today = utcDateKey();
    const yesterday = dateAddDays(today, -1);
    const milestones = Object.keys(cfg.streakBonusXP || {}).map((s) => parseInt(s, 10)).filter(Number.isFinite);

    const usersSnap = await db.collection("applications").get();
    let advanced = 0;
    let reset = 0;
    let bonusesAwarded = 0;

    for (const userDoc of usersSnap.docs) {
      const userData = userDoc.data() || {};
      if (!userData.ownerUid) continue;

      const streak = userData.streak || {currentDays: 0, longestDays: 0, lastActiveDate: null, lastBonusAwardedAt: {}};
      const lastActive = streak.lastActiveDate;

      let newCurrent = streak.currentDays || 0;
      let newLongest = streak.longestDays || 0;

      if (!lastActive) {
        // No activity yet — leave the streak at 0.
        continue;
      } else if (lastActive === today || lastActive === yesterday) {
        // Active today (already counted) or yesterday (count today's transition).
        if (lastActive === yesterday) {
          newCurrent += 1;
          if (newCurrent > newLongest) newLongest = newCurrent;
        }
      } else {
        // Two-or-more day gap — reset.
        if (newCurrent > 0) {
          newCurrent = 0;
          reset++;
        }
      }

      const updates = {streak: {...streak, currentDays: newCurrent, longestDays: newLongest}};

      // Idempotent milestone bonuses.
      const bonusMap = streak.lastBonusAwardedAt || {};
      let bonusXP = 0;
      const bonusUpdates = {...bonusMap};
      for (const m of milestones) {
        if (newCurrent >= m && !bonusMap[m]) {
          bonusXP += cfg.streakBonusXP[m] || 0;
          bonusUpdates[m] = admin.firestore.Timestamp.now();
        }
      }
      if (bonusXP > 0) {
        updates.xpPoints = admin.firestore.FieldValue.increment(bonusXP);
        updates.streak = {...updates.streak, lastBonusAwardedAt: bonusUpdates};
        bonusesAwarded++;
        // Audit row.
        try {
          await db.collection("xp_transactions").add({
            source: "streak_bonus",
            userId: userData.ownerUid || "",
            userName: userData.name || "",
            userEmail: userData.email || "",
            amount: bonusXP,
            timestamp: admin.firestore.FieldValue.serverTimestamp(),
            streakDays: newCurrent,
          });
        } catch (e) {
          console.warn("streak xp audit failed:", e);
        }
        // Push.
        if (userData.fcmToken) {
          try {
            await sendPush(
              userData.fcmToken,
              `${newCurrent}-DAY STREAK`,
              `+${bonusXP} XP bonus unlocked`,
              {type: "streak_bonus", days: String(newCurrent)},
            );
          } catch (_) {}
        }
      }

      if (newCurrent !== (streak.currentDays || 0) || bonusXP > 0) {
        await userDoc.ref.set(updates, {merge: true});
        advanced++;
      }
    }

    console.log(`streaks: advanced=${advanced} reset=${reset} bonuses=${bonusesAwarded}`);
  }
);

// Hook into the existing applications doc updates: when xpPoints grows we know
// the user just did something XP-worthy, so stamp lastActiveDate. The streak
// counter itself is computed by the nightly scheduled function above.
exports.onApplicationUpdatedStreak = onDocumentUpdated(
  "applications/{appId}",
  async (event) => {
    const before = event.data.before.data() || {};
    const after = event.data.after.data() || {};
    const beforeXP = Number(before.xpPoints) || 0;
    const afterXP = Number(after.xpPoints) || 0;
    if (afterXP <= beforeXP) return;

    const today = utcDateKey();
    const streak = after.streak || {};
    if (streak.lastActiveDate === today) return;

    await event.data.after.ref.set({
      streak: {...streak, lastActiveDate: today},
    }, {merge: true});
  }
);

// ---------------------------------------------------------------------------
// AI quest drafting — Anthropic SDK
//
// Admin-only callable that drafts a TEK-flavored quest title + description
// from a free-form theme. Uses Haiku 4.5 because (a) admin-driven, (b)
// latency-tolerant, (c) output is small (~150 tokens), and (d) cost matters
// more than peak intelligence on flavor-text generation.
// ---------------------------------------------------------------------------

const TEK_VOICE_SYSTEM_PROMPT = `You generate quest copy for TEK, an invite-only nightclub & community platform.

VOICE: cyber-noir, terse, conspiratorial. Think mission briefings handed to operatives. Two to three sentences max for the description. Title MUST be UPPERCASE, two to four words, evocative.

CONSTRAINTS:
- Title: 2-4 words, UPPERCASE, no period, no quotes, evocative not literal.
- Description: 1-3 short sentences, present tense, second person ("you"). Hint at the action, don't explain it.
- Never reference XP, points, the app, or "the system" — those are mechanics, not flavor.
- Never use emoji, hashtags, or markdown.
- Match the verification mechanic (qr_code = scan something hidden, timer = stay/wait, friend_added = recruit, code_entry = enter a passphrase).

OUTPUT FORMAT — return ONLY JSON, no preamble:
{"title": "...", "description": "...", "suggestedTarget": <int>}

suggestedTarget: 1 for qr_code/code_entry; the timer minutes for timer; the friend count for friend_added.`;

exports.generateQuestWithAI = onCall(
  {
    region: "us-central1",
    enforceAppCheck: false,
    secrets: [ANTHROPIC_API_KEY],
  },
  async (request) => {
    if (!request.auth || !request.auth.uid) {
      throw new HttpsError("unauthenticated", "Sign in required");
    }

    const adminsDoc = await db.collection("config").doc("admins").get();
    const adminUids = adminsDoc.exists ? (adminsDoc.data().uids || []) : [];
    if (!adminUids.includes(request.auth.uid)) {
      throw new HttpsError("permission-denied", "Admin only");
    }

    const cfg = await getQuestsConfig();
    if (!cfg.aiGenerationEnabled) {
      throw new HttpsError("failed-precondition", "AI generation is disabled");
    }

    const data = request.data || {};
    const theme = typeof data.theme === "string" ? data.theme.trim() : "";
    const verificationType = typeof data.verificationType === "string" ? data.verificationType : "qr_code";
    const xpReward = (typeof data.xpReward === "number") ? data.xpReward : 50;
    if (!theme) {
      throw new HttpsError("invalid-argument", "theme required");
    }

    const Anthropic = require("@anthropic-ai/sdk");
    const client = new Anthropic({apiKey: ANTHROPIC_API_KEY.value()});

    const userPrompt = `THEME: ${theme}
VERIFICATION: ${verificationType}
XP REWARD: ${xpReward}

Generate a quest in TEK voice. Return ONLY the JSON object, nothing else.`;

    let response;
    try {
      response = await client.messages.create({
        model: "claude-haiku-4-5",
        max_tokens: 400,
        system: TEK_VOICE_SYSTEM_PROMPT,
        messages: [{role: "user", content: userPrompt}],
      });
    } catch (e) {
      console.error("Anthropic call failed:", e);
      throw new HttpsError("internal", `AI generation failed: ${e.message || e}`);
    }

    const textBlock = (response.content || []).find((b) => b.type === "text");
    const raw = textBlock ? textBlock.text : "";
    const cleaned = raw.replace(/^```(?:json)?\s*/i, "").replace(/```\s*$/i, "").trim();
    let parsed;
    try {
      parsed = JSON.parse(cleaned);
    } catch (e) {
      console.warn("AI returned non-JSON. Raw:", raw);
      throw new HttpsError("internal", "AI returned malformed JSON");
    }

    return {
      title: typeof parsed.title === "string" ? parsed.title.toUpperCase() : "",
      description: typeof parsed.description === "string" ? parsed.description : "",
      suggestedTarget: (typeof parsed.suggestedTarget === "number") ? parsed.suggestedTarget : 1,
    };
  }
);

// Batch variant — returns N concepts at once. Saves admin time when planning
// an event's mission list. Same gates as the single-shot version.
const TEK_VOICE_BATCH_SYSTEM_PROMPT = `You generate quest copy for TEK, an invite-only nightclub & community platform.

VOICE: cyber-noir, terse, conspiratorial. Think mission briefings handed to operatives.

CONSTRAINTS PER QUEST:
- Title: 2-4 words, UPPERCASE, no period, no quotes, evocative not literal.
- Description: 1-3 short sentences, present tense, second person ("you"). Hint at the action, don't explain it.
- Never reference XP, points, the app, or "the system".
- Never use emoji, hashtags, or markdown.
- Match the verification mechanic (qr_code = scan something hidden, timer = stay/wait, friend_added = recruit, code_entry = enter a passphrase).

BATCH RULES:
- Each quest in the batch must be distinct (different angle, different mechanic emphasis).
- Spread across difficulty: 2 easy, 2 medium, 1 hard.
- Stay coherent with the theme.

OUTPUT FORMAT — return ONLY a JSON object with a "quests" array, no preamble:
{"quests": [{"title": "...", "description": "...", "suggestedTarget": <int>}, ...]}

suggestedTarget rules:
- qr_code / code_entry → 1
- timer → number of minutes (15-90)
- friend_added → number of friends (1-3)`;

exports.generateQuestBatchWithAI = onCall(
  {
    region: "us-central1",
    enforceAppCheck: false,
    secrets: [ANTHROPIC_API_KEY],
    timeoutSeconds: 60,
  },
  async (request) => {
    if (!request.auth || !request.auth.uid) {
      throw new HttpsError("unauthenticated", "Sign in required");
    }

    const adminsDoc = await db.collection("config").doc("admins").get();
    const adminUids = adminsDoc.exists ? (adminsDoc.data().uids || []) : [];
    if (!adminUids.includes(request.auth.uid)) {
      throw new HttpsError("permission-denied", "Admin only");
    }

    const cfg = await getQuestsConfig();
    if (!cfg.aiGenerationEnabled) {
      throw new HttpsError("failed-precondition", "AI generation is disabled");
    }

    const data = request.data || {};
    const theme = typeof data.theme === "string" ? data.theme.trim() : "";
    const verificationType = typeof data.verificationType === "string" ? data.verificationType : "qr_code";
    const xpReward = (typeof data.xpReward === "number") ? data.xpReward : 50;
    const count = Math.max(2, Math.min(8, (typeof data.count === "number") ? data.count : 5));
    if (!theme) {
      throw new HttpsError("invalid-argument", "theme required");
    }

    const Anthropic = require("@anthropic-ai/sdk");
    const client = new Anthropic({apiKey: ANTHROPIC_API_KEY.value()});

    const userPrompt = `THEME: ${theme}
VERIFICATION: ${verificationType}
XP REWARD: ${xpReward}
BATCH SIZE: ${count}

Generate ${count} distinct quest concepts in TEK voice. Return ONLY the JSON object, nothing else.`;

    let response;
    try {
      response = await client.messages.create({
        model: "claude-haiku-4-5",
        max_tokens: 1500,
        system: TEK_VOICE_BATCH_SYSTEM_PROMPT,
        messages: [{role: "user", content: userPrompt}],
      });
    } catch (e) {
      console.error("Anthropic batch call failed:", e);
      throw new HttpsError("internal", `AI batch generation failed: ${e.message || e}`);
    }

    const textBlock = (response.content || []).find((b) => b.type === "text");
    const raw = textBlock ? textBlock.text : "";
    const cleaned = raw.replace(/^```(?:json)?\s*/i, "").replace(/```\s*$/i, "").trim();

    let parsed;
    try {
      parsed = JSON.parse(cleaned);
    } catch (e) {
      console.warn("AI batch returned non-JSON. Raw:", raw);
      throw new HttpsError("internal", "AI returned malformed JSON");
    }

    const rawQuests = Array.isArray(parsed.quests) ? parsed.quests : [];
    const quests = rawQuests
      .filter((q) => q && typeof q.title === "string" && typeof q.description === "string")
      .map((q) => ({
        title: q.title.toUpperCase().trim(),
        description: String(q.description).trim(),
        suggestedTarget: (typeof q.suggestedTarget === "number") ? q.suggestedTarget : 1,
      }));

    if (quests.length === 0) {
      throw new HttpsError("internal", "AI returned empty batch");
    }

    return {quests};
  }
);

