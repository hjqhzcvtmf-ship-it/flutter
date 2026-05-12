# TEK Mailbot Setup - Quick Reference

## 🔴 CURRENT STATUS (Jan 23, 2026 - End of Day)

**ISSUE:** Cloud Function deployed successfully but app gets `[firebase_functions/internal] INTERNAL` error when calling it.

**What's Working:**
- ✅ Firebase project created (tek-nightclub-app)
- ✅ iOS app registered and configured
- ✅ Cloud Function deploys successfully to us-central1
- ✅ Flutter app builds and runs on simulator
- ✅ All UI working (forms, navigation, image picker)

**Current Problem:**
- ❌ When submitting membership application, getting INTERNAL error
- Function is deployed but not being called successfully
- Error happens even with minimal test function (just returns "TEST123")

**Latest Code State:**
- Cloud Function: Minimal test version at `/cloud_functions/functions/index.js`
- Flutter app: Updated with detailed error logging in `_submitApplication()` method
- App calls: `FirebaseFunctions.instanceFor(region: 'us-central1').httpsCallable('sendMembershipEmail')`

**Next Steps to Try:**
1. Check Firebase Console logs at: https://console.firebase.google.com/project/tek-nightclub-app/functions/logs
2. Verify Cloud Functions API is fully enabled
3. Check IAM permissions for Cloud Functions service account
4. Try upgrading cloud_functions package from 4.6.0 to latest
5. Consider switching back to 1st gen functions if 2nd gen has compatibility issues
6. Test function directly via curl/Postman to isolate if issue is Flutter or Firebase

**Credentials Set:**
- Email: linolyander@outlook.com
- App Password: frzf yugb uxxz jizn (stored as Firebase secrets)
- Admin Email: linolyander@icloud.com

## What I've Set Up:

✅ **Flutter App Updates**
- Added Firebase and Cloud Functions dependencies to `pubspec.yaml`
- Updated `main.dart` to initialize Firebase on app startup
- Modified membership application submit function to call Cloud Function
- Creates `firebase_options.dart` (placeholder - needs your credentials)

✅ **Cloud Functions Created**
- `/cloud_functions/functions/index.js` - Email sending logic
- `/cloud_functions/package.json` - Node.js dependencies

✅ **Documentation**
- `FIREBASE_SETUP.md` - Complete step-by-step setup guide

## What Happens Now:

1. User fills out membership form
2. Clicks "SUBMIT APPLICATION"
3. App calls Firebase Cloud Function `sendMembershipEmail`
4. Cloud Function:
   - Generates random referral code
   - Sends email to applicant with their code
   - Sends email to linolyander@icloud.com with application details
   - Saves application to Firestore database
5. User sees success message with referral code

## Quick Start (From scratch):

```bash
# 1. Setup Firebase CLI
npm install -g firebase-tools
firebase login

# 2. Go to cloud_functions directory
cd cloud_functions
npm install

# 3. Set email credentials

# Recommended (2nd gen): Firebase Secrets
firebase functions:secrets:set MAIL_SENDER_EMAIL
firebase functions:secrets:set MAIL_SENDER_PASSWORD

# Also needed for Stripe payments (if using createPaymentIntent)
firebase functions:secrets:set STRIPE_SECRET_KEY

# 4. Deploy to Firebase
firebase deploy --only functions

# 5. Update firebase_options.dart with your project credentials
# (Get from Firebase Console → Project Settings)

# 6. Back in Flutter app
flutter pub get
flutter run
```

## Testing:

1. Open app
2. Tap "APPLY FOR MEMBERSHIP"
3. Fill in all fields + upload picture
4. Click "SUBMIT APPLICATION"
5. Check email (yours and linolyander@icloud.com) for confirmation emails

## Email Features Implemented:

✅ Confirmation email to applicant
✅ Admin notification to linolyander@icloud.com
✅ Automatic referral code generation
✅ Application saved to Firestore
✅ Error handling and logging

## Next Steps:

1. Create Firebase project at console.firebase.google.com
2. Register iOS app with your Bundle ID
3. Download GoogleService-Info.plist and add to Xcode
4. Follow the detailed setup guide in FIREBASE_SETUP.md

---

## 🔧 DEBUGGING NOTES (Jan 23, 2026)

### What We Tried:
1. ✅ Deployed 1st gen function → Worked but got deprecation warnings
2. ✅ Migrated to 2nd gen functions → INTERNAL error
3. ✅ Used defineSecret() for credentials → Still INTERNAL error  
4. ✅ Hardcoded credentials in function → Still INTERNAL error
5. ✅ Created minimal test function (no email, just return test data) → Still INTERNAL error
6. ✅ Added detailed error logging to Flutter app → Confirmed FirebaseFunctionsException with code "internal"

### Error Output:
```
ERROR TYPE: FirebaseFunctionsException
Firebase Functions Error Code: internal
Firebase Functions Error Message: INTERNAL
Firebase Functions Error Details: null
```

### Files Modified Today:
- `/cloud_functions/functions/index.js` - Now minimal test version
- `/lib/main.dart` - Added FirebaseFunctionsException detailed logging
- `/pubspec.yaml` - Has cloud_functions: ^4.6.0 (might need upgrade)

### Commands to Resume:
```bash
# Check logs
open "https://console.firebase.google.com/project/tek-nightclub-app/functions/logs"

# Redeploy if needed
cd /Users/linolyander/flutter_application_3tek
firebase deploy --only functions --project tek-nightclub-app

# Run app with logging
flutter run

# Upgrade cloud_functions if needed
flutter pub upgrade cloud_functions
```

### Possible Root Causes:
- Cloud Functions API might need additional permissions
- Region mismatch (we specified us-central1 but maybe default is different)
- cloud_functions package version incompatibility with 2nd gen functions
- Service account permissions issue
- Need to enable unauthenticated invocations for callable functions

Need help with any step?
