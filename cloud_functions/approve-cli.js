#!/usr/bin/env node

/**
 * TEK Application Approval CLI
 * 
 * Usage:
 *   node approve-cli.js <appId> approve
 *   node approve-cli.js <appId> reject
 * 
 * Or run interactively:
 *   node approve-cli.js
 */

const admin = require('firebase-admin');
const readline = require('readline');

// Initialize Firebase Admin
const serviceAccount = require('./serviceAccountKey.json');
admin.initializeApp({
  credential: admin.credential.cert(serviceAccount)
});

const db = admin.firestore();

function generateReferralCode() {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  let code = '';
  for (let i = 0; i < 6; i++) {
    code += chars.charAt(Math.floor(Math.random() * chars.length));
  }
  return code;
}

async function listPendingApplications() {
  const snapshot = await db.collection('applications')
    .where('status', '==', 'pending')
    .orderBy('submittedAt', 'desc')
    .get();

  if (snapshot.empty) {
    console.log('No pending applications.\n');
    return [];
  }

  console.log('\n📋 PENDING APPLICATIONS:\n');
  const apps = [];
  snapshot.forEach((doc) => {
    const data = doc.data();
    apps.push({ id: doc.id, ...data });
    console.log(`ID: ${doc.id}`);
    console.log(`Name: ${data.name}`);
    console.log(`Email: ${data.email}`);
    console.log(`Phone: ${data.phone}`);
    console.log(`Instagram: @${data.instagram}`);
    console.log(`Bio: ${data.bio}`);
    if (data.profileImageUrl) {
      console.log(`Profile Image: ${data.profileImageUrl}`);
    }
    console.log('---\n');
  });

  return apps;
}

async function approveApplication(appId) {
  const appRef = db.collection('applications').doc(appId);
  const appDoc = await appRef.get();

  if (!appDoc.exists) {
    throw new Error('Application not found');
  }

  const appData = appDoc.data();

  if (appData.status !== 'pending') {
    throw new Error(`Application is already ${appData.status}`);
  }

  // Generate referral code
  const referralCode = generateReferralCode();

  // Update application
  await appRef.update({
    referralCode: referralCode,
    status: 'approved',
    approvedAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  console.log(`\n✅ Application APPROVED!`);
  console.log(`   Name: ${appData.name}`);
  console.log(`   Email: ${appData.email}`);
  console.log(`   Referral Code: ${referralCode}`);
  console.log(`\n⚠️  IMPORTANT: You must manually trigger the Cloud Function to send the welcome email.`);
  console.log(`   Run this command:`);
  console.log(`   firebase functions:config:get | node -e "const {approveApplication} = require('./index.js'); approveApplication({data: {appId: '${appId}', action: 'approve'}})"`);
  console.log(`\n   Or use the Firebase Console to call: approveApplication({appId: '${appId}', action: 'approve'})\n`);
}

async function rejectApplication(appId) {
  const appRef = db.collection('applications').doc(appId);
  const appDoc = await appRef.get();

  if (!appDoc.exists) {
    throw new Error('Application not found');
  }

  const appData = appDoc.data();

  if (appData.status !== 'pending') {
    throw new Error(`Application is already ${appData.status}`);
  }

  await appRef.update({
    status: 'rejected',
    rejectedAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  console.log(`\n❌ Application REJECTED`);
  console.log(`   Name: ${appData.name}`);
  console.log(`   Email: ${appData.email}\n`);
}

async function interactive() {
  const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout
  });

  const question = (prompt) => new Promise((resolve) => {
    rl.question(prompt, resolve);
  });

  try {
    const apps = await listPendingApplications();
    
    if (apps.length === 0) {
      rl.close();
      process.exit(0);
    }

    const appId = await question('Enter Application ID: ');
    const action = await question('Action (approve/reject): ');

    if (action.toLowerCase() === 'approve') {
      await approveApplication(appId.trim());
    } else if (action.toLowerCase() === 'reject') {
      await rejectApplication(appId.trim());
    } else {
      console.log('Invalid action. Use "approve" or "reject".');
    }
  } catch (error) {
    console.error('Error:', error.message);
  } finally {
    rl.close();
    process.exit(0);
  }
}

async function main() {
  const args = process.argv.slice(2);

  if (args.length === 0) {
    // Interactive mode
    await interactive();
  } else if (args.length === 2) {
    // CLI mode
    const [appId, action] = args;
    
    try {
      if (action.toLowerCase() === 'approve') {
        await approveApplication(appId);
      } else if (action.toLowerCase() === 'reject') {
        await rejectApplication(appId);
      } else {
        console.log('Invalid action. Use "approve" or "reject".');
        process.exit(1);
      }
      process.exit(0);
    } catch (error) {
      console.error('Error:', error.message);
      process.exit(1);
    }
  } else {
    console.log('Usage:');
    console.log('  node approve-cli.js                    # Interactive mode');
    console.log('  node approve-cli.js <appId> approve    # Approve application');
    console.log('  node approve-cli.js <appId> reject     # Reject application');
    process.exit(1);
  }
}

main();
