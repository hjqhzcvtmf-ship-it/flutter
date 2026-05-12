# User Management - Delete Feature

## Overview
Added ability to delete users from the Control panel's "View All Users" screen.

## What's New

### Delete User Button
- Every user card now has a red "DELETE USER" button at the bottom
- Shows confirmation dialog before deletion
- Displays loading indicator during deletion
- Automatically refreshes the user list after successful deletion

### Status Badges
- User cards now show status badges: **PENDING**, **APPROVED**, or **REJECTED**
- Color-coded:
  - 🟢 Green = Approved
  - 🟠 Orange = Pending
  - 🔴 Red = Rejected

## How to Delete a User

1. Log in as admin (linolyander@icloud.com)
2. Go to **CONTROL** tab
3. Tap **"View All Users"**
4. Find the user you want to delete
5. Tap the red **"DELETE USER"** button
6. Confirm deletion in the dialog
7. User is permanently removed from Firestore

## What Gets Deleted

When you delete a user, the following is removed:
- ✅ User's application document from Firestore
- ✅ All user data (name, email, phone, instagram, bio)
- ✅ Referral code
- ✅ XP points
- ✅ Friends list
- ✅ Friend requests
- ✅ Status information

## Use Cases

### Deleting Old Test Accounts
```
Example: Devon's old profile needs to be deleted
1. Go to Control > View All Users
2. Find "Devon" in the list
3. Tap "DELETE USER"
4. Confirm deletion
5. Devon can now reapply with a fresh application
```

### Cleaning Up Duplicates
If someone accidentally submitted multiple applications, you can delete the duplicates.

### Removing Rejected Applications
You can clean up rejected applications to keep the database tidy.

## Safety Features

- ⚠️ **Confirmation Required**: Always asks "Are you sure?" before deleting
- 🔒 **Admin Only**: Only accessible from the Control panel
- ⏳ **Loading Feedback**: Shows progress during deletion
- ✅ **Success Message**: Confirms when deletion is complete
- ❌ **Error Handling**: Shows clear error messages if something goes wrong

## Technical Details

### Implementation
- Direct Firestore deletion using document ID
- No Cloud Function needed (faster)
- Client-side operation with proper error handling
- Immediate UI refresh after deletion

### Firestore Document Path
```
/applications/{docId}
```

### Code Location
- File: `lib/app_main.dart`
- Class: `AllUsersScreen` → `_AllUsersScreenState`
- Method: `_deleteUser(Map<String, dynamic> user)`

## Example Workflow

**Before Deletion:**
```
Applications Collection:
├── abc123 (Devon - APPROVED - XP: 150)
├── def456 (Sarah - PENDING - XP: 0)
└── ghi789 (Mike - APPROVED - XP: 300)
```

**Delete Devon's old profile → Submit new application:**
```
Applications Collection:
├── def456 (Sarah - PENDING - XP: 0)
├── ghi789 (Mike - APPROVED - XP: 300)
└── jkl012 (Devon - PENDING - XP: 0)  ← New application
```

## Important Notes

- 🚨 **Deletion is permanent** - There is no undo
- 📧 No email is sent to the user when their account is deleted
- 🔄 User can reapply immediately after deletion
- 💾 Profile images in Firebase Storage are NOT automatically deleted (manual cleanup needed)

## Future Enhancements

Potential improvements:
- [ ] Bulk delete multiple users
- [ ] Delete profile images from Storage
- [ ] Archive deleted users instead of permanent deletion
- [ ] Send notification email to deleted users
- [ ] Export user data before deletion
- [ ] Restore deleted users (soft delete)
