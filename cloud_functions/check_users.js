const admin = require("firebase-admin");
admin.initializeApp({ projectId: "tek-nightclub-app" });
const db = admin.firestore();

(async () => {
  const snap = await db.collection("applications").get();
  const statuses = {};
  let noEmail = 0;
  const emailSet = new Set();
  let dupes = 0;

  snap.docs.forEach((d) => {
    const data = d.data();
    const status = (data.status || "").toLowerCase().trim() || "(none)";
    const email = (data.email || "").trim().toLowerCase();
    statuses[status] = (statuses[status] || 0) + 1;
    if (!email || !email.includes("@")) {
      noEmail++;
    } else {
      if (emailSet.has(email)) dupes++;
      emailSet.add(email);
    }
  });

  console.log("Total docs:", snap.size);
  console.log("Unique emails:", emailSet.size);
  console.log("Duplicate emails:", dupes);
  console.log("No email:", noEmail);
  console.log("Status breakdown:", JSON.stringify(statuses, null, 2));
  process.exit(0);
})();
