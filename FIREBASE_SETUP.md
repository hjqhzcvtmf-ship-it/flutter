# Firebase Setup for TEK Mailbot

## Step-by-Step Setup Instructions

### 1. Create Firebase Project
- Go to [Firebase Console](https://console.firebase.google.com/)
- Click "Add Project"
- Name it "tek-nightclub-app"
- Enable Google Analytics (optional)
- Create the project

### 2. Register Your App

**For iOS:**
- In Firebase Console, click "Add app" → iOS
- Bundle ID: `com.example.flutterApplication3tek`
- Download `GoogleService-Info.plist`
- Open Xcode: `open ios/Runner.xcworkspace`
- In Xcode, right-click "Runner" folder → Add Files to "Runner"
- Select the downloaded `GoogleService-Info.plist`
- Click "Finish" (ensure it's added to Target: Runner)

**For Android (if needed):**
- In Firebase Console, click "Add app" → Android
- Package name: `com.example.flutter_application_3tek`
- Download `google-services.json`
- Place it in `android/app/google-services.json`

### 3. Update firebase_options.dart
Replace the placeholder values in `/lib/firebase_options.dart` with your actual Firebase credentials:
- Get them from Firebase Console → Project Settings → General tab
- Copy API Key, App ID, Project ID, Storage Bucket, and Messaging Sender ID

### 4. Setup Cloud Functions

**Prerequisites:**
```bash
npm install -g firebase-tools
firebase login
```

**Navigate to cloud_functions directory:**
```bash
cd /Users/linolyander/flutter_application_3tek/cloud_functions
npm install
```

**Configure Environment Variables:**

Set up Gmail or another email service:

**Option A: Using Gmail (Recommended)**
1. Enable 2FA on your Gmail account
2. Create an [App Password](https://myaccount.google.com/apppasswords)
3. Run this command in cloud_functions directory:
```bash
firebase functions:secrets:set MAIL_SENDER_EMAIL
firebase functions:secrets:set MAIL_SENDER_PASSWORD
```

If you're also using Stripe payments:
```bash
firebase functions:secrets:set STRIPE_SECRET_KEY

# Required for Stripe webhooks (recommended for production)
firebase functions:secrets:set STRIPE_WEBHOOK_SECRET
```

### Stripe Webhook Setup (Recommended)

This project includes an HTTP webhook function that verifies Stripe signatures and fulfills tickets server-side.

1. Deploy functions (or redeploy) so the webhook exists.
2. In Stripe Dashboard → Developers → Webhooks → “Add endpoint”
3. Endpoint URL:
  - `https://us-central1-tek-nightclub-app.cloudfunctions.net/stripeWebhook`
4. Events to send:
  - `payment_intent.succeeded`
5. Copy the “Signing secret” (starts with `whsec_...`)
6. Set it in Firebase:
```bash
firebase functions:secrets:set STRIPE_WEBHOOK_SECRET
```

After that, Stripe will call the webhook automatically whenever a payment succeeds.

**Option B: Using SendGrid**
1. Sign up for [SendGrid](https://sendgrid.com/)
2. Get your API key
3. Run:
```bash
firebase functions:config:set sendgrid.api_key="your-sendgrid-api-key"
```
4. Update the Cloud Function code to use SendGrid instead of nodemailer

### 5. Deploy Cloud Functions

```bash
cd /Users/linolyander/flutter_application_3tek/cloud_functions
firebase deploy --only functions
```

Watch for the URL of your deployed function. It should look like:
```
sendMembershipEmail: https://us-central1-tek-nightclub-app.cloudfunctions.net/sendMembershipEmail
```

### 6. Verify Setup in Flutter App

- Run `flutter pub get` to install new dependencies
- Hot reload or restart the app
- Test by:
  1. Filling out the membership application form
  2. Uploading a profile picture
  3. Clicking "SUBMIT APPLICATION"
  4. You should receive confirmation emails

### 7. Troubleshooting

**Error: "No matching document"**
- Ensure Firestore is enabled in Firebase Console

**Error: "Permission denied"**
- This project uses locked-down Firestore rules. Make sure:
  - Your app is signed in (anonymous auth is used)
  - Admin-only actions require adding your Firebase Auth UID to `/config/admins`

### Firestore Security (Required for production)

This repo ships with restrictive rules in `firestore.rules`.

Admin allowlist:
- Create a Firestore document: `/config/admins`
- Add field: `uids` (array of strings)
- Put your admin device UID in that array.

You can find the UID in your debug logs (look for `FirebaseAuth uid: ...`).

### App Check (Strongly Recommended)

Anonymous auth alone is not enough security if attackers can script Firebase.

This app uses `firebase_app_check` and several Cloud Functions are configured with `enforceAppCheck: true`.

Quick debug setup (fastest way to get unblocked during development):
- Run the app once and copy the log line `Firebase App Check debug token: ...`
- Firebase Console → App Check → your app → Manage debug tokens → Add token

Production setup (recommended):
- Enable Firebase App Check and enforce it for:
  - Cloud Functions
  - Firestore
- Configure provider:
  - Android: Play Integrity
  - iOS: App Attest

This ensures only your real app can call Firestore/Functions.

**Email not sending**
- Check Cloud Functions logs: `firebase functions:log`
- Verify email credentials in config
- Check spam folder

### 8. Production Checklist

- [ ] Update firebase_options.dart with production credentials
- [ ] Set proper Firestore security rules
- [ ] Enable email rate limiting in Cloud Functions
- [ ] Set up email templates for branding
- [ ] Add SMS notifications (optional)
- [ ] Test email delivery

## Admin Dashboard Setup (Optional)

You can create a simple web dashboard in Firebase Hosting to:
- View pending applications
- Approve/reject applications
- Manually generate referral codes
- View email logs

This would be a separate Firebase Hosting project with a simple HTML/React interface.
