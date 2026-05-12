# TEK Application Approval Workflow

## Overview

When someone submits a membership application:
1. ✅ Application is saved to Firestore with `status: "pending"` (NO referral code yet)
2. ✅ You (Lino) receive an email notification with application details
3. ⏳ Applicant sees message: "Application submitted! You will receive an email once approved."
4. ⏳ Applicant does NOT receive referral code until you approve

## How to Approve or Reject Applications

### Method 1: Reply to Email (Simplest)
When you receive the admin notification email:
- **To APPROVE:** Reply with: `YES [Application-ID]`
- **To REJECT:** Reply with: `NO [Application-ID]`

Example:
```
YES 8xK9mPqW2vN4jLrT5sY
```

### Method 2: Use Firebase Console
1. Go to [Firebase Console](https://console.firebase.google.com/project/tek-nightclub-app/functions)
2. Find function: `approveApplication`
3. Click "Test function"
4. Enter data:
```json
{
  "appId": "8xK9mPqW2vN4jLrT5sY",
  "action": "approve"
}
```
5. Click "Test"

### Method 3: Use CLI Tool (Advanced)
```bash
cd cloud_functions
node approve-cli.js
```

This will:
1. List all pending applications
2. Prompt you for Application ID
3. Ask approve/reject
4. Process the application

## What Happens When You Approve

1. ✅ Referral code is generated (e.g., `A7B2X9`)
2. ✅ Application status changes from `pending` → `approved`
3. ✅ Welcome email is sent to applicant with referral code
4. ✅ Applicant can now use the code to log in

## What Happens When You Reject

1. ❌ Application status changes to `rejected`
2. ❌ Polite rejection email is sent to applicant
3. ❌ No referral code is generated

## Email Template Examples

### Admin Notification Email (You Receive)
```
Subject: New TEK Application: Devon Smith

Name: Devon Smith
Email: devon@example.com
Phone: +1 (555) 123-4567
Instagram: @devonsmith
Bio: Love nightlife and meeting new people!
Profile Image: [View Image]

To approve this application, reply with:
YES 8xK9mPqW2vN4jLrT5sY

To reject this application, reply with:
NO 8xK9mPqW2vN4jLrT5sY

Application ID: 8xK9mPqW2vN4jLrT5sY
```

### Welcome Email (Approved Applicant Receives)
```
Subject: Welcome to TEK! Your Referral Code

Hi Devon,

Welcome to TEK! We're excited to have you join our community.

Your referral code is: A7B2X9

Use this code to access the app and start exploring events!

Best regards,
The TEK Team
```

### Rejection Email (Rejected Applicant Receives)
```
Subject: TEK Application Update

Hi Devon,

Thank you for applying to TEK. Unfortunately, we are unable to approve 
your application at this time.

We wish you all the best!

Best regards,
The TEK Team
```

## Checking Pending Applications

### Via Firebase Console
1. Go to [Firestore Database](https://console.firebase.google.com/project/tek-nightclub-app/firestore)
2. Navigate to `applications` collection
3. Filter by `status == "pending"`

### Via CLI
```bash
cd cloud_functions
node approve-cli.js
```
Lists all pending applications with full details.

## Troubleshooting

### "Application not found" error
- Double-check the Application ID from the email
- Ensure you're copying the full ID (no extra spaces)

### "Application already approved/rejected"
- This application has already been processed
- Check Firestore to see the current status

### Email not sending
- Check Firebase Functions logs
- Verify `MAIL_SENDER_EMAIL` and `MAIL_SENDER_PASSWORD` secrets are set
- Ensure Gmail App Password is valid

## Technical Details

### Cloud Functions
- `notifyAdminNewApplication` - Sends notification to admin when application submitted
- `approveApplication` - Processes approval/rejection and sends welcome/rejection email
- `sendMembershipEmail` - Legacy function (still available but not used in new flow)

### Firestore Structure
```javascript
applications/{docId}
  name: string
  email: string
  phone: string
  instagram: string
  bio: string
  profileImageUrl: string (optional)
  status: "pending" | "approved" | "rejected"
  submittedAt: timestamp
  approvedAt: timestamp (only if approved)
  rejectedAt: timestamp (only if rejected)
  referralCode: string (only if approved)
  xpPoints: number
  friends: array
  friendRequests: array
```

### Application Flow Diagram
```
User Submits Application
         ↓
    Firestore Save
    (status: pending)
         ↓
   Admin Email Sent
         ↓
    [You Decide]
    /          \
APPROVE      REJECT
   ↓             ↓
Generate      No Code
Code (A7B2X9)   Generated
   ↓             ↓
Update         Update
Firestore      Firestore
(approved)     (rejected)
   ↓             ↓
Welcome       Rejection
Email Sent    Email Sent
```

## Security

- Only authenticated users can submit applications
- Only admins can approve/reject applications  
- Referral codes are generated securely
- Email verification prevents duplicates
- Phone number verification prevents duplicates

## Future Enhancements

- [ ] Email reply parsing (auto-detect YES/NO replies)
- [ ] Admin dashboard web interface
- [ ] Batch approval/rejection
- [ ] Application review notes
- [ ] Applicant communication history
