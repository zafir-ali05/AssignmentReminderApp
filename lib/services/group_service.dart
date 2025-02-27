import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:random_string/random_string.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/group.dart';

class GroupService {
  final CollectionReference _groupsCollection = 
      FirebaseFirestore.instance.collection('groups');
  final CollectionReference _assignmentsCollection = 
      FirebaseFirestore.instance.collection('assignments');
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  Future<Group> createGroup(String name, String creatorId) async {
    // Generate a unique 6-character code
    String groupId = randomAlphaNumeric(6).toUpperCase();
    
    // Ensure the code is unique
    while ((await _groupsCollection.doc(groupId).get()).exists) {
      groupId = randomAlphaNumeric(6).toUpperCase();
    }

    final group = Group(
      id: groupId,
      name: name,
      creatorId: creatorId,
      members: [creatorId],
      createdAt: DateTime.now(),
    );

    await _groupsCollection.doc(groupId).set(group.toMap());
    return group;
  }

  Future<void> createGroupFromModel(Group group) async {
    final userId = _auth.currentUser?.uid;
    if (userId == null) {
      throw Exception('User must be authenticated');
    }

    try {
      // Create the group in the main groups collection
      await _groupsCollection.doc(group.id).set({
        ...group.toMap(),
        'creatorId': userId,
        'members': [userId], // Store as array instead of map
        'createdAt': FieldValue.serverTimestamp(),
      });

      // Add reference to user's groups collection
      await _firestore
          .collection('users')
          .doc(userId)
          .collection('groups')
          .doc(group.id)
          .set({
        'groupId': group.id,
        'name': group.name,
        'joinedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      print('Error creating group: $e');
      rethrow;
    }
  }

  Future<Group?> joinGroup(String groupId, String userId) async {
    final docSnapshot = await _groupsCollection.doc(groupId).get();
    
    if (!docSnapshot.exists) {
      throw Exception('Group not found');
    }

    final groupData = docSnapshot.data() as Map<String, dynamic>;
    final group = Group.fromMap(groupData);

    if (group.members.contains(userId)) {
      throw Exception('You are already a member of this group');
    }

    final updatedMembers = [...group.members, userId];
    await _groupsCollection.doc(groupId).update({'members': updatedMembers});

    return Group.fromMap({
      ...groupData,
      'members': updatedMembers,
    });
  }

  Future<void> leaveGroup(String groupId, String userId) async {
    final docSnapshot = await _groupsCollection.doc(groupId).get();
    
    if (!docSnapshot.exists) {
      throw Exception('Group not found');
    }

    final groupData = docSnapshot.data() as Map<String, dynamic>;
    final members = List<String>.from(groupData['members']);

    if (!members.contains(userId)) {
      throw Exception('You are not a member of this group');
    }

    members.remove(userId);

    if (members.isEmpty) {
      // Delete all assignments for this group
      final assignmentsSnapshot = await _assignmentsCollection
          .where('groupId', isEqualTo: groupId)
          .get();
      
      final batch = FirebaseFirestore.instance.batch();
      
      // Add assignment deletions to batch
      for (var doc in assignmentsSnapshot.docs) {
        batch.delete(doc.reference);
      }
      
      // Add group deletion to batch
      batch.delete(_groupsCollection.doc(groupId));
      
      // Execute all deletions in a single batch
      await batch.commit();
    } else {
      // Update group with remaining members
      await _groupsCollection.doc(groupId).update({'members': members});
    }
  }

  Stream<List<Group>> getUserGroups(String userId) {
    if (userId.isEmpty) {
      throw Exception('User ID cannot be empty');
    }

    return _groupsCollection
        .where('members', arrayContains: userId)
        .snapshots()
        .map((snapshot) {
          return snapshot.docs.map((doc) {
            try {
              return Group.fromMap({
                ...doc.data() as Map<String, dynamic>,
                'id': doc.id,
              });
            } catch (e) {
              print('Error parsing group data: $e');
              return null;
            }
          })
          .where((group) => group != null)
          .cast<Group>()
          .toList();
        });
  }

  Stream<List<Group>> getUserGroupsFromUser() {
    final userId = _auth.currentUser?.uid;
    if (userId == null) {
      throw Exception('User must be authenticated');
    }

    return _firestore
        .collection('users')
        .doc(userId)
        .collection('groups')
        .orderBy('name')
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => Group.fromMap({...doc.data(), 'id': doc.id}))
            .toList());
  }
}
