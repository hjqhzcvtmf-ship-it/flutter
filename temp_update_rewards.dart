import 'package:cloud_firestore/cloud_firestore.dart';

void main() async {
  // This assumes Firebase is already initialized
  final db = FirebaseFirestore.instance;
  
  print('Searching for user G5ET2H...');
  final snapshot = await db.collection('applications')
      .where('referralCode', isEqualTo: 'G5ET2H')
      .limit(1)
      .get();

  if (snapshot.docs.isEmpty) {
    print('ERROR: User not found');
    return;
  }

  final docRef = snapshot.docs.first.reference;
  
  // Create 3 rewards all with level 1
  final rewards = [
    {'type': 'drink', 'level': 1, 'createdAt': Timestamp.now()},
    {'type': 'drink', 'level': 1, 'createdAt': Timestamp.now()},
    {'type': 'drink', 'level': 1, 'createdAt': Timestamp.now()},
  ];

  print('Updating rewards...');
  await docRef.update({'rewards': rewards});
  
  print('✓ Done! User now has 3 level-1 rewards');
}
