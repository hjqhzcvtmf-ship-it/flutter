import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'cosmos_bg.dart';
import 'observability.dart';
import 'tek_sounds.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_stripe/flutter_stripe.dart' as stripe;
import 'package:uuid/uuid.dart';
import 'package:share_plus/share_plus.dart';
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';
import 'package:intl/intl.dart';
import 'firebase_options.dart';
import 'package:qr_flutter/qr_flutter.dart' as qr_flutter;
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shimmer/shimmer.dart';
import 'package:cached_network_image/cached_network_image.dart';

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // System handles background/terminated notifications via APNs — no action needed here.
}

// Global Firestore instance
late final FirebaseFirestore db;

// Global storage for application data
Map<String, dynamic> _applicationData = {};

const List<String> _ugcReportCategories = <String>[
  'Harassment or bullying',
  'Hate speech',
  'Spam',
  'Sexual or explicit content',
  'Threats or violence',
  'Impersonation',
  'Other',
];

final List<RegExp> _prohibitedContentPatterns = <RegExp>[
  RegExp(r'\bfuck(?:ing|ed|er)?\b', caseSensitive: false),
  RegExp(r'\bshit(?:ty)?\b', caseSensitive: false),
  RegExp(r'\bbitch(?:es)?\b', caseSensitive: false),
  RegExp(r'\basshole\b', caseSensitive: false),
  RegExp(r'\bbastard\b', caseSensitive: false),
  RegExp(r'\bdick\b', caseSensitive: false),
  RegExp(r'\bcunt\b', caseSensitive: false),
  RegExp(r'\bslut\b', caseSensitive: false),
  RegExp(r'\bwhore\b', caseSensitive: false),
  RegExp(r'\bporn\b', caseSensitive: false),
];

bool containsProhibitedContent(String text) {
  final value = text.trim();
  if (value.isEmpty) return false;
  return _prohibitedContentPatterns.any((pattern) => pattern.hasMatch(value));
}

Future<QueryDocumentSnapshot<Map<String, dynamic>>?>
_getApplicationDocByReferralCode(String? referralCode) async {
  final code = (referralCode ?? '').trim();
  if (code.isEmpty) return null;
  final snapshot = await FirebaseFirestore.instance
      .collection('applications')
      .where('referralCode', isEqualTo: code)
      .limit(1)
      .get();
  if (snapshot.docs.isEmpty) return null;
  return snapshot.docs.first;
}

Future<List<String>> _getBlockedUsersForReferralCode(
  String? referralCode,
) async {
  final doc = await _getApplicationDocByReferralCode(referralCode);
  if (doc == null) return const <String>[];
  return (doc.data()['blockedUsers'] as List?)?.cast<String>() ??
      const <String>[];
}

Future<void> _blockReferralCode({
  required String currentUserCode,
  required String targetCode,
}) async {
  final myDoc = await _getApplicationDocByReferralCode(currentUserCode);
  if (myDoc == null) throw Exception('User profile not found');
  await myDoc.reference.update({
    'blockedUsers': FieldValue.arrayUnion(<String>[targetCode]),
  });
  // Apple Guideline 1.2: Blocking must notify the developer of the
  // inappropriate content so they can act within 24 hours.
  try {
    await FirebaseFirestore.instance.collection('moderation_reports').add({
      'reporterCode': currentUserCode,
      'reporterUid': FirebaseAuth.instance.currentUser?.uid,
      'reportedUserCode': targetCode,
      'category': 'Block',
      'details': 'User was blocked. Content hidden from reporter\'s feed.',
      'source': 'block_action',
      'type': 'user',
      'timestamp': Timestamp.now(),
      'status': 'pending',
    });
  } catch (_) {
    // Best-effort: don't fail the block if the report write fails
  }
}

Future<void> _unblockReferralCode({
  required String currentUserCode,
  required String targetCode,
}) async {
  final myDoc = await _getApplicationDocByReferralCode(currentUserCode);
  if (myDoc == null) throw Exception('User profile not found');
  await myDoc.reference.update({
    'blockedUsers': FieldValue.arrayRemove(<String>[targetCode]),
  });
}

Future<bool> _areUsersBlocked({
  required String? currentUserCode,
  required String? targetCode,
}) async {
  final mine = (currentUserCode ?? '').trim();
  final theirs = (targetCode ?? '').trim();
  if (mine.isEmpty || theirs.isEmpty) return false;

  final myBlocked = await _getBlockedUsersForReferralCode(mine);
  if (myBlocked.contains(theirs)) return true;

  final theirBlocked = await _getBlockedUsersForReferralCode(theirs);
  return theirBlocked.contains(mine);
}

Iterable<List<T>> _chunkList<T>(List<T> items, int chunkSize) sync* {
  for (int index = 0; index < items.length; index += chunkSize) {
    final end = (index + chunkSize < items.length)
        ? index + chunkSize
        : items.length;
    yield items.sublist(index, end);
  }
}

/// Deletes the current user's account data from Firestore and profile image from Storage.
Future<void> deleteCurrentUserAccount() async {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) throw Exception('No user signed in');
  final uid = user.uid;

  // Delete Firestore user document (adjust collection name as needed)
  try {
    await db.collection('users').doc(uid).delete();
  } catch (e) {
    print('Error deleting Firestore user document: $e');
  }

  // Delete profile image from Firebase Storage (adjust path as needed)
  try {
    final profileImageRef = FirebaseStorage.instance.ref().child(
      'profile_images/$uid.jpg',
    );
    await profileImageRef.delete();
  } catch (e) {
    print('Error deleting profile image from Storage: $e');
  }

  // Optionally sign out and clear local data
  try {
    await FirebaseAuth.instance.signOut();
  } catch (e) {
    print('Error signing out: $e');
  }

  // Clear local app data if needed
  _applicationData.clear();
  final prefs = await SharedPreferences.getInstance();
  await prefs.clear();
}

const String tekAdminModePrefsKey = 'tek_admin_mode';

final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

class ReferralSessionManager {
  ReferralSessionManager._();

  static final ReferralSessionManager instance = ReferralSessionManager._();

  static const _deviceIdKey = 'tek_device_id';
  static const _sessionIdPrefsKey = 'tek_active_session_id';
  static const _sessionAppIdPrefsKey = 'tek_active_session_app_id';
  final Uuid _uuid = const Uuid();

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _sub;

  String? _referralCode;
  String? _sessionId;
  String? _deviceId;
  String? _uid;

  Future<String> _getOrCreateDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = (prefs.getString(_deviceIdKey) ?? '').trim();
    if (existing.isNotEmpty) return existing;
    final fresh = _uuid.v4();
    await prefs.setString(_deviceIdKey, fresh);
    return fresh;
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    _referralCode = null;
    _sessionId = null;
    _uid = null;
    // Keep _deviceId cached.
  }

  Future<void> _kickToLogin({required String reason}) async {
    await stop();

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('userReferralCode');
    await prefs.remove('isAdmin');
    await prefs.remove(tekAdminModePrefsKey);
    await prefs.remove(_sessionIdPrefsKey);
    await prefs.remove(_sessionAppIdPrefsKey);

    _applicationData.clear();

    try {
      await FirebaseAuth.instance.signOut();
    } catch (_) {
      // Best-effort.
    }

    final ctx = appNavigatorKey.currentContext;
    if (ctx != null) {
      ScaffoldMessenger.of(ctx).showSnackBar(
        SnackBar(
          content: Text(reason),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 4),
        ),
      );
    }

    appNavigatorKey.currentState?.pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const ReferralCodeScreen()),
      (route) => false,
    );
  }

  Future<void> ensureActiveForReferralCode(String referralCode) async {
    final trimmed = referralCode.trim().toUpperCase();
    if (trimmed.isEmpty) return;

    var currentUid = FirebaseAuth.instance.currentUser?.uid;
    if (currentUid == null) {
      // Be resilient: if bootstrap/auth raced, try signing in now.
      await FirebaseAuth.instance.signInAnonymously();
      currentUid = FirebaseAuth.instance.currentUser?.uid;
    }
    if (currentUid == null) {
      throw StateError('Not signed in');
    }

    // Force-mint/refresh an ID token before calling Cloud Functions.
    // This helps in cases where Functions is invoked immediately after sign-in.
    final token = await FirebaseAuth.instance.currentUser?.getIdToken(true);
    if (token == null || token.isEmpty) {
      throw StateError('Failed to obtain Firebase ID token');
    }

    // Idempotent: if we're already enforcing this code, just return.
    if (_referralCode == trimmed && _uid == currentUid && _sub != null) {
      return;
    }

    await stop();

    _referralCode = trimmed;
    _uid = currentUid;
    _deviceId ??= await _getOrCreateDeviceId();

    final functions = FirebaseFunctions.instanceFor(region: 'us-central1');
    final activate = functions.httpsCallable(
      'activateApplicationSessionByReferralCode',
    );

    Future<HttpsCallableResult<dynamic>> callActivate() =>
        activate.call({'referralCode': trimmed, 'deviceId': _deviceId});

    HttpsCallableResult<dynamic> res;
    try {
      res = await callActivate().timeout(const Duration(seconds: 20));
    } on FirebaseFunctionsException catch (e) {
      // Retry once after a forced auth/token refresh.
      if (e.code == 'unauthenticated') {
        try {
          await FirebaseAuth.instance.signOut();
        } catch (_) {}
        await FirebaseAuth.instance.signInAnonymously();
        await FirebaseAuth.instance.currentUser?.getIdToken(true);
        await Future<void>.delayed(const Duration(milliseconds: 350));
        res = await callActivate().timeout(const Duration(seconds: 20));
      } else {
        rethrow;
      }
    }

    final data = res.data;
    final appId = (data is Map && data['appId'] is String)
        ? (data['appId'] as String).trim()
        : '';
    final sessionId = (data is Map && data['sessionId'] is String)
        ? (data['sessionId'] as String).trim()
        : '';

    if (appId.isEmpty || sessionId.isEmpty) {
      throw StateError(
        'activateApplicationSessionByReferralCode returned invalid data',
      );
    }

    _sessionId = sessionId;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_sessionIdPrefsKey, sessionId);
    await prefs.setString(_sessionAppIdPrefsKey, appId);

    Obs.logEvent('referral_redeemed', {'app_id': appId});
    Obs.setUser(FirebaseAuth.instance.currentUser?.uid, referralCode: trimmed);

    _sub = db
        .collection('applications')
        .doc(appId)
        .snapshots()
        .listen(
          (snap) async {
            // Firestore often emits cached (potentially stale) snapshots first.
            // Never force-logout based on cache state.
            final isFromCache = snap.metadata.isFromCache;

            if (!snap.exists) {
              if (isFromCache) return;
              await _kickToLogin(
                reason: 'Logged out: membership record not found.',
              );
              return;
            }
            final doc = snap.data() ?? {};
            final activeSessionId = doc['activeSessionId'] is String
                ? (doc['activeSessionId'] as String).trim()
                : '';

            if (isFromCache) return;

            // If another device activates this referral code, it overwrites the activeSessionId.
            // We treat any mismatch as a forced logout.
            if (_sessionId != null &&
                activeSessionId.isNotEmpty &&
                activeSessionId != _sessionId) {
              await _kickToLogin(
                reason:
                    'You were logged out because this account was used on another device.',
              );
              return;
            }
          },
          onError: (e) {
            // If listener fails, don’t force logout; allow app to keep running.
            debugPrint('ReferralSessionManager listener error: $e');
          },
        );
  }
}

class AdminStatusManager {
  AdminStatusManager._();

  static final AdminStatusManager instance = AdminStatusManager._();

  Future<bool> isCurrentUserAdmin() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || uid.isEmpty) return false;

    final functions = FirebaseFunctions.instanceFor(region: 'us-central1');
    final callable = functions.httpsCallable('getAdminStatus');
    final res = await callable.call().timeout(const Duration(seconds: 10));
    final data = res.data;
    if (data is Map && data['isAdmin'] == true) return true;
    return false;
  }
}

// ==================== POLISH HELPERS ====================

/// Cinematic page transition: fade + subtle scale, ~280ms.
Route<T> cinematicRoute<T>(Widget page) {
  return PageRouteBuilder<T>(
    transitionDuration: const Duration(milliseconds: 280),
    reverseTransitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (_, __, ___) => page,
    transitionsBuilder: (_, animation, __, child) {
      final curve = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: curve,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.96, end: 1.0).animate(curve),
          child: child,
        ),
      );
    },
  );
}

/// Pulsing green glow wrapper for key CTA buttons.
class GlowPulse extends StatefulWidget {
  final Widget child;
  final Color color;
  final double maxBlur;
  const GlowPulse({super.key, required this.child, this.color = const Color(0xFF00FF41), this.maxBlur = 22});

  @override
  State<GlowPulse> createState() => _GlowPulseState();
}

class _GlowPulseState extends State<GlowPulse> with SingleTickerProviderStateMixin {
  late AnimationController _c;
  late Animation<double> _a;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat(reverse: true);
    _a = Tween<double>(begin: 4, end: widget.maxBlur).animate(CurvedAnimation(parent: _c, curve: Curves.easeInOut));
  }

  @override
  void dispose() { _c.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _a,
      builder: (_, child) => Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          boxShadow: [BoxShadow(color: widget.color.withValues(alpha: 0.45), blurRadius: _a.value, spreadRadius: 1)],
        ),
        child: child,
      ),
      child: widget.child,
    );
  }
}

/// Top-down green pill toast for XP claim & similar wins.
void showXPToast(BuildContext context, {required String title, String? subtitle, IconData icon = Icons.bolt}) {
  HapticFeedback.mediumImpact();
  TekSounds.instance.claimXp();
  final overlay = Overlay.of(context);
  final entry = OverlayEntry(
    builder: (ctx) => _XPToastWidget(title: title, subtitle: subtitle, icon: icon),
  );
  overlay.insert(entry);
  Future.delayed(const Duration(milliseconds: 2400), () => entry.remove());
}

class _XPToastWidget extends StatefulWidget {
  final String title;
  final String? subtitle;
  final IconData icon;
  const _XPToastWidget({required this.title, this.subtitle, required this.icon});

  @override
  State<_XPToastWidget> createState() => _XPToastWidgetState();
}

class _XPToastWidgetState extends State<_XPToastWidget> with SingleTickerProviderStateMixin {
  late AnimationController _c;
  late Animation<Offset> _slide;
  late Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 320));
    _slide = Tween<Offset>(begin: const Offset(0, -1.2), end: Offset.zero)
        .animate(CurvedAnimation(parent: _c, curve: Curves.easeOutCubic));
    _fade = CurvedAnimation(parent: _c, curve: Curves.easeOut);
    _c.forward();
    Future.delayed(const Duration(milliseconds: 1900), () { if (mounted) _c.reverse(); });
  }

  @override
  void dispose() { _c.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 12,
      left: 24,
      right: 24,
      child: SlideTransition(
        position: _slide,
        child: FadeTransition(
          opacity: _fade,
          child: Material(
            color: Colors.transparent,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
              decoration: BoxDecoration(
                color: const Color(0xFF00FF41),
                borderRadius: BorderRadius.circular(40),
                boxShadow: [BoxShadow(color: const Color(0xFF00FF41).withValues(alpha: 0.6), blurRadius: 24, spreadRadius: 2)],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(widget.icon, color: Colors.black, size: 20),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(widget.title, style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 14, letterSpacing: 1.2)),
                        if (widget.subtitle != null && widget.subtitle!.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(widget.subtitle!, style: const TextStyle(color: Colors.black87, fontSize: 11, letterSpacing: 0.5)),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// XP value that animates from previous to new whenever the value changes.
class AnimatedXP extends StatelessWidget {
  final int value;
  final TextStyle style;
  final String suffix;
  const AnimatedXP({super.key, required this.value, required this.style, this.suffix = ' XP'});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: value.toDouble()),
      duration: const Duration(milliseconds: 900),
      curve: Curves.easeOutCubic,
      builder: (_, v, __) => Text('${v.round()}$suffix', style: style),
    );
  }
}

// ==================== SKELETONS, FADE-IN IMAGE, STAGGER ====================

class SkeletonCard extends StatelessWidget {
  final double height;
  final double? width;
  final double radius;
  const SkeletonCard({super.key, this.height = 80, this.width, this.radius = 12});

  @override
  Widget build(BuildContext context) {
    return Shimmer.fromColors(
      baseColor: Colors.white.withValues(alpha: 0.06),
      highlightColor: const Color(0xFF00FF41).withValues(alpha: 0.18),
      period: const Duration(milliseconds: 1400),
      child: Container(
        width: width ?? double.infinity,
        height: height,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(radius),
        ),
      ),
    );
  }
}

class SkeletonList extends StatelessWidget {
  final int count;
  final double itemHeight;
  final EdgeInsets padding;
  const SkeletonList({super.key, this.count = 5, this.itemHeight = 88, this.padding = const EdgeInsets.fromLTRB(16, 12, 16, 100)});

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: padding,
      physics: const BouncingScrollPhysics(),
      itemCount: count,
      itemBuilder: (_, __) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: SkeletonCard(height: itemHeight),
      ),
    );
  }
}

class SkeletonAvatar extends StatelessWidget {
  final double size;
  const SkeletonAvatar({super.key, this.size = 80});

  @override
  Widget build(BuildContext context) {
    return Shimmer.fromColors(
      baseColor: Colors.white.withValues(alpha: 0.06),
      highlightColor: const Color(0xFF00FF41).withValues(alpha: 0.18),
      child: Container(
        width: size,
        height: size,
        decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.white12),
      ),
    );
  }
}

class FadeInNetImage extends StatelessWidget {
  final String url;
  final double? width;
  final double? height;
  final BoxFit fit;
  final BorderRadius? borderRadius;
  final double? avatarSize;
  const FadeInNetImage({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.borderRadius,
    this.avatarSize,
  });

  @override
  Widget build(BuildContext context) {
    final placeholder = avatarSize != null
        ? SkeletonAvatar(size: avatarSize!)
        : SkeletonCard(height: height ?? 150, width: width, radius: borderRadius?.topLeft.x ?? 12);
    final errorWidget = Container(
      width: width,
      height: height,
      color: Colors.grey[900],
      child: const Icon(Icons.image, color: Colors.white24, size: 40),
    );
    final image = CachedNetworkImage(
      imageUrl: url,
      width: width,
      height: height,
      fit: fit,
      fadeInDuration: const Duration(milliseconds: 240),
      fadeOutDuration: const Duration(milliseconds: 120),
      placeholder: (_, __) => placeholder,
      errorWidget: (_, __, ___) => errorWidget,
    );
    if (avatarSize != null) {
      return ClipOval(child: SizedBox(width: avatarSize, height: avatarSize, child: image));
    }
    if (borderRadius != null) {
      return ClipRRect(borderRadius: borderRadius!, child: image);
    }
    return image;
  }
}

class _FullscreenImageView extends StatelessWidget {
  final String url;
  const _FullscreenImageView({required this.url});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Center(
        child: InteractiveViewer(
          minScale: 1.0,
          maxScale: 4.0,
          child: FadeInNetImage(url: url, fit: BoxFit.contain),
        ),
      ),
    );
  }
}

class StaggeredItem extends StatefulWidget {
  final int index;
  final Widget child;
  const StaggeredItem({super.key, required this.index, required this.child});

  @override
  State<StaggeredItem> createState() => _StaggeredItemState();
}

class _StaggeredItemState extends State<StaggeredItem> with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 320));
    _fade = CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);
    _slide = Tween<Offset>(begin: const Offset(0, 0.06), end: Offset.zero)
        .animate(CurvedAnimation(parent: _c, curve: Curves.easeOutCubic));
    final delay = (widget.index.clamp(0, 10)) * 50;
    Future.delayed(Duration(milliseconds: delay), () { if (mounted) _c.forward(); });
  }

  @override
  void dispose() { _c.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(position: _slide, child: widget.child),
    );
  }
}

/// Increments whenever the user re-taps the currently-active bottom nav tab.
/// Active screens listen and animate their main scrollable to the top.
final ValueNotifier<int> tabReTapTick = ValueNotifier<int>(0);

// ==================== TEK MATERIALS: Frosted Glass + Chrome Edges ====================

/// A frosted-glass surface with optional chrome (steel) edge.
/// Used for AppBars-on-scroll, modal sheets, story headers — every surface that
/// should feel like a HUD overlay rather than a flat panel.
class FrostedGlass extends StatelessWidget {
  final Widget child;
  final double sigma;
  final double opacity;
  final BorderRadius? borderRadius;
  final bool chromeEdge;
  const FrostedGlass({
    super.key,
    required this.child,
    this.sigma = 18,
    this.opacity = 0.55,
    this.borderRadius,
    this.chromeEdge = true,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: borderRadius ?? BorderRadius.zero,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: opacity),
            borderRadius: borderRadius,
            border: chromeEdge
                ? Border.all(color: const Color(0xFF7A7A7A).withValues(alpha: 0.35), width: 0.6)
                : null,
          ),
          child: child,
        ),
      ),
    );
  }
}

// ==================== TEK INPUT: Press-State Spring ====================

/// Wraps a child to give a mechanical compress-on-press feel (scale 0.97, fast snap-back).
/// Uses Listener so it does NOT consume taps — child buttons still fire their own onPressed.
/// Use sparingly — only on key CTA buttons, not every tappable surface.
class PressScale extends StatefulWidget {
  final Widget child;
  final double scaleTo;
  final Duration duration;
  const PressScale({
    super.key,
    required this.child,
    this.scaleTo = 0.97,
    this.duration = const Duration(milliseconds: 80),
  });

  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) {
        if (!_down) setState(() => _down = true);
      },
      onPointerUp: (_) {
        if (_down) setState(() => _down = false);
      },
      onPointerCancel: (_) {
        if (_down) setState(() => _down = false);
      },
      child: AnimatedScale(
        scale: _down ? widget.scaleTo : 1.0,
        duration: widget.duration,
        curve: _down ? Curves.easeOut : Curves.elasticOut,
        child: widget.child,
      ),
    );
  }
}

// ==================== TEK SOUND ====================

// ==================== QUESTS V2: GLOBAL CONFIG ====================
//
// Live mirror of `config/quests` Firestore doc. Read by the SIDEQUESTS tab,
// admin panel, and any feature-gated UI. Writes happen through the admin
// FEATURE FLAGS section (admin-only by Firestore rules).

class QuestsConfig {
  final bool enabled;
  final bool dailyRotationEnabled;
  final int dailyQuestCount;
  final int weeklyQuestCount;
  final bool streaksEnabled;
  final Map<int, int> streakBonusXP;
  final bool aiGenerationEnabled;

  const QuestsConfig({
    required this.enabled,
    required this.dailyRotationEnabled,
    required this.dailyQuestCount,
    required this.weeklyQuestCount,
    required this.streaksEnabled,
    required this.streakBonusXP,
    required this.aiGenerationEnabled,
  });

  static const QuestsConfig defaults = QuestsConfig(
    enabled: true,
    dailyRotationEnabled: true,
    dailyQuestCount: 3,
    weeklyQuestCount: 1,
    streaksEnabled: true,
    streakBonusXP: {3: 50, 7: 150, 30: 1000},
    aiGenerationEnabled: true,
  );

  factory QuestsConfig.fromMap(Map<String, dynamic> data) {
    final rawBonus = data['streakBonusXP'];
    final bonus = <int, int>{};
    if (rawBonus is Map) {
      rawBonus.forEach((k, v) {
        final day = int.tryParse('$k');
        final xp = (v is num) ? v.toInt() : int.tryParse('$v');
        if (day != null && xp != null) bonus[day] = xp;
      });
    }
    return QuestsConfig(
      enabled: data['enabled'] as bool? ?? defaults.enabled,
      dailyRotationEnabled:
          data['dailyRotationEnabled'] as bool? ?? defaults.dailyRotationEnabled,
      dailyQuestCount: (data['dailyQuestCount'] as num?)?.toInt() ??
          defaults.dailyQuestCount,
      weeklyQuestCount: (data['weeklyQuestCount'] as num?)?.toInt() ??
          defaults.weeklyQuestCount,
      streaksEnabled: data['streaksEnabled'] as bool? ?? defaults.streaksEnabled,
      streakBonusXP: bonus.isEmpty ? defaults.streakBonusXP : bonus,
      aiGenerationEnabled: data['aiGenerationEnabled'] as bool? ??
          defaults.aiGenerationEnabled,
    );
  }
}

/// Live config notifier. Updated by [QuestsConfigService] from Firestore.
final ValueNotifier<QuestsConfig> questsConfig =
    ValueNotifier<QuestsConfig>(QuestsConfig.defaults);

class QuestsConfigService {
  QuestsConfigService._();
  static final QuestsConfigService instance = QuestsConfigService._();

  bool _started = false;

  void start() {
    if (_started) return;
    _started = true;
    try {
      FirebaseFirestore.instance
          .collection('config')
          .doc('quests')
          .snapshots()
          .listen((snap) {
        if (!snap.exists) {
          questsConfig.value = QuestsConfig.defaults;
          return;
        }
        questsConfig.value = QuestsConfig.fromMap(snap.data() ?? {});
      }, onError: (_) {
        // Keep last known value on transient errors.
      });
    } catch (_) {
      // Firestore not ready yet — caller can retry.
      _started = false;
    }
  }

  Future<void> updateFlags(Map<String, dynamic> patch) async {
    await FirebaseFirestore.instance
        .collection('config')
        .doc('quests')
        .set(patch, SetOptions(merge: true));
  }
}

// ==================== REWARD REDEMPTION ====================

const int kRedemptionXpCost = 100;

class _RedeemDrinkButton extends StatelessWidget {
  final String referralCode;
  final String userName;
  const _RedeemDrinkButton({required this.referralCode, required this.userName});

  @override
  Widget build(BuildContext context) {
    if (referralCode.isEmpty) return const SizedBox.shrink();
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('applications')
          .where('referralCode', isEqualTo: referralCode)
          .limit(1)
          .snapshots(),
      builder: (context, snap) {
        final docs = snap.data?.docs ?? [];
        if (docs.isEmpty) return const SizedBox.shrink();
        final data = docs.first.data() as Map<String, dynamic>;
        final xp = (data['xpPoints'] as num?)?.toInt() ?? 0;
        final canRedeem = xp >= kRedemptionXpCost;
        return PressScale(
          child: GlowPulse(
          color: canRedeem ? const Color(0xFF00FF41) : Colors.white24,
          maxBlur: canRedeem ? 18 : 4,
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: canRedeem
                  ? () {
                      HapticFeedback.mediumImpact();
                      showDialog(
                        context: context,
                        barrierDismissible: false,
                        builder: (_) => _RedeemQrDialog(
                          referralCode: referralCode,
                          userName: userName,
                        ),
                      );
                    }
                  : null,
              icon: Icon(
                canRedeem ? Icons.local_bar : Icons.lock_outline,
                color: canRedeem ? Colors.black : Colors.white38,
                size: 18,
              ),
              label: Text(
                canRedeem
                    ? 'REDEEM FREE DRINK'
                    : '${kRedemptionXpCost - xp} XP TO FREE DRINK',
                style: TextStyle(
                  color: canRedeem ? Colors.black : Colors.white54,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.5,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: canRedeem
                    ? const Color(0xFF00FF41)
                    : Colors.white.withValues(alpha: 0.05),
                disabledBackgroundColor: Colors.white.withValues(alpha: 0.05),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(
                    color: canRedeem ? const Color(0xFF00FF41) : Colors.white24,
                    width: 1,
                  ),
                ),
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
          ),
        );
      },
    );
  }
}

// ==================== FRIEND QR (show + scan) ====================

class _FriendQrScreen extends StatefulWidget {
  final String myReferralCode;
  final String myName;
  const _FriendQrScreen({required this.myReferralCode, required this.myName});

  @override
  State<_FriendQrScreen> createState() => _FriendQrScreenState();
}

class _FriendQrScreenState extends State<_FriendQrScreen> with SingleTickerProviderStateMixin {
  late TabController _tab;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Color(0xFF00FF41)),
        title: const Text('CONNECT',
            style: TextStyle(color: Color(0xFF00FF41), fontSize: 14, fontWeight: FontWeight.bold, letterSpacing: 3)),
        centerTitle: true,
        bottom: TabBar(
          controller: _tab,
          labelColor: const Color(0xFF00FF41),
          unselectedLabelColor: Colors.white54,
          indicatorColor: const Color(0xFF00FF41),
          labelStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.5),
          tabs: const [
            Tab(text: 'MY CODE'),
            Tab(text: 'SCAN'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tab,
        children: [
          _myQr(),
          _FriendQrScannerTab(),
        ],
      ),
    );
  }

  Widget _myQr() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('SHOW THIS TO ANOTHER OPERATOR',
                style: TextStyle(color: Color(0xFF7A7A7A), fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 2)),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(color: const Color(0xFF00FF41).withValues(alpha: 0.4), blurRadius: 32, spreadRadius: 2),
                ],
              ),
              child: qr_flutter.QrImageView(data: 'TEK:${widget.myReferralCode}', size: 220),
            ),
            const SizedBox(height: 24),
            Text(widget.myName.toUpperCase(),
                style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 2)),
            const SizedBox(height: 4),
            Text(widget.myReferralCode,
                style: const TextStyle(color: Color(0xFF00FF41), fontSize: 13, letterSpacing: 3, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }
}

class _FriendQrScannerTab extends StatefulWidget {
  @override
  State<_FriendQrScannerTab> createState() => _FriendQrScannerTabState();
}

class _FriendQrScannerTabState extends State<_FriendQrScannerTab> {
  late final MobileScannerController _ctrl;
  bool _processing = false;
  String? _resultMsg;
  Color _resultColor = Colors.white54;

  @override
  void initState() {
    super.initState();
    _ctrl = MobileScannerController(detectionSpeed: DetectionSpeed.normal, facing: CameraFacing.back);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _handle(BarcodeCapture cap) async {
    if (_processing) return;
    final raw = cap.barcodes.isNotEmpty ? (cap.barcodes.first.rawValue ?? '') : '';
    if (!raw.startsWith('TEK:')) return;
    setState(() => _processing = true);
    HapticFeedback.heavyImpact();
    final theirCode = raw.substring(4).trim();
    try {
      final prefs = await SharedPreferences.getInstance();
      final myCode = prefs.getString('userReferralCode');
      if (myCode == null || myCode == theirCode) throw Exception('Cannot add self');

      final theirSnap = await FirebaseFirestore.instance
          .collection('applications')
          .where('referralCode', isEqualTo: theirCode)
          .limit(1)
          .get();
      if (theirSnap.docs.isEmpty) throw Exception('Operator not found');

      // Add my code to their friendRequests
      final theirDoc = theirSnap.docs.first;
      await theirDoc.reference.update({
        'friendRequests': FieldValue.arrayUnion([myCode]),
      });

      _flash('REQUEST SENT — AWAITING ACCEPT', const Color(0xFF00FF41));
      Future.delayed(const Duration(milliseconds: 1500), () {
        if (mounted) Navigator.pop(context);
      });
    } catch (e) {
      _flash('${e.toString().replaceFirst('Exception: ', '').toUpperCase()}', Colors.red);
    }
  }

  void _flash(String msg, Color color) {
    setState(() {
      _resultMsg = msg;
      _resultColor = color;
    });
    Future.delayed(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() { _resultMsg = null; _processing = false; });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        MobileScanner(controller: _ctrl, onDetect: _handle),
        Container(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment.center,
              radius: 0.7,
              colors: [Colors.transparent, Colors.black.withValues(alpha: 0.6)],
            ),
          ),
        ),
        Center(
          child: SizedBox(
            width: 240, height: 240,
            child: CustomPaint(
              painter: _QRCornerPainter(color: _resultColor == Colors.white54 ? const Color(0xFF00FF41) : _resultColor),
            ),
          ),
        ),
        Positioned(
          bottom: 32,
          left: 24, right: 24,
          child: Text(
            _resultMsg ?? 'POINT AT ANOTHER OPERATOR\'S TEK QR',
            textAlign: TextAlign.center,
            style: TextStyle(color: _resultColor, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1.5),
          ),
        ),
      ],
    );
  }
}

// ==================== RELAY POWER (XP transmission) ====================

class _RelayPowerDialog extends StatefulWidget {
  final String recipientCode;
  final String recipientName;
  const _RelayPowerDialog({required this.recipientCode, required this.recipientName});

  @override
  State<_RelayPowerDialog> createState() => _RelayPowerDialogState();
}

class _RelayPowerDialogState extends State<_RelayPowerDialog> {
  static const _amounts = [5, 10, 25, 50];
  int _selected = 10;
  bool _sending = false;
  String? _error;
  int _myXp = 0;

  @override
  void initState() {
    super.initState();
    _loadMyXp();
  }

  Future<void> _loadMyXp() async {
    final prefs = await SharedPreferences.getInstance();
    final code = prefs.getString('userReferralCode');
    if (code == null) return;
    final snap = await FirebaseFirestore.instance
        .collection('applications')
        .where('referralCode', isEqualTo: code)
        .limit(1)
        .get();
    if (!mounted || snap.docs.isEmpty) return;
    setState(() => _myXp = (snap.docs.first.data()['xpPoints'] as num?)?.toInt() ?? 0);
  }

  Future<void> _send() async {
    setState(() { _sending = true; _error = null; });
    try {
      final prefs = await SharedPreferences.getInstance();
      final senderCode = prefs.getString('userReferralCode');
      if (senderCode == null || senderCode.isEmpty) throw Exception('No sender');
      if (senderCode == widget.recipientCode) throw Exception('Cannot relay to yourself');
      final senderSnap = await FirebaseFirestore.instance
          .collection('applications')
          .where('referralCode', isEqualTo: senderCode)
          .limit(1)
          .get();
      if (senderSnap.docs.isEmpty) throw Exception('Sender doc not found');
      final recipientSnap = await FirebaseFirestore.instance
          .collection('applications')
          .where('referralCode', isEqualTo: widget.recipientCode)
          .limit(1)
          .get();
      if (recipientSnap.docs.isEmpty) throw Exception('Recipient not found');

      final senderDoc = senderSnap.docs.first;
      final recipientDoc = recipientSnap.docs.first;
      final senderXp = (senderDoc.data()['xpPoints'] as num?)?.toInt() ?? 0;
      final recipientXp = (recipientDoc.data()['xpPoints'] as num?)?.toInt() ?? 0;

      if (senderXp < _selected) throw Exception('Not enough XP');

      final batch = FirebaseFirestore.instance.batch();
      batch.update(senderDoc.reference, {'xpPoints': senderXp - _selected});
      batch.update(recipientDoc.reference, {'xpPoints': recipientXp + _selected});
      await batch.commit();

      // Log both sides as xp_transactions for audit trail
      final ts = FieldValue.serverTimestamp();
      await Future.wait([
        FirebaseFirestore.instance.collection('xp_transactions').add({
          'source': 'relay_send',
          'senderCode': senderCode,
          'recipientCode': widget.recipientCode,
          'amount': -_selected,
          'previousXP': senderXp,
          'newXP': senderXp - _selected,
          'userName': senderDoc.data()['name'] ?? '',
          'userEmail': senderDoc.data()['email'] ?? '',
          'timestamp': ts,
        }),
        FirebaseFirestore.instance.collection('xp_transactions').add({
          'source': 'relay_receive',
          'senderCode': senderCode,
          'recipientCode': widget.recipientCode,
          'amount': _selected,
          'previousXP': recipientXp,
          'newXP': recipientXp + _selected,
          'userName': recipientDoc.data()['name'] ?? '',
          'userEmail': recipientDoc.data()['email'] ?? '',
          'timestamp': ts,
        }),
        FirebaseFirestore.instance.collection('tek_notifications').add({
          'recipientCode': widget.recipientCode,
          'type': 'relay_received',
          'title': 'POWER RELAYED',
          'body': '${senderDoc.data()['name'] ?? senderCode} sent you +$_selected XP',
          'read': false,
          'createdAt': FieldValue.serverTimestamp(),
        }),
      ]);

      HapticFeedback.heavyImpact();
      TekSounds.instance.relay();
      if (!mounted) return;
      Navigator.pop(context);
      showXPToast(context,
          title: '-$_selected XP RELAYED',
          subtitle: 'TO ${widget.recipientName.toUpperCase()}',
          icon: Icons.bolt);
    } catch (e) {
      if (mounted) setState(() { _sending = false; _error = '$e'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final canAfford = _myXp >= _selected;
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: FrostedGlass(
        sigma: 22,
        opacity: 0.78,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFF00FF41).withValues(alpha: 0.7), width: 1.2),
            boxShadow: [
              BoxShadow(color: const Color(0xFF00FF41).withValues(alpha: 0.25), blurRadius: 24),
            ],
          ),
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Icon(Icons.bolt, color: Color(0xFF00FF41), size: 16),
                const SizedBox(width: 6),
                const Text('RELAY POWER',
                    style: TextStyle(color: Color(0xFF00FF41), fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 3)),
              ]),
              const SizedBox(height: 8),
              Text('TRANSFERRING XP TO ${widget.recipientName.toUpperCase()}',
                  style: const TextStyle(color: Colors.white70, fontSize: 11, letterSpacing: 1)),
              const SizedBox(height: 16),
              Text('YOUR BALANCE: $_myXp XP',
                  style: const TextStyle(color: Colors.white54, fontSize: 11, letterSpacing: 1)),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _amounts.map((amount) {
                  final isSelected = amount == _selected;
                  return PressScale(
                    child: GestureDetector(
                      onTap: () {
                        HapticFeedback.selectionClick();
                        TekSounds.instance.tap();
                        setState(() => _selected = amount);
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: isSelected ? const Color(0xFF00FF41) : Colors.transparent,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0xFF00FF41), width: 1.2),
                        ),
                        child: Text('+$amount XP',
                            style: TextStyle(
                              color: isSelected ? Colors.black : const Color(0xFF00FF41),
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1,
                            )),
                      ),
                    ),
                  );
                }).toList(),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 11)),
              ],
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _sending ? null : () => Navigator.pop(context),
                    child: const Text('CANCEL', style: TextStyle(color: Colors.white38)),
                  ),
                  const SizedBox(width: 8),
                  PressScale(
                    child: ElevatedButton(
                      onPressed: (_sending || !canAfford) ? null : _send,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00FF41),
                        disabledBackgroundColor: Colors.white12,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      child: _sending
                          ? const SizedBox(width: 16, height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                          : Text(canAfford ? 'RELAY ENGAGE' : 'NOT ENOUGH XP',
                              style: TextStyle(
                                color: canAfford ? Colors.black : Colors.white38,
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                                letterSpacing: 1.5,
                              )),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RedeemQrDialog extends StatefulWidget {
  final String referralCode;
  final String userName;
  const _RedeemQrDialog({required this.referralCode, required this.userName});

  @override
  State<_RedeemQrDialog> createState() => _RedeemQrDialogState();
}

class _RedeemQrDialogState extends State<_RedeemQrDialog> {
  String? _docId;
  String? _code;
  Timer? _ticker;
  int _secondsLeft = 300;
  bool _creating = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _create();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _create() async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
      final code = _randomCode(8);
      final now = DateTime.now();
      final expires = now.add(const Duration(minutes: 5));
      final ref = await FirebaseFirestore.instance.collection('redemptions').add({
        'userCode': widget.referralCode,
        'userName': widget.userName,
        'userUid': uid,
        'code': code,
        'reward': 'free_drink',
        'xpCost': kRedemptionXpCost,
        'redeemed': false,
        'createdAt': Timestamp.fromDate(now),
        'expiresAt': Timestamp.fromDate(expires),
      });
      if (!mounted) return;
      setState(() {
        _docId = ref.id;
        _code = code;
        _creating = false;
      });
      _ticker = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted) {
          t.cancel();
          return;
        }
        final left = expires.difference(DateTime.now()).inSeconds;
        setState(() => _secondsLeft = left < 0 ? 0 : left);
        if (left <= 0) t.cancel();
      });
    } catch (e) {
      if (mounted) setState(() { _creating = false; _error = '$e'; });
    }
  }

  String _randomCode(int len) {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final r = math.Random.secure();
    return List.generate(len, (_) => chars[r.nextInt(chars.length)]).join();
  }

  String _fmt(int s) => '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: FrostedGlass(
        sigma: 24,
        opacity: 0.78,
        borderRadius: BorderRadius.circular(16),
        child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFF00FF41), width: 1.5),
          boxShadow: [
            BoxShadow(color: const Color(0xFF00FF41).withValues(alpha: 0.35), blurRadius: 32, spreadRadius: 1),
          ],
        ),
        child: _docId == null
          ? Padding(
              padding: const EdgeInsets.all(40),
              child: _creating
                  ? const Center(child: CircularProgressIndicator(color: Color(0xFF00FF41)))
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error ?? 'Failed to create redemption', style: const TextStyle(color: Colors.red)),
                        const SizedBox(height: 12),
                        TextButton(onPressed: () => Navigator.pop(context),
                            child: const Text('CLOSE', style: TextStyle(color: Color(0xFF00FF41)))),
                      ],
                    ),
            )
          : StreamBuilder<DocumentSnapshot>(
              stream: FirebaseFirestore.instance.collection('redemptions').doc(_docId).snapshots(),
              builder: (context, snap) {
                final data = snap.data?.data() as Map<String, dynamic>?;
                final redeemed = data?['redeemed'] as bool? ?? false;
                final expired = _secondsLeft <= 0;
                return Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        redeemed ? 'REDEEMED ✓' : (expired ? 'EXPIRED' : 'SHOW TO BARTENDER'),
                        style: TextStyle(
                          color: redeemed ? const Color(0xFF00FF41) : (expired ? Colors.red : Colors.white),
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 2,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Container(
                        color: Colors.white,
                        padding: const EdgeInsets.all(16),
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            Opacity(
                              opacity: (redeemed || expired) ? 0.25 : 1.0,
                              child: qr_flutter.QrImageView(data: _code!, size: 200),
                            ),
                            if (redeemed)
                              const Icon(Icons.check_circle, color: Color(0xFF00FF41), size: 80),
                            if (expired && !redeemed)
                              const Icon(Icons.timer_off, color: Colors.red, size: 80),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        redeemed
                            ? 'Enjoy your drink 🍹'
                            : (expired ? 'Generate a new one to retry.' : 'Expires in ${_fmt(_secondsLeft)}'),
                        style: TextStyle(
                          color: redeemed
                              ? const Color(0xFF00FF41)
                              : (expired ? Colors.red : Colors.white54),
                          fontSize: 12,
                          letterSpacing: 1,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text('CODE: $_code',
                          style: const TextStyle(color: Colors.white38, fontSize: 11, letterSpacing: 2)),
                      const SizedBox(height: 12),
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('CLOSE', style: TextStyle(color: Color(0xFF00FF41))),
                      ),
                    ],
                  ),
                );
              },
            ),
      ),
      ),
    );
  }
}

class _RedemptionScannerButton extends StatelessWidget {
  const _RedemptionScannerButton();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: () {
            HapticFeedback.lightImpact();
            Navigator.push(
              context,
              cinematicRoute(const _RedemptionScannerPage()),
            );
          },
          icon: const Icon(Icons.qr_code_scanner, color: Color(0xFF00FF41), size: 18),
          label: const Text('SCAN REDEMPTION QR',
              style: TextStyle(color: Color(0xFF00FF41), fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
          style: OutlinedButton.styleFrom(
            side: const BorderSide(color: Color(0xFF00FF41)),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            padding: const EdgeInsets.symmetric(vertical: 12),
          ),
        ),
      ),
    );
  }
}

class _RedemptionScannerPage extends StatefulWidget {
  const _RedemptionScannerPage();

  @override
  State<_RedemptionScannerPage> createState() => _RedemptionScannerPageState();
}

class _RedemptionScannerPageState extends State<_RedemptionScannerPage> {
  late final MobileScannerController _controller;
  bool _processing = false;
  String? _resultMsg;
  Color _resultColor = Colors.white;

  @override
  void initState() {
    super.initState();
    _controller = MobileScannerController(detectionSpeed: DetectionSpeed.normal, facing: CameraFacing.back);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _handle(BarcodeCapture capture) async {
    if (_processing) return;
    final raw = capture.barcodes.isNotEmpty ? (capture.barcodes.first.rawValue ?? '') : '';
    if (raw.isEmpty) return;
    setState(() => _processing = true);
    HapticFeedback.mediumImpact();
    try {
      final snap = await FirebaseFirestore.instance
          .collection('redemptions')
          .where('code', isEqualTo: raw.trim().toUpperCase())
          .limit(1)
          .get();
      if (snap.docs.isEmpty) {
        _flash('Not a valid redemption code', Colors.red);
        return;
      }
      final doc = snap.docs.first;
      final data = doc.data();
      if (data['redeemed'] == true) {
        _flash('Already redeemed', Colors.orange);
        return;
      }
      final expiresAt = (data['expiresAt'] as Timestamp?)?.toDate();
      if (expiresAt != null && expiresAt.isBefore(DateTime.now())) {
        _flash('Code expired', Colors.red);
        return;
      }
      // Find user app doc to deduct XP
      final userCode = data['userCode'] as String?;
      final xpCost = (data['xpCost'] as num?)?.toInt() ?? kRedemptionXpCost;
      if (userCode != null) {
        final appSnap = await FirebaseFirestore.instance
            .collection('applications')
            .where('referralCode', isEqualTo: userCode)
            .limit(1)
            .get();
        if (appSnap.docs.isNotEmpty) {
          final appDoc = appSnap.docs.first;
          final currentXP = (appDoc.data()['xpPoints'] as num?)?.toInt() ?? 0;
          if (currentXP < xpCost) {
            _flash('User no longer has enough XP', Colors.red);
            return;
          }
          final batch = FirebaseFirestore.instance.batch();
          batch.update(doc.reference, {
            'redeemed': true,
            'redeemedAt': FieldValue.serverTimestamp(),
            'redeemedByAdminUid': FirebaseAuth.instance.currentUser?.uid ?? '',
          });
          batch.update(appDoc.reference, {
            'xpPoints': currentXP - xpCost,
          });
          await batch.commit();
          await FirebaseFirestore.instance.collection('xp_transactions').add({
            'source': 'redemption',
            'reward': data['reward'] ?? 'free_drink',
            'redemptionId': doc.id,
            'userId': appDoc.id,
            'userName': appDoc.data()['name'] ?? '',
            'userEmail': appDoc.data()['email'] ?? '',
            'amount': -xpCost,
            'previousXP': currentXP,
            'newXP': currentXP - xpCost,
            'timestamp': FieldValue.serverTimestamp(),
          });
        }
      }
      HapticFeedback.heavyImpact();
      TekSounds.instance.redeem();
      _flash('✓ REDEEMED FOR ${(data['userName'] ?? userCode).toString().toUpperCase()}', const Color(0xFF00FF41));
      Future.delayed(const Duration(milliseconds: 1600), () {
        if (mounted) Navigator.pop(context);
      });
    } catch (e) {
      _flash('Error: $e', Colors.red);
    }
  }

  void _flash(String msg, Color color) {
    setState(() {
      _resultMsg = msg;
      _resultColor = color;
    });
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() { _resultMsg = null; _processing = false; });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        iconTheme: const IconThemeData(color: Color(0xFF00FF41)),
        title: const Text('REDEMPTION SCANNER',
            style: TextStyle(color: Color(0xFF00FF41), fontSize: 14, fontWeight: FontWeight.bold, letterSpacing: 2)),
        centerTitle: true,
      ),
      body: Stack(
        children: [
          MobileScanner(controller: _controller, onDetect: _handle),
          Container(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment.center,
                radius: 0.7,
                colors: [Colors.transparent, Colors.black.withValues(alpha: 0.55)],
              ),
            ),
          ),
          Center(
            child: SizedBox(
              width: 240,
              height: 240,
              child: CustomPaint(
                painter: _QRCornerPainter(color: _resultColor == Colors.white ? const Color(0xFF00FF41) : _resultColor),
              ),
            ),
          ),
          Positioned(
            bottom: 80,
            left: 24,
            right: 24,
            child: Text(
              _resultMsg ?? 'POINT AT USER\'S REDEMPTION QR',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _resultColor == Colors.white ? Colors.white54 : _resultColor,
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Admin-only diagnostics for push notifications: shows the captured FCM token
/// and any setup error so we can debug without console access.
class _PushDiagnosticsPanel extends StatefulWidget {
  const _PushDiagnosticsPanel();

  @override
  State<_PushDiagnosticsPanel> createState() => _PushDiagnosticsPanelState();
}

class _PushDiagnosticsPanelState extends State<_PushDiagnosticsPanel> {
  String? _token;
  String? _error;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _token = prefs.getString('lastFcmToken');
      _error = prefs.getString('lastPushSetupError');
      _loaded = true;
    });
  }

  Future<void> _retry() async {
    HapticFeedback.lightImpact();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('lastPushSetupError');
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null) {
        await prefs.setString('lastFcmToken', token);
      }
    } catch (e) {
      await prefs.setString('lastPushSetupError', '$e');
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const SizedBox.shrink();
    final ok = _token != null && _token!.isNotEmpty;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: ok ? const Color(0xFF00FF41).withValues(alpha: 0.4) : Colors.red.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(ok ? Icons.notifications_active : Icons.notifications_off,
                color: ok ? const Color(0xFF00FF41) : Colors.red, size: 14),
            const SizedBox(width: 6),
            Text('PUSH DIAGNOSTICS',
                style: TextStyle(
                    color: ok ? const Color(0xFF00FF41) : Colors.red,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 2)),
            const Spacer(),
            GestureDetector(
              onTap: _retry,
              child: const Icon(Icons.refresh, color: Colors.white54, size: 16),
            ),
          ]),
          const SizedBox(height: 8),
          Text(
            ok
                ? 'TOKEN: ${_token!.substring(0, 16)}...${_token!.substring(_token!.length - 8)}'
                : 'TOKEN: NOT CAPTURED',
            style: TextStyle(
                color: ok ? Colors.white : Colors.red.shade300,
                fontSize: 11,
                fontFamily: 'monospace'),
          ),
          if (_error != null && _error!.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text('ERROR: $_error',
                style: const TextStyle(color: Colors.red, fontSize: 10)),
          ],
          const SizedBox(height: 8),
          if (ok)
            GestureDetector(
              onTap: () {
                Clipboard.setData(ClipboardData(text: _token!));
                HapticFeedback.lightImpact();
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text('Token copied'),
                    duration: Duration(seconds: 1),
                    backgroundColor: Color(0xFF00FF41)));
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: const Color(0xFF00FF41).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: const Color(0xFF00FF41), width: 1),
                ),
                child: const Text('COPY TOKEN',
                    style: TextStyle(color: Color(0xFF00FF41), fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
              ),
            ),
        ],
      ),
    );
  }
}

// ==================== UTILITY FUNCTIONS ====================
class AppUtils {
  // Copy text to clipboard with feedback
  static Future<void> copyToClipboard(
    BuildContext context,
    String text, {
    String? message,
  }) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message ?? 'Copied to clipboard!'),
          backgroundColor: Color(0xFF00FF41),
          duration: Duration(seconds: 2),
        ),
      );
    }
    HapticFeedback.lightImpact();
  }

  // Format date nicely
  static String formatDate(dynamic date) {
    if (date == null) return 'N/A';
    DateTime dateTime;
    if (date is Timestamp) {
      dateTime = date.toDate();
    } else if (date is DateTime) {
      dateTime = date;
    } else {
      return 'N/A';
    }

    final now = DateTime.now();
    final difference = now.difference(dateTime);

    if (difference.inDays == 0) {
      return 'Today ${DateFormat('HH:mm').format(dateTime)}';
    } else if (difference.inDays == 1) {
      return 'Yesterday ${DateFormat('HH:mm').format(dateTime)}';
    } else if (difference.inDays < 7) {
      return '${difference.inDays} days ago';
    } else {
      return DateFormat('MMM d, y').format(dateTime);
    }
  }

  // Format time ago
  static String timeAgo(dynamic date) {
    if (date == null) return 'N/A';
    DateTime dateTime;
    if (date is Timestamp) {
      dateTime = date.toDate();
    } else if (date is DateTime) {
      dateTime = date;
    } else {
      return 'N/A';
    }

    final now = DateTime.now();
    final difference = now.difference(dateTime);

    if (difference.inSeconds < 60) {
      return 'Just now';
    } else if (difference.inMinutes < 60) {
      return '${difference.inMinutes}m ago';
    } else if (difference.inHours < 24) {
      return '${difference.inHours}h ago';
    } else if (difference.inDays < 7) {
      return '${difference.inDays}d ago';
    } else {
      return DateFormat('MMM d').format(dateTime);
    }
  }

  // Validate email
  static bool isValidEmail(String email) {
    return RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$').hasMatch(email);
  }

  // Validate phone
  static bool isValidPhone(String phone) {
    return RegExp(r'^\+?[\d\s\-\(\)]{10,}$').hasMatch(phone);
  }

  // Show error message
  static void showError(BuildContext context, String message) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.red,
          duration: Duration(seconds: 3),
        ),
      );
    }
  }

  // Show success message
  static void showSuccess(BuildContext context, String message) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Color(0xFF00FF41),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  // Format XP with commas
  static String formatXP(int xp) {
    return NumberFormat('#,###').format(xp);
  }

  // Empty state widget
  static Widget buildEmptyState({
    required IconData icon,
    required String title,
    String? subtitle,
    VoidCallback? onAction,
    String? actionLabel,
  }) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 80, color: Colors.white30),
            SizedBox(height: 16),
            Text(
              title,
              style: TextStyle(
                color: Colors.white70,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
            if (subtitle != null) ...[
              SizedBox(height: 8),
              Text(
                subtitle,
                style: TextStyle(color: Colors.white38, fontSize: 14),
                textAlign: TextAlign.center,
              ),
            ],
            if (onAction != null && actionLabel != null) ...[
              SizedBox(height: 24),
              ElevatedButton(
                onPressed: onAction,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Color(0xFF00FF41),
                  foregroundColor: Colors.black,
                  padding: EdgeInsets.symmetric(horizontal: 32, vertical: 12),
                ),
                child: Text(actionLabel),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // Loading indicator
  static Widget buildLoadingIndicator({String? message}) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(
            valueColor: AlwaysStoppedAnimation(Color(0xFF00FF41)),
          ),
          if (message != null) ...[
            SizedBox(height: 16),
            Text(message, style: TextStyle(color: Colors.white70)),
          ],
        ],
      ),
    );
  }

  // Confirmation dialog
  static Future<bool> showConfirmDialog(
    BuildContext context, {
    required String title,
    required String message,
    String confirmText = 'Confirm',
    String cancelText = 'Cancel',
    bool isDangerous = false,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Color(0xFF1A1A1A).withValues(alpha: 0.85),
        title: Text(title, style: TextStyle(color: Color(0xFFB8B8C0))),
        content: Text(message, style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(cancelText, style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: isDangerous ? Colors.red : Color(0xFF00FF41),
              foregroundColor: isDangerous ? Colors.white : Colors.black,
            ),
            child: Text(confirmText),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  static Future<void> showTicketPass(
    BuildContext context, {
    required String eventTitle,
    required String ticketCode,
    DateTime? startAt,
    String? location,
  }) async {
    if (!context.mounted) return;

    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (context) {
        return Dialog.fullscreen(
          backgroundColor: Colors.transparent,
          child: SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Row(
                    children: [
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close, color: Color(0xFFB8B8C0)),
                        tooltip: 'Close',
                      ),
                      const Spacer(),
                      IconButton(
                        onPressed: () => copyToClipboard(
                          context,
                          ticketCode,
                          message: 'Ticket code copied',
                        ),
                        icon: const Icon(Icons.copy, color: Color(0xFF00FF41)),
                        tooltip: 'Copy code',
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Text(
                            'SHOW THIS BY THE DOOR',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 2,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            eventTitle.toUpperCase(),
                            style: const TextStyle(
                              color: Color(0xFFB8B8C0),
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          if (startAt != null) ...[
                            const SizedBox(height: 8),
                            Text(
                              DateFormat('EEE, MMM d · HH:mm').format(startAt),
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 14,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ],
                          if (location != null &&
                              location.trim().isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Text(
                              location,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 14,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ],
                          const SizedBox(height: 24),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 18,
                              vertical: 22,
                            ),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: const Color(0xFF00FF41),
                                width: 2,
                              ),
                              color: Colors.white.withValues(alpha: 0.05),
                            ),
                            child: Column(
                              children: [
                                const Text(
                                  'TICKET CODE',
                                  style: TextStyle(
                                    color: Colors.white54,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 2,
                                  ),
                                ),
                                const SizedBox(height: 10),
                                SelectableText(
                                  ticketCode,
                                  style: const TextStyle(
                                    color: Color(0xFFB8B8C0),
                                    fontSize: 26,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 1,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 18),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton(
                              onPressed: () => copyToClipboard(
                                context,
                                ticketCode,
                                message: 'Ticket code copied',
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF00FF41),
                                foregroundColor: Colors.black,
                                minimumSize: const Size(double.infinity, 52),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                              child: const Text(
                                'COPY CODE',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

Future<void> _bootstrapApp({bool skipAuth = false}) async {
  // Initialize Firebase and safely ignore duplicate-app on hot restart or native auto-config
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    ).timeout(const Duration(seconds: 20));
  } on FirebaseException catch (e) {
    if (e.code == 'duplicate-app') {
      Firebase.app();
    } else {
      rethrow;
    }
  }

  // Ensure we have an auth session (required by firestore.rules and callable functions).
  if (!skipAuth && FirebaseAuth.instance.currentUser == null) {
    await FirebaseAuth.instance.signInAnonymously().timeout(
      const Duration(seconds: 20),
    );
  }

  // Stripe (publishable key injected via --dart-define-from-file=stripe.dev.json / stripe.live.json)
  final publishableKey = const String.fromEnvironment('STRIPE_PUBLISHABLE_KEY');
  if (publishableKey.isNotEmpty) {
    stripe.Stripe.publishableKey = publishableKey;
    // Must match ios/Runner/Info.plist URL scheme.
    stripe.Stripe.urlScheme = 'tek';
    await stripe.Stripe.instance.applySettings().timeout(
      const Duration(seconds: 20),
    );
  }

  // Initialize Firestore default instance
  db = FirebaseFirestore.instance;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  unawaited(TekSounds.instance.ensureInit());
  runApp(const MyApp());
}

/// Premium page transition: fade + scale + slide up
class _CosmosPageTransitionsBuilder extends PageTransitionsBuilder {
  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return FadeTransition(
      opacity: curved,
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.94, end: 1.0).animate(curved),
        child: child,
      ),
    );
  }
}

const Color _chromeTextColor = Color(0xFFE7E8ED);
const Color _chromeTextMuted = Color(0xFFBDC2CB);
const List<Shadow> _chromeGlowShadows = [
  Shadow(color: Color(0x22000000), offset: Offset(0, 1), blurRadius: 2),
  Shadow(color: Color(0x3000FF41), offset: Offset(0, 0), blurRadius: 10),
  Shadow(color: Color(0x1800FF41), offset: Offset(0, 0), blurRadius: 22),
];

class TekWordmark extends StatefulWidget {
  final double fontSize;
  final double letterSpacing;

  const TekWordmark({
    super.key,
    required this.fontSize,
    this.letterSpacing = 5.5,
  });

  @override
  State<TekWordmark> createState() => _TekWordmarkState();
}

class _TekWordmarkState extends State<TekWordmark>
    with SingleTickerProviderStateMixin {
  late final AnimationController _sweepController;

  @override
  void initState() {
    super.initState();
    _sweepController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 4200),
    )..repeat();
  }

  @override
  void dispose() {
    _sweepController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _sweepController,
      builder: (context, child) {
        final sweep = _sweepController.value;
        final sweepCenter = -1.25 + (sweep * 2.5);
        final baseText = Text(
          'TEK',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: widget.fontSize,
            fontWeight: FontWeight.w500,
            letterSpacing: widget.letterSpacing,
            height: 0.95,
            shadows: const [
              Shadow(
                color: Color(0x6600FF41),
                offset: Offset(0, 0),
                blurRadius: 8,
              ),
              Shadow(
                color: Color(0x2200FF41),
                offset: Offset(0, 0),
                blurRadius: 20,
              ),
              Shadow(
                color: Color(0x44000000),
                offset: Offset(0, 2),
                blurRadius: 4,
              ),
            ],
          ),
        );

        return Stack(
          alignment: Alignment.center,
          children: [
            ShaderMask(
              blendMode: BlendMode.srcIn,
              shaderCallback: (bounds) => const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0xFFF8FAFC),
                  Color(0xFFD7DCE3),
                  Color(0xFFF4F6F8),
                  Color(0xFFB6F7C4),
                ],
                stops: [0.0, 0.3, 0.72, 1.0],
              ).createShader(bounds),
              child: baseText,
            ),
            ShaderMask(
              blendMode: BlendMode.srcIn,
              shaderCallback: (bounds) => LinearGradient(
                begin: Alignment(sweepCenter - 0.22, -0.25),
                end: Alignment(sweepCenter + 0.22, 0.25),
                colors: const [
                  Color(0x00000000),
                  Color(0x22FFFFFF),
                  Color(0xCCFFFFFF),
                  Color(0x66D8FFE1),
                  Color(0x00000000),
                ],
                stops: [0.0, 0.32, 0.5, 0.68, 1.0],
              ).createShader(bounds),
              child: baseText,
            ),
          ],
        );
      },
    );
  }
}

class Ps3XpProgressBar extends StatefulWidget {
  final double progress;
  final double height;
  final BorderRadius borderRadius;

  const Ps3XpProgressBar({
    super.key,
    required this.progress,
    this.height = 12,
    this.borderRadius = const BorderRadius.all(Radius.circular(10)),
  });

  @override
  State<Ps3XpProgressBar> createState() => _Ps3XpProgressBarState();
}

class _Ps3XpProgressBarState extends State<Ps3XpProgressBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _flareController;

  @override
  void initState() {
    super.initState();
    _flareController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3600),
    )..repeat();
  }

  @override
  void dispose() {
    _flareController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final clampedProgress = widget.progress.clamp(0.0, 1.0);

    return AnimatedBuilder(
      animation: _flareController,
      builder: (context, child) {
        final sweep = _flareController.value;
        return ClipRRect(
          borderRadius: widget.borderRadius,
          child: SizedBox(
            height: widget.height,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                final fillWidth = width * clampedProgress;
                final flareX = fillWidth <= 0
                    ? 0.0
                    : (fillWidth * (0.2 + (0.75 * sweep))).clamp(
                        0.0,
                        fillWidth,
                      );

                return Stack(
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        borderRadius: widget.borderRadius,
                        border: Border.all(
                          color: const Color(0x44E9ECF1),
                          width: 0.7,
                        ),
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            const Color(0xFF1A1A1D),
                            const Color(0xFF060606),
                          ],
                        ),
                      ),
                    ),
                    if (fillWidth > 0)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Container(
                          width: fillWidth,
                          decoration: BoxDecoration(
                            borderRadius: widget.borderRadius,
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                const Color(0xFFF3F5F7),
                                const Color(0xFFD5DBE1),
                                const Color(0xFF8EFFA8),
                                const Color(0xFF1D8A38),
                              ],
                              stops: const [0.0, 0.22, 0.55, 1.0],
                            ),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x2200FF41),
                                blurRadius: 10,
                                spreadRadius: 0.5,
                              ),
                            ],
                          ),
                          child: Stack(
                            children: [
                              Positioned.fill(
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                        const Color(0x99FFFFFF),
                                        const Color(0x33FFFFFF),
                                        Colors.transparent,
                                      ],
                                      stops: const [0.0, 0.35, 1.0],
                                    ),
                                  ),
                                ),
                              ),
                              Positioned(
                                left: flareX - 14,
                                top: -4,
                                bottom: -4,
                                child: Container(
                                  width: 28,
                                  decoration: const BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.centerLeft,
                                      end: Alignment.centerRight,
                                      colors: [
                                        Color(0x00FFFFFF),
                                        Color(0x88FFFFFF),
                                        Color(0x00FFFFFF),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (fillWidth > 6)
                      Positioned(
                        left: (fillWidth - 8).clamp(0.0, width - 16),
                        top: -2,
                        child: Container(
                          width: 16,
                          height: widget.height + 4,
                          decoration: BoxDecoration(
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0xAAFFFFFF),
                                blurRadius: 10,
                                spreadRadius: -2,
                              ),
                              BoxShadow(
                                color: Color(0x6600FF41),
                                blurRadius: 14,
                                spreadRadius: -1,
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      navigatorKey: appNavigatorKey,
      title: 'TEK',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.transparent,
        colorScheme: ColorScheme.dark(
          primary: Color(0xFF00FF41),
          secondary: Color(0xFF00FF41),
          surface: Color(0xFF0D0D0D),
        ),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
        ),
        pageTransitionsTheme: PageTransitionsTheme(
          builders: {
            TargetPlatform.iOS: _CosmosPageTransitionsBuilder(),
            TargetPlatform.android: _CosmosPageTransitionsBuilder(),
          },
        ),
        bottomSheetTheme: const BottomSheetThemeData(
          backgroundColor: Color(0xFF0A0A0A),
        ),
        dialogTheme: const DialogThemeData(backgroundColor: Color(0xFF0A0A0A)),
        textTheme: const TextTheme(
          displayLarge: TextStyle(
            color: _chromeTextColor,
            fontWeight: FontWeight.bold,
            shadows: _chromeGlowShadows,
          ),
          displayMedium: TextStyle(
            color: _chromeTextColor,
            fontWeight: FontWeight.bold,
            shadows: _chromeGlowShadows,
          ),
          displaySmall: TextStyle(
            color: _chromeTextColor,
            fontWeight: FontWeight.bold,
            shadows: _chromeGlowShadows,
          ),
          headlineLarge: TextStyle(
            color: _chromeTextColor,
            fontWeight: FontWeight.bold,
            shadows: _chromeGlowShadows,
          ),
          headlineMedium: TextStyle(
            color: _chromeTextColor,
            fontWeight: FontWeight.w600,
            shadows: _chromeGlowShadows,
          ),
          headlineSmall: TextStyle(
            color: _chromeTextColor,
            fontWeight: FontWeight.w600,
            shadows: _chromeGlowShadows,
          ),
          titleLarge: TextStyle(
            color: _chromeTextColor,
            fontWeight: FontWeight.w600,
            shadows: _chromeGlowShadows,
          ),
          titleMedium: TextStyle(
            color: _chromeTextColor,
            fontWeight: FontWeight.w500,
            shadows: _chromeGlowShadows,
          ),
          titleSmall: TextStyle(
            color: _chromeTextMuted,
            fontWeight: FontWeight.w500,
            shadows: _chromeGlowShadows,
          ),
          bodyLarge: TextStyle(
            color: _chromeTextColor,
            shadows: _chromeGlowShadows,
          ),
          bodyMedium: TextStyle(
            color: _chromeTextMuted,
            shadows: _chromeGlowShadows,
          ),
          bodySmall: TextStyle(
            color: Color(0xFF979CA6),
            shadows: _chromeGlowShadows,
          ),
          labelLarge: TextStyle(
            color: _chromeTextColor,
            fontWeight: FontWeight.w600,
            shadows: _chromeGlowShadows,
          ),
          labelMedium: TextStyle(
            color: _chromeTextMuted,
            fontWeight: FontWeight.w500,
            shadows: _chromeGlowShadows,
          ),
          labelSmall: TextStyle(
            color: Color(0xFF979CA6),
            fontWeight: FontWeight.w500,
            shadows: _chromeGlowShadows,
          ),
        ),
      ),
      builder: (context, child) {
        return Stack(
          children: [
            const Positioned.fill(child: CosmosBackground()),
            Positioned.fill(
              child: DefaultTextStyle.merge(
                style: const TextStyle(
                  color: _chromeTextColor,
                  shadows: _chromeGlowShadows,
                ),
                child: child ?? const SizedBox.shrink(),
              ),
            ),
          ],
        );
      },
      home: const BootstrapGate(),
    );
  }
}

class BootstrapGate extends StatefulWidget {
  const BootstrapGate({super.key});

  @override
  State<BootstrapGate> createState() => _BootstrapGateState();
}

const String _onboardingSeenKey = 'tek_onboarding_seen';

class _BootstrapGateState extends State<BootstrapGate> {
  bool _ready = false;
  bool _bypassAuth = false;
  bool _onboardingSeen = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    setState(() {
      _ready = false;
      _bypassAuth = false;
      _error = null;
    });

    try {
      debugPrint('BootstrapGate: starting bootstrap…');
      await _bootstrapApp();
      if (!mounted) return;
      debugPrint('BootstrapGate: bootstrap complete');
      final prefs = await SharedPreferences.getInstance();
      _onboardingSeen = prefs.getBool(_onboardingSeenKey) ?? false;
      if (!mounted) return;
      setState(() => _ready = true);
    } catch (e, st) {
      debugPrint('BootstrapGate init failed: $e\n$st');
      if (!mounted) return;
      setState(() => _error = e);
    }
  }

  String _friendlyBootstrapError(Object error) {
    if (error is FirebaseAuthException) {
      switch (error.code) {
        case 'admin-restricted-operation':
          return 'Anonymous sign-in is blocked in Firebase Auth for this project.\n\nFix: Firebase Console → Authentication → Sign-in method → enable Anonymous.';
        case 'operation-not-allowed':
          return 'This sign-in method is disabled in Firebase Auth.\n\nFix: Firebase Console → Authentication → Sign-in method → enable Anonymous.';
        case 'network-request-failed':
          return 'Network error while signing in. Check simulator network and try again.';
      }
      final msg = (error.message ?? '').trim();
      return msg.isNotEmpty ? msg : 'Auth error: ${error.code}';
    }

    if (error is FirebaseException) {
      final msg = (error.message ?? '').trim();
      if (msg.isNotEmpty) return msg;
      return 'Firebase error: ${error.code}';
    }

    return error.toString();
  }

  @override
  Widget build(BuildContext context) {
    if (_ready || _bypassAuth) {
      if (!_onboardingSeen && !_bypassAuth) {
        return const OnboardingFilm();
      }
      return const ReferralCodeScreen();
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Starting TEK…',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                if (_error == null) ...[
                  const CircularProgressIndicator(),
                  const SizedBox(height: 12),
                  const Text(
                    'Initializing Firebase and services',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white70),
                  ),
                ] else ...[
                  const Text(
                    'Startup failed',
                    style: TextStyle(
                      color: Colors.redAccent,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _friendlyBootstrapError(_error!),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      ElevatedButton(
                        onPressed: _start,
                        child: const Text('Try again'),
                      ),
                      if (kDebugMode) ...[
                        const SizedBox(width: 12),
                        OutlinedButton(
                          onPressed: () async {
                            try {
                              await _bootstrapApp(skipAuth: true);
                              if (!mounted) return;
                              setState(() {
                                _bypassAuth = true;
                                _error = null;
                              });
                            } catch (e, st) {
                              debugPrint(
                                'BootstrapGate bypass init failed: $e\n$st',
                              );
                              if (!mounted) return;
                              setState(() => _error = e);
                            }
                          },
                          child: const Text('Continue without login'),
                        ),
                      ],
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ==================== ONBOARDING FILM ====================
//
// First-launch intro. 3 panels, swipeable, all caps machined typography,
// matches the TEK aesthetic (black + neon green + cosmos bg already behind).
// Sets onboarding_seen flag on completion → user never sees it again.

class OnboardingFilm extends StatefulWidget {
  const OnboardingFilm({super.key});

  @override
  State<OnboardingFilm> createState() => _OnboardingFilmState();
}

class _OnboardingFilmState extends State<OnboardingFilm>
    with TickerProviderStateMixin {
  final _pageCtrl = PageController();
  int _page = 0;
  late final AnimationController _glowCtrl;

  static const _panels = <_OnboardingPanelData>[
    _OnboardingPanelData(
      icon: Icons.bolt,
      eyebrow: 'TRANSMISSION RECEIVED',
      title: 'WELCOME,\nOPERATOR',
      body: 'You have been granted access.\nThis is TEK.',
    ),
    _OnboardingPanelData(
      icon: Icons.diamond,
      eyebrow: 'INVITATION ONLY',
      title: 'NOT A CLUB.\nA NETWORK.',
      body: 'Members. Events. Missions.\nA progression you earn.',
    ),
    _OnboardingPanelData(
      icon: Icons.local_fire_department,
      eyebrow: 'YOUR ASSIGNMENT',
      title: 'COMPLETE\nMISSIONS',
      body: 'Earn XP. Climb the ladder.\nUnlock the inner circle.',
    ),
  ];

  @override
  void initState() {
    super.initState();
    _glowCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    _glowCtrl.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    HapticFeedback.lightImpact();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_onboardingSeenKey, true);
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const ReferralCodeScreen()),
    );
  }

  void _next() {
    HapticFeedback.selectionClick();
    if (_page < _panels.length - 1) {
      _pageCtrl.nextPage(
        duration: const Duration(milliseconds: 380),
        curve: Curves.easeOutCubic,
      );
    } else {
      _finish();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isLast = _page == _panels.length - 1;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Column(
          children: [
            // Skip
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _finish,
                    child: const Text(
                      'SKIP',
                      style: TextStyle(
                        color: Colors.white38,
                        fontSize: 11,
                        letterSpacing: 3,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // Pages
            Expanded(
              child: PageView.builder(
                controller: _pageCtrl,
                itemCount: _panels.length,
                onPageChanged: (p) => setState(() => _page = p),
                itemBuilder: (context, i) => _OnboardingPanel(
                  data: _panels[i],
                  glow: _glowCtrl,
                ),
              ),
            ),
            // Page indicators
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(_panels.length, (i) {
                final active = i == _page;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 240),
                  curve: Curves.easeOutCubic,
                  width: active ? 24 : 8,
                  height: 4,
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  decoration: BoxDecoration(
                    color: active
                        ? const Color(0xFF00FF41)
                        : Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                    boxShadow: active
                        ? [
                            BoxShadow(
                              color: const Color(0xFF00FF41)
                                  .withValues(alpha: 0.6),
                              blurRadius: 8,
                            ),
                          ]
                        : null,
                  ),
                );
              }),
            ),
            const SizedBox(height: 28),
            // CTA
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton(
                  onPressed: _next,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00FF41),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    elevation: 0,
                  ),
                  child: Text(
                    isLast ? 'PROCEED' : 'CONTINUE',
                    style: const TextStyle(
                      color: Colors.black,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 3,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}

class _OnboardingPanelData {
  final IconData icon;
  final String eyebrow;
  final String title;
  final String body;
  const _OnboardingPanelData({
    required this.icon,
    required this.eyebrow,
    required this.title,
    required this.body,
  });
}

class _OnboardingPanel extends StatelessWidget {
  final _OnboardingPanelData data;
  final AnimationController glow;
  const _OnboardingPanel({required this.data, required this.glow});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Glowing icon ring
          AnimatedBuilder(
            animation: glow,
            builder: (context, _) {
              final t = glow.value;
              return Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: const Color(0xFF00FF41),
                    width: 1.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF00FF41)
                          .withValues(alpha: 0.25 + 0.35 * t),
                      blurRadius: 24 + 18 * t,
                      spreadRadius: 1 + 2 * t,
                    ),
                  ],
                ),
                child: Icon(
                  data.icon,
                  color: const Color(0xFF00FF41),
                  size: 52,
                ),
              );
            },
          ),
          const SizedBox(height: 42),
          // Eyebrow
          Text(
            data.eyebrow,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Color(0xFF00FF41),
              fontSize: 11,
              fontWeight: FontWeight.bold,
              letterSpacing: 4,
            ),
          ),
          const SizedBox(height: 18),
          // Title
          Text(
            data.title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 32,
              fontWeight: FontWeight.bold,
              letterSpacing: 3,
              height: 1.1,
            ),
          ),
          const SizedBox(height: 22),
          // Body
          Text(
            data.body,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 14,
              height: 1.6,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}

// ==================== REFERRAL CODE SCREEN ====================
class ReferralCodeScreen extends StatefulWidget {
  const ReferralCodeScreen({super.key});

  @override
  State<ReferralCodeScreen> createState() => _ReferralCodeScreenState();
}

class _ReferralCodeScreenState extends State<ReferralCodeScreen>
    with TickerProviderStateMixin {
  final TextEditingController _codeController = TextEditingController();
  bool _isLoading = false;
  late AnimationController _portalCtrl;
  late AnimationController _fadeCtrl;
  late Animation<double> _fadeAnim;

  Future<void> _ensureAnonAuth() async {
    if (FirebaseAuth.instance.currentUser != null) return;
    await FirebaseAuth.instance.signInAnonymously();
  }

  @override
  void initState() {
    super.initState();
    _portalCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3000),
    )..repeat(reverse: true);
    _fadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _fadeAnim = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOut);
    _fadeCtrl.forward();
    _checkLoginStatus();
  }

  Future<void> _checkLoginStatus() async {
    final prefs = await SharedPreferences.getInstance();
    final savedCode = prefs.getString('userReferralCode');

    if (savedCode != null && mounted) {
      // User is already logged in, load their data and navigate
      await _loadUserData(savedCode);

      // Enforce/refresh single-device session on cold start too.
      // If this fails, don't silently bypass the single-device protection.
      try {
        await ReferralSessionManager.instance.ensureActiveForReferralCode(
          savedCode,
        );
      } on FirebaseFunctionsException catch (e) {
        final msg = e.code == 'unauthenticated'
            ? 'Session refresh failed. Please tap Continue again (or restart the app).'
            : '${e.code}: ${e.message ?? ''}'.trim();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Login failed (session): $msg'),
              backgroundColor: Colors.red,
              duration: const Duration(seconds: 6),
            ),
          );
        }
        return;
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Login failed (session): ${e.toString()}'),
              backgroundColor: Colors.red,
              duration: const Duration(seconds: 6),
            ),
          );
        }
        return;
      }

      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (context) => MainApp(
              isAdmin: false,
              initialIndex: _applicationData.isNotEmpty ? 4 : 0,
            ),
          ),
        );
      }
    }
  }

  Future<void> _loadUserData(String code) async {
    try {
      await _ensureAnonAuth();
      final snapshot = await db
          .collection('applications')
          .where('referralCode', isEqualTo: code)
          .limit(1)
          .get();

      if (snapshot.docs.isNotEmpty) {
        _applicationData = snapshot.docs.first.data();
        final prefs = await SharedPreferences.getInstance();
        // Member flow should never enable admin/control.
        await prefs.remove('isAdmin');
        await prefs.remove(tekAdminModePrefsKey);
        _applicationData['isAdmin'] = false;
      }
    } catch (e) {
      print('Error loading user data: $e');
    }
  }

  Future<void> _validateAndLogin() async {
    final code = _codeController.text.trim().toUpperCase();

    if (code.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Please enter a referral code'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      // Ensure auth exists so Firestore rules + callable functions work.
      try {
        await _ensureAnonAuth();
      } on FirebaseAuthException catch (e) {
        final msg =
            (e.code == 'admin-restricted-operation' ||
                e.code == 'operation-not-allowed')
            ? 'Anonymous sign-in is disabled for this Firebase project. Enable it in Firebase Console → Authentication → Sign-in method.'
            : (e.message ?? 'Auth error: ${e.code}');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(msg),
              backgroundColor: Colors.red,
              duration: Duration(seconds: 6),
            ),
          );
        }
        return;
      }

      // Check if code exists in Firestore
      print('Checking code in Firestore: $code');
      final snapshot = await db
          .collection('applications')
          .where('referralCode', isEqualTo: code.trim().toUpperCase())
          .limit(1)
          .get();

      print('Query results: ${snapshot.docs.length} documents found');
      if (snapshot.docs.isNotEmpty) {
        print(
          'Found document with code: ${snapshot.docs.first.data()['referralCode']}',
        );
      }

      if (snapshot.docs.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Invalid referral code. Please check your email or try again in a moment.',
              ),
              backgroundColor: Colors.red,
              duration: Duration(seconds: 4),
            ),
          );
        }
        setState(() => _isLoading = false);
        return;
      }

      // Valid code, save login state
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('userReferralCode', code);

      _applicationData = snapshot.docs.first.data();
      // Member flow should never enable admin/control.
      await prefs.remove('isAdmin');
      await prefs.remove(tekAdminModePrefsKey);
      _applicationData['isAdmin'] = false;

      // Warm up / refresh token right before session activation.
      // This makes `activateApplicationSessionByReferralCode` less likely to see `request.auth == null`.
      await FirebaseAuth.instance.currentUser?.getIdToken(true);

      // Single-device session: claim this referral code now.
      try {
        await ReferralSessionManager.instance.ensureActiveForReferralCode(code);
      } on FirebaseFunctionsException catch (e) {
        final uid = FirebaseAuth.instance.currentUser?.uid;
        final projectId = Firebase.app().options.projectId;
        final msg = e.code == 'unauthenticated'
            ? 'Unauthenticated (uid=${uid ?? 'null'}, project=$projectId). If you already enabled Anonymous auth, reinstall the app and verify the iOS Firebase project matches.'
            : '${e.code}: ${e.message ?? ''}'.trim();
        debugPrint('Session activation failed: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Login failed (session): $msg'),
              backgroundColor: Colors.red,
              duration: const Duration(seconds: 6),
            ),
          );
        }
        return;
      } catch (e) {
        debugPrint('Session activation failed: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Login failed (session): ${e.toString()}'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }

      // Sync the referralCode custom claim BEFORE navigating into MainApp,
      // so the first check-in / RSVP / story attempt has the claim in the
      // local token. Without this, freshly-logged-in users would hit
      // `permission-denied` on their first rule-gated write because the
      // token issued by anonymous auth doesn't carry the claim yet.
      try {
        final callable = FirebaseFunctions.instanceFor(region: 'us-central1')
            .httpsCallable('syncReferralClaim');
        await callable.call(<String, dynamic>{'referralCode': code});
        await FirebaseAuth.instance.currentUser?.getIdToken(true);
      } catch (e) {
        // Non-fatal — _MainAppState.initState will retry on next launch.
        debugPrint('Initial referralCode claim sync failed: $e');
      }

      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (context) => MainApp(isAdmin: false, initialIndex: 4),
          ),
        );
      }
    } catch (e) {
      print('Login error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error validating code. Please try again.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: FadeTransition(
        opacity: _fadeAnim,
        child: SingleChildScrollView(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(height: 60),
              GestureDetector(
                onLongPress: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const AdminLoginPage()),
                  );
                },
                child: const TekWordmark(fontSize: 32, letterSpacing: 7),
              ),
              SizedBox(height: 60),
              _buildGlowingPortal(),
              SizedBox(height: 50),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  'ENTER REFERRAL CODE',
                  style: TextStyle(
                    fontSize: 16,
                    color: Colors.white70,
                    letterSpacing: 1.5,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              SizedBox(height: 24),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 24),
                child: TextField(
                  controller: _codeController,
                  style: TextStyle(color: Color(0xFFB8B8C0)),
                  decoration: InputDecoration(
                    hintText: 'Enter code',
                    hintStyle: TextStyle(color: Colors.white30),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: Colors.white30),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: Colors.white30),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(
                        color: Color(0xFF00FF41),
                        width: 2,
                      ),
                    ),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 16,
                    ),
                  ),
                ),
              ),
              SizedBox(height: 32),
              GlowButton(
                onPressed: _isLoading ? null : _validateAndLogin,
                label: 'CONTINUE',
                color: Color(0xFFB8B8C0),
                isLoading: _isLoading,
                width: 220,
                height: 54,
              ),
              SizedBox(height: 16),
              TextButton(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => MembershipApplicationScreen(),
                    ),
                  );
                },
                child: Text(
                  'APPLY FOR MEMBERSHIP',
                  style: TextStyle(
                    color: Color(0xFF00FF41),
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1,
                  ),
                ),
              ),
              SizedBox(height: 80),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGlowingPortal() {
    return AnimatedBuilder(
      animation: _portalCtrl,
      builder: (context, child) {
        final pulse = 0.94 + 0.06 * _portalCtrl.value;
        final glowAlpha = 0.3 + 0.25 * _portalCtrl.value;
        return Center(
          child: Transform.scale(
            scale: pulse,
            child: SizedBox(
              width: 300,
              height: 300,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Outermost ambient green glow
                  Container(
                    width: 300,
                    height: 300,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Color(
                            0xFF00FF41,
                          ).withValues(alpha: glowAlpha * 0.5),
                          blurRadius: 60,
                          spreadRadius: 8,
                        ),
                        BoxShadow(
                          color: Color(
                            0xFF00FF41,
                          ).withValues(alpha: glowAlpha * 0.2),
                          blurRadius: 120,
                          spreadRadius: 20,
                        ),
                      ],
                    ),
                  ),
                  // Outermost chrome ring
                  Container(
                    width: 290,
                    height: 290,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Color(
                          0xFF7A7A7A,
                        ).withValues(alpha: 0.5 + 0.3 * _portalCtrl.value),
                        width: 1.5,
                      ),
                    ),
                  ),
                  // Second chrome ring with green tint
                  Container(
                    width: 265,
                    height: 265,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Color(
                          0xFF00FF41,
                        ).withValues(alpha: 0.12 + 0.08 * _portalCtrl.value),
                        width: 1,
                      ),
                    ),
                  ),
                  // Third chrome ring
                  Container(
                    width: 240,
                    height: 240,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Color(
                          0xFF8A8A8A,
                        ).withValues(alpha: 0.35 + 0.2 * _portalCtrl.value),
                        width: 1.5,
                      ),
                    ),
                  ),
                  // Green energy field — outer corona
                  Container(
                    width: 230,
                    height: 230,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          Color(
                            0xFF00FF41,
                          ).withValues(alpha: 0.20 + 0.12 * _portalCtrl.value),
                          Color(
                            0xFF00CC33,
                          ).withValues(alpha: 0.14 + 0.08 * _portalCtrl.value),
                          Color(0xFF003D10).withValues(alpha: 0.08),
                          Colors.transparent,
                        ],
                        stops: const [0.0, 0.35, 0.7, 1.0],
                        radius: 0.85,
                      ),
                    ),
                  ),
                  // Inner chrome containment ring
                  Container(
                    width: 210,
                    height: 210,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Color(0xFF5A5A5A).withValues(alpha: 0.4),
                        width: 1,
                      ),
                    ),
                  ),
                  // Green energy ring — bright inner boundary
                  Container(
                    width: 200,
                    height: 200,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Color(
                          0xFF00FF41,
                        ).withValues(alpha: 0.25 + 0.15 * _portalCtrl.value),
                        width: 1.5,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Color(
                            0xFF00FF41,
                          ).withValues(alpha: 0.15 + 0.1 * _portalCtrl.value),
                          blurRadius: 15,
                          spreadRadius: 1,
                        ),
                      ],
                    ),
                  ),
                  // The void — deep black center with green edge bleed
                  Container(
                    width: 190,
                    height: 190,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          Color(0xFF000000),
                          Color(0xFF010A04),
                          Color(0xFF002A0F).withValues(alpha: 0.5),
                        ],
                        stops: const [0.0, 0.6, 1.0],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _codeController.dispose();
    _portalCtrl.dispose();
    _fadeCtrl.dispose();
    super.dispose();
  }
}

class AdminLoginPage extends StatefulWidget {
  const AdminLoginPage({super.key});

  @override
  State<AdminLoginPage> createState() => _AdminLoginPageState();
}

class _AdminLoginPageState extends State<AdminLoginPage> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _loading = false;
  bool _obscure = true;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _signInAdmin() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (email.isEmpty || !email.contains('@') || password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enter admin email and password'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() => _loading = true);
    try {
      // This will switch the Firebase user on this device.
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
      await FirebaseAuth.instance.currentUser?.getIdToken(true);

      final isAdmin = await AdminStatusManager.instance.isCurrentUserAdmin();
      if (!isAdmin) {
        // Keep admin-only access strict: if the account isn't allowlisted, revert.
        final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
        if (!mounted) return;

        await showDialog<void>(
          context: context,
          builder: (dialogCtx) {
            return AlertDialog(
              backgroundColor: const Color(0xFF0B0B0B),
              title: const Text(
                'Not allowlisted',
                style: TextStyle(color: Color(0xFFB8B8C0)),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'This account signed in successfully, but it is not in config/admins.uids.',
                    style: TextStyle(color: Colors.white70, height: 1.4),
                  ),
                  const SizedBox(height: 12),
                  const Text('UID:', style: TextStyle(color: Colors.white54)),
                  const SizedBox(height: 6),
                  SelectableText(
                    uid.isEmpty ? '(missing uid)' : uid,
                    style: const TextStyle(
                      color: Color(0xFFB8B8C0),
                      fontFamily: 'monospace',
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Copy this UID and make it the ONLY entry in config/admins.uids.',
                    style: TextStyle(color: Colors.white54, height: 1.3),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    if (uid.isNotEmpty) {
                      Clipboard.setData(ClipboardData(text: uid));
                    }
                    Navigator.of(dialogCtx).pop();
                  },
                  child: const Text('Copy UID'),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.of(dialogCtx).pop(),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                  child: const Text('OK'),
                ),
              ],
            );
          },
        );

        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.remove(tekAdminModePrefsKey);
          await prefs.remove('isAdmin');
          await prefs.remove('userReferralCode');
        } catch (_) {
          // Best-effort.
        }

        await FirebaseAuth.instance.signOut();
        await FirebaseAuth.instance.signInAnonymously();
        return;
      }

      await ReferralSessionManager.instance.stop();
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('userReferralCode');

      // Admin UI should only be visible in explicit admin mode.
      await prefs.setBool(tekAdminModePrefsKey, true);
      await prefs.remove('isAdmin');

      _applicationData.clear();
      _applicationData['isAdmin'] = false;

      if (!mounted) return;
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(
          builder: (_) => const MainApp(initialIndex: 4, isAdmin: true),
        ),
        (route) => false,
      );
    } on FirebaseAuthException catch (e) {
      final msg = e.code == 'operation-not-allowed'
          ? 'Email/password sign-in is disabled in Firebase. Enable it in Firebase Console → Authentication → Sign-in method.'
          : (e.message ?? e.code);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(msg),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 6),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Admin login failed: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 6),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Color(0xFFB8B8C0)),
          onPressed: () => Navigator.pop(context),
        ),
        centerTitle: true,
        title: const Text(
          'ADMIN LOGIN',
          style: TextStyle(
            color: Color(0xFFFF0000),
            fontWeight: FontWeight.bold,
            letterSpacing: 2,
          ),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'This is for TEK admins only.\nLong-press the TEK title on the login screen to open this page.',
              style: TextStyle(color: Colors.white54, height: 1.4),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _emailController,
              enabled: !_loading,
              keyboardType: TextInputType.emailAddress,
              style: const TextStyle(color: Color(0xFFB8B8C0)),
              decoration: const InputDecoration(
                labelText: 'Admin email',
                labelStyle: TextStyle(color: Colors.white70),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _passwordController,
              enabled: !_loading,
              obscureText: _obscure,
              style: const TextStyle(color: Color(0xFFB8B8C0)),
              decoration: InputDecoration(
                labelText: 'Password',
                labelStyle: const TextStyle(color: Colors.white70),
                suffixIcon: IconButton(
                  onPressed: _loading
                      ? null
                      : () => setState(() => _obscure = !_obscure),
                  icon: Icon(
                    _obscure ? Icons.visibility : Icons.visibility_off,
                    color: Colors.white54,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _loading ? null : _signInAdmin,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFF0000),
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: Text(_loading ? 'Signing in…' : 'Sign in'),
            ),
          ],
        ),
      ),
    );
  }
}

// ==================== MEMBERSHIP APPLICATION SCREEN ====================
class MembershipApplicationScreen extends StatefulWidget {
  const MembershipApplicationScreen({super.key});

  @override
  State<MembershipApplicationScreen> createState() =>
      _MembershipApplicationScreenState();
}

class _MembershipApplicationScreenState
    extends State<MembershipApplicationScreen> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _bioController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _instagramController = TextEditingController();
  String? _profileImage;
  bool _eulaAccepted = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: Color(0xFFB8B8C0)),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'APPLY FOR MEMBERSHIP',
          style: TextStyle(
            color: Color(0xFFB8B8C0),
            fontSize: 16,
            fontWeight: FontWeight.bold,
            letterSpacing: 1,
          ),
        ),
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Column(
            children: [
              SizedBox(height: 20),
              // Profile Picture
              GestureDetector(
                onTap: () async {
                  final ImagePicker picker = ImagePicker();
                  final XFile? image = await picker.pickImage(
                    source: ImageSource.gallery,
                  );

                  if (image != null) {
                    setState(() {
                      _profileImage = image.path;
                    });
                  }
                },
                child: Container(
                  width: 150,
                  height: 150,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Color(0xFF00FF41), width: 2),
                    color: Colors.grey[900],
                  ),
                  child: _profileImage == null
                      ? Icon(Icons.camera_alt, color: Colors.white70, size: 40)
                      : ClipOval(
                          child: Image.file(
                            File(_profileImage!),
                            fit: BoxFit.cover,
                          ),
                        ),
                ),
              ),
              SizedBox(height: 8),
              Text(
                'TAP TO UPLOAD PROFILE PICTURE',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 11,
                  letterSpacing: 1,
                ),
              ),
              SizedBox(height: 30),
              // Name
              _buildTextField(
                controller: _nameController,
                label: 'FULL NAME',
                hint: 'Enter your full name',
              ),
              SizedBox(height: 16),
              // Email
              _buildTextField(
                controller: _emailController,
                label: 'EMAIL',
                hint: 'your.email@example.com',
              ),
              SizedBox(height: 16),
              // Phone
              _buildTextField(
                controller: _phoneController,
                label: 'PHONE NUMBER',
                hint: '+1 (555) 123-4567',
              ),
              SizedBox(height: 16),
              // Instagram
              _buildTextField(
                controller: _instagramController,
                label: 'INSTAGRAM USERNAME',
                hint: '@yourusername',
              ),
              SizedBox(height: 16),
              // Bio
              _buildTextField(
                controller: _bioController,
                label: 'BIO',
                hint: 'Tell us about yourself...',
                maxLines: 4,
              ),
              SizedBox(height: 30),
              // EULA Acceptance Checkbox
              Container(
                padding: EdgeInsets.all(12),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white10),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Checkbox(
                      value: _eulaAccepted,
                      onChanged: (value) {
                        setState(() {
                          _eulaAccepted = value ?? false;
                        });
                      },
                      activeColor: Color(0xFF00FF41),
                      checkColor: Colors.black,
                    ),
                    Expanded(
                      child: GestureDetector(
                        onTap: () {
                          setState(() {
                            _eulaAccepted = !_eulaAccepted;
                          });
                        },
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Terms of Service & Privacy',
                              style: TextStyle(
                                color: Color(0xFFB8B8C0),
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            SizedBox(height: 4),
                            Text(
                              'I agree to the Terms of Service and acknowledge the Privacy Policy. I understand there is zero tolerance for objectionable content or abusive users.',
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(height: 30),
              // Submit Button
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _eulaAccepted
                      ? () {
                          _submitApplication(context);
                        }
                      : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _eulaAccepted
                        ? Color(0xFF00FF41).withValues(alpha: 0.2)
                        : Colors.grey[700],
                    side: BorderSide(
                      color: _eulaAccepted ? Color(0xFF00FF41) : Colors.grey,
                      width: 2,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    padding: EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: Text(
                    _eulaAccepted
                        ? 'SUBMIT APPLICATION'
                        : 'ACCEPT TERMS TO CONTINUE',
                    style: TextStyle(
                      color: _eulaAccepted ? Color(0xFF00FF41) : Colors.grey,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1,
                    ),
                  ),
                ),
              ),
              SizedBox(height: 30),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required String hint,
    int maxLines = 1,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: Colors.white70,
            fontSize: 11,
            fontWeight: FontWeight.bold,
            letterSpacing: 1,
          ),
        ),
        SizedBox(height: 8),
        TextField(
          controller: controller,
          maxLines: maxLines,
          style: TextStyle(color: Color(0xFFB8B8C0)),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: Colors.white30),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: Colors.white10),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: Colors.white10),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: Color(0xFF00FF41), width: 2),
            ),
            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          ),
        ),
      ],
    );
  }

  void _submitApplication(BuildContext context) async {
    if (_nameController.text.isEmpty ||
        _emailController.text.isEmpty ||
        _phoneController.text.isEmpty ||
        _instagramController.text.isEmpty ||
        _bioController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Please fill in all fields'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    if (_profileImage == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Please add a profile photo before submitting'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    try {
      // Ensure user is authenticated (required for Firestore queries)
      if (FirebaseAuth.instance.currentUser == null) {
        await FirebaseAuth.instance.signInAnonymously();
      }

      // Check if email already exists
      final emailQuery = await db
          .collection('applications')
          .where('email', isEqualTo: _emailController.text.trim())
          .limit(1)
          .get();

      if (emailQuery.docs.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'This email is already registered. Please use your existing referral code to log in.',
            ),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 4),
          ),
        );
        return;
      }

      // Check if phone number already exists
      final phoneQuery = await db
          .collection('applications')
          .where('phone', isEqualTo: _phoneController.text.trim())
          .limit(1)
          .get();

      if (phoneQuery.docs.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'This phone number is already registered. Please use your existing referral code to log in.',
            ),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 4),
          ),
        );
        return;
      }

      if (containsProhibitedContent(_bioController.text.trim())) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Please remove abusive or explicit language from your bio before submitting.',
            ),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      // Upload profile image if provided
      String? profileImageUrl;
      if (_profileImage != null) {
        try {
          print('Uploading profile image...');
          final file = File(_profileImage!);
          final timestamp = DateTime.now().millisecondsSinceEpoch;
          final storageRef = FirebaseStorage.instance
              .ref()
              .child('profile_images')
              .child('new_${timestamp}_${_emailController.text.trim()}.jpg');

          final uploadTask = storageRef.putFile(file);
          final uploadSnapshot = await uploadTask;

          if (uploadSnapshot.state == TaskState.success) {
            profileImageUrl = await uploadSnapshot.ref.getDownloadURL();
            print('Profile image uploaded: $profileImageUrl');
          } else {
            print('Upload failed with state: ${uploadSnapshot.state}');
          }
        } catch (e) {
          print('Profile image upload error: $e');
          // Continue without image rather than failing the whole application
        }
      }

      // Save application to Firestore with pending status (no referral code yet)
      final applicationData = {
        'name': _nameController.text.trim(),
        'email': _emailController.text.trim(),
        'phone': _phoneController.text.trim(),
        'instagram': _instagramController.text.trim(),
        'bio': _bioController.text.trim(),
        'status': 'pending',
        'submittedAt': FieldValue.serverTimestamp(),
        'friendRequests': [],
        'friends': [],
        'blockedUsers': [],
        'xpPoints': 0,
        if (profileImageUrl != null) 'profileImageUrl': profileImageUrl,
      };

      await db.collection('applications').add(applicationData);
      print('Application saved to Firestore as pending');

      // Send admin notification email (no welcome email to applicant yet)
      final HttpsCallable callable = FirebaseFunctions.instanceFor(
        region: 'us-central1',
      ).httpsCallable('notifyAdminNewApplication');

      await callable.call({
        'name': _nameController.text.trim(),
        'email': _emailController.text.trim(),
        'phone': _phoneController.text.trim(),
        'instagram': _instagramController.text.trim(),
        'bio': _bioController.text.trim(),
        'adminEmail': 'linolyander@icloud.com',
        if (profileImageUrl != null) 'profileImageUrl': profileImageUrl,
      });

      print('Admin notification sent');

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Application submitted! You will receive an email once approved.',
          ),
          backgroundColor: Color(0xFF00FF41),
          duration: Duration(seconds: 3),
        ),
      );

      // Navigate back to referral code screen
      Future.delayed(Duration(seconds: 2), () {
        if (mounted) {
          Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute(builder: (context) => ReferralCodeScreen()),
            (route) => false,
          );
        }
      });
    } catch (e) {
      print('ERROR DETAILS: $e');
      print('ERROR TYPE: ${e.runtimeType}');
      if (e is FirebaseFunctionsException) {
        print('Firebase Functions Error Code: ${e.code}');
        print('Firebase Functions Error Message: ${e.message}');
        print('Firebase Functions Error Details: ${e.details}');
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error submitting application: ${e.toString()}'),
          backgroundColor: Colors.red,
          duration: Duration(seconds: 5),
        ),
      );
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _bioController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _instagramController.dispose();
    super.dispose();
  }
}

// ==================== USER PROFILE PAGE ====================
class UserProfilePage extends StatefulWidget {
  final Map<String, dynamic>? applicationData;

  const UserProfilePage({super.key, this.applicationData});

  @override
  State<UserProfilePage> createState() => _UserProfilePageState();
}

class _UserProfilePageState extends State<UserProfilePage> {
  late Map<String, dynamic> profileData;

  @override
  void initState() {
    super.initState();
    profileData =
        widget.applicationData ??
        {
          'name': 'Devon',
          'email': 'devon@example.com',
          'phone': '+1 (555) 123-4567',
          'instagram': '@devon',
          'bio': 'Clubbing enthusiast. Love to dance!',
          'profileImage': null,
        };
    _refreshProfileData();

    final code = profileData['referralCode'];
    if (code is String && code.trim().isNotEmpty) {
      // Fire-and-forget; this will also start the session listener.
      ReferralSessionManager.instance.ensureActiveForReferralCode(code);
    }
  }

  Future<void> _refreshProfileData() async {
    try {
      final referralCode = profileData['referralCode'];
      if (referralCode != null && referralCode.isNotEmpty) {
        final snapshot = await FirebaseFirestore.instance
            .collection('applications')
            .where('referralCode', isEqualTo: referralCode)
            .limit(1)
            .get();

        if (snapshot.docs.isNotEmpty && mounted) {
          final data = snapshot.docs.first.data();
          setState(() {
            profileData = data;
            _applicationData = data;
          });
        }
      }
    } catch (e) {
      print('Error refreshing profile: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        toolbarHeight: 78,
        automaticallyImplyLeading: false,
        centerTitle: true,
        title: const Padding(
          padding: EdgeInsets.only(top: 6),
          child: TekWordmark(fontSize: 22, letterSpacing: 5.2),
        ),
        actions: [
          IconButton(
            padding: const EdgeInsets.only(right: 12),
            icon: Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.black.withValues(alpha: 0.35),
                border:
                    Border.all(color: const Color(0x55D9DEE6), width: 0.8),
              ),
              child: const Icon(
                Icons.settings,
                color: _chromeTextColor,
                size: 20,
              ),
            ),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => const SettingsScreen()),
            ),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(12),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Container(
              width: double.infinity,
              height: 1.5,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                gradient: const LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [
                    Color(0x66F4F6F9),
                    Color(0xFFF7F9FB),
                    Color(0x66F4F6F9),
                  ],
                ),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x3300FF41),
                    blurRadius: 10,
                    spreadRadius: 0.5,
                  ),
                  BoxShadow(
                    color: Color(0x55FFFFFF),
                    blurRadius: 6,
                    spreadRadius: -1,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      body: Stack(
        children: [
          SingleChildScrollView(
            child: Column(
              children: [
                const SizedBox(height: 8),
                GestureDetector(
                  onTap: () async {
                    try {
                      final ImagePicker picker = ImagePicker();
                      final XFile? image = await picker.pickImage(
                        source: ImageSource.gallery,
                        maxWidth: 800,
                        maxHeight: 800,
                        imageQuality: 85,
                      );

                      if (image == null) return;

                      if (mounted) {
                        showDialog(
                          context: context,
                          barrierDismissible: false,
                          builder: (context) => const Center(
                            child: CircularProgressIndicator(
                              valueColor: AlwaysStoppedAnimation(
                                Color(0xFF00FF41),
                              ),
                            ),
                          ),
                        );
                      }

                      final referralCode = profileData['referralCode'];
                      final file = File(image.path);
                      final timestamp = DateTime.now().millisecondsSinceEpoch;
                      final storageRef = FirebaseStorage.instance
                          .ref()
                          .child('profile_images')
                          .child('${referralCode}_$timestamp.jpg');

                      final uploadTask = storageRef.putFile(file);
                      final uploadSnapshot = await uploadTask;

                      if (uploadSnapshot.state == TaskState.success) {
                        final downloadUrl = await uploadSnapshot.ref
                            .getDownloadURL();
                        final snapshot = await FirebaseFirestore.instance
                            .collection('applications')
                            .where('referralCode', isEqualTo: referralCode)
                            .limit(1)
                            .get();

                        if (snapshot.docs.isNotEmpty) {
                          await snapshot.docs.first.reference.update({
                            'profileImageUrl': downloadUrl,
                          });

                          setState(() {
                            profileData['profileImageUrl'] = downloadUrl;
                            _applicationData['profileImageUrl'] = downloadUrl;
                          });

                          if (mounted) {
                            Navigator.pop(context);
                            AppUtils.showSuccess(
                              context,
                              'Profile picture updated!',
                            );
                          }
                        }
                      }
                    } catch (e) {
                      print('Error updating profile picture: $e');
                      if (mounted) {
                        Navigator.pop(context);
                        AppUtils.showError(
                          context,
                          'Failed to update picture: $e',
                        );
                      }
                    }
                  },
                  child: _buildProfileCircle(220),
                ),
                const SizedBox(height: 20),
                Text(
                  (profileData['name'] as String? ?? 'N/A').toUpperCase(),
                  style: const TextStyle(
                    color: Color(0xFFB8B8C0),
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(height: 16),
                StreamBuilder<QuerySnapshot>(
                  stream: FirebaseFirestore.instance
                      .collection('applications')
                      .where(
                        'referralCode',
                        isEqualTo: profileData['referralCode'] ?? '',
                      )
                      .limit(1)
                      .snapshots(),
                  builder: (context, snapshot) {
                    final doc = (snapshot.data?.docs.isNotEmpty ?? false)
                        ? snapshot.data!.docs.first
                        : null;
                    final xpPoints =
                        (doc?.data() as Map<String, dynamic>?)?['xpPoints'] ??
                        0;
                    final level = (xpPoints ~/ 100) + 1;
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.visibility,
                            size: 14,
                            color: Colors.white70,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'LEVEL $level',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                              letterSpacing: 1,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
                const SizedBox(height: 12),
                StreamBuilder<QuerySnapshot>(
                  stream: FirebaseFirestore.instance
                      .collection('applications')
                      .where(
                        'referralCode',
                        isEqualTo: profileData['referralCode'] ?? '',
                      )
                      .limit(1)
                      .snapshots(),
                  builder: (context, snapshot) {
                    final doc = (snapshot.data?.docs.isNotEmpty ?? false)
                        ? snapshot.data!.docs.first
                        : null;
                    final xpPoints =
                        (doc?.data() as Map<String, dynamic>?)?['xpPoints'] ??
                        0;
                    final xpCurrent = xpPoints % 100;
                    const xpMax = 100;

                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: TweenAnimationBuilder<double>(
                        tween: Tween<double>(begin: 0, end: xpCurrent / xpMax),
                        duration: const Duration(milliseconds: 1100),
                        curve: Curves.easeOutCubic,
                        builder: (_, v, __) => Ps3XpProgressBar(
                          progress: v,
                          height: 10,
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 8),
                StreamBuilder<QuerySnapshot>(
                  stream: FirebaseFirestore.instance
                      .collection('applications')
                      .where(
                        'referralCode',
                        isEqualTo: profileData['referralCode'] ?? '',
                      )
                      .limit(1)
                      .snapshots(),
                  builder: (context, snapshot) {
                    final doc = (snapshot.data?.docs.isNotEmpty ?? false)
                        ? snapshot.data!.docs.first
                        : null;
                    final xpPoints =
                        (doc?.data() as Map<String, dynamic>?)?['xpPoints'] ??
                        0;
                    final xpCurrent = xpPoints % 100;
                    const xpMax = 100;

                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          AnimatedXP(
                            value: xpCurrent,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const Text(
                            '$xpMax XP',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
                const SizedBox(height: 8),
                StreamBuilder<QuerySnapshot>(
                  stream: FirebaseFirestore.instance
                      .collection('applications')
                      .where(
                        'referralCode',
                        isEqualTo: profileData['referralCode'] ?? '',
                      )
                      .limit(1)
                      .snapshots(),
                  builder: (context, snapshot) {
                    final doc = (snapshot.data?.docs.isNotEmpty ?? false)
                        ? snapshot.data!.docs.first
                        : null;
                    final xpPoints =
                        (doc?.data() as Map<String, dynamic>?)?['xpPoints'] ??
                        0;
                    final xpCurrent = xpPoints % 100;
                    const xpMax = 100;
                    final xpToNext = xpMax - xpCurrent;

                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        '$xpToNext XP TO FREE DRINK',
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.5,
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 16),
                if (profileData['instagram'] != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      '@${profileData['instagram']}',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                if (profileData['bio'] != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      profileData['bio'] as String,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                        height: 1.5,
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: ElevatedButton.icon(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => EditProfileInfoPage(
                            currentData: profileData,
                            onSave: (updatedData) async {
                              try {
                                final referralCode =
                                    profileData['referralCode'];
                                if (referralCode == null ||
                                    referralCode.toString().trim().isEmpty) {
                                  AppUtils.showError(
                                    context,
                                    'Invalid user session - no referral code',
                                  );
                                  return;
                                }

                                final snapshot = await FirebaseFirestore
                                    .instance
                                    .collection('applications')
                                    .where(
                                      'referralCode',
                                      isEqualTo: referralCode,
                                    )
                                    .limit(1)
                                    .get();

                                if (snapshot.docs.isEmpty) {
                                  AppUtils.showError(
                                    context,
                                    'User profile not found in database',
                                  );
                                  return;
                                }

                                final Map<String, dynamic> updateData = {
                                  'name': updatedData['name'] ?? '',
                                  'email': updatedData['email'] ?? '',
                                  'phone': updatedData['phone'] ?? '',
                                  'instagram': updatedData['instagram'] ?? '',
                                };

                                if (updatedData['bio'] != null) {
                                  updateData['bio'] = updatedData['bio'];
                                }

                                if (updatedData['profileImage'] != null &&
                                    updatedData['profileImage'] is File) {
                                  try {
                                    final file =
                                        updatedData['profileImage'] as File;
                                    final storage = FirebaseStorage.instance;
                                    final storageRef = storage
                                        .ref()
                                        .child('profile_images')
                                        .child(
                                          '${referralCode}_${DateTime.now().millisecondsSinceEpoch}.jpg',
                                        );

                                    final uploadTask = storageRef.putFile(file);
                                    final uploadSnapshot = await uploadTask;

                                    if (uploadSnapshot.state ==
                                        TaskState.success) {
                                      final downloadUrl = await uploadSnapshot
                                          .ref
                                          .getDownloadURL();
                                      updateData['profileImageUrl'] =
                                          downloadUrl;
                                    } else {
                                      throw Exception(
                                        'Upload failed with state: ${uploadSnapshot.state}',
                                      );
                                    }
                                  } catch (e) {
                                    if (mounted) {
                                      AppUtils.showError(
                                        context,
                                        'Image upload failed: $e',
                                      );
                                    }
                                    return;
                                  }
                                }

                                await snapshot.docs.first.reference.update(
                                  updateData,
                                );
                                await Future.delayed(
                                  const Duration(milliseconds: 500),
                                );
                                await _refreshProfileData();

                                setState(() {
                                  profileData['name'] = updatedData['name'];
                                  profileData['email'] = updatedData['email'];
                                  profileData['phone'] = updatedData['phone'];
                                  profileData['instagram'] =
                                      updatedData['instagram'];
                                  if (updatedData['bio'] != null) {
                                    profileData['bio'] = updatedData['bio'];
                                  }
                                  if (updateData.containsKey(
                                    'profileImageUrl',
                                  )) {
                                    profileData['profileImageUrl'] =
                                        updateData['profileImageUrl'];
                                  }

                                  _applicationData['name'] =
                                      updatedData['name'];
                                  _applicationData['email'] =
                                      updatedData['email'];
                                  _applicationData['phone'] =
                                      updatedData['phone'];
                                  _applicationData['instagram'] =
                                      updatedData['instagram'];
                                  if (updatedData['bio'] != null) {
                                    _applicationData['bio'] =
                                        updatedData['bio'];
                                  }
                                  if (updateData.containsKey(
                                    'profileImageUrl',
                                  )) {
                                    _applicationData['profileImageUrl'] =
                                        updateData['profileImageUrl'];
                                  }
                                });

                                AppUtils.showSuccess(
                                  context,
                                  'Profile updated successfully!',
                                );
                              } catch (e) {
                                AppUtils.showError(
                                  context,
                                  'Failed to update profile: ${e.toString()}',
                                );
                              }
                            },
                          ),
                        ),
                      );
                    },
                    icon: const Icon(
                      Icons.edit,
                      size: 16,
                      color: Color(0xFFB8B8C0),
                    ),
                    label: const Text(
                      'EDIT INFORMATION',
                      style: TextStyle(
                        color: Color(0xFFB8B8C0),
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Color(0xFF00FF41).withOpacity(0.1),
                      side: const BorderSide(
                        color: Color(0xFF00FF41),
                        width: 1,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.symmetric(
                        vertical: 12,
                        horizontal: 20,
                      ),
                      minimumSize: const Size(double.infinity, 48),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _RedeemDrinkButton(
                    referralCode: (profileData['referralCode'] ?? '') as String,
                    userName: (profileData['name'] ?? '') as String,
                  ),
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: PressScale(
                    child: SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () {
                          HapticFeedback.lightImpact();
                          TekSounds.instance.tap();
                          Navigator.push(context, cinematicRoute(_FriendQrScreen(
                            myReferralCode: (profileData['referralCode'] ?? '') as String,
                            myName: (profileData['name'] ?? '') as String,
                          )));
                        },
                        icon: const Icon(Icons.qr_code_2, color: Color(0xFF00FF41), size: 16),
                        label: const Text('CONNECT VIA QR',
                            style: TextStyle(color: Color(0xFF00FF41), fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Color(0xFF00FF41)),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: FutureBuilder<QuerySnapshot>(
                    future: FirebaseFirestore.instance
                        .collection('applications')
                        .where(
                          'referralCode',
                          isEqualTo: profileData['referralCode'] ?? '',
                        )
                        .limit(1)
                        .get(),
                    builder: (context, snapshot) {
                      final doc = (snapshot.data?.docs.isNotEmpty ?? false)
                          ? snapshot.data!.docs.first
                          : null;
                      final xpPoints =
                          (doc?.data() as Map<String, dynamic>?)?['xpPoints'] ??
                          0;
                      final level = (xpPoints ~/ 100) + 1;
                      final xpCurrent = xpPoints % 100;
                      const xpMax = 100;

                      return ElevatedButton(
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => RewardsProgressPage(
                                currentLevel: level,
                                currentXP: xpCurrent,
                                maxXP: xpMax,
                              ),
                            ),
                          );
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.transparent,
                          side: const BorderSide(
                            color: Colors.white30,
                            width: 1,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          padding: const EdgeInsets.symmetric(
                            vertical: 10,
                            horizontal: 20,
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: const [
                            Text(
                              'REWARDS',
                              style: TextStyle(
                                color: Color(0xFFB8B8C0),
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            SizedBox(width: 8),
                            Icon(
                              Icons.arrow_forward,
                              color: Color(0xFFB8B8C0),
                              size: 14,
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 20),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: const Text(
                      'EDIT PICTURES',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white10),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 60,
                          height: 60,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            color: Colors.grey[800],
                          ),
                          child: const Icon(
                            Icons.image,
                            color: Colors.white30,
                            size: 30,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            (profileData['name'] as String).toUpperCase(),
                            style: const TextStyle(
                              color: Color(0xFFB8B8C0),
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const Icon(
                          Icons.arrow_forward,
                          color: Colors.white30,
                          size: 20,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white10),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.person, color: Colors.white70, size: 24),
                        SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'EDIT INFO',
                            style: TextStyle(
                              color: Color(0xFFB8B8C0),
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        Icon(
                          Icons.arrow_forward,
                          color: Colors.white30,
                          size: 20,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: ElevatedButton.icon(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const InviteFriendsPage(),
                        ),
                      );
                    },
                    icon: const Icon(
                      Icons.person_add,
                      size: 18,
                      color: Color(0xFF00FF41),
                    ),
                    label: const Text(
                      'INVITE FRIENDS',
                      style: TextStyle(
                        color: Color(0xFF00FF41),
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00FF41).withOpacity(0.1),
                      side: const BorderSide(
                        color: Color(0xFF00FF41),
                        width: 1,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.symmetric(
                        vertical: 12,
                        horizontal: 20,
                      ),
                      minimumSize: const Size(double.infinity, 48),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                _TrophyWallSection(profileData: profileData),
                const SizedBox(height: 30),
              ],
            ),
          ),
          IgnorePointer(
            child: Container(
              height: 72,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0xF0000000),
                    Color(0x70000000),
                    Color(0x00000000),
                  ],
                  stops: [0.0, 0.35, 1.0],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProfileCircle(double size) {
    final portalSize = size + 60;
    return SizedBox(
      width: portalSize,
      height: portalSize,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Outer green ambient glow
          Container(
            width: portalSize,
            height: portalSize,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Color(0xFF00FF41).withValues(alpha: 0.15),
                  blurRadius: 40,
                  spreadRadius: 5,
                ),
              ],
            ),
          ),
          // Outer chrome ring
          Container(
            width: portalSize - 4,
            height: portalSize - 4,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: Color(0xFF7A7A7A).withValues(alpha: 0.5),
                width: 1.5,
              ),
            ),
          ),
          // Green energy ring
          Container(
            width: portalSize - 20,
            height: portalSize - 20,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: Color(0xFF00FF41).withValues(alpha: 0.2),
                width: 1,
              ),
            ),
          ),
          // Inner chrome ring
          Container(
            width: portalSize - 35,
            height: portalSize - 35,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: Color(0xFF8A8A8A).withValues(alpha: 0.35),
                width: 1.5,
              ),
            ),
          ),
          // Green glow border around image
          Container(
            width: size + 6,
            height: size + 6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: Color(0xFF00FF41).withValues(alpha: 0.35),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: Color(0xFF00FF41).withValues(alpha: 0.12),
                  blurRadius: 12,
                  spreadRadius: 1,
                ),
              ],
            ),
          ),
          // The actual profile image
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(shape: BoxShape.circle),
            child: ClipOval(
              child:
                  profileData['profileImageUrl'] != null &&
                      profileData['profileImageUrl'].toString().isNotEmpty
                  ? Image.network(
                      profileData['profileImageUrl'],
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) {
                        return Container(
                          color: Colors.grey[800],
                          child: Icon(
                            Icons.person,
                            size: size * 0.5,
                            color: Colors.white30,
                          ),
                        );
                      },
                      loadingBuilder: (context, child, loadingProgress) {
                        if (loadingProgress == null) return child;
                        return Container(
                          color: Colors.grey[800],
                          child: Center(
                            child: CircularProgressIndicator(
                              valueColor: AlwaysStoppedAnimation(
                                Color(0xFF00FF41),
                              ),
                            ),
                          ),
                        );
                      },
                    )
                  : Container(
                      color: Colors.grey[800],
                      child: Icon(
                        Icons.person,
                        size: size * 0.5,
                        color: Colors.white30,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

// ==================== TROPHY WALL ====================

class _BadgeDef {
  final String name;
  final String subtitle;
  final IconData icon;
  final Color color;
  final bool Function(Map<String, dynamic>) earned;

  _BadgeDef({
    required this.name,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.earned,
  });
}

final List<_BadgeDef> _tekBadges = [
  _BadgeDef(
    name: 'FIRST CONTACT',
    subtitle: 'Complete 1 mission',
    icon: Icons.bolt,
    color: const Color(0xFFCD7F32),
    earned: (d) => ((d['completedSidequests'] as List?)?.length ?? 0) >= 1,
  ),
  _BadgeDef(
    name: 'OPERATOR',
    subtitle: 'Complete 5 missions',
    icon: Icons.military_tech,
    color: const Color(0xFFC0C0C0),
    earned: (d) => ((d['completedSidequests'] as List?)?.length ?? 0) >= 5,
  ),
  _BadgeDef(
    name: 'DEEP COVER',
    subtitle: 'Complete 10 missions',
    icon: Icons.shield,
    color: const Color(0xFFFFD700),
    earned: (d) => ((d['completedSidequests'] as List?)?.length ?? 0) >= 10,
  ),
  _BadgeDef(
    name: 'PHANTOM',
    subtitle: 'Complete 18 missions',
    icon: Icons.nights_stay,
    color: const Color(0xFF00FF41),
    earned: (d) => ((d['completedSidequests'] as List?)?.length ?? 0) >= 18,
  ),
  _BadgeDef(
    name: 'RECRUIT',
    subtitle: 'Make 1 friend',
    icon: Icons.person_add,
    color: const Color(0xFFCD7F32),
    earned: (d) => ((d['friends'] as List?)?.length ?? 0) >= 1,
  ),
  _BadgeDef(
    name: 'CONNECTED',
    subtitle: 'Have 5 friends',
    icon: Icons.group,
    color: const Color(0xFFC0C0C0),
    earned: (d) => ((d['friends'] as List?)?.length ?? 0) >= 5,
  ),
  _BadgeDef(
    name: 'NETWORKED',
    subtitle: 'Have 10 friends',
    icon: Icons.hub,
    color: const Color(0xFFFFD700),
    earned: (d) => ((d['friends'] as List?)?.length ?? 0) >= 10,
  ),
  _BadgeDef(
    name: 'INITIATE',
    subtitle: 'Reach 100 XP',
    icon: Icons.star_border,
    color: const Color(0xFFCD7F32),
    earned: (d) => ((d['xpPoints'] as num?)?.toInt() ?? 0) >= 100,
  ),
  _BadgeDef(
    name: 'ASSET',
    subtitle: 'Reach 500 XP',
    icon: Icons.star_half,
    color: const Color(0xFFC0C0C0),
    earned: (d) => ((d['xpPoints'] as num?)?.toInt() ?? 0) >= 500,
  ),
  _BadgeDef(
    name: 'OPERATIVE',
    subtitle: 'Reach 1000 XP',
    icon: Icons.star,
    color: const Color(0xFFFFD700),
    earned: (d) => ((d['xpPoints'] as num?)?.toInt() ?? 0) >= 1000,
  ),
  _BadgeDef(
    name: 'LEGEND',
    subtitle: 'Reach 2500 XP',
    icon: Icons.auto_awesome,
    color: const Color(0xFF00FF41),
    earned: (d) => ((d['xpPoints'] as num?)?.toInt() ?? 0) >= 2500,
  ),
  _BadgeDef(
    name: 'CHALLENGER',
    subtitle: 'Win a challenge',
    icon: Icons.emoji_events,
    color: const Color(0xFFFFD700),
    earned: (d) => ((d['challengesWon'] as num?)?.toInt() ?? 0) >= 1,
  ),
];

// ==================== TEK REWARD LADDER ====================
//
// XP-driven reward tiers. Level formula matches existing code:
//   level = (xpPoints ~/ 100) + 1
// Reward unlocks when xpPoints >= xpRequired.

class _TekReward {
  final String id;
  final String name;
  final String description;
  final int xpRequired;
  final int level;
  final IconData icon;
  final Color color;

  const _TekReward({
    required this.id,
    required this.name,
    required this.description,
    required this.xpRequired,
    required this.level,
    required this.icon,
    required this.color,
  });
}

const List<_TekReward> _tekRewards = [
  _TekReward(
    id: 'welcome_drink',
    name: 'WELCOME DRINK',
    description: 'A drink on the house, on us.',
    xpRequired: 200,
    level: 2,
    icon: Icons.local_cafe,
    color: Color(0xFFCD7F32),
  ),
  _TekReward(
    id: 'free_drink',
    name: 'FREE DRINK',
    description: 'One drink token at any TEK event.',
    xpRequired: 500,
    level: 5,
    icon: Icons.local_bar,
    color: Color(0xFFC0C0C0),
  ),
  _TekReward(
    id: 'plus_one_guest',
    name: '+1 GUEST',
    description: 'Bring one friend without an invite slot.',
    xpRequired: 800,
    level: 8,
    icon: Icons.person_add_alt_1,
    color: Color(0xFF87CEEB),
  ),
  _TekReward(
    id: 'free_ticket',
    name: 'FREE TICKET',
    description: 'One free entry to any TEK event.',
    xpRequired: 1200,
    level: 12,
    icon: Icons.confirmation_num,
    color: Color(0xFFFFD700),
  ),
  _TekReward(
    id: 'vip_entry',
    name: 'VIP ENTRY',
    description: 'Priority queue at every event.',
    xpRequired: 1800,
    level: 18,
    icon: Icons.star,
    color: Color(0xFFFFD700),
  ),
  _TekReward(
    id: 'reserved_booth',
    name: 'RESERVED BOOTH',
    description: 'Your booth, reserved on arrival.',
    xpRequired: 2500,
    level: 25,
    icon: Icons.weekend,
    color: Color(0xFF00FF41),
  ),
  _TekReward(
    id: 'inner_circle',
    name: 'INNER CIRCLE',
    description: 'Founder access. Perks every event.',
    xpRequired: 4000,
    level: 40,
    icon: Icons.diamond,
    color: Color(0xFF9F59FF),
  ),
  _TekReward(
    id: 'black_card',
    name: 'BLACK CARD',
    description: 'Lifetime perks. Custom benefits.',
    xpRequired: 6000,
    level: 60,
    icon: Icons.workspace_premium,
    color: Color(0xFFE63946),
  ),
];

/// Highest-tier reward already unlocked at this XP, or null if below all tiers.
_TekReward? _currentTekReward(int xp) {
  _TekReward? current;
  for (final r in _tekRewards) {
    if (xp >= r.xpRequired) current = r;
  }
  return current;
}

/// Next reward the user is working toward, or null if all unlocked.
_TekReward? _nextTekReward(int xp) {
  for (final r in _tekRewards) {
    if (xp < r.xpRequired) return r;
  }
  return null;
}

// ==================== TEK IDENTITY TIERS (Founder / VIP / Member) ====================

/// Identity tags layered ON TOP of the reward ladder.
/// - FOUNDER: among the first 100 approved members (by createdAt). Permanent.
/// - VIP: top 10 by xpPoints right now. Rotating.
/// - INNER CIRCLE / BLACK CARD: derived from reward ladder when they hit those tiers.
enum TekIdentityTier { founder, vip, blackCard, innerCircle, member }

class TekTier {
  final TekIdentityTier kind;
  final String label;
  final IconData icon;
  final Color color;
  const TekTier(this.kind, this.label, this.icon, this.color);
}

const _tierFounder = TekTier(TekIdentityTier.founder, 'FOUNDER', Icons.shield, Color(0xFFC0C0C0));
const _tierVip = TekTier(TekIdentityTier.vip, 'VIP', Icons.star, Color(0xFFFFD700));
const _tierBlackCard = TekTier(TekIdentityTier.blackCard, 'BLACK CARD', Icons.workspace_premium, Color(0xFFE63946));
const _tierInnerCircle = TekTier(TekIdentityTier.innerCircle, 'INNER CIRCLE', Icons.diamond, Color(0xFF9F59FF));

/// Resolve the highest-priority tier badge for a user given their data + flags.
/// Priority: Black Card > Inner Circle > Founder > VIP > none
TekTier? resolveTier({
  required int xp,
  required bool isFounder,
  required bool isVip,
}) {
  if (xp >= 6000) return _tierBlackCard;
  if (xp >= 4000) return _tierInnerCircle;
  if (isFounder) return _tierFounder;
  if (isVip) return _tierVip;
  return null;
}

/// Live cache of the top-10 VIP referralCodes, refreshed periodically.
class TekVipCache {
  TekVipCache._();
  static final TekVipCache instance = TekVipCache._();

  Set<String> _vipCodes = {};
  DateTime? _lastFetch;

  Set<String> get codes => _vipCodes;

  Future<void> refreshIfStale() async {
    final now = DateTime.now();
    if (_lastFetch != null && now.difference(_lastFetch!) < const Duration(minutes: 10)) return;
    try {
      final snap = await FirebaseFirestore.instance
          .collection('applications')
          .orderBy('xpPoints', descending: true)
          .limit(10)
          .get();
      _vipCodes = snap.docs
          .map((d) => (d.data()['referralCode'] as String?) ?? '')
          .where((c) => c.isNotEmpty)
          .toSet();
      _lastFetch = now;
    } catch (_) {}
  }
}

bool isFounderFromData(Map<String, dynamic> appData) {
  // App-side flag: admins set `founder: true` on the first 100 approved members,
  // OR a founderCutoff date has been written to config/founders { cutoffAt: <Timestamp> }.
  if (appData['founder'] == true) return true;
  return false;
}

/// Visible tier badge: a small icon + label chip.
/// Use beside name in chat headers, friend lists, profile, RANKS, stories.
class TekTierBadge extends StatelessWidget {
  final TekTier tier;
  final double height;
  const TekTierBadge({super.key, required this.tier, this.height = 18});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: tier.color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: tier.color, width: 0.8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(tier.icon, size: height * 0.55, color: tier.color),
          const SizedBox(width: 4),
          Text(
            tier.label,
            style: TextStyle(
              color: tier.color,
              fontSize: height * 0.5,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
            ),
          ),
        ],
      ),
    );
  }
}

/// Avatar with a tier-colored ring + optional small tier glyph at the corner.
/// Drop-in replacement for plain CircleAvatars throughout the app.
class TieredAvatar extends StatelessWidget {
  final String? imageUrl;
  final String fallbackText;
  final double size;
  final TekTier? tier;
  const TieredAvatar({
    super.key,
    required this.imageUrl,
    required this.fallbackText,
    this.size = 48,
    this.tier,
  });

  @override
  Widget build(BuildContext context) {
    final ringColor = tier?.color ?? const Color(0xFF00FF41).withValues(alpha: 0.5);
    final ringWidth = tier == null ? 1.5 : 2.5;
    return SizedBox(
      width: size + 6,
      height: size + 6,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          Container(
            width: size + 6,
            height: size + 6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: ringColor, width: ringWidth),
              boxShadow: tier == null
                  ? null
                  : [BoxShadow(color: ringColor.withValues(alpha: 0.5), blurRadius: 12)],
            ),
          ),
          ClipOval(
            child: SizedBox(
              width: size,
              height: size,
              child: (imageUrl != null && imageUrl!.isNotEmpty)
                  ? FadeInNetImage(url: imageUrl!, avatarSize: size)
                  : Container(
                      color: const Color(0xFF00FF41).withValues(alpha: 0.15),
                      alignment: Alignment.center,
                      child: Text(
                        fallbackText.trim().isEmpty ? '?' : fallbackText.trim()[0].toUpperCase(),
                        style: TextStyle(
                          color: const Color(0xFF00FF41),
                          fontSize: size * 0.4,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
            ),
          ),
          if (tier != null)
            Positioned(
              right: -2,
              bottom: -2,
              child: Container(
                width: size * 0.35,
                height: size * 0.35,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.black,
                  border: Border.all(color: tier!.color, width: 1.2),
                ),
                child: Icon(tier!.icon, size: size * 0.18, color: tier!.color),
              ),
            ),
        ],
      ),
    );
  }
}

class _TrophyWallSection extends StatelessWidget {
  final Map<String, dynamic> profileData;

  const _TrophyWallSection({required this.profileData});

  @override
  Widget build(BuildContext context) {
    final questCount =
        (profileData['completedSidequests'] as List?)?.length ?? 0;
    final friendCount = (profileData['friends'] as List?)?.length ?? 0;
    final xp = (profileData['xpPoints'] as num?)?.toInt() ?? 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'STATS',
            style: TextStyle(
              color: Colors.white70,
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 1,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              _StatCell(label: 'MISSIONS', value: '$questCount'),
              _StatCell(label: 'FRIENDS', value: '$friendCount'),
              _StatCell(label: 'XP', value: '$xp', animateTo: xp),
            ],
          ),
        ),
        const SizedBox(height: 24),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'BADGES',
            style: TextStyle(
              color: Colors.white70,
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 1,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: GridView.count(
            crossAxisCount: 3,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
            childAspectRatio: 0.9,
            children: _tekBadges
                .map((b) => _BadgeTile(badge: b, earned: b.earned(profileData)))
                .toList(),
          ),
        ),
      ],
    );
  }
}

class _StatCell extends StatelessWidget {
  final String label;
  final String value;
  final int? animateTo;

  const _StatCell({required this.label, required this.value, this.animateTo});

  @override
  Widget build(BuildContext context) {
    const valueStyle = TextStyle(
      color: Color(0xFF00FF41),
      fontSize: 22,
      fontWeight: FontWeight.bold,
    );
    return Expanded(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 4),
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white10),
        ),
        child: Column(
          children: [
            animateTo != null
                ? AnimatedXP(value: animateTo!, style: valueStyle, suffix: '')
                : Text(value, style: valueStyle),
            const SizedBox(height: 4),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white54,
                fontSize: 9,
                letterSpacing: 0.5,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BadgeTile extends StatelessWidget {
  final _BadgeDef badge;
  final bool earned;

  _BadgeTile({required this.badge, required this.earned});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: earned
            ? badge.color.withOpacity(0.1)
            : Colors.white.withOpacity(0.03),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: earned ? badge.color.withOpacity(0.4) : Colors.white10,
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            badge.icon,
            color: earned ? badge.color : Colors.white24,
            size: 22,
          ),
          const SizedBox(height: 6),
          Text(
            badge.name,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: earned ? Colors.white : Colors.white30,
              fontSize: 8,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            badge.subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: earned ? Colors.white54 : Colors.white24,
              fontSize: 7,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}

// ==================== REWARDS PROGRESS PAGE ====================
class RewardsProgressPage extends StatelessWidget {
  final int currentLevel;
  final int currentXP;
  final int maxXP;

  const RewardsProgressPage({
    super.key,
    required this.currentLevel,
    required this.currentXP,
    required this.maxXP,
  });

  @override
  Widget build(BuildContext context) {
    final xp = currentXP;
    final next = _nextTekReward(xp);
    final unlocked = _tekRewards.where((r) => xp >= r.xpRequired).toList();
    final upcoming = _tekRewards.where((r) => xp < r.xpRequired).toList();

    final prevThreshold = unlocked.isEmpty ? 0 : unlocked.last.xpRequired;
    final nextThreshold = next?.xpRequired ?? math.max(maxXP, prevThreshold);
    final progress = next == null
        ? 1.0
        : ((xp - prevThreshold) / math.max(1, nextThreshold - prevThreshold))
            .clamp(0.0, 1.0)
            .toDouble();
    final xpToNext = next == null ? 0 : nextThreshold - xp;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Color(0xFFB8B8C0)),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'REWARDS',
          style: TextStyle(
            color: Color(0xFF00FF41),
            fontSize: 18,
            fontWeight: FontWeight.bold,
            letterSpacing: 2,
          ),
        ),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Current Level Card
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      const Color(0xFF00FF41).withValues(alpha: 0.2),
                      const Color(0xFF00FF41).withValues(alpha: 0.05),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                      color: const Color(0xFF00FF41).withValues(alpha: 0.3)),
                ),
                child: Column(
                  children: [
                    Text(
                      'LEVEL $currentLevel',
                      style: const TextStyle(
                        color: Color(0xFF00FF41),
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 2,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '$xp XP',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          '$nextThreshold XP',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Ps3XpProgressBar(
                      progress: progress,
                      height: 14,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      next == null
                          ? 'ALL REWARDS UNLOCKED'
                          : '$xpToNext XP TO ${next.name}',
                      style: TextStyle(
                        color: next == null
                            ? const Color(0xFFFFD700)
                            : Colors.white54,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 32),

              if (next != null) ...[
                const Text(
                  'NEXT REWARD',
                  style: TextStyle(
                    color: Color(0xFF00FF41),
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.5,
                  ),
                ),
                const SizedBox(height: 16),
                _buildRewardCard(reward: next, locked: true, isNext: true),
                const SizedBox(height: 32),
              ],

              if (unlocked.isNotEmpty) ...[
                const Text(
                  'UNLOCKED',
                  style: TextStyle(
                    color: Color(0xFF00FF41),
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.5,
                  ),
                ),
                const SizedBox(height: 16),
                ...unlocked.expand((r) => [
                      _buildRewardCard(reward: r, locked: false, isNext: false),
                      const SizedBox(height: 12),
                    ]),
                const SizedBox(height: 20),
              ],

              if (upcoming.length > (next == null ? 0 : 1)) ...[
                const Text(
                  'HIGHER TIERS',
                  style: TextStyle(
                    color: Colors.white38,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.5,
                  ),
                ),
                const SizedBox(height: 16),
                ...upcoming.skip(next == null ? 0 : 1).expand((r) => [
                      _buildRewardCard(reward: r, locked: true, isNext: false),
                      const SizedBox(height: 12),
                    ]),
                const SizedBox(height: 20),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRewardCard({
    required _TekReward reward,
    required bool locked,
    required bool isNext,
  }) {
    final accent = locked ? Colors.white24 : reward.color;
    final highlight = isNext ? const Color(0xFF00FF41) : accent;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: locked ? 0.03 : 0.06),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: highlight.withValues(alpha: locked && !isNext ? 0.25 : 0.7),
          width: isNext ? 2 : 1.2,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: locked
                  ? Colors.white.withValues(alpha: 0.05)
                  : reward.color.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: locked
                      ? Colors.white12
                      : reward.color.withValues(alpha: 0.5)),
            ),
            child: Icon(
              locked ? Icons.lock : reward.icon,
              color: locked ? Colors.white38 : reward.color,
              size: 28,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'LEVEL ${reward.level}  •  ${reward.xpRequired} XP',
                      style: TextStyle(
                        color: locked ? Colors.white38 : Colors.white70,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1,
                      ),
                    ),
                    if (!locked) ...[
                      const SizedBox(width: 8),
                      const Icon(Icons.check_circle,
                          color: Color(0xFF00FF41), size: 14),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  reward.name,
                  style: TextStyle(
                    color: locked ? Colors.white54 : Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  reward.description,
                  style: TextStyle(
                    color: locked ? Colors.white38 : Colors.white70,
                    fontSize: 13,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ==================== INVITE FRIENDS PAGE ====================
class InviteFriendsPage extends StatefulWidget {
  const InviteFriendsPage({super.key});

  @override
  State<InviteFriendsPage> createState() => _InviteFriendsPageState();
}

class _InviteFriendsPageState extends State<InviteFriendsPage> {
  bool _loading = true;
  String? _inviteCode;
  String? _inviteLink;
  List<Map<String, dynamic>> _invitedFriends = [];
  int _approvedCount = 0;
  int _ticketBuyerCount = 0;
  bool _drinkRewardEarned = false;
  bool _freeTicketEarned = false;
  List<Map<String, dynamic>> _rewards = [];
  String? _errorMessage;
  final TextEditingController _emailController = TextEditingController();
  bool _sendingEmail = false;

  @override
  void initState() {
    super.initState();
    _loadInviteStats();
  }

  Future<void> _loadInviteStats() async {
    setState(() {
      _loading = true;
      _errorMessage = null;
    });

    try {
      // Pass the user's saved referralCode so the server can find their
      // application doc even when ownerUid hasn't been back-filled yet
      // (race with _syncReferralClaim on app start).
      final prefs = await SharedPreferences.getInstance();
      final savedCode = prefs.getString('userReferralCode')?.trim() ?? '';
      final callable = FirebaseFunctions.instanceFor(
        region: 'us-central1',
      ).httpsCallable('getInviteStats');
      final result = await callable.call(<String, dynamic>{
        'referralCode': savedCode,
      });
      final data = result.data as Map<String, dynamic>? ?? {};

      setState(() {
        _inviteCode = data['inviteCode'] as String?;
        _inviteLink = data['inviteLink'] as String?;
        _invitedFriends = List<Map<String, dynamic>>.from(
          (data['invitedFriends'] as List? ?? []).map(
            (e) => Map<String, dynamic>.from(e as Map),
          ),
        );
        _approvedCount = (data['approvedCount'] as num?)?.toInt() ?? 0;
        _ticketBuyerCount = (data['ticketBuyerCount'] as num?)?.toInt() ?? 0;
        _drinkRewardEarned = data['drinkRewardEarned'] == true;
        _freeTicketEarned = data['freeTicketEarned'] == true;
        _rewards = List<Map<String, dynamic>>.from(
          (data['rewards'] as List? ?? []).map(
            (e) => Map<String, dynamic>.from(e as Map),
          ),
        );
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _errorMessage = 'Could not load invite data. Please try again.';
      });
      print('Error loading invite stats: $e');
    }
  }

  void _shareInviteLink() {
    if (_inviteLink == null || _inviteLink!.isEmpty) return;
    SharePlus.instance.share(
      ShareParams(
        text: 'Join me on TEK! Apply for membership here: $_inviteLink',
      ),
    );
  }

  void _copyInviteCode() {
    if (_inviteCode == null) return;
    Clipboard.setData(ClipboardData(text: _inviteLink ?? _inviteCode!));
    AppUtils.showSuccess(context, 'Invite link copied!');
  }

  Future<void> _sendEmailInvite() async {
    final email = _emailController.text.trim();
    if (email.isEmpty) {
      AppUtils.showError(context, 'Please enter an email address');
      return;
    }
    final emailRegex = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');
    if (!emailRegex.hasMatch(email)) {
      AppUtils.showError(context, 'Please enter a valid email address');
      return;
    }

    setState(() => _sendingEmail = true);

    try {
      final prefs = await SharedPreferences.getInstance();
      final savedCode = prefs.getString('userReferralCode')?.trim() ?? '';
      final callable = FirebaseFunctions.instanceFor(
        region: 'us-central1',
      ).httpsCallable('sendInviteEmail');
      await callable.call({
        'friendEmail': email,
        'referralCode': savedCode,
      });

      _emailController.clear();
      if (mounted) {
        AppUtils.showSuccess(context, 'Invitation sent to $email!');
      }
      // Refresh stats to show updated list
      await _loadInviteStats();
    } catch (e) {
      String message = 'Failed to send invitation';
      if (e is FirebaseFunctionsException) {
        if (e.code == 'already-exists') {
          message = 'You already sent an invitation to this email';
        } else if (e.code == 'resource-exhausted') {
          message = 'Daily limit reached (5 invites). Try again tomorrow';
        } else if (e.message != null) {
          message = e.message!;
        }
      }
      if (mounted) {
        AppUtils.showError(context, message);
      }
    } finally {
      if (mounted) setState(() => _sendingEmail = false);
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Color(0xFFB8B8C0)),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'INVITE FRIENDS',
          style: TextStyle(
            color: Color(0xFF00FF41),
            fontSize: 18,
            fontWeight: FontWeight.bold,
            letterSpacing: 2,
          ),
        ),
        centerTitle: true,
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(
                valueColor: AlwaysStoppedAnimation(Color(0xFF00FF41)),
              ),
            )
          : _errorMessage != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _errorMessage!,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 14,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: _loadInviteStats,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(
                          0xFF00FF41,
                        ).withOpacity(0.15),
                      ),
                      child: const Text(
                        'RETRY',
                        style: TextStyle(color: Color(0xFF00FF41)),
                      ),
                    ),
                  ],
                ),
              ),
            )
          : RefreshIndicator(
              onRefresh: _loadInviteStats,
              color: const Color(0xFF00FF41),
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Invite Code Card
                    _buildInviteCodeCard(),
                    const SizedBox(height: 24),

                    // Reward Progress
                    _buildRewardProgress(),
                    const SizedBox(height: 24),

                    // Invited Friends List
                    _buildInvitedFriendsList(),
                    const SizedBox(height: 24),

                    // Earned Rewards
                    if (_rewards.isNotEmpty) ...[
                      _buildEarnedRewards(),
                      const SizedBox(height: 24),
                    ],
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildInviteCodeCard() {
    final hasCode = _inviteCode != null;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            const Color(0xFF00FF41).withOpacity(hasCode ? 0.15 : 0.05),
            const Color(0xFF00FF41).withOpacity(hasCode ? 0.04 : 0.01),
          ],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF00FF41).withOpacity(hasCode ? 0.3 : 0.15)),
      ),
      child: Column(
        children: [
          const Text(
            'YOUR INVITE CODE',
            style: TextStyle(
              color: Colors.white54,
              fontSize: 11,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            hasCode ? _inviteCode! : 'Pending',
            style: TextStyle(
              color: const Color(0xFF00FF41),
              fontSize: hasCode ? 28 : 24,
              fontWeight: FontWeight.bold,
              letterSpacing: hasCode ? 3 : 2,
              fontStyle: hasCode ? FontStyle.normal : FontStyle.italic,
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Invite 5 friends to earn a free drink.\nIf all 5 buy tickets, you get a free ticket!',
            style: TextStyle(color: Colors.white54, fontSize: 12, height: 1.5),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          if (hasCode) Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _shareInviteLink,
                  icon: const Icon(Icons.share, size: 18, color: Colors.black),
                  label: const Text(
                    'SHARE',
                    style: TextStyle(
                      color: Colors.black,
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1,
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00FF41),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              ElevatedButton(
                onPressed: _copyInviteCode,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white.withOpacity(0.08),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: const BorderSide(color: Colors.white24),
                  ),
                  padding: const EdgeInsets.symmetric(
                    vertical: 14,
                    horizontal: 16,
                  ),
                ),
                child: const Icon(Icons.copy, size: 18, color: Colors.white70),
              ),
            ],
          ),
          const SizedBox(height: 20),
          // Email invite section
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.03),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'SEND EMAIL INVITE',
                  style: TextStyle(
                    color: Colors.white54,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.5,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _emailController,
                        keyboardType: TextInputType.emailAddress,
                        style: const TextStyle(color: Colors.white, fontSize: 14),
                        decoration: InputDecoration(
                          hintText: 'friend@email.com',
                          hintStyle: const TextStyle(color: Colors.white24),
                          filled: true,
                          fillColor: Colors.white.withOpacity(0.05),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(color: Colors.white10),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(color: Colors.white10),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(color: Color(0xFF00FF41)),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    ElevatedButton(
                      onPressed: _sendingEmail ? null : _sendEmailInvite,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00FF41),
                        disabledBackgroundColor: const Color(0xFF00FF41).withOpacity(0.3),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                      ),
                      child: _sendingEmail
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation(Colors.black),
                              ),
                            )
                          : const Icon(Icons.send, size: 18, color: Colors.black),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRewardProgress() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'INVITE PROGRESS',
          style: TextStyle(
            color: Color(0xFF00FF41),
            fontSize: 14,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.5,
          ),
        ),
        const SizedBox(height: 12),

        // Milestone 1: Free Drink (5 approved invites)
        _buildMilestoneCard(
          icon: Icons.local_bar,
          title: 'FREE DRINK',
          description: '5 invited friends approved',
          current: _approvedCount,
          target: 5,
          earned: _drinkRewardEarned,
        ),
        const SizedBox(height: 12),

        // Milestone 2: Free Ticket (5 invitees bought tickets)
        _buildMilestoneCard(
          icon: Icons.confirmation_num,
          title: 'FREE TICKET',
          description: '5 invited friends bought tickets',
          current: _ticketBuyerCount,
          target: 5,
          earned: _freeTicketEarned,
        ),
        const SizedBox(height: 12),

        // XP info
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.03),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white10),
          ),
          child: Row(
            children: [
              const Icon(Icons.star, color: Color(0xFF00FF41), size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '+50 XP per approved invite (${_approvedCount * 50} XP earned)',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMilestoneCard({
    required IconData icon,
    required String title,
    required String description,
    required int current,
    required int target,
    required bool earned,
  }) {
    final progress = (current / target).clamp(0.0, 1.0);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: earned
            ? const Color(0xFF00FF41).withOpacity(0.08)
            : Colors.white.withOpacity(0.03),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: earned
              ? const Color(0xFF00FF41).withOpacity(0.5)
              : Colors.white10,
          width: earned ? 1.5 : 1,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: earned
                  ? const Color(0xFF00FF41).withOpacity(0.2)
                  : Colors.white.withOpacity(0.05),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              icon,
              color: earned ? const Color(0xFF00FF41) : Colors.white38,
              size: 26,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: earned ? const Color(0xFF00FF41) : Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (earned) ...[
                      const SizedBox(width: 8),
                      const Icon(
                        Icons.check_circle,
                        color: Color(0xFF00FF41),
                        size: 18,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: progress,
                          backgroundColor: Colors.white10,
                          valueColor: AlwaysStoppedAnimation(
                            earned
                                ? const Color(0xFF00FF41)
                                : const Color(0xFF00FF41).withOpacity(0.6),
                          ),
                          minHeight: 6,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      '$current / $target',
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInvitedFriendsList() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'INVITED FRIENDS (${_invitedFriends.length})',
          style: const TextStyle(
            color: Color(0xFF00FF41),
            fontSize: 14,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.5,
          ),
        ),
        const SizedBox(height: 12),
        if (_invitedFriends.isEmpty)
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.03),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white10),
            ),
            child: const Center(
              child: Column(
                children: [
                  Icon(Icons.person_add, color: Colors.white24, size: 40),
                  SizedBox(height: 12),
                  Text(
                    'No friends invited yet.\nShare your invite link to get started!',
                    style: TextStyle(color: Colors.white38, fontSize: 13),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          )
        else
          ...(_invitedFriends.map((friend) => _buildFriendTile(friend))),
      ],
    );
  }

  Widget _buildFriendTile(Map<String, dynamic> friend) {
    final name = friend['name'] as String? ?? 'Unknown';
    final status = friend['status'] as String? ?? 'pending';
    final boughtTicket = friend['boughtTicket'] == true;
    final profileImageUrl = friend['profileImageUrl'] as String?;

    Color statusColor;
    String statusLabel;
    IconData statusIcon;

    if (boughtTicket) {
      statusColor = const Color(0xFF00FF41);
      statusLabel = 'TICKET BOUGHT';
      statusIcon = Icons.confirmation_num;
    } else if (status == 'approved') {
      statusColor = const Color(0xFF4FC3F7);
      statusLabel = 'APPROVED';
      statusIcon = Icons.check_circle;
    } else if (status == 'rejected') {
      statusColor = const Color(0xFFFF4141);
      statusLabel = 'REJECTED';
      statusIcon = Icons.cancel;
    } else {
      statusColor = const Color(0xFFFFB74D);
      statusLabel = 'PENDING';
      statusIcon = Icons.hourglass_empty;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.03),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white24),
            ),
            child: ClipOval(
              child: profileImageUrl != null && profileImageUrl.isNotEmpty
                  ? Image.network(
                      profileImageUrl,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        color: Colors.grey[800],
                        child: const Icon(
                          Icons.person,
                          color: Colors.white30,
                          size: 20,
                        ),
                      ),
                    )
                  : Container(
                      color: Colors.grey[800],
                      child: const Icon(
                        Icons.person,
                        color: Colors.white30,
                        size: 20,
                      ),
                    ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              name.toUpperCase(),
              style: const TextStyle(
                color: Color(0xFFB8B8C0),
                fontSize: 14,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
          ),
          Icon(statusIcon, color: statusColor, size: 16),
          const SizedBox(width: 6),
          Text(
            statusLabel,
            style: TextStyle(
              color: statusColor,
              fontSize: 11,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEarnedRewards() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'YOUR REWARDS',
          style: TextStyle(
            color: Color(0xFF00FF41),
            fontSize: 14,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.5,
          ),
        ),
        const SizedBox(height: 12),
        ..._rewards.map((reward) {
          final type = reward['type'] as String? ?? '';
          final redeemed = reward['redeemed'] == true;
          final icon = type == 'free_drink'
              ? Icons.local_bar
              : Icons.confirmation_num;
          final label = type == 'free_drink' ? 'FREE DRINK' : 'FREE TICKET';

          return Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: redeemed
                    ? [
                        Colors.white.withOpacity(0.03),
                        Colors.white.withOpacity(0.01),
                      ]
                    : [
                        const Color(0xFF00FF41).withOpacity(0.15),
                        const Color(0xFF00FF41).withOpacity(0.04),
                      ],
              ),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: redeemed
                    ? Colors.white24
                    : const Color(0xFF00FF41).withOpacity(0.5),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  icon,
                  color: redeemed ? Colors.white38 : const Color(0xFF00FF41),
                  size: 28,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          color: redeemed
                              ? Colors.white54
                              : const Color(0xFF00FF41),
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        redeemed ? 'Redeemed' : 'Show this at the bar',
                        style: TextStyle(
                          color: redeemed ? Colors.white38 : Colors.white54,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                if (!redeemed)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF00FF41).withOpacity(0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text(
                      'ACTIVE',
                      style: TextStyle(
                        color: Color(0xFF00FF41),
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                if (redeemed)
                  const Icon(Icons.check, color: Colors.white38, size: 20),
              ],
            ),
          );
        }),
      ],
    );
  }
}

// ==================== MAIN APP WITH BOTTOM NAV ====================
class MainApp extends StatefulWidget {
  final int initialIndex;
  final bool isAdmin;
  const MainApp({super.key, this.initialIndex = 0, this.isAdmin = false});

  @override
  State<MainApp> createState() => _MainAppState();
}

class _MainAppState extends State<MainApp> {
  late int _selectedIndex;
  bool _adminMode = false;
  bool _adminAllowlisted = false;

  bool get _showControl => _adminMode && _adminAllowlisted;

  @override
  void initState() {
    super.initState();
    _adminMode = widget.isAdmin;
    _adminAllowlisted = widget.isAdmin;
    final maxIndex = _showControl ? 5 : 4;
    _selectedIndex = widget.initialIndex.clamp(0, maxIndex);

    // Keep CONTROL visibility in sync with explicit admin mode + backend allowlist.
    unawaited(_refreshAdminState());

    // Start live mirror of config/quests so the SIDEQUESTS feature gate updates in real time.
    QuestsConfigService.instance.start();

    // Enforce single-device session for normal users (referral code based).
    SharedPreferences.getInstance().then((prefs) {
      final code = prefs.getString('userReferralCode');
      if (code != null && code.trim().isNotEmpty) {
        ReferralSessionManager.instance.ensureActiveForReferralCode(code);
      }
    });

    unawaited(_setupPushNotifications());
    unawaited(_checkDailyStreak());
    unawaited(TekVipCache.instance.refreshIfStale());
    unawaited(_syncReferralClaim());
  }

  /// Syncs the `referralCode` custom claim on the user's auth token so
  /// Firestore rules that gate on `request.auth.token.referralCode`
  /// (check-ins, RSVPs, stories) can authorize the user.
  ///
  /// Passes the user's saved referralCode from SharedPreferences as a
  /// hint, so the server can find the application doc even when
  /// `ownerUid` hasn't been back-filled yet (most users today).
  ///
  /// Safe to call repeatedly. After the server confirms the canonical
  /// referralCode for this user, force-refreshes the local ID token
  /// only when the cached claim is stale or missing — avoids a
  /// network round-trip on every app launch.
  Future<void> _syncReferralClaim() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;
      // Allow anonymous users — most TEK members are signed in
      // anonymously by Firebase Auth, then bound to their referral
      // code via the saved pref.

      final prefs = await SharedPreferences.getInstance();
      final savedCode = prefs.getString('userReferralCode')?.trim() ?? '';
      // No code yet = user hasn't completed referral entry. Skip silently.
      if (savedCode.isEmpty) return;

      // 1. Ensure server has the claim set on the user record.
      final callable = FirebaseFunctions.instanceFor(region: 'us-central1')
          .httpsCallable('syncReferralClaim');
      final result = await callable.call(<String, dynamic>{
        'referralCode': savedCode,
      });
      final data = (result.data is Map)
          ? Map<String, dynamic>.from(result.data as Map)
          : <String, dynamic>{};
      final serverCode = data['referralCode'] as String?;

      if (serverCode == null || serverCode.isEmpty) return;

      // 2. Force-refresh the local ID token if our cached claim is
      //    missing or doesn't match the server's. Skip the refresh
      //    when the local token already matches.
      final localResult = await user.getIdTokenResult();
      final localCode = localResult.claims?['referralCode'] as String?;
      if (localCode != serverCode) {
        await user.getIdToken(true);
        debugPrint('referralCode claim refreshed: $serverCode');
      }
    } catch (e) {
      // Non-fatal — rules just won't authorize until next try.
      debugPrint('syncReferralClaim failed: $e');
    }
  }

  Future<void> _checkDailyStreak() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final code = prefs.getString('userReferralCode');
      if (code == null || code.isEmpty) return;
      final snap = await FirebaseFirestore.instance
          .collection('applications')
          .where('referralCode', isEqualTo: code)
          .limit(1)
          .get();
      if (snap.docs.isEmpty) return;
      final doc = snap.docs.first;
      final data = doc.data();
      final lastLoginTs = data['lastLoginDate'] as Timestamp?;
      final streakCount = (data['streakCount'] as num?)?.toInt() ?? 0;
      final currentXP = (data['xpPoints'] as num?)?.toInt() ?? 0;
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      DateTime? last = lastLoginTs?.toDate();
      DateTime? lastDay = last == null ? null : DateTime(last.year, last.month, last.day);

      // Already logged in today — no change.
      if (lastDay != null && lastDay.isAtSameMomentAs(today)) return;

      int newStreak;
      bool extended;
      if (lastDay == null) {
        newStreak = 1;
        extended = true;
      } else if (today.difference(lastDay).inDays == 1) {
        newStreak = streakCount + 1;
        extended = true;
      } else {
        newStreak = 1;
        extended = true; // first day of new streak still earns
      }

      int xpReward = 5;
      bool weeklyBonus = false;
      if (newStreak > 0 && newStreak % 7 == 0) {
        xpReward += 25;
        weeklyBonus = true;
      }

      await doc.reference.update({
        'lastLoginDate': Timestamp.fromDate(today),
        'streakCount': newStreak,
        'xpPoints': currentXP + xpReward,
      });
      await FirebaseFirestore.instance.collection('xp_transactions').add({
        'source': 'daily_streak',
        'streakCount': newStreak,
        'userId': FirebaseAuth.instance.currentUser?.uid ?? '',
        'userName': data['name'] ?? '',
        'userEmail': data['email'] ?? '',
        'amount': xpReward,
        'previousXP': currentXP,
        'newXP': currentXP + xpReward,
        'timestamp': FieldValue.serverTimestamp(),
      });
      if (!mounted || !extended) return;
      Future.delayed(const Duration(milliseconds: 700), () {
        if (!mounted) return;
        showXPToast(context,
            title: '+$xpReward XP — DAY $newStreak STREAK',
            subtitle: weeklyBonus ? '7-DAY BONUS UNLOCKED 🔥' : null,
            icon: Icons.local_fire_department);
      });
    } catch (e) {
      debugPrint('Daily streak check failed: $e');
    }
  }

  Future<void> _setupPushNotifications() async {
    try {
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

    final settings = await FirebaseMessaging.instance.requestPermission(
      alert: true, badge: true, sound: true,
    );
    debugPrint('PUSH PERMISSION STATUS: ${settings.authorizationStatus}');
    if (settings.authorizationStatus != AuthorizationStatus.authorized &&
        settings.authorizationStatus != AuthorizationStatus.provisional) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('lastPushSetupError',
            'Permission not granted: ${settings.authorizationStatus}');
      } catch (_) {}
      return;
    }

    await FirebaseMessaging.instance.setForegroundNotificationPresentationOptions(
      alert: true, badge: true, sound: true,
    );

    final token = await FirebaseMessaging.instance.getToken();
    debugPrint('FCM TOKEN: ${token == null ? "NULL" : "${token.substring(0, 16)}..."}');
    if (token != null) {
      await _saveFcmToken(token);
    } else {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('lastPushSetupError', 'getToken returned null');
      } catch (_) {}
    }
    FirebaseMessaging.instance.onTokenRefresh.listen(_saveFcmToken);
    } catch (e, st) {
      debugPrint('PUSH SETUP FAILED: $e\n$st');
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('lastPushSetupError', '$e');
      } catch (_) {}
    }

    FirebaseMessaging.onMessage.listen((message) {
      if (!mounted) return;
      final n = message.notification;
      if (n == null) return;
      HapticFeedback.lightImpact();
      TekSounds.instance.transmission();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(n.title ?? '', style: const TextStyle(
                fontWeight: FontWeight.bold, color: Colors.black, fontSize: 14)),
            if ((n.body ?? '').isNotEmpty)
              Text(n.body!, style: const TextStyle(color: Colors.black87, fontSize: 13)),
          ],
        ),
        backgroundColor: const Color(0xFF00FF41),
        duration: const Duration(seconds: 4),
        behavior: SnackBarBehavior.floating,
      ));
    });
  }

  Future<void> _saveFcmToken(String token) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final code = prefs.getString('userReferralCode');
      if (code == null || code.isEmpty) {
        await prefs.setString('lastPushSetupError', 'No referralCode in prefs when saving FCM token');
        return;
      }
      final snap = await FirebaseFirestore.instance
          .collection('applications')
          .where('referralCode', isEqualTo: code)
          .limit(1)
          .get();
      if (snap.docs.isEmpty) {
        await prefs.setString('lastPushSetupError', 'No application doc found for $code');
        return;
      }
      await snap.docs.first.reference.update({'fcmToken': token});
      await prefs.setString('lastFcmToken', token);
      await prefs.remove('lastPushSetupError');
      debugPrint('FCM TOKEN SAVED to applications/${snap.docs.first.id}');
    } catch (e, st) {
      debugPrint('SAVE FCM TOKEN FAILED: $e\n$st');
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('lastPushSetupError', 'Save FCM failed: $e');
      } catch (_) {}
    }
  }

  Future<void> _refreshAdminState() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final prefs = await SharedPreferences.getInstance();
    final persistedAdminMode = prefs.getBool(tekAdminModePrefsKey) ?? false;

    // CONTROL should only be possible for a non-anonymous account AND when admin mode was explicitly entered.
    final effectiveAdminMode =
        (widget.isAdmin || persistedAdminMode) && !user.isAnonymous;

    if (!effectiveAdminMode) {
      if (persistedAdminMode) {
        await prefs.remove(tekAdminModePrefsKey);
      }
      if (!mounted) return;
      if (_adminMode || _adminAllowlisted) {
        setState(() {
          _adminMode = false;
          _adminAllowlisted = false;
          _selectedIndex = _selectedIndex.clamp(0, 4);
        });
      }
      return;
    }

    bool allowlisted = _adminAllowlisted;
    bool didCheck = false;
    try {
      allowlisted = await AdminStatusManager.instance.isCurrentUserAdmin();
      didCheck = true;
    } catch (_) {
      // Ignore transient callable failures.
    }

    // If we definitively checked and the account isn't allowlisted, revoke admin mode.
    if (didCheck && !allowlisted) {
      await prefs.remove(tekAdminModePrefsKey);
      await prefs.remove('isAdmin');
      _applicationData['isAdmin'] = false;

      try {
        await FirebaseAuth.instance.signOut();
        await FirebaseAuth.instance.signInAnonymously();
      } catch (_) {
        // Best-effort.
      }

      if (!mounted) return;
      appNavigatorKey.currentState?.pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const ReferralCodeScreen()),
        (route) => false,
      );
      return;
    }

    if (!mounted) return;
    final nextAdminMode = true;
    final nextAllowlisted = allowlisted;
    final changed =
        nextAdminMode != _adminMode || nextAllowlisted != _adminAllowlisted;
    if (!changed) return;

    setState(() {
      _adminMode = nextAdminMode;
      _adminAllowlisted = nextAllowlisted;
      final maxIndex = _showControl ? 5 : 4;
      _selectedIndex = _selectedIndex.clamp(0, maxIndex);
    });
  }

  List<Widget> get _screens {
    if (_showControl) {
      return [
        SocialScreen(),
        MyTicketsPage(),
        SidequestScreen(),
        EventsScreen(isAdmin: true),
        UserProfilePage(applicationData: _applicationData),
        AdminProfilePage(applicationData: _applicationData),
      ];
    }
    return [
      SocialScreen(),
      MyTicketsPage(),
      SidequestScreen(),
      EventsScreen(isAdmin: false),
      UserProfilePage(applicationData: _applicationData),
    ];
  }

  Widget _navIcon(IconData icon, bool selected) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: selected
            ? const [
                BoxShadow(
                  color: Color(0x2600FF41),
                  blurRadius: 14,
                  spreadRadius: 1,
                ),
              ]
            : null,
      ),
      child: Icon(
        icon,
        color: selected ? const Color(0xFF00FF41) : const Color(0xFF8F959E),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 350),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) {
          return FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.03),
                end: Offset.zero,
              ).animate(animation),
              child: child,
            ),
          );
        },
        child: KeyedSubtree(
          key: ValueKey<int>(_selectedIndex),
          child: _screens[_selectedIndex],
        ),
      ),
      bottomNavigationBar: ClipRRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.5),
              border: const Border(
                top: BorderSide(color: Colors.white10, width: 0.5),
              ),
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final tabCount = _showControl ? 6 : 5;
                final tabWidth = constraints.maxWidth / tabCount;
                final pillWidth = 28.0;
                return Stack(
                  children: [
                    AnimatedPositioned(
                      duration: const Duration(milliseconds: 280),
                      curve: Curves.easeOutCubic,
                      left: tabWidth * _selectedIndex + (tabWidth - pillWidth) / 2,
                      top: 0,
                      child: Container(
                        width: pillWidth,
                        height: 3,
                        decoration: BoxDecoration(
                          color: _showControl ? const Color(0xFFFF0000) : const Color(0xFF00FF41),
                          borderRadius: BorderRadius.circular(2),
                          boxShadow: [
                            BoxShadow(
                              color: (_showControl ? const Color(0xFFFF0000) : const Color(0xFF00FF41)).withValues(alpha: 0.6),
                              blurRadius: 8,
                              spreadRadius: 0,
                            ),
                          ],
                        ),
                      ),
                    ),
                    Theme(
                      data: Theme.of(context).copyWith(
                        splashColor: Colors.transparent,
                        highlightColor: Colors.transparent,
                        splashFactory: NoSplash.splashFactory,
                      ),
                      child: BottomNavigationBar(
              backgroundColor: Colors.transparent,
              elevation: 0,
              type: BottomNavigationBarType.fixed,
              currentIndex: _selectedIndex,
              onTap: (index) {
                if (index == _selectedIndex) {
                  HapticFeedback.selectionClick();
                  TekSounds.instance.tap();
                  tabReTapTick.value++;
                } else {
                  HapticFeedback.selectionClick();
                  TekSounds.instance.tap();
                  setState(() {
                    _selectedIndex = index;
                  });
                }
              },
              items: [
                BottomNavigationBarItem(
                  icon: _navIcon(Icons.group, _selectedIndex == 0),
                  label: 'SOCIAL',
                ),
                BottomNavigationBarItem(
                  icon: _navIcon(Icons.confirmation_num, _selectedIndex == 1),
                  label: 'TICKETS',
                ),
                BottomNavigationBarItem(
                  icon: _navIcon(Icons.bolt, _selectedIndex == 2),
                  label: 'QUESTS',
                ),
                BottomNavigationBarItem(
                  icon: _navIcon(Icons.calendar_today, _selectedIndex == 3),
                  label: 'EVENTS',
                ),
                BottomNavigationBarItem(
                  icon: _navIcon(Icons.person, _selectedIndex == 4),
                  label: 'PROFILE',
                ),
                if (_showControl)
                  BottomNavigationBarItem(
                    icon: _navIcon(
                      Icons.admin_panel_settings,
                      _selectedIndex == 5,
                    ),
                    label: 'CONTROL',
                  ),
              ],
              selectedItemColor: _showControl
                  ? Color(0xFFFF0000)
                  : Color(0xFF00FF41),
              unselectedItemColor: const Color(0xFF8F959E),
              selectedLabelStyle: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
              unselectedLabelStyle: const TextStyle(
                fontSize: 11,
                letterSpacing: 0.5,
              ),
            ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

// ==================== SOCIAL SCREEN ====================
class SocialScreen extends StatefulWidget {
  const SocialScreen({super.key});

  @override
  State<SocialScreen> createState() => _SocialScreenState();
}

class _SocialScreenState extends State<SocialScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  String? _currentUserCode;

  List<Map<String, dynamic>> _searchResults = [];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _initializeModerationState();
    _searchController.addListener(() {
      setState(() {
        _searchQuery = _searchController.text;
      });
      _performUserSearch(_searchQuery);
    });
  }

  Future<void> _initializeModerationState() async {
    final prefs = await SharedPreferences.getInstance();
    final userCode = prefs.getString('userReferralCode');
    if (!mounted) return;
    setState(() {
      _currentUserCode = userCode;
    });
  }

  Future<void> _performUserSearch(String query) async {
    if (query.isEmpty) {
      setState(() {
        _searchResults = [];
      });
      return;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final currentUserCode =
          _currentUserCode ?? prefs.getString('userReferralCode');
      final blockedUsers = await _getBlockedUsersForReferralCode(
        currentUserCode,
      );
      final snapshot = await FirebaseFirestore.instance
          .collection('applications')
          .get();

      final results = <Map<String, dynamic>>[];
      final queryLower = query.toLowerCase();

      for (var doc in snapshot.docs) {
        final data = doc.data();
        final name = (data['name'] as String? ?? '').toLowerCase();
        final referralCode = (data['referralCode'] as String? ?? '')
            .toLowerCase();
        final email = (data['email'] as String? ?? '').toLowerCase();
        final rawReferralCode = (data['referralCode'] as String? ?? '').trim();
        final targetBlockedUsers =
            (data['blockedUsers'] as List?)?.cast<String>() ?? const <String>[];

        if (rawReferralCode.isEmpty ||
            rawReferralCode == currentUserCode ||
            blockedUsers.contains(rawReferralCode) ||
            (currentUserCode != null &&
                targetBlockedUsers.contains(currentUserCode))) {
          continue;
        }

        if (name.contains(queryLower) ||
            referralCode.contains(queryLower) ||
            email.contains(queryLower)) {
          results.add({
            'name': data['name'] ?? 'Unknown',
            'referralCode': data['referralCode'],
            'level': data['xpPoints'] != null
                ? ((data['xpPoints'] as int) ~/ 100) + 1
                : 1,
            'email': data['email'] ?? '',
            'phone': data['phone'] ?? '',
            'instagram': data['instagram'] ?? '',
            'bio': data['bio'] ?? '',
            'profileImageUrl': data['profileImageUrl'],
          });
        }
      }

      setState(() {
        _currentUserCode = currentUserCode;
        _searchResults = results;
      });
    } catch (e) {
      print('Error searching users: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    // If there's a search query, show search results instead of tabs
    if (_searchQuery.isNotEmpty) {
      return Scaffold(
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          centerTitle: true,
          title: const TekWordmark(fontSize: 24, letterSpacing: 5.5),
        ),
        body: Column(
          children: [
            // Search Bar
            Padding(
              padding: EdgeInsets.all(12),
              child: TextField(
                controller: _searchController,
                style: TextStyle(color: Color(0xFFB8B8C0)),
                decoration: InputDecoration(
                  hintText: 'Search username or name...',
                  hintStyle: TextStyle(color: Colors.white30),
                  prefixIcon: Icon(Icons.search, color: Colors.white70),
                  suffixIcon: _searchQuery.isNotEmpty
                      ? IconButton(
                          icon: Icon(Icons.clear, color: Colors.white70),
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _searchQuery = '');
                          },
                        )
                      : null,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.white10),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.white10),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Color(0xFF00FF41), width: 2),
                  ),
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                ),
              ),
            ),
            Expanded(child: _buildSearchResults()),
          ],
        ),
      );
    }

    // Default tab view when not searching
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          centerTitle: true,
          title: const TekWordmark(fontSize: 24, letterSpacing: 5.5),
        ),
        body: Column(
          children: [
            // Search Bar
            Padding(
              padding: EdgeInsets.all(12),
              child: TextField(
                controller: _searchController,
                style: TextStyle(color: Color(0xFFB8B8C0)),
                decoration: InputDecoration(
                  hintText: 'Search username or name...',
                  hintStyle: TextStyle(color: Colors.white30),
                  prefixIcon: Icon(Icons.search, color: Colors.white70),
                  suffixIcon: _searchQuery.isNotEmpty
                      ? IconButton(
                          icon: Icon(Icons.clear, color: Colors.white70),
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _searchQuery = '');
                          },
                        )
                      : null,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.white10),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.white10),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Color(0xFF00FF41), width: 2),
                  ),
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                ),
              ),
            ),
            const _NightReportCard(),
            const _MissionControlHero(),
            const _StoriesRow(),
            Container(
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: Colors.white10, width: 1),
                ),
              ),
              child: TabBar(
                controller: _tabController,
                tabs: [
                  Tab(text: 'FRIENDLIST'),
                  Tab(text: 'REQUESTS'),
                  Tab(text: 'CREWS'),
                ],
                labelColor: Color(0xFF00FF41),
                unselectedLabelColor: Colors.white70,
                labelStyle: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1,
                ),
                indicatorColor: Color(0xFF00FF41),
              ),
            ),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildFriendList(),
                  _buildRequests(),
                  _buildCrews(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchResults() {
    if (_searchResults.isEmpty) {
      return Center(
        child: Text(
          'No users found',
          style: TextStyle(
            color: Colors.white70,
            fontSize: 16,
            fontWeight: FontWeight.w500,
          ),
        ),
      );
    }

    return ListView.builder(
      itemCount: _searchResults.length,
      itemBuilder: (context, index) {
        final user = _searchResults[index];
        return GestureDetector(
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => UserProfileView(userData: user),
              ),
            );
          },
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: Colors.white10, width: 0.5),
              ),
            ),
            child: Row(
              children: [
                // Profile Picture
                Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Color(0xFFB8B8C0), width: 2),
                  ),
                  child: ClipOval(
                    child:
                        user['profileImageUrl'] != null &&
                            user['profileImageUrl'].toString().isNotEmpty
                        ? Image.network(
                            user['profileImageUrl'],
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) {
                              return Container(
                                color: Colors.grey[800],
                                child: Icon(
                                  Icons.person,
                                  color: Colors.white30,
                                ),
                              );
                            },
                          )
                        : Container(
                            color: Colors.grey[800],
                            child: Icon(Icons.person, color: Colors.white30),
                          ),
                  ),
                ),
                SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        user['name'] as String,
                        style: TextStyle(
                          color: Color(0xFFB8B8C0),
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        // Referral code is private; do not display in public lists
                        '',
                        style: TextStyle(color: Colors.white70, fontSize: 11),
                      ),
                      Text(
                        'LEVEL ${user['level']}',
                        style: TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.arrow_forward, color: Colors.white70),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildFriendList() {
    return FutureBuilder<String?>(
      future: SharedPreferences.getInstance().then(
        (prefs) => prefs.getString('userReferralCode'),
      ),
      builder: (context, userSnapshot) {
        if (!userSnapshot.hasData) {
          return const Center(
            child: CircularProgressIndicator(color: Color(0xFF00FF41)),
          );
        }

        final currentUserCode = userSnapshot.data;
        if (currentUserCode == null) {
          return Center(
            child: Text(
              'Please log in to view friends',
              style: TextStyle(color: Colors.white70),
            ),
          );
        }

        return StreamBuilder<DocumentSnapshot>(
          stream: FirebaseFirestore.instance
              .collection('applications')
              .where('referralCode', isEqualTo: currentUserCode)
              .snapshots()
              .map(
                (snapshot) =>
                    snapshot.docs.isNotEmpty ? snapshot.docs.first : null,
              )
              .handleError((_) => null)
              .where((doc) => doc != null)
              .cast<DocumentSnapshot>(),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(
                child: CircularProgressIndicator(color: Color(0xFF00FF41)),
              );
            }

            if (!snapshot.hasData) {
              return Center(
                child: Text(
                  'YOU HAVE NO FRIENDS YET',
                  style: TextStyle(color: Colors.white70, fontSize: 16),
                ),
              );
            }

            final userData = snapshot.data!.data() as Map<String, dynamic>;
            final friendCodes =
                (userData['friends'] as List?)?.cast<String>() ?? [];
            final blockedUsers =
                (userData['blockedUsers'] as List?)?.cast<String>() ?? [];
            // Apple 1.2: remove blocked users from feed instantly
            final visibleFriends = friendCodes
                .where((code) => !blockedUsers.contains(code))
                .toList();

            if (visibleFriends.isEmpty) {
              return Center(
                child: Text(
                  'YOU HAVE NO FRIENDS YET',
                  style: TextStyle(color: Colors.white70, fontSize: 16),
                ),
              );
            }

            return ListView.builder(
              itemCount: visibleFriends.length,
              itemBuilder: (context, index) {
                final friendCode = visibleFriends[index];
                return FutureBuilder<DocumentSnapshot?>(
                  future: FirebaseFirestore.instance
                      .collection('applications')
                      .where('referralCode', isEqualTo: friendCode)
                      .limit(1)
                      .get()
                      .then(
                        (snap) => snap.docs.isNotEmpty
                            ? snap.docs.first as DocumentSnapshot
                            : null,
                      )
                      .catchError((_) => null),
                  builder: (context, friendSnapshot) {
                    if (friendSnapshot.connectionState ==
                        ConnectionState.waiting) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        child: Container(
                          height: 80,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.05),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Center(
                            child: CircularProgressIndicator(
                              color: Color(0xFF00FF41),
                              strokeWidth: 2,
                            ),
                          ),
                        ),
                      );
                    }

                    if (!friendSnapshot.hasData) {
                      return const SizedBox.shrink();
                    }

                    final friendData =
                        friendSnapshot.data!.data() as Map<String, dynamic>;
                    return GestureDetector(
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) =>
                                UserProfileView(userData: friendData),
                          ),
                        );
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(
                              color: Colors.white10,
                              width: 0.5,
                            ),
                          ),
                        ),
                        child: Row(
                          children: [
                            // Profile Picture
                            Container(
                              width: 60,
                              height: 60,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Color(0xFFB8B8C0),
                                  width: 2,
                                ),
                              ),
                              child: ClipOval(
                                child:
                                    friendData['profileImageUrl'] != null &&
                                        friendData['profileImageUrl']
                                            .toString()
                                            .isNotEmpty
                                    ? Image.network(
                                        friendData['profileImageUrl'],
                                        fit: BoxFit.cover,
                                        errorBuilder:
                                            (context, error, stackTrace) {
                                              return Container(
                                                color: Colors.grey[800],
                                                child: const Icon(
                                                  Icons.person,
                                                  color: Colors.white30,
                                                ),
                                              );
                                            },
                                      )
                                    : Container(
                                        color: Colors.grey[800],
                                        child: const Icon(
                                          Icons.person,
                                          color: Colors.white30,
                                        ),
                                      ),
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Builder(builder: (context) {
                                final friendXp = ((friendData['xpPoints'] ?? 0) as num).toInt();
                                final friendCodeStr = (friendData['referralCode'] as String?) ?? '';
                                final friendTier = resolveTier(
                                  xp: friendXp,
                                  isFounder: isFounderFromData(friendData),
                                  isVip: TekVipCache.instance.codes.contains(friendCodeStr),
                                );
                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Flexible(
                                          child: Text(
                                            friendData['name'] ?? 'Unknown',
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              color: Color(0xFFB8B8C0),
                                              fontSize: 16,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                        if (friendTier != null) ...[
                                          const SizedBox(width: 6),
                                          TekTierBadge(tier: friendTier),
                                        ],
                                      ],
                                    ),
                                    Text(
                                      'LEVEL ${friendXp ~/ 100 + 1}',
                                      style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                );
                              }),
                            ),
                            IconButton(
                              icon: const Icon(
                                Icons.message,
                                color: Color(0xFF00FF41),
                              ),
                              onPressed: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => ChatScreen(
                                      friendCode: friendCode,
                                      friendName:
                                          friendData['name'] ?? 'Friend',
                                      friendImageUrl:
                                          friendData['profileImageUrl'],
                                    ),
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildRequests() {
    return FutureBuilder<String?>(
      future: SharedPreferences.getInstance().then(
        (prefs) => prefs.getString('userReferralCode'),
      ),
      builder: (context, userSnapshot) {
        if (!userSnapshot.hasData) {
          return const Center(
            child: CircularProgressIndicator(color: Color(0xFF00FF41)),
          );
        }

        final currentUserCode = userSnapshot.data;
        if (currentUserCode == null) {
          return Center(
            child: Text(
              'Please log in to view requests',
              style: TextStyle(color: Colors.white70),
            ),
          );
        }

        return StreamBuilder<DocumentSnapshot>(
          stream: FirebaseFirestore.instance
              .collection('applications')
              .where('referralCode', isEqualTo: currentUserCode)
              .snapshots()
              .map(
                (snapshot) =>
                    snapshot.docs.isNotEmpty ? snapshot.docs.first : null,
              )
              .handleError((_) => null)
              .where((doc) => doc != null)
              .cast<DocumentSnapshot>(),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(
                child: CircularProgressIndicator(color: Color(0xFF00FF41)),
              );
            }

            if (!snapshot.hasData) {
              return Center(
                child: Text(
                  'No friend requests',
                  style: TextStyle(color: Colors.white70),
                ),
              );
            }

            final userData = snapshot.data!.data() as Map<String, dynamic>;
            final friendRequests =
                (userData['friendRequests'] as List?)?.cast<String>() ?? [];

            if (friendRequests.isEmpty) {
              return Center(
                child: Text(
                  'No friend requests',
                  style: TextStyle(color: Colors.white70),
                ),
              );
            }

            return ListView.builder(
              itemCount: friendRequests.length,
              itemBuilder: (context, index) {
                final requesterCode = friendRequests[index];
                return FutureBuilder<DocumentSnapshot?>(
                  future: FirebaseFirestore.instance
                      .collection('applications')
                      .where('referralCode', isEqualTo: requesterCode)
                      .limit(1)
                      .get()
                      .then(
                        (snap) => snap.docs.isNotEmpty
                            ? snap.docs.first as DocumentSnapshot
                            : null,
                      )
                      .catchError((_) => null),
                  builder: (context, userDocSnapshot) {
                    if (userDocSnapshot.connectionState ==
                        ConnectionState.waiting) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        child: Container(
                          height: 80,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.05),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Center(
                            child: CircularProgressIndicator(
                              color: Color(0xFF00FF41),
                              strokeWidth: 2,
                            ),
                          ),
                        ),
                      );
                    }

                    if (!userDocSnapshot.hasData) {
                      return const SizedBox.shrink();
                    }

                    final requesterData =
                        userDocSnapshot.data!.data() as Map<String, dynamic>;
                    return Container(
                      margin: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.05),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: const Color(0xFF00FF41).withValues(alpha: 0.3),
                          width: 1,
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          children: [
                            // Profile Picture
                            Container(
                              width: 60,
                              height: 60,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Color(0xFFB8B8C0),
                                  width: 2,
                                ),
                              ),
                              child: ClipOval(
                                child:
                                    requesterData['profileImageUrl'] != null &&
                                        requesterData['profileImageUrl']
                                            .toString()
                                            .isNotEmpty
                                    ? Image.network(
                                        requesterData['profileImageUrl'],
                                        fit: BoxFit.cover,
                                        errorBuilder:
                                            (context, error, stackTrace) {
                                              return Container(
                                                color: Colors.grey[800],
                                                child: const Icon(
                                                  Icons.person,
                                                  color: Colors.white30,
                                                ),
                                              );
                                            },
                                      )
                                    : Container(
                                        color: Colors.grey[800],
                                        child: const Icon(
                                          Icons.person,
                                          color: Colors.white30,
                                        ),
                                      ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            // User Info
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    requesterData['name'] ?? 'Unknown',
                                    style: const TextStyle(
                                      color: Color(0xFFB8B8C0),
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  Text(
                                    // Referral code is private; do not display in public lists
                                    '',
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            // Action Buttons
                            Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                ElevatedButton(
                                  onPressed: () => _acceptFriendRequest(
                                    currentUserCode,
                                    requesterCode,
                                    friendRequests,
                                    snapshot.data!.id,
                                  ),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFF00FF41),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 8,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                  ),
                                  child: const Text(
                                    'Accept',
                                    style: TextStyle(
                                      color: Colors.black,
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 4),
                                ElevatedButton(
                                  onPressed: () => _rejectFriendRequest(
                                    currentUserCode,
                                    requesterCode,
                                    friendRequests,
                                    snapshot.data!.id,
                                  ),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.red.withValues(
                                      alpha: 0.7,
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 8,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                  ),
                                  child: const Text(
                                    'Reject',
                                    style: TextStyle(
                                      color: Color(0xFFB8B8C0),
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  Future<void> _acceptFriendRequest(
    String currentUserCode,
    String requesterCode,
    List<String> friendRequests,
    String currentUserDocId,
  ) async {
    try {
      // Remove requester from friendRequests list
      friendRequests.remove(requesterCode);

      // Update current user: remove from friendRequests, add to friends
      final currentUserRef = FirebaseFirestore.instance
          .collection('applications')
          .doc(currentUserDocId);

      final currentUserData =
          (await currentUserRef.get()).data() as Map<String, dynamic>;
      final currentFriends =
          (currentUserData['friends'] as List?)?.cast<String>() ?? [];
      if (!currentFriends.contains(requesterCode)) {
        currentFriends.add(requesterCode);
      }

      await currentUserRef.update({
        'friendRequests': friendRequests,
        'friends': currentFriends,
      });

      // Update requester user: add current user to friends
      final requesterSnapshot = await FirebaseFirestore.instance
          .collection('applications')
          .where('referralCode', isEqualTo: requesterCode)
          .limit(1)
          .get();

      if (requesterSnapshot.docs.isNotEmpty) {
        final requesterRef = requesterSnapshot.docs.first.reference;
        final requesterData = requesterSnapshot.docs.first.data();
        final requesterFriends =
            (requesterData['friends'] as List?)?.cast<String>() ?? [];
        if (!requesterFriends.contains(currentUserCode)) {
          requesterFriends.add(currentUserCode);
        }

        await requesterRef.update({'friends': requesterFriends});
      }

      Obs.logEvent('friend_added', {
        'friend_count': (await currentUserRef.get()).get('friends')?.length ?? 0,
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Friend request accepted!'),
            backgroundColor: Color(0xFF00FF41),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error accepting request: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _rejectFriendRequest(
    String currentUserCode,
    String requesterCode,
    List<String> friendRequests,
    String currentUserDocId,
  ) async {
    try {
      // Remove requester from friendRequests list
      friendRequests.remove(requesterCode);

      // Update current user
      await FirebaseFirestore.instance
          .collection('applications')
          .doc(currentUserDocId)
          .update({'friendRequests': friendRequests});

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Friend request rejected'),
            backgroundColor: Colors.white70,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error rejecting request: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Widget _buildCrews() {
    if (_currentUserCode == null) {
      return const Center(
        child: Text('STAND BY — IDENTIFYING OPERATOR',
            style: TextStyle(color: Color(0xFF00FF41), fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 2)),
      );
    }
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('crews')
          .where('memberCodes', arrayContains: _currentUserCode)
          .snapshots(),
      builder: (context, snapshot) {
        final docs = snapshot.data?.docs ?? [];
        return Stack(
          children: [
            ListView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
              children: [
                _TierLoungesSection(userCode: _currentUserCode!),
                const SizedBox(height: 16),
                const _CrewLeaderboard(),
                const SizedBox(height: 8),
                if (docs.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 48),
                    child: Center(
                      child: Text('NO CREWS FORMED — RECRUIT A SQUAD',
                          style: TextStyle(color: Color(0xFF00FF41), fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 2)),
                    ),
                  )
                else
                  ...docs.map((d) => _CrewListTile(doc: d)),
              ],
            ),
            Positioned(
              bottom: 20,
              right: 16,
              child: FloatingActionButton(
                heroTag: 'createCrew',
                onPressed: _showCreateCrewDialog,
                backgroundColor: const Color(0xFF00FF41),
                child: const Icon(Icons.add, color: Colors.black),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showCreateCrewDialog() async {
    if (_currentUserCode == null) return;
    final snap = await FirebaseFirestore.instance
        .collection('applications')
        .where('referralCode', isEqualTo: _currentUserCode)
        .limit(1)
        .get();
    if (!mounted) return;
    final friends = snap.docs.isNotEmpty
        ? ((snap.docs.first.data()['friends'] as List?)?.cast<String>() ?? [])
        : <String>[];
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (_) => _CreateCrewDialog(
        userCode: _currentUserCode!,
        friendCodes: friends,
      ),
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }
}

// ==================== CREWS ====================

class CrewChatScreen extends StatefulWidget {
  final String crewId;
  final String crewName;
  final List<String> memberCodes;

  const CrewChatScreen({
    super.key,
    required this.crewId,
    required this.crewName,
    required this.memberCodes,
  });

  @override
  State<CrewChatScreen> createState() => _CrewChatScreenState();
}

class _CrewChatScreenState extends State<CrewChatScreen> {
  final _msgController = TextEditingController();
  final _scrollController = ScrollController();
  String? _userCode;
  String? _userName;
  String? _userUid;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _loadUser();
  }

  @override
  void dispose() {
    _msgController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadUser() async {
    final prefs = await SharedPreferences.getInstance();
    final code = prefs.getString('userReferralCode');
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (!mounted) return;
    setState(() {
      _userCode = code;
      _userUid = uid;
    });
    if (code == null) return;
    final snap = await FirebaseFirestore.instance
        .collection('applications')
        .where('referralCode', isEqualTo: code)
        .limit(1)
        .get();
    if (!mounted || snap.docs.isEmpty) return;
    setState(
        () => _userName = snap.docs.first.data()['name'] as String? ?? code);
  }

  Future<void> _send() async {
    final text = _msgController.text.trim();
    if (text.isEmpty || _userCode == null || _userUid == null) return;
    setState(() => _sending = true);
    _msgController.clear();
    try {
      await FirebaseFirestore.instance
          .collection('crews')
          .doc(widget.crewId)
          .collection('messages')
          .add({
        'senderCode': _userCode,
        'senderName': _userName ?? _userCode,
        'senderUid': _userUid,
        'text': text,
        'sentAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Failed to send: $e'),
              backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Color(0xFFB8B8C0)),
          onPressed: () => Navigator.pop(context),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.crewName,
              style: const TextStyle(
                color: Color(0xFF00FF41),
                fontSize: 16,
                fontWeight: FontWeight.bold,
                letterSpacing: 1,
              ),
            ),
            Text(
              '${widget.memberCodes.length} MEMBERS',
              style: const TextStyle(
                  color: Colors.white38, fontSize: 10, letterSpacing: 0.5),
            ),
          ],
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(color: Colors.white10, height: 1),
        ),
      ),
      body: Column(
        children: [
          _MemberAvatarRow(memberCodes: widget.memberCodes),
          const Divider(color: Colors.white10, height: 1),
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('crews')
                  .doc(widget.crewId)
                  .collection('messages')
                  .orderBy('sentAt', descending: true)
                  .limit(100)
                  .snapshots(),
              builder: (context, snapshot) {
                final docs = snapshot.data?.docs ?? [];
                if (docs.isEmpty) {
                  return const Center(
                    child: Text(
                      'CHANNEL OPEN — TRANSMIT',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white38, fontSize: 13),
                    ),
                  );
                }
                return ListView.builder(
                  controller: _scrollController,
                  reverse: true,
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  itemCount: docs.length,
                  itemBuilder: (context, i) {
                    final data = docs[i].data() as Map<String, dynamic>;
                    final isMe = data['senderCode'] == _userCode;
                    final senderName =
                        data['senderName'] as String? ?? '?';
                    final text = data['text'] as String? ?? '';
                    final ts = (data['sentAt'] as Timestamp?)?.toDate();
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        mainAxisAlignment: isMe
                            ? MainAxisAlignment.end
                            : MainAxisAlignment.start,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          if (!isMe) ...[
                            CircleAvatar(
                              radius: 14,
                              backgroundColor: Colors.white10,
                              child: Text(
                                senderName.isNotEmpty
                                    ? senderName[0].toUpperCase()
                                    : '?',
                                style: const TextStyle(
                                  color: Color(0xFF00FF41),
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                          ],
                          Flexible(
                            child: Column(
                              crossAxisAlignment: isMe
                                  ? CrossAxisAlignment.end
                                  : CrossAxisAlignment.start,
                              children: [
                                if (!isMe)
                                  Text(
                                    senderName,
                                    style: const TextStyle(
                                        color: Colors.white38,
                                        fontSize: 10,
                                        letterSpacing: 0.3),
                                  ),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 8),
                                  decoration: BoxDecoration(
                                    color: isMe
                                        ? const Color(0xFF00FF41)
                                            .withValues(alpha: 0.15)
                                        : Colors.white
                                            .withValues(alpha: 0.08),
                                    borderRadius: BorderRadius.only(
                                      topLeft: const Radius.circular(12),
                                      topRight: const Radius.circular(12),
                                      bottomLeft:
                                          Radius.circular(isMe ? 12 : 4),
                                      bottomRight:
                                          Radius.circular(isMe ? 4 : 12),
                                    ),
                                    border: Border.all(
                                      color: isMe
                                          ? const Color(0xFF00FF41)
                                              .withValues(alpha: 0.3)
                                          : Colors.white12,
                                    ),
                                  ),
                                  child: Text(
                                    text,
                                    style: TextStyle(
                                      color: isMe
                                          ? const Color(0xFF00FF41)
                                          : Colors.white,
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                                if (ts != null)
                                  Text(
                                    '${ts.hour.toString().padLeft(2, '0')}:${ts.minute.toString().padLeft(2, '0')}',
                                    style: const TextStyle(
                                        color: Colors.white24, fontSize: 9),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
            decoration: const BoxDecoration(
              color: Colors.black,
              border: Border(top: BorderSide(color: Colors.white10)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _msgController,
                    style:
                        const TextStyle(color: Colors.white, fontSize: 14),
                    decoration: InputDecoration(
                      hintText: 'Message crew...',
                      hintStyle: const TextStyle(
                          color: Colors.white38, fontSize: 13),
                      filled: true,
                      fillColor: Colors.white.withValues(alpha: 0.05),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: const BorderSide(color: Colors.white10),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: const BorderSide(color: Colors.white10),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: const BorderSide(
                            color: Color(0xFF00FF41), width: 1.5),
                      ),
                    ),
                    onSubmitted: (_) => _send(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: _sending ? null : _send,
                  icon: Icon(
                    Icons.send,
                    color: _sending
                        ? Colors.white24
                        : const Color(0xFF00FF41),
                    size: 22,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MemberAvatarRow extends StatelessWidget {
  final List<String> memberCodes;
  const _MemberAvatarRow({required this.memberCodes});

  @override
  Widget build(BuildContext context) {
    if (memberCodes.isEmpty) return const SizedBox.shrink();
    final codes = memberCodes.take(10).toList();
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('applications')
          .where('referralCode', whereIn: codes)
          .snapshots(),
      builder: (context, snapshot) {
        final docs = snapshot.data?.docs ?? [];
        return SizedBox(
          height: 64,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: docs.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (context, i) {
              final data = docs[i].data() as Map<String, dynamic>;
              final name = data['name'] as String? ?? '?';
              final imgUrl = data['profileImageUrl'] as String?;
              return Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircleAvatar(
                    radius: 16,
                    backgroundColor: Colors.white10,
                    backgroundImage:
                        imgUrl != null ? NetworkImage(imgUrl) : null,
                    child: imgUrl == null
                        ? Text(
                            name.isNotEmpty ? name[0].toUpperCase() : '?',
                            style: const TextStyle(
                              color: Color(0xFF00FF41),
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          )
                        : null,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    name.split(' ').first,
                    style: const TextStyle(
                        color: Colors.white38, fontSize: 8),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}

class _CreateCrewDialog extends StatefulWidget {
  final String userCode;
  final List<String> friendCodes;
  const _CreateCrewDialog(
      {required this.userCode, required this.friendCodes});

  @override
  State<_CreateCrewDialog> createState() => _CreateCrewDialogState();
}

class _CreateCrewDialogState extends State<_CreateCrewDialog> {
  final _nameController = TextEditingController();
  final Set<String> _selected = {};
  bool _saving = false;
  List<Map<String, dynamic>> _friends = [];

  @override
  void initState() {
    super.initState();
    _loadFriends();
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _loadFriends() async {
    if (widget.friendCodes.isEmpty) return;
    final codes = widget.friendCodes.take(10).toList();
    final snap = await FirebaseFirestore.instance
        .collection('applications')
        .where('referralCode', whereIn: codes)
        .get();
    if (mounted) {
      setState(
          () => _friends = snap.docs.map((d) => d.data()).toList());
    }
  }

  Future<void> _create() async {
    final name = _nameController.text.trim().toUpperCase();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Enter a crew name'),
          backgroundColor: Colors.red));
      return;
    }
    setState(() => _saving = true);
    try {
      await FirebaseFirestore.instance.collection('crews').add({
        'name': name,
        'memberCodes': [widget.userCode, ..._selected],
        'createdBy': widget.userCode,
        'createdAt': FieldValue.serverTimestamp(),
        'xpTotal': 0,
      });
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Failed: $e'), backgroundColor: Colors.red));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF0D0D1A),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xFF00FF41)),
      ),
      title: const Text('CREATE CREW',
          style: TextStyle(
              color: Color(0xFF00FF41),
              fontWeight: FontWeight.bold,
              fontSize: 16,
              letterSpacing: 2)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameController,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              decoration: InputDecoration(
                labelText: 'CREW NAME',
                labelStyle: const TextStyle(
                    color: Color(0xFF00FF41),
                    fontSize: 12,
                    letterSpacing: 1),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Colors.white24)),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(
                        color: Color(0xFF00FF41), width: 1.5)),
                filled: true,
                fillColor: Colors.white.withValues(alpha: 0.04),
              ),
            ),
            if (_friends.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text('INVITE FRIENDS',
                    style: TextStyle(
                        color: Colors.white54,
                        fontSize: 11,
                        letterSpacing: 1)),
              ),
              const SizedBox(height: 8),
              ..._friends.map((f) {
                final code = f['referralCode'] as String? ?? '';
                final name = f['name'] as String? ?? code;
                final sel = _selected.contains(code);
                return CheckboxListTile(
                  value: sel,
                  onChanged: (v) => setState(() {
                    if (v == true) {
                      _selected.add(code);
                    } else {
                      _selected.remove(code);
                    }
                  }),
                  title: Text(name,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 13)),
                  activeColor: const Color(0xFF00FF41),
                  checkColor: Colors.black,
                  contentPadding: EdgeInsets.zero,
                );
              }),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('CANCEL',
              style: TextStyle(color: Colors.white38)),
        ),
        ElevatedButton(
          onPressed: _saving ? null : _create,
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF00FF41),
            foregroundColor: Colors.black,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8)),
          ),
          child: _saving
              ? const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.black))
              : const Text('CREATE',
                  style: TextStyle(fontWeight: FontWeight.bold)),
        ),
      ],
    );
  }
}

// ==================== NIGHT REPORT (event recap card) ====================

/// Surfaces a "NIGHT REPORT" card on home if the user has a check-in to an event
/// that ended in the last 6h–72h window. Tap → fullscreen recap.
class _NightReportCard extends StatefulWidget {
  const _NightReportCard();

  @override
  State<_NightReportCard> createState() => _NightReportCardState();
}

class _NightReportCardState extends State<_NightReportCard> {
  String? _userCode;
  ({DocumentSnapshot event, DateTime endedAt})? _recent;
  bool _checked = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final prefs = await SharedPreferences.getInstance();
    final code = prefs.getString('userReferralCode');
    if (code == null || code.isEmpty) {
      if (mounted) setState(() => _checked = true);
      return;
    }
    _userCode = code;
    try {
      final dismissedId = prefs.getString('dismissedNightReportEventId');
      // Find user's check-in docs (using collectionGroup)
      final myCheckins = await FirebaseFirestore.instance
          .collectionGroup('checkins')
          .where(FieldPath.documentId, isEqualTo: code)
          .get();
      final now = DateTime.now();
      for (final c in myCheckins.docs) {
        final eventId = c.reference.parent.parent?.id;
        if (eventId == null || eventId == dismissedId) continue;
        final eventDoc = await FirebaseFirestore.instance.collection('events').doc(eventId).get();
        if (!eventDoc.exists) continue;
        final start = (eventDoc.data()?['startAt'] as Timestamp?)?.toDate();
        if (start == null) continue;
        // "Ended" 6h after start; show window 6h–72h after start.
        final endedAt = start.add(const Duration(hours: 6));
        if (now.isAfter(endedAt) && now.isBefore(start.add(const Duration(hours: 72)))) {
          if (mounted) {
            setState(() {
              _recent = (event: eventDoc, endedAt: endedAt);
              _checked = true;
            });
          }
          return;
        }
      }
    } catch (_) {}
    if (mounted) setState(() => _checked = true);
  }

  Future<void> _dismiss() async {
    if (_recent == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('dismissedNightReportEventId', _recent!.event.id);
    if (mounted) setState(() => _recent = null);
  }

  void _open() {
    if (_recent == null) return;
    HapticFeedback.lightImpact();
    TekSounds.instance.tap();
    Navigator.push(context, cinematicRoute(_NightReportFullscreen(
      eventId: _recent!.event.id,
      eventData: _recent!.event.data() as Map<String, dynamic>,
      userCode: _userCode!,
      sinceMs: ((_recent!.event.data() as Map<String, dynamic>)['startAt'] as Timestamp).millisecondsSinceEpoch,
    )));
  }

  @override
  Widget build(BuildContext context) {
    if (!_checked || _recent == null || _userCode == null) return const SizedBox.shrink();
    final data = _recent!.event.data() as Map<String, dynamic>;
    final title = (data['title'] as String? ?? 'EVENT').toUpperCase();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: PressScale(
        child: GestureDetector(
          onTap: _open,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.65),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFFFFD700).withValues(alpha: 0.5), width: 1),
              boxShadow: [BoxShadow(color: const Color(0xFFFFD700).withValues(alpha: 0.18), blurRadius: 22)],
            ),
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Row(
              children: [
                Container(
                  width: 38, height: 38,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFFFFD700).withValues(alpha: 0.14),
                    border: Border.all(color: const Color(0xFFFFD700), width: 1.2),
                  ),
                  child: const Icon(Icons.assessment, color: Color(0xFFFFD700), size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('NIGHT REPORT — TAP FOR DEBRIEF',
                          style: TextStyle(color: Color(0xFFFFD700), fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 2)),
                      const SizedBox(height: 4),
                      Text(title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold, letterSpacing: 1)),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white38, size: 18),
                  onPressed: _dismiss,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NightReportFullscreen extends StatefulWidget {
  final String eventId;
  final Map<String, dynamic> eventData;
  final String userCode;
  final int sinceMs;
  const _NightReportFullscreen({
    required this.eventId,
    required this.eventData,
    required this.userCode,
    required this.sinceMs,
  });

  @override
  State<_NightReportFullscreen> createState() => _NightReportFullscreenState();
}

class _NightReportFullscreenState extends State<_NightReportFullscreen> {
  int? _missionsCompleted;
  int? _xpEarned;
  int? _storiesPosted;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  Future<void> _loadStats() async {
    try {
      final since = Timestamp.fromMillisecondsSinceEpoch(widget.sinceMs);
      final missionsSnap = await FirebaseFirestore.instance
          .collection('sidequest_completions')
          .where('userCode', isEqualTo: widget.userCode)
          .where('completedAt', isGreaterThan: since)
          .get();
      final missions = missionsSnap.docs.length;
      int xp = 0;
      for (final d in missionsSnap.docs) {
        xp += (d.data()['xpAwarded'] as num?)?.toInt() ?? 0;
      }
      final storiesSnap = await FirebaseFirestore.instance
          .collection('stories')
          .where('userCode', isEqualTo: widget.userCode)
          .where('createdAt', isGreaterThan: since)
          .get();
      if (mounted) {
        setState(() {
          _missionsCompleted = missions;
          _xpEarned = xp;
          _storiesPosted = storiesSnap.docs.length;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _share() {
    final title = widget.eventData['title'] as String? ?? 'EVENT';
    final text = 'TEK NIGHT REPORT — $title\n'
        'Missions: ${_missionsCompleted ?? 0}\n'
        'XP Earned: ${_xpEarned ?? 0}\n'
        'Stories: ${_storiesPosted ?? 0}\n\n'
        'Build your night. Build your name. tek.app';
    SharePlus.instance.share(ShareParams(text: text));
  }

  @override
  Widget build(BuildContext context) {
    final title = (widget.eventData['title'] as String? ?? 'EVENT').toUpperCase();
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Color(0xFFFFD700)),
        title: const Text('NIGHT REPORT',
            style: TextStyle(color: Color(0xFFFFD700), fontSize: 14, fontWeight: FontWeight.bold, letterSpacing: 3)),
        centerTitle: true,
        actions: [
          IconButton(icon: const Icon(Icons.ios_share, color: Color(0xFFFFD700)), onPressed: _loading ? null : _share),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFFFFD700)))
          : Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 20),
                  Text(title, textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold, letterSpacing: 2)),
                  const SizedBox(height: 6),
                  const Text('OPERATIONS COMPLETE — DEBRIEF',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Color(0xFFFFD700), fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 2)),
                  const SizedBox(height: 30),
                  _ReportRow(label: 'MISSIONS COMPLETED', value: '${_missionsCompleted ?? 0}', icon: Icons.bolt),
                  const SizedBox(height: 12),
                  _ReportRow(label: 'XP EARNED', value: '+${_xpEarned ?? 0}', icon: Icons.show_chart),
                  const SizedBox(height: 12),
                  _ReportRow(label: 'STORIES POSTED', value: '${_storiesPosted ?? 0}', icon: Icons.camera_alt),
                  const Spacer(),
                  PressScale(
                    child: ElevatedButton.icon(
                      onPressed: _share,
                      icon: const Icon(Icons.ios_share, color: Colors.black),
                      label: const Text('SHARE REPORT',
                          style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, letterSpacing: 2)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFFFD700),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                ],
              ),
            ),
    );
  }
}

class _ReportRow extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  const _ReportRow({required this.label, required this.value, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFFD700).withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(icon, color: const Color(0xFFFFD700), size: 22),
          const SizedBox(width: 14),
          Expanded(
            child: Text(label,
                style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 2)),
          ),
          AnimatedXP(value: int.tryParse(value.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0, suffix: '',
              style: const TextStyle(color: Color(0xFFFFD700), fontSize: 22, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}

// ==================== MISSION CONTROL HERO (adaptive home card) ====================

/// Context-aware hero card at the top of SOCIAL. Switches between:
///  - LIVE: user is checked into an event
///  - TONIGHT / THIS WEEK: upcoming event
///  - READY MISSION: an unlocked, uncompleted mission
///  - STAND BY: nothing new — quiet state with a transmission ping
class _MissionControlHero extends StatefulWidget {
  const _MissionControlHero();

  @override
  State<_MissionControlHero> createState() => _MissionControlHeroState();
}

class _MissionControlHeroState extends State<_MissionControlHero> {
  String? _userCode;
  Set<String> _completedIds = {};

  @override
  void initState() {
    super.initState();
    _loadUser();
  }

  Future<void> _loadUser() async {
    final prefs = await SharedPreferences.getInstance();
    final code = prefs.getString('userReferralCode');
    if (code == null || code.isEmpty) return;
    final snap = await FirebaseFirestore.instance
        .collection('applications')
        .where('referralCode', isEqualTo: code)
        .limit(1)
        .get();
    if (!mounted) return;
    setState(() {
      _userCode = code;
      if (snap.docs.isNotEmpty) {
        _completedIds = ((snap.docs.first.data()['completedSidequests'] as List?) ?? [])
            .cast<String>()
            .toSet();
      }
    });
  }

  String _fmtCountdown(Duration d) {
    if (d.isNegative) return '0:00';
    final days = d.inDays;
    final hours = d.inHours.remainder(24);
    final mins = d.inMinutes.remainder(60);
    if (days > 0) return '${days}D ${hours}H';
    if (hours > 0) return '${hours}H ${mins}M';
    return '${mins}M';
  }

  @override
  Widget build(BuildContext context) {
    if (_userCode == null) return const SizedBox.shrink();
    return FutureBuilder<List<QuerySnapshot>>(
      future: Future.wait([
        FirebaseFirestore.instance
            .collection('events')
            .orderBy('startAt')
            .limit(20)
            .get(),
        FirebaseFirestore.instance
            .collection('sidequests')
            .where('active', isEqualTo: true)
            .limit(20)
            .get(),
      ]),
      builder: (context, snap) {
        if (!snap.hasData) {
          return _buildSkeleton();
        }
        final events = snap.data![0].docs;
        final missions = snap.data![1].docs;
        final now = DateTime.now();

        // 1) Look for active checkin in any event
        return StreamBuilder<QuerySnapshot>(
          stream: FirebaseFirestore.instance
              .collectionGroup('checkins')
              .where(FieldPath.documentId, isEqualTo: _userCode)
              .snapshots(),
          builder: (context, checkinSnap) {
            DocumentSnapshot? activeCheckinEvent;
            if (checkinSnap.hasData && checkinSnap.data!.docs.isNotEmpty) {
              // Find the parent event of the checkin (most recent)
              final myCheckins = checkinSnap.data!.docs;
              for (final c in myCheckins) {
                final eventId = c.reference.parent.parent?.id;
                if (eventId == null) continue;
                final eventDoc = events.firstWhere(
                  (e) => e.id == eventId,
                  orElse: () => events.isEmpty ? events.first : events.first,
                );
                final start = (eventDoc.data() as Map<String, dynamic>?)?['startAt'] as Timestamp?;
                if (start == null) continue;
                final startDt = start.toDate();
                // Within 12h of start = "live"
                if (now.isAfter(startDt.subtract(const Duration(hours: 2))) &&
                    now.isBefore(startDt.add(const Duration(hours: 12)))) {
                  activeCheckinEvent = eventDoc;
                  break;
                }
              }
            }

            if (activeCheckinEvent != null) {
              return _heroLive(activeCheckinEvent);
            }

            // 2) Find the next upcoming event (earliest startAt > now)
            DocumentSnapshot? upcoming;
            DateTime? upcomingAt;
            for (final e in events) {
              final t = (e.data() as Map<String, dynamic>)['startAt'] as Timestamp?;
              if (t == null) continue;
              final dt = t.toDate();
              if (dt.isAfter(now)) {
                if (upcomingAt == null || dt.isBefore(upcomingAt)) {
                  upcoming = e;
                  upcomingAt = dt;
                }
              }
            }
            if (upcoming != null && upcomingAt != null) {
              return _heroUpcoming(upcoming, upcomingAt);
            }

            // 3) Highlight a ready mission (active, not completed, no unmet prereq)
            for (final m in missions) {
              if (_completedIds.contains(m.id)) continue;
              final data = m.data() as Map<String, dynamic>;
              final prereq = data['requiresQuestId'] as String?;
              if (prereq != null && prereq.isNotEmpty && !_completedIds.contains(prereq)) continue;
              return _heroMission(m);
            }

            // 4) Default: stand-by
            return _heroStandBy();
          },
        );
      },
    );
  }

  Widget _shell({required Widget child, Color accent = const Color(0xFF00FF41)}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: accent.withValues(alpha: 0.4), width: 1),
          boxShadow: [
            BoxShadow(color: accent.withValues(alpha: 0.18), blurRadius: 22, spreadRadius: 0),
          ],
        ),
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: child,
      ),
    );
  }

  Widget _heroLabel(String text, {Color color = const Color(0xFF00FF41)}) {
    return Row(
      children: [
        Container(width: 6, height: 6, decoration: BoxDecoration(shape: BoxShape.circle, color: color)),
        const SizedBox(width: 6),
        Text(text, style: TextStyle(color: color, fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 2.5)),
      ],
    );
  }

  Widget _heroLive(DocumentSnapshot event) {
    final data = event.data() as Map<String, dynamic>;
    final title = (data['title'] as String? ?? 'EVENT').toUpperCase();
    final location = (data['location'] as String? ?? '').toUpperCase();
    return _shell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _heroLabel('● LIVE  //  YOU ARE ON-SITE'),
          const SizedBox(height: 6),
          Text(title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Color(0xFF00FF41), fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 1)),
          if (location.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(location, style: const TextStyle(color: Colors.white54, fontSize: 11, letterSpacing: 1)),
          ],
          const SizedBox(height: 10),
          PressScale(
            child: ElevatedButton(
              onPressed: () {
                HapticFeedback.lightImpact();
                TekSounds.instance.tap();
                Navigator.push(
                  context,
                  cinematicRoute(EventDetailScreen(eventId: event.id, eventData: data)),
                );
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00FF41),
                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: const Text('OPEN MISSION HUB',
                  style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, letterSpacing: 1.5, fontSize: 12)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _heroUpcoming(DocumentSnapshot event, DateTime when) {
    final data = event.data() as Map<String, dynamic>;
    final title = (data['title'] as String? ?? 'EVENT').toUpperCase();
    final diff = when.difference(DateTime.now());
    final isTonight = diff.inHours < 18 && when.day == DateTime.now().day;
    final label = isTonight ? '● TONIGHT  //  TRANSMISSION INCOMING' : '● UPCOMING  //  STAND BY';
    return _shell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _heroLabel(label),
          const SizedBox(height: 6),
          Text(title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Color(0xFF00FF41), fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 1)),
          const SizedBox(height: 2),
          Text('T-${_fmtCountdown(diff)}',
              style: const TextStyle(color: Colors.white54, fontSize: 12, letterSpacing: 2, fontFamily: 'monospace')),
          const SizedBox(height: 10),
          PressScale(
            child: OutlinedButton(
              onPressed: () {
                HapticFeedback.lightImpact();
                TekSounds.instance.tap();
                Navigator.push(
                  context,
                  cinematicRoute(EventDetailScreen(eventId: event.id, eventData: data)),
                );
              },
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Color(0xFF00FF41)),
                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: const Text('OPEN BRIEF',
                  style: TextStyle(color: Color(0xFF00FF41), fontWeight: FontWeight.bold, letterSpacing: 1.5, fontSize: 12)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _heroMission(DocumentSnapshot mission) {
    final data = mission.data() as Map<String, dynamic>;
    final title = (data['title'] as String? ?? 'MISSION').toUpperCase();
    final xp = (data['xpReward'] as num?)?.toInt() ?? 0;
    return _shell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _heroLabel('● MISSION READY  //  AWAITING OPERATOR'),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Color(0xFF00FF41), fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 1)),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF00FF41).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: const Color(0xFF00FF41).withValues(alpha: 0.5)),
                ),
                child: Text('+$xp XP',
                    style: const TextStyle(color: Color(0xFF00FF41), fontWeight: FontWeight.bold, fontSize: 11)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          PressScale(
            child: ElevatedButton(
              onPressed: () {
                HapticFeedback.lightImpact();
                TekSounds.instance.tap();
                Navigator.push(
                  context,
                  cinematicRoute(SidequestDetailPage(
                    questId: mission.id,
                    data: data,
                    completed: false,
                    userCode: _userCode,
                  )),
                );
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00FF41),
                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: const Text('OPEN BRIEF',
                  style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, letterSpacing: 1.5, fontSize: 12)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _heroStandBy() {
    return _shell(
      accent: Colors.white24,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _heroLabel('● STAND BY  //  TRANSMISSION SILENT', color: Colors.white54),
          const SizedBox(height: 6),
          const Text('NO ACTIVE OBJECTIVES',
              style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 1)),
          const SizedBox(height: 4),
          const Text('A new transmission will reach you when there is one.',
              style: TextStyle(color: Colors.white38, fontSize: 11, height: 1.4)),
        ],
      ),
    );
  }

  Widget _buildSkeleton() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: SkeletonCard(height: 92, radius: 14),
    );
  }
}

// ==================== STORIES (24h photo posts) ====================

class _StoriesRow extends StatefulWidget {
  const _StoriesRow();

  @override
  State<_StoriesRow> createState() => _StoriesRowState();
}

class _StoriesRowState extends State<_StoriesRow> {
  String? _userCode;
  String? _userName;
  String? _userImageUrl;
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    _loadMe();
  }

  Future<void> _loadMe() async {
    final prefs = await SharedPreferences.getInstance();
    final code = prefs.getString('userReferralCode');
    if (code == null || code.isEmpty) return;
    final snap = await FirebaseFirestore.instance
        .collection('applications')
        .where('referralCode', isEqualTo: code)
        .limit(1)
        .get();
    if (!mounted) return;
    setState(() {
      _userCode = code;
      if (snap.docs.isNotEmpty) {
        final d = snap.docs.first.data();
        _userName = d['name'] as String?;
        _userImageUrl = d['profileImageUrl'] as String?;
      }
    });
  }

  Future<void> _addStory() async {
    if (_userCode == null) return;
    HapticFeedback.lightImpact();
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery, maxWidth: 1280, maxHeight: 1280, imageQuality: 80);
    if (picked == null) return;
    setState(() => _uploading = true);
    try {
      final ts = DateTime.now().millisecondsSinceEpoch;
      final ref = FirebaseStorage.instance.ref('stories/$_userCode/$ts.jpg');
      await ref.putFile(File(picked.path));
      final url = await ref.getDownloadURL();
      final now = DateTime.now();
      await FirebaseFirestore.instance.collection('stories').add({
        'userCode': _userCode,
        'userName': _userName ?? _userCode,
        'profileImageUrl': _userImageUrl ?? '',
        'photoUrl': url,
        'createdAt': Timestamp.fromDate(now),
        'expiresAt': Timestamp.fromDate(now.add(const Duration(hours: 24))),
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Story upload failed: $e'),
          backgroundColor: Colors.red,
        ));
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 96,
      child: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('stories')
            .where('expiresAt', isGreaterThan: Timestamp.now())
            .orderBy('expiresAt', descending: true)
            .snapshots(),
        builder: (context, snap) {
          final docs = snap.data?.docs ?? [];
          final byUser = <String, List<DocumentSnapshot>>{};
          for (final d in docs) {
            final m = d.data() as Map<String, dynamic>;
            final code = m['userCode'] as String? ?? '';
            if (code.isEmpty) continue;
            byUser.putIfAbsent(code, () => <DocumentSnapshot>[]).add(d);
          }
          final entries = byUser.entries.toList()
            ..sort((a, b) {
              if (a.key == _userCode) return -1;
              if (b.key == _userCode) return 1;
              final aTs = (a.value.first.data() as Map<String, dynamic>)['createdAt'] as Timestamp?;
              final bTs = (b.value.first.data() as Map<String, dynamic>)['createdAt'] as Timestamp?;
              return (bTs?.compareTo(aTs ?? Timestamp(0, 0)) ?? 0);
            });

          return ListView.builder(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            itemCount: entries.length + 1,
            itemBuilder: (context, i) {
              if (i == 0) {
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: GestureDetector(
                    onTap: _uploading ? null : _addStory,
                    child: Column(
                      children: [
                        Stack(
                          alignment: Alignment.center,
                          children: [
                            Container(
                              width: 60, height: 60,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(color: const Color(0xFF00FF41).withValues(alpha: 0.5), width: 1.5),
                                color: Colors.black,
                              ),
                              child: _userImageUrl != null && _userImageUrl!.isNotEmpty
                                  ? ClipOval(child: FadeInNetImage(url: _userImageUrl!, avatarSize: 56))
                                  : const Icon(Icons.person, color: Colors.white24, size: 28),
                            ),
                            Positioned(
                              bottom: 0,
                              right: 0,
                              child: Container(
                                width: 22, height: 22,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: const Color(0xFF00FF41),
                                  border: Border.all(color: Colors.black, width: 2),
                                ),
                                child: _uploading
                                    ? const Padding(
                                        padding: EdgeInsets.all(4),
                                        child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.black),
                                      )
                                    : const Icon(Icons.add, color: Colors.black, size: 14),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        const Text('YOUR STORY',
                            style: TextStyle(color: Colors.white54, fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 1)),
                      ],
                    ),
                  ),
                );
              }
              final entry = entries[i - 1];
              final storyDocs = entry.value;
              final first = storyDocs.first.data() as Map<String, dynamic>;
              final name = (first['userName'] as String? ?? '?');
              final url = (first['profileImageUrl'] as String? ?? '');
              final isMe = entry.key == _userCode;
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: GestureDetector(
                  onTap: () {
                    HapticFeedback.lightImpact();
                    TekSounds.instance.storyOpen();
                    Navigator.push(
                      context,
                      cinematicRoute(_StoryViewerScreen(stories: storyDocs)),
                    );
                  },
                  child: Column(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: const LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [Color(0xFF00FF41), Color(0xFF005521)],
                          ),
                        ),
                        child: Container(
                          width: 56, height: 56,
                          decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.black),
                          padding: const EdgeInsets.all(2),
                          child: url.isNotEmpty
                              ? ClipOval(child: FadeInNetImage(url: url, avatarSize: 52))
                              : Container(
                                  decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFF00FF41)),
                                  child: Center(
                                    child: Text(
                                      name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase(),
                                      style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      SizedBox(
                        width: 64,
                        child: Text(
                          isMe ? 'YOU' : name.toUpperCase(),
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white70, fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 1),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _StoryViewerScreen extends StatefulWidget {
  final List<DocumentSnapshot> stories;
  const _StoryViewerScreen({required this.stories});

  @override
  State<_StoryViewerScreen> createState() => _StoryViewerScreenState();
}

class _StoryViewerScreenState extends State<_StoryViewerScreen> with SingleTickerProviderStateMixin {
  int _index = 0;
  late AnimationController _progress;

  @override
  void initState() {
    super.initState();
    _progress = AnimationController(vsync: this, duration: const Duration(seconds: 5))
      ..addStatusListener((s) {
        if (s == AnimationStatus.completed) _next();
      });
    _progress.forward();
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  void _next() {
    if (_index >= widget.stories.length - 1) {
      Navigator.pop(context);
      return;
    }
    setState(() => _index++);
    _progress
      ..reset()
      ..forward();
  }

  void _prev() {
    if (_index == 0) return;
    setState(() => _index--);
    _progress
      ..reset()
      ..forward();
  }

  String _timeAgo(Timestamp? ts) {
    if (ts == null) return '';
    final diff = DateTime.now().difference(ts.toDate());
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    return '${diff.inDays}d';
  }

  @override
  Widget build(BuildContext context) {
    final story = widget.stories[_index].data() as Map<String, dynamic>;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTapUp: (details) {
                  final w = MediaQuery.of(context).size.width;
                  if (details.localPosition.dx < w / 3) {
                    _prev();
                  } else {
                    _next();
                  }
                },
                child: Center(
                  child: FadeInNetImage(url: story['photoUrl'] as String? ?? '', fit: BoxFit.contain),
                ),
              ),
            ),
            Positioned(
              top: 8,
              left: 8,
              right: 8,
              child: Row(
                children: List.generate(widget.stories.length, (i) {
                  return Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: AnimatedBuilder(
                        animation: _progress,
                        builder: (_, __) {
                          final v = i < _index
                              ? 1.0
                              : (i == _index ? _progress.value : 0.0);
                          return Container(
                            height: 2,
                            decoration: BoxDecoration(
                              color: Colors.white24,
                              borderRadius: BorderRadius.circular(2),
                            ),
                            child: FractionallySizedBox(
                              alignment: Alignment.centerLeft,
                              widthFactor: v,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: const Color(0xFF00FF41),
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  );
                }),
              ),
            ),
            Positioned(
              top: 18,
              left: 12,
              right: 12,
              child: Row(
                children: [
                  if ((story['profileImageUrl'] as String? ?? '').isNotEmpty)
                    FadeInNetImage(url: story['profileImageUrl'] as String, avatarSize: 32)
                  else
                    Container(
                      width: 32, height: 32,
                      decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFF00FF41)),
                      child: Center(
                        child: Text(
                          (story['userName'] as String? ?? '?').trim().isEmpty
                              ? '?'
                              : (story['userName'] as String).trim()[0].toUpperCase(),
                          style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                  const SizedBox(width: 10),
                  Text(
                    (story['userName'] as String? ?? '').toUpperCase(),
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, letterSpacing: 1),
                  ),
                  const SizedBox(width: 8),
                  Text(_timeAgo(story['createdAt'] as Timestamp?),
                      style: const TextStyle(color: Colors.white54, fontSize: 11)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ==================== TIER LOUNGES (level-gated chat rooms) ====================

class _TierLoungeDef {
  final String id;
  final String name;
  final IconData icon;
  final Color color;
  final int xpRequired;
  const _TierLoungeDef({
    required this.id,
    required this.name,
    required this.icon,
    required this.color,
    required this.xpRequired,
  });
}

const List<_TierLoungeDef> _tierLounges = [
  _TierLoungeDef(
    id: 'inner_circle',
    name: 'INNER CIRCLE',
    icon: Icons.diamond,
    color: Color(0xFF9F59FF),
    xpRequired: 4000,
  ),
  _TierLoungeDef(
    id: 'black_card',
    name: 'BLACK CARD',
    icon: Icons.workspace_premium,
    color: Color(0xFFE63946),
    xpRequired: 6000,
  ),
];

class _TierLoungesSection extends StatelessWidget {
  final String userCode;
  const _TierLoungesSection({required this.userCode});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('applications')
          .where('referralCode', isEqualTo: userCode)
          .limit(1)
          .snapshots(),
      builder: (context, snap) {
        final docs = snap.data?.docs ?? [];
        if (docs.isEmpty) return const SizedBox.shrink();
        final myXp = ((docs.first.data() as Map<String, dynamic>)['xpPoints'] as num?)?.toInt() ?? 0;
        return Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF7A7A7A).withValues(alpha: 0.3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(children: [
                Icon(Icons.lock_outline, color: Color(0xFF7A7A7A), size: 14),
                SizedBox(width: 6),
                Text('TIER LOUNGES — ELITE CHANNELS',
                    style: TextStyle(color: Color(0xFF7A7A7A), fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 2)),
              ]),
              const SizedBox(height: 10),
              for (final lounge in _tierLounges) ...[
                _TierLoungeRow(lounge: lounge, myXp: myXp, userCode: userCode),
                if (lounge.id != _tierLounges.last.id) const SizedBox(height: 8),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _TierLoungeRow extends StatelessWidget {
  final _TierLoungeDef lounge;
  final int myXp;
  final String userCode;
  const _TierLoungeRow({required this.lounge, required this.myXp, required this.userCode});

  @override
  Widget build(BuildContext context) {
    final unlocked = myXp >= lounge.xpRequired;
    final xpToGo = unlocked ? 0 : lounge.xpRequired - myXp;
    return PressScale(
      child: GestureDetector(
        onTap: !unlocked
            ? null
            : () {
                HapticFeedback.lightImpact();
                TekSounds.instance.tap();
                Navigator.push(
                  context,
                  cinematicRoute(_TierLoungeChatScreen(lounge: lounge, userCode: userCode)),
                );
              },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: unlocked ? lounge.color.withValues(alpha: 0.10) : Colors.white.withValues(alpha: 0.03),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: unlocked ? lounge.color.withValues(alpha: 0.6) : Colors.white12, width: 1),
          ),
          child: Row(
            children: [
              Icon(unlocked ? lounge.icon : Icons.lock,
                  color: unlocked ? lounge.color : Colors.white24, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(lounge.name,
                        style: TextStyle(
                          color: unlocked ? lounge.color : Colors.white54,
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.5,
                        )),
                    const SizedBox(height: 2),
                    Text(
                      unlocked ? 'ACCESS GRANTED' : '$xpToGo XP TO UNLOCK',
                      style: TextStyle(
                        color: unlocked ? Colors.white70 : Colors.white38,
                        fontSize: 10,
                        letterSpacing: 1,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(unlocked ? Icons.chevron_right : Icons.lock_outline,
                  color: unlocked ? lounge.color : Colors.white24, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}

class _TierLoungeChatScreen extends StatefulWidget {
  final _TierLoungeDef lounge;
  final String userCode;
  const _TierLoungeChatScreen({required this.lounge, required this.userCode});

  @override
  State<_TierLoungeChatScreen> createState() => _TierLoungeChatScreenState();
}

class _TierLoungeChatScreenState extends State<_TierLoungeChatScreen> {
  final _msgController = TextEditingController();
  String? _userName;
  String? _userImageUrl;
  String? _userUid;

  @override
  void initState() {
    super.initState();
    _loadUser();
  }

  @override
  void dispose() {
    _msgController.dispose();
    super.dispose();
  }

  Future<void> _loadUser() async {
    _userUid = FirebaseAuth.instance.currentUser?.uid;
    final snap = await FirebaseFirestore.instance
        .collection('applications')
        .where('referralCode', isEqualTo: widget.userCode)
        .limit(1)
        .get();
    if (!mounted) return;
    if (snap.docs.isNotEmpty) {
      setState(() {
        _userName = snap.docs.first.data()['name'] as String?;
        _userImageUrl = snap.docs.first.data()['profileImageUrl'] as String?;
      });
    }
  }

  Future<void> _send() async {
    final text = _msgController.text.trim();
    if (text.isEmpty || _userUid == null) return;
    _msgController.clear();
    HapticFeedback.lightImpact();
    await FirebaseFirestore.instance
        .collection('tier_lounges')
        .doc(widget.lounge.id)
        .collection('messages')
        .add({
      'senderUid': _userUid,
      'senderCode': widget.userCode,
      'senderName': _userName ?? widget.userCode,
      'senderImageUrl': _userImageUrl ?? '',
      'text': text,
      'sentAt': FieldValue.serverTimestamp(),
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: widget.lounge.color),
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(widget.lounge.icon, color: widget.lounge.color, size: 18),
            const SizedBox(width: 8),
            Text(widget.lounge.name,
                style: TextStyle(color: widget.lounge.color, fontSize: 14, fontWeight: FontWeight.bold, letterSpacing: 2)),
          ],
        ),
        centerTitle: true,
      ),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('tier_lounges')
                  .doc(widget.lounge.id)
                  .collection('messages')
                  .orderBy('sentAt', descending: true)
                  .limit(100)
                  .snapshots(),
              builder: (context, snap) {
                final docs = snap.data?.docs ?? [];
                if (docs.isEmpty) {
                  return const Center(
                    child: Text('CHANNEL OPEN — TRANSMIT',
                        style: TextStyle(color: Color(0xFF00FF41), fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 2)),
                  );
                }
                return ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  itemCount: docs.length,
                  itemBuilder: (_, i) {
                    final d = docs[i].data() as Map<String, dynamic>;
                    final isMine = d['senderCode'] == widget.userCode;
                    final name = d['senderName'] as String? ?? '?';
                    final text = d['text'] as String? ?? '';
                    return Align(
                      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
                        decoration: BoxDecoration(
                          color: isMine
                              ? widget.lounge.color.withValues(alpha: 0.18)
                              : Colors.white.withValues(alpha: 0.07),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isMine ? widget.lounge.color.withValues(alpha: 0.5) : Colors.white12,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                          children: [
                            if (!isMine)
                              Text(name.toUpperCase(),
                                  style: TextStyle(color: widget.lounge.color, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1)),
                            Text(text, style: const TextStyle(color: Colors.white, fontSize: 14)),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    controller: _msgController,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                    decoration: InputDecoration(
                      hintText: 'TRANSMIT TO ${widget.lounge.name}...',
                      hintStyle: const TextStyle(color: Colors.white38, letterSpacing: 1, fontSize: 12),
                      filled: true,
                      fillColor: Colors.white.withValues(alpha: 0.06),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                    ),
                    onSubmitted: (_) => _send(),
                  ),
                ),
                const SizedBox(width: 8),
                PressScale(
                  child: GestureDetector(
                    onTap: _send,
                    child: Container(
                      width: 40, height: 40,
                      decoration: BoxDecoration(color: widget.lounge.color, shape: BoxShape.circle),
                      child: const Icon(Icons.send, color: Colors.black, size: 18),
                    ),
                  ),
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

// ==================== CREW LIST TILE (extracted from old _buildCrews) ====================

class _CrewListTile extends StatelessWidget {
  final QueryDocumentSnapshot doc;
  const _CrewListTile({required this.doc});

  @override
  Widget build(BuildContext context) {
    final data = doc.data() as Map<String, dynamic>;
    final name = data['name'] as String? ?? 'UNNAMED CREW';
    final memberCodes = (data['memberCodes'] as List?)?.cast<String>() ?? [];
    final xpTotal = (data['xpTotal'] as num?)?.toInt() ?? 0;
    return PressScale(
      child: GestureDetector(
        onTap: () {
          HapticFeedback.lightImpact();
          TekSounds.instance.tap();
          Navigator.push(
            context,
            cinematicRoute(CrewChatScreen(
              crewId: doc.id,
              crewName: name,
              memberCodes: memberCodes,
            )),
          );
        },
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white10),
          ),
          child: Row(
            children: [
              Container(
                width: 46, height: 46,
                decoration: BoxDecoration(
                  color: const Color(0xFF00FF41).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFF00FF41).withValues(alpha: 0.3)),
                ),
                child: const Center(child: Icon(Icons.groups, color: Color(0xFF00FF41), size: 24)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name,
                        style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
                    Text('${memberCodes.length} members',
                        style: const TextStyle(color: Colors.white38, fontSize: 11)),
                  ],
                ),
              ),
              if (xpTotal > 0)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00FF41).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text('$xpTotal XP',
                      style: const TextStyle(color: Color(0xFF00FF41), fontSize: 11, fontWeight: FontWeight.bold)),
                ),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right, color: Colors.white30, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

// ==================== CREW LEADERBOARD ====================

class _CrewLeaderboard extends StatelessWidget {
  const _CrewLeaderboard();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('crews')
          .orderBy('xpTotal', descending: true)
          .limit(20)
          .snapshots(),
      builder: (context, snap) {
        final docs = snap.data?.docs ?? [];
        if (docs.isEmpty) return const SizedBox.shrink();
        return Container(
          margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF00FF41).withValues(alpha: 0.3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(children: [
                Icon(Icons.emoji_events, color: Color(0xFF00FF41), size: 14),
                SizedBox(width: 6),
                Text('CREW RANKINGS', style: TextStyle(color: Color(0xFF00FF41), fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 2)),
              ]),
              const SizedBox(height: 10),
              ...List.generate(docs.length > 5 ? 5 : docs.length, (i) {
                final d = docs[i].data() as Map<String, dynamic>;
                final name = d['name'] as String? ?? 'CREW';
                final xp = (d['xpTotal'] as num?)?.toInt() ?? 0;
                final medals = ['🥇', '🥈', '🥉'];
                final rankColor = i == 0
                    ? const Color(0xFFFFD700)
                    : i == 1
                        ? const Color(0xFFC0C0C0)
                        : i == 2
                            ? const Color(0xFFCD7F32)
                            : Colors.white38;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(children: [
                    SizedBox(
                      width: 22,
                      child: i < 3
                          ? Text(medals[i], style: const TextStyle(fontSize: 13))
                          : Text('${i + 1}', style: TextStyle(color: rankColor, fontSize: 12, fontWeight: FontWeight.bold)),
                    ),
                    const SizedBox(width: 6),
                    Expanded(child: Text(name, overflow: TextOverflow.ellipsis, style: TextStyle(color: rankColor, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 0.5))),
                    Text('$xp XP', style: TextStyle(color: rankColor, fontSize: 11, fontWeight: FontWeight.bold)),
                  ]),
                );
              }),
            ],
          ),
        );
      },
    );
  }
}

// ==================== EVENTS SCREEN CREATE MODAL (for admin button) ====================
class EventsScreenCreateModal extends StatefulWidget {
  const EventsScreenCreateModal({super.key});

  @override
  State<EventsScreenCreateModal> createState() =>
      _EventsScreenCreateModalState();
}

class _EventsScreenCreateModalState extends State<EventsScreenCreateModal> {
  final _titleCtrl = TextEditingController();
  final _locationCtrl = TextEditingController();
  final _priceCtrl = TextEditingController();
  final _capacityCtrl = TextEditingController();
  final _descriptionCtrl = TextEditingController();
  DateTime? _startDate;
  File? _eventImage;
  bool _isSubmitting = false;

  double? _tryParsePrice(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return 0;

    var s = trimmed.replaceAll(RegExp(r'[^0-9,\.-]'), '');
    if (s.isEmpty) return null;

    // Handle common locale formats:
    // - "200,50" -> 200.50
    // - "1.234,50" -> 1234.50
    // - "1,234.50" -> 1234.50
    final lastComma = s.lastIndexOf(',');
    final lastDot = s.lastIndexOf('.');
    if (lastComma != -1 && lastDot != -1) {
      if (lastComma > lastDot) {
        // dot thousands, comma decimals
        s = s.replaceAll('.', '');
        s = s.replaceAll(',', '.');
      } else {
        // comma thousands, dot decimals
        s = s.replaceAll(',', '');
      }
    } else if (lastComma != -1) {
      s = s.replaceAll(',', '.');
    }

    final value = double.tryParse(s);
    if (value == null) return null;
    if (value.isNaN || value.isInfinite || value < 0) return null;
    return value;
  }

  @override
  void initState() {
    super.initState();
    _startDate = DateTime.now().add(const Duration(days: 1));
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _locationCtrl.dispose();
    _priceCtrl.dispose();
    _capacityCtrl.dispose();
    _descriptionCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickEventImage() async {
    if (_isSubmitting) return;
    try {
      final picker = ImagePicker();
      final image = await picker.pickImage(source: ImageSource.gallery);
      if (!mounted) return;
      if (image != null) {
        setState(() {
          _eventImage = File(image.path);
        });
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not pick image: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _pickDateTime() async {
    if (_isSubmitting) return;
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: _startDate ?? now,
      firstDate: now,
      lastDate: DateTime(now.year + 3),
    );
    if (!mounted) return;
    if (date == null) return;

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_startDate ?? now),
    );
    if (!mounted) return;
    if (time == null) return;

    setState(() {
      _startDate = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      );
    });
  }

  Widget _buildTextField(
    TextEditingController c,
    String hint, {
    int maxLines = 1,
    TextInputType keyboard = TextInputType.text,
  }) {
    return TextField(
      controller: c,
      maxLines: maxLines,
      keyboardType: keyboard,
      inputFormatters: keyboard == TextInputType.text
          ? null
          : <TextInputFormatter>[
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
            ],
      style: const TextStyle(color: Color(0xFFB8B8C0)),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: Colors.white38),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.05),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Colors.white24),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF00FF41), width: 2),
        ),
      ),
    );
  }

  Future<void> _createEvent() async {
    print('DEBUG: _createEvent called');
    if (_titleCtrl.text.isEmpty || _startDate == null) {
      print(
        'DEBUG: Validation failed - title: ${_titleCtrl.text}, date: $_startDate',
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Title and date/time are required'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }
    try {
      setState(() {
        _isSubmitting = true;
      });
      print('DEBUG: Starting event creation');
      final parsedPrice = _tryParsePrice(_priceCtrl.text);
      if (parsedPrice == null) {
        if (mounted) {
          setState(() {
            _isSubmitting = false;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Please enter a valid ticket price (numbers only) or leave it empty for free.',
              ),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }
      final price = parsedPrice;
      final capacity = int.tryParse(_capacityCtrl.text) ?? 0;
      print('DEBUG: price=$price, capacity=$capacity');

      String imageUrl = '';
      if (_eventImage != null) {
        print('DEBUG: Uploading image...');
        final ref = FirebaseStorage.instance.ref(
          'event_images/${DateTime.now().millisecondsSinceEpoch}',
        );
        await ref.putFile(_eventImage!);
        imageUrl = await ref.getDownloadURL();
        print('DEBUG: Image uploaded: $imageUrl');
      }

      print('DEBUG: Adding to Firestore...');
      await FirebaseFirestore.instance.collection('events').add({
        'title': _titleCtrl.text.trim(),
        'location': _locationCtrl.text.trim(),
        'price': price,
        'capacity': capacity,
        'ticketsSold': 0,
        'description': _descriptionCtrl.text.trim(),
        'imageUrl': imageUrl,
        'startAt': Timestamp.fromDate(_startDate!),
        'createdAt': Timestamp.now(),
      });
      print('DEBUG: Event created successfully');
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      print('DEBUG: Error creating event: $e');
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not create event: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          'Create Event',
          style: TextStyle(
            color: Color(0xFFB8B8C0),
            fontWeight: FontWeight.bold,
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.close, color: Color(0xFFB8B8C0)),
          onPressed: _isSubmitting
              ? null
              : () => Navigator.of(context).pop(false),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GestureDetector(
                onTap: _pickEventImage,
                child: Container(
                  height: 150,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: _eventImage != null
                          ? const Color(0xFF00FF41)
                          : Colors.white24,
                      width: 2,
                    ),
                    color: Colors.white.withValues(alpha: 0.05),
                  ),
                  child: _eventImage != null
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Image.file(_eventImage!, fit: BoxFit.cover),
                        )
                      : const Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.image, color: Colors.white70, size: 40),
                            SizedBox(height: 8),
                            Text(
                              'Tap to pick event image',
                              style: TextStyle(color: Colors.white70),
                            ),
                          ],
                        ),
                ),
              ),
              const SizedBox(height: 16),
              _buildTextField(_titleCtrl, 'Title'),
              const SizedBox(height: 12),
              _buildTextField(_locationCtrl, 'Location'),
              const SizedBox(height: 12),
              _buildTextField(
                _priceCtrl,
                'Ticket price (numbers only, e.g. 200 or 200.50)',
                keyboard: const TextInputType.numberWithOptions(decimal: true),
              ),
              const SizedBox(height: 12),
              _buildTextField(
                _capacityCtrl,
                'Capacity (e.g. 500)',
                keyboard: TextInputType.number,
              ),
              const SizedBox(height: 12),
              _buildTextField(_descriptionCtrl, 'Description', maxLines: 3),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _startDate != null
                          ? 'Date: ${_startDate!.toLocal()}'
                          : 'Pick date & time',
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ),
                  TextButton(
                    onPressed: _pickDateTime,
                    child: const Text(
                      'Pick',
                      style: TextStyle(color: Color(0xFF00FF41)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _isSubmitting ? null : _createEvent,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00FF41),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Text(
                    _isSubmitting ? 'Creating…' : 'Create Event',
                    style: const TextStyle(
                      color: Colors.black,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}

// ==================== EVENT LIVE CHAT ====================

class EventChatScreen extends StatefulWidget {
  final String eventId;
  final String eventTitle;
  const EventChatScreen({super.key, required this.eventId, required this.eventTitle});

  @override
  State<EventChatScreen> createState() => _EventChatScreenState();
}

class _EventChatScreenState extends State<EventChatScreen> with SingleTickerProviderStateMixin {
  final _msgController = TextEditingController();
  String? _userCode;
  String? _userName;
  String? _userUid;
  late AnimationController _dotController;
  late Animation<double> _dotAnim;

  @override
  void initState() {
    super.initState();
    _dotController = AnimationController(vsync: this, duration: const Duration(milliseconds: 800))..repeat(reverse: true);
    _dotAnim = Tween<double>(begin: 0.3, end: 1.0).animate(_dotController);
    _loadUser();
  }

  @override
  void dispose() {
    _dotController.dispose();
    _msgController.dispose();
    super.dispose();
  }

  Future<void> _loadUser() async {
    final prefs = await SharedPreferences.getInstance();
    final code = prefs.getString('userReferralCode');
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (code == null) return;
    final snap = await FirebaseFirestore.instance
        .collection('applications')
        .where('referralCode', isEqualTo: code)
        .limit(1)
        .get();
    if (!mounted) return;
    setState(() {
      _userCode = code;
      _userUid = uid;
      _userName = snap.docs.isNotEmpty ? snap.docs.first.data()['name'] as String? : code;
    });
  }

  Future<void> _send() async {
    final text = _msgController.text.trim();
    if (text.isEmpty || _userCode == null) return;
    _msgController.clear();
    await FirebaseFirestore.instance
        .collection('events')
        .doc(widget.eventId)
        .collection('messages')
        .add({
      'senderCode': _userCode,
      'senderName': _userName ?? _userCode,
      'senderUid': _userUid ?? '',
      'text': text,
      'sentAt': FieldValue.serverTimestamp(),
    });
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance.collection('events').doc(widget.eventId).snapshots(),
      builder: (context, eventSnap) {
        final chatOpen = (eventSnap.data?.data() as Map<String, dynamic>?)?['chatOpen'] as bool? ?? false;
        return Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            iconTheme: const IconThemeData(color: Colors.white54),
            title: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FadeTransition(
                  opacity: _dotAnim,
                  child: Container(
                    width: 8, height: 8,
                    decoration: const BoxDecoration(color: Color(0xFF00FF41), shape: BoxShape.circle),
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    widget.eventTitle.toUpperCase(),
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Color(0xFF00FF41), fontSize: 14, fontWeight: FontWeight.bold, letterSpacing: 1.5),
                  ),
                ),
              ],
            ),
            centerTitle: true,
          ),
          body: Column(
            children: [
              if (!chatOpen)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  color: Colors.red.withValues(alpha: 0.15),
                  child: const Text('CHAT HAS ENDED', textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.red, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 2)),
                ),
              Expanded(
                child: StreamBuilder<QuerySnapshot>(
                  stream: FirebaseFirestore.instance
                      .collection('events')
                      .doc(widget.eventId)
                      .collection('messages')
                      .orderBy('sentAt', descending: true)
                      .limit(100)
                      .snapshots(),
                  builder: (context, snap) {
                    final docs = snap.data?.docs ?? [];
                    if (docs.isEmpty) {
                      return const Center(child: Text('CHANNEL SILENT — INITIATE TRANSMISSION',
                          style: TextStyle(color: Colors.white38, fontSize: 12, letterSpacing: 1.5, fontWeight: FontWeight.bold)));
                    }
                    return ListView.builder(
                      reverse: true,
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      itemCount: docs.length,
                      itemBuilder: (_, i) {
                        final d = docs[i].data() as Map<String, dynamic>;
                        final isMine = d['senderCode'] == _userCode;
                        final name = d['senderName'] as String? ?? '?';
                        final text = d['text'] as String? ?? '';
                        return Align(
                          alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
                          child: Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
                            decoration: BoxDecoration(
                              color: isMine
                                  ? const Color(0xFF00FF41).withValues(alpha: 0.15)
                                  : Colors.white.withValues(alpha: 0.07),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: isMine ? const Color(0xFF00FF41).withValues(alpha: 0.4) : Colors.white12,
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                              children: [
                                if (!isMine)
                                  Text(name.toUpperCase(),
                                      style: const TextStyle(color: Color(0xFF00FF41), fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1)),
                                Text(text, style: const TextStyle(color: Colors.white, fontSize: 14)),
                              ],
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
              if (chatOpen)
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    child: Row(children: [
                      Expanded(
                        child: TextField(
                          controller: _msgController,
                          style: const TextStyle(color: Colors.white, fontSize: 14),
                          decoration: InputDecoration(
                            hintText: 'Message...',
                            hintStyle: const TextStyle(color: Colors.white38),
                            filled: true,
                            fillColor: Colors.white.withValues(alpha: 0.06),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                          ),
                          onSubmitted: (_) => _send(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: _send,
                        child: Container(
                          width: 40, height: 40,
                          decoration: const BoxDecoration(color: Color(0xFF00FF41), shape: BoxShape.circle),
                          child: const Icon(Icons.send, color: Colors.black, size: 18),
                        ),
                      ),
                    ]),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _LiveChatButton extends StatefulWidget {
  final String eventId;
  final String eventTitle;
  const _LiveChatButton({required this.eventId, required this.eventTitle});

  @override
  State<_LiveChatButton> createState() => _LiveChatButtonState();
}

class _LiveChatButtonState extends State<_LiveChatButton> with SingleTickerProviderStateMixin {
  late AnimationController _pulse;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 800))..repeat(reverse: true);
    _anim = Tween<double>(begin: 0.3, end: 1.0).animate(_pulse);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.push(context, MaterialPageRoute(
          builder: (_) => EventChatScreen(eventId: widget.eventId, eventTitle: widget.eventTitle))),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: const Color(0xFF00FF41).withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFF00FF41), width: 1.5),
        ),
        child: Row(children: [
          FadeTransition(
            opacity: _anim,
            child: Container(
              width: 10, height: 10,
              decoration: const BoxDecoration(color: Color(0xFF00FF41), shape: BoxShape.circle),
            ),
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Text('JOIN LIVE CHAT',
                style: TextStyle(color: Color(0xFF00FF41), fontSize: 14, fontWeight: FontWeight.bold, letterSpacing: 2)),
          ),
          const Icon(Icons.chat_bubble_outline, color: Color(0xFF00FF41), size: 18),
        ]),
      ),
    );
  }
}

// ==================== EVENTS SCREEN ====================
class EventsScreen extends StatefulWidget {
  final bool isAdmin;
  const EventsScreen({super.key, this.isAdmin = false});

  @override
  State<EventsScreen> createState() => _EventsScreenState();
}

class _EventsScreenState extends State<EventsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        title: const TekWordmark(fontSize: 24, letterSpacing: 5.5),
      ),
      floatingActionButton: widget.isAdmin
          ? FloatingActionButton(
              backgroundColor: const Color(0xFF00FF41),
              onPressed: () async {
                try {
                  final created = await Navigator.of(context).push<bool>(
                    MaterialPageRoute(
                      builder: (_) => const EventsScreenCreateModal(),
                    ),
                  );
                  if (!mounted) return;
                  if (created == true) {
                    AppUtils.showSuccess(context, 'Event created');
                  }
                } catch (_) {
                  // Ignore navigation errors if the route stack changes.
                }
              },
              child: const Icon(Icons.add, color: Colors.black),
            )
          : null,
      body: Column(
        children: [
          Container(
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: Colors.white10, width: 1),
              ),
            ),
            child: TabBar(
              controller: _tabController,
              tabs: const [
                Tab(text: 'UPCOMING EVENTS'),
                Tab(text: 'PREVIOUS EVENTS'),
              ],
              labelColor: Colors.white,
              unselectedLabelColor: Colors.white70,
              labelStyle: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 1,
              ),
              indicatorColor: const Color(0xFF00FF41),
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildEventStream(upcoming: true),
                _buildEventStream(upcoming: false),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEventStream({required bool upcoming}) {
    final now = DateTime.now();
    final query = FirebaseFirestore.instance
        .collection('events')
        .orderBy('startAt');

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: query.snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const SkeletonList(itemHeight: 200);
        }
        if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
          return const Center(
            child: Text(
              'TRANSMISSION SILENT — STAND BY',
              style: TextStyle(color: Color(0xFF00FF41), fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 2),
            ),
          );
        }

        final docs = snapshot.data!.docs.where((doc) {
          final ts = doc.data()['startAt'] as Timestamp?;
          final start = ts?.toDate();
          if (start == null) return false;
          return upcoming ? start.isAfter(now) : start.isBefore(now);
        }).toList();

        if (docs.isEmpty) {
          return Center(
            child: Text(
              upcoming ? 'NO UPCOMING TRANSMISSIONS' : 'NO PREVIOUS OPS LOGGED',
              style: const TextStyle(color: Colors.white70),
            ),
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 16),
          physics: const BouncingScrollPhysics(),
          itemCount: docs.length,
          itemBuilder: (context, index) {
            final doc = docs[index];
            final data = doc.data();
            final start = (data['startAt'] as Timestamp).toDate();
            final dateLabel =
                '${start.day} ${_monthName(start.month)} · ${start.hour.toString().padLeft(2, '0')}:${start.minute.toString().padLeft(2, '0')}';
            return StaggeredItem(
              index: index,
              child: _buildEventCard(data, doc.id, dateLabel),
            );
          },
        );
      },
    );
  }

  Widget _buildEventCard(
    Map<String, dynamic> data,
    String id,
    String dateLabel,
  ) {
    final rawPrice = data['price'];
    final price = rawPrice is num
        ? rawPrice.toDouble()
        : double.tryParse(rawPrice?.toString() ?? '') ?? 0.0;
    final currency = (data['currency'] ?? 'sek').toString().toUpperCase();
    final priceLabel = price <= 0
        ? 'FREE'
        : '${price.toStringAsFixed(price.truncateToDouble() == price ? 0 : 2)} $currency';

    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        Navigator.push(
          context,
          cinematicRoute(EventDetailScreen(eventId: id, eventData: data)),
        );
      },
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white10),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.5),
              blurRadius: 10,
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Stack(
            children: [
              Container(
                height: 150,
                color: Colors.grey[900],
                child:
                    data['imageUrl'] != null &&
                        data['imageUrl'].toString().isNotEmpty
                    ? Hero(
                        tag: 'event-img-$id',
                        child: FadeInNetImage(
                          url: data['imageUrl'],
                          fit: BoxFit.cover,
                          width: double.infinity,
                          height: 150,
                        ),
                      )
                    : const Icon(Icons.image, color: Colors.white30, size: 50),
              ),
              Positioned(
                top: 10,
                right: 10,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.65),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: Colors.white10),
                  ),
                  child: Text(
                    priceLabel,
                    style: const TextStyle(
                      color: Color(0xFFB8B8C0),
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ),
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.7),
                        Colors.black.withValues(alpha: 0.3),
                        Colors.transparent,
                      ],
                    ),
                  ),
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        data['title'] ?? 'Event',
                        style: const TextStyle(
                          color: Color(0xFFB8B8C0),
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        dateLabel,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 4),
                      if (data['location'] != null)
                        Text(
                          data['location'],
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _monthName(int m) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return months[m - 1];
  }
}

// ==================== EVENT DETAIL SCREEN ====================
class EventDetailScreen extends StatefulWidget {
  final String eventId;
  final Map<String, dynamic> eventData;

  const EventDetailScreen({
    super.key,
    required this.eventId,
    required this.eventData,
  });

  @override
  State<EventDetailScreen> createState() => _EventDetailScreenState();
}

class _EventDetailScreenState extends State<EventDetailScreen> {
  bool _loading = false;
  String? _userCode;
  Set<String> _completedIds = {};
  bool _isAdmin = false;

  @override
  void initState() {
    super.initState();
    _loadUserData();
    _checkAdmin();
  }

  Future<void> _checkAdmin() async {
    final admin = await AdminStatusManager.instance.isCurrentUserAdmin();
    if (mounted) setState(() => _isAdmin = admin);
  }

  Future<void> _loadUserData() async {
    final prefs = await SharedPreferences.getInstance();
    final code = prefs.getString('userReferralCode');
    if (!mounted) return;
    setState(() => _userCode = code);
    if (code == null) return;
    final snap = await FirebaseFirestore.instance
        .collection('applications')
        .where('referralCode', isEqualTo: code)
        .limit(1)
        .get();
    if (!mounted || snap.docs.isEmpty) return;
    final completed =
        (snap.docs.first.data()['completedSidequests'] as List?)
            ?.cast<String>()
            .toSet() ??
        {};
    setState(() => _completedIds = completed);
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.eventData;
    final start = (data['startAt'] as Timestamp?)?.toDate();
    final capacity = (data['capacity'] ?? 0) as int;
    final sold = (data['ticketsSold'] ?? 0) as int;
    final remaining = capacity > 0 ? capacity - sold : null;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Color(0xFFB8B8C0)),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (data['imageUrl'] != null &&
                data['imageUrl'].toString().isNotEmpty)
              Hero(
                tag: 'event-img-${widget.eventId}',
                child: FadeInNetImage(
                  url: data['imageUrl'],
                  width: double.infinity,
                  height: 220,
                  fit: BoxFit.cover,
                  borderRadius: BorderRadius.circular(12),
                ),
              )
            else
              Container(
                height: 180,
                margin: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white10),
                  color: Colors.grey[900],
                ),
                child: const Center(
                  child: Icon(Icons.image, color: Colors.white30, size: 60),
                ),
              ),
            const SizedBox(height: 20),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    data['title'] ?? 'Event',
                    style: const TextStyle(
                      color: Color(0xFFB8B8C0),
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (start != null)
                    Text(
                      DateFormat('EEE, MMM d · HH:mm').format(start),
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 14,
                      ),
                    ),
                  if (data['location'] != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      data['location'],
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 14,
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  if (data['description'] != null &&
                      data['description'].toString().isNotEmpty)
                    Text(
                      data['description'],
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 14,
                      ),
                    ),
                  const SizedBox(height: 12),
                  Text(
                    'Price: ${data['price'] ?? 0}',
                    style: const TextStyle(
                      color: Color(0xFFB8B8C0),
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (remaining != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Remaining: $remaining / $capacity',
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ],
                  const SizedBox(height: 20),
                  StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                    stream: FirebaseAuth.instance.currentUser == null
                        ? null
                        : FirebaseFirestore.instance
                              .collection('users')
                              .doc(FirebaseAuth.instance.currentUser!.uid)
                              .collection('tickets')
                              .where('eventId', isEqualTo: widget.eventId)
                              .limit(1)
                              .snapshots(),
                    builder: (context, snapshot) {
                      final hasTicket =
                          (snapshot.data?.docs.isNotEmpty ?? false);
                      final ownedTicketId = hasTicket
                          ? snapshot.data!.docs.first.id
                          : '';
                      final buttonLabel = hasTicket
                          ? 'SHOW TICKET'
                          : 'GET TICKET';

                      return SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: _loading
                              ? null
                              : (hasTicket
                                    ? () => AppUtils.showTicketPass(
                                        context,
                                        eventTitle: (data['title'] ?? 'Event')
                                            .toString(),
                                        ticketCode: ownedTicketId,
                                        startAt: start,
                                        location: (data['location'] ?? '')
                                            .toString(),
                                      )
                                    : _purchaseTicket),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF00FF41),
                            minimumSize: const Size(double.infinity, 50),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: _loading
                              ? const SizedBox(
                                  height: 18,
                                  width: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.black,
                                  ),
                                )
                              : Text(
                                  buttonLabel,
                                  style: const TextStyle(
                                    color: Colors.black,
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 1,
                                  ),
                                ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 12),
                  if (_userCode == null)
                    const Text(
                      'Login to purchase tickets.',
                      style: TextStyle(color: Colors.redAccent),
                    ),
                  const SizedBox(height: 16),
                  _EventMissionsSection(
                    eventId: widget.eventId,
                    userCode: _userCode,
                    completedIds: _completedIds,
                  ),
                  const SizedBox(height: 16),
                  _GoingSection(
                    eventId: widget.eventId,
                    userCode: _userCode,
                  ),
                  const SizedBox(height: 16),
                  _CheckInSection(
                    eventId: widget.eventId,
                    userCode: _userCode,
                  ),
                  if (data['chatOpen'] == true) ...[
                    const SizedBox(height: 16),
                    _LiveChatButton(
                      eventId: widget.eventId,
                      eventTitle: (data['title'] ?? '').toString(),
                    ),
                  ],
                  if (_isAdmin) ...[
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: () => FirebaseFirestore.instance
                          .collection('events')
                          .doc(widget.eventId)
                          .update({'chatOpen': !(data['chatOpen'] == true)}),
                      icon: Icon(
                        data['chatOpen'] == true ? Icons.chat_bubble : Icons.chat_bubble_outline,
                        color: const Color(0xFF00FF41), size: 16),
                      label: Text(
                        data['chatOpen'] == true ? 'CLOSE LIVE CHAT' : 'OPEN LIVE CHAT',
                        style: const TextStyle(color: Color(0xFF00FF41), fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Color(0xFF00FF41)),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Future<void> _purchaseTicket() async {
    // Extra guard against rapid double-taps before the button rebuilds disabled.
    if (_loading) return;
    if (FirebaseAuth.instance.currentUser == null) {
      AppUtils.showError(context, 'Please try again (auth not ready)');
      return;
    }
    setState(() => _loading = true);
    try {
      Obs.logEvent('ticket_purchase_started', {'event_id': widget.eventId});
      final functions = FirebaseFunctions.instanceFor(region: 'us-central1');

      final createIntent = functions.httpsCallable(
        'createEventTicketPaymentIntent',
      );
      final createResult = await createIntent.call({
        'eventId': widget.eventId,
        'quantity': 1,
      });
      final createData = Map<String, dynamic>.from(createResult.data as Map);
      final isFree = createData['free'] == true;

      String? paymentIntentId;
      if (!isFree) {
        final clientSecret = (createData['clientSecret'] ?? '').toString();
        paymentIntentId = (createData['paymentIntentId'] ?? '').toString();
        if (clientSecret.isEmpty || paymentIntentId.isEmpty) {
          throw Exception('Missing payment info');
        }

        await stripe.Stripe.instance.initPaymentSheet(
          paymentSheetParameters: stripe.SetupPaymentSheetParameters(
            merchantDisplayName: 'TEK',
            paymentIntentClientSecret: clientSecret,
            style: ThemeMode.dark,
            allowsDelayedPaymentMethods: true,
          ),
        );

        await stripe.Stripe.instance.presentPaymentSheet();
      }

      final finalize = functions.httpsCallable('finalizeEventTicketPurchase');
      await finalize.call({
        'eventId': widget.eventId,
        'quantity': 1,
        'free': isFree,
        if (!isFree) 'paymentIntentId': paymentIntentId,
      });

      Obs.logEvent('ticket_purchase_succeeded', {
        'event_id': widget.eventId,
        'free': isFree,
      });

      if (mounted) {
        AppUtils.showSuccess(context, 'Ticket secured');
        Navigator.pop(context);
      }
    } on stripe.StripeException catch (e) {
      // User cancel shows up here too.
      AppUtils.showError(context, e.error.message ?? 'Payment cancelled');
    } catch (e) {
      AppUtils.showError(context, 'Could not get ticket: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }
}

// ==================== EVENT-SCOPED MISSIONS ====================

class _EventMissionsSection extends StatelessWidget {
  final String eventId;
  final String? userCode;
  final Set<String> completedIds;

  const _EventMissionsSection({
    required this.eventId,
    required this.userCode,
    required this.completedIds,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('sidequests')
          .where('eventId', isEqualTo: eventId)
          .where('active', isEqualTo: true)
          .snapshots(),
      builder: (context, snapshot) {
        final docs = snapshot.data?.docs ?? [];
        if (docs.isEmpty) return const SizedBox.shrink();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Divider(color: Colors.white10),
            const SizedBox(height: 12),
            const Text(
              'EVENT MISSIONS',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 11,
                fontWeight: FontWeight.bold,
                letterSpacing: 2,
              ),
            ),
            const SizedBox(height: 10),
            ...docs.map((doc) {
              final data = doc.data() as Map<String, dynamic>;
              final title = data['title'] as String? ?? '';
              final xp = (data['xpReward'] as num?)?.toInt() ?? 0;
              final done = completedIds.contains(doc.id);
              return GestureDetector(
                onTap: () {
                  HapticFeedback.lightImpact();
                  Navigator.push(
                    context,
                    cinematicRoute(SidequestDetailPage(
                        questId: doc.id,
                        data: data,
                        userCode: userCode,
                        completed: done,
                      )),
                  );
                },
                child: Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: done
                        ? Colors.white.withOpacity(0.03)
                        : const Color(0xFF00FF41).withOpacity(0.06),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: done
                          ? Colors.white10
                          : const Color(0xFF00FF41).withOpacity(0.3),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        done ? Icons.check_circle : Icons.bolt,
                        color: done
                            ? Colors.white24
                            : const Color(0xFF00FF41),
                        size: 18,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          title,
                          style: TextStyle(
                            color:
                                done ? Colors.white38 : Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: const Color(0xFF00FF41).withOpacity(0.1),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          '+$xp XP',
                          style: const TextStyle(
                            color: Color(0xFF00FF41),
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
          ],
        );
      },
    );
  }
}

// ==================== EVENT GOING (RSVP) ====================

class _GoingSection extends StatefulWidget {
  final String eventId;
  final String? userCode;
  const _GoingSection({required this.eventId, required this.userCode});

  @override
  State<_GoingSection> createState() => _GoingSectionState();
}

class _GoingSectionState extends State<_GoingSection> {
  bool _saving = false;

  Future<void> _toggle(bool currentlyGoing) async {
    if (widget.userCode == null) return;
    setState(() => _saving = true);
    HapticFeedback.lightImpact();
    final ref = FirebaseFirestore.instance
        .collection('events')
        .doc(widget.eventId)
        .collection('rsvps')
        .doc(widget.userCode);
    try {
      if (currentlyGoing) {
        await ref.delete();
      } else {
        final appSnap = await FirebaseFirestore.instance
            .collection('applications')
            .where('referralCode', isEqualTo: widget.userCode)
            .limit(1)
            .get();
        final appData = appSnap.docs.isNotEmpty ? appSnap.docs.first.data() : <String, dynamic>{};
        await ref.set({
          'userCode': widget.userCode,
          'userName': appData['name'] ?? widget.userCode,
          'profileImageUrl': appData['profileImageUrl'] ?? '',
          'rsvpedAt': FieldValue.serverTimestamp(),
        });
      }
    } catch (_) {}
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.userCode == null) return const SizedBox.shrink();
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('events')
          .doc(widget.eventId)
          .collection('rsvps')
          .snapshots(),
      builder: (context, snap) {
        final docs = snap.data?.docs ?? [];
        final iAmGoing = docs.any((d) => d.id == widget.userCode);
        return Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF00FF41).withValues(alpha: 0.3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Icon(Icons.people_alt, color: Color(0xFF00FF41), size: 14),
                const SizedBox(width: 6),
                const Text('GOING',
                    style: TextStyle(color: Color(0xFF00FF41), fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 2)),
                const Spacer(),
                Text('${docs.length}',
                    style: const TextStyle(color: Color(0xFF00FF41), fontSize: 12, fontWeight: FontWeight.bold)),
              ]),
              const SizedBox(height: 10),
              if (docs.isEmpty)
                const Text('AWAITING FIRST RSVP', style: TextStyle(color: Color(0xFF00FF41), fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.5))
              else
                SizedBox(
                  height: 44,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    physics: const BouncingScrollPhysics(),
                    itemCount: docs.length > 24 ? 24 : docs.length,
                    itemBuilder: (_, i) {
                      final d = docs[i].data() as Map<String, dynamic>;
                      final url = (d['profileImageUrl'] as String? ?? '');
                      final name = (d['userName'] as String? ?? '?');
                      return Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: url.isNotEmpty
                            ? FadeInNetImage(url: url, avatarSize: 38)
                            : Container(
                                width: 38, height: 38,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: const Color(0xFF00FF41).withValues(alpha: 0.15),
                                  border: Border.all(color: const Color(0xFF00FF41), width: 1),
                                ),
                                child: Center(
                                  child: Text(name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase(),
                                      style: const TextStyle(color: Color(0xFF00FF41), fontWeight: FontWeight.bold)),
                                ),
                              ),
                      );
                    },
                  ),
                ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _saving ? null : () => _toggle(iAmGoing),
                  icon: Icon(iAmGoing ? Icons.check_circle : Icons.celebration,
                      color: iAmGoing ? Colors.black : const Color(0xFF00FF41), size: 18),
                  label: Text(iAmGoing ? "I'M GOING" : "I'M GOING",
                      style: TextStyle(
                          color: iAmGoing ? Colors.black : const Color(0xFF00FF41),
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 2)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: iAmGoing ? const Color(0xFF00FF41) : Colors.transparent,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                      side: const BorderSide(color: Color(0xFF00FF41), width: 1.5),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ==================== EVENT CHECK-IN ====================

class _CheckInSection extends StatefulWidget {
  final String eventId;
  final String? userCode;

  const _CheckInSection({required this.eventId, required this.userCode});

  @override
  State<_CheckInSection> createState() => _CheckInSectionState();
}

class _CheckInSectionState extends State<_CheckInSection> {
  bool _checkedIn = false;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    if (widget.userCode != null) _loadStatus();
  }

  Future<void> _loadStatus() async {
    final snap = await FirebaseFirestore.instance
        .collection('events')
        .doc(widget.eventId)
        .collection('checkins')
        .doc(widget.userCode)
        .get();
    if (mounted) setState(() => _checkedIn = snap.exists);
  }

  Future<void> _toggle() async {
    if (widget.userCode == null) return;
    setState(() => _checking = true);
    try {
      final docRef = FirebaseFirestore.instance
          .collection('events')
          .doc(widget.eventId)
          .collection('checkins')
          .doc(widget.userCode);

      if (_checkedIn) {
        await docRef.delete();
        setState(() => _checkedIn = false);
      } else {
        final appSnap = await FirebaseFirestore.instance
            .collection('applications')
            .where('referralCode', isEqualTo: widget.userCode)
            .limit(1)
            .get();
        final appData =
            appSnap.docs.isNotEmpty ? appSnap.docs.first.data() : {};
        await docRef.set({
          'userCode': widget.userCode,
          'userName': appData['name'] ?? 'Unknown',
          'profileImageUrl': appData['profileImageUrl'],
          'checkedInAt': FieldValue.serverTimestamp(),
        });
        Obs.logEvent('event_checkin', {'event_id': widget.eventId});
        setState(() => _checkedIn = true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.userCode == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(color: Colors.white10),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _checking ? null : _toggle,
            icon: Icon(
              _checkedIn ? Icons.location_on : Icons.location_off,
              size: 16,
              color: _checkedIn ? const Color(0xFF00FF41) : Colors.white54,
            ),
            label: Text(
              _checkedIn ? 'CHECKED IN' : 'CHECK IN',
              style: TextStyle(
                color: _checkedIn ? const Color(0xFF00FF41) : Colors.white54,
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 1,
              ),
            ),
            style: OutlinedButton.styleFrom(
              side: BorderSide(
                color: _checkedIn
                    ? const Color(0xFF00FF41).withOpacity(0.5)
                    : Colors.white24,
              ),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),
        const SizedBox(height: 16),
        StreamBuilder<QuerySnapshot>(
          stream: FirebaseFirestore.instance
              .collection('events')
              .doc(widget.eventId)
              .collection('checkins')
              .snapshots(),
          builder: (context, snapshot) {
            final docs = snapshot.data?.docs ?? [];
            if (docs.isEmpty) return const SizedBox.shrink();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${docs.length} AT THIS EVENT',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.5,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: docs.map((doc) {
                    final d = doc.data() as Map<String, dynamic>;
                    final imgUrl = d['profileImageUrl'] as String?;
                    final name = (d['userName'] as String? ?? '?');
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircleAvatar(
                          radius: 22,
                          backgroundColor: Colors.white10,
                          backgroundImage: imgUrl != null
                              ? NetworkImage(imgUrl)
                              : null,
                          child: imgUrl == null
                              ? Text(
                                  name.isNotEmpty
                                      ? name[0].toUpperCase()
                                      : '?',
                                  style: const TextStyle(
                                    color: Color(0xFF00FF41),
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                  ),
                                )
                              : null,
                        ),
                        const SizedBox(height: 4),
                        SizedBox(
                          width: 48,
                          child: Text(
                            name.split(' ').first,
                            textAlign: TextAlign.center,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 9,
                            ),
                          ),
                        ),
                      ],
                    );
                  }).toList(),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

// ==================== CHAT SCREEN ====================
class ChatScreen extends StatefulWidget {
  final String friendCode;
  final String friendName;
  final String? friendImageUrl;

  const ChatScreen({
    super.key,
    required this.friendCode,
    required this.friendName,
    this.friendImageUrl,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _messageController = TextEditingController();
  String? _currentUserCode;
  String? _chatId;
  bool _isBlocked = false;
  bool _isCheckingBlockState = true;
  bool _sendingPhoto = false;

  Future<void> _sendPhotoMessage() async {
    if (_chatId == null || _isBlocked || _currentUserCode == null) return;
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery, maxWidth: 1280, maxHeight: 1280, imageQuality: 80);
    if (picked == null) return;
    setState(() => _sendingPhoto = true);
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
      final ts = DateTime.now().millisecondsSinceEpoch;
      final ref = FirebaseStorage.instance.ref('chat_photos/$_chatId/${ts}_$uid.jpg');
      await ref.putFile(File(picked.path));
      final url = await ref.getDownloadURL();
      final expiresAt = DateTime.now().add(const Duration(hours: 24));
      await FirebaseFirestore.instance
          .collection('chats')
          .doc(_chatId!)
          .collection('messages')
          .add({
        'senderUid': uid,
        'senderCode': _currentUserCode,
        'senderName': '',
        'message': '',
        'photoUrl': url,
        'timestamp': Timestamp.now(),
        'expiresAt': Timestamp.fromDate(expiresAt),
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Photo upload failed: $e'),
          backgroundColor: Colors.red,
        ));
      }
    } finally {
      if (mounted) setState(() => _sendingPhoto = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _initializeChat();
  }

  Future<void> _initializeChat() async {
    final prefs = await SharedPreferences.getInstance();
    final userCode = prefs.getString('userReferralCode');
    if (userCode != null && mounted) {
      setState(() {
        _currentUserCode = userCode;
        // Create a consistent chat ID by sorting the codes
        final codes = [userCode, widget.friendCode];
        codes.sort();
        _chatId = '${codes[0]}_${codes[1]}';
      });
    }
    await _refreshBlockState();
  }

  Future<void> _refreshBlockState() async {
    try {
      final isBlocked = await _areUsersBlocked(
        currentUserCode: _currentUserCode,
        targetCode: widget.friendCode,
      );
      if (!mounted) return;
      setState(() {
        _isBlocked = isBlocked;
        _isCheckingBlockState = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isCheckingBlockState = false;
      });
      debugPrint('Error checking chat block state: $e');
    }
  }

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _sendMessage() async {
    if (_messageController.text.trim().isEmpty) return;
    if (_isBlocked) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'You cannot message this user because one of you has blocked the other.',
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    try {
      final currentUid = FirebaseAuth.instance.currentUser?.uid;
      if (currentUid == null || currentUid.isEmpty) {
        throw Exception('Not signed in');
      }

      final messageText = _messageController.text.trim();
      if (containsProhibitedContent(messageText)) {
        throw Exception(
          'Please remove abusive or explicit language before sending.',
        );
      }

      final blockedNow = await _areUsersBlocked(
        currentUserCode: _currentUserCode,
        targetCode: widget.friendCode,
      );
      if (blockedNow) {
        if (mounted) {
          setState(() {
            _isBlocked = true;
          });
        }
        throw Exception(
          'Messaging is unavailable because this conversation is blocked.',
        );
      }

      _messageController.clear();

      // Create 24-hour expiry timestamp
      final expiresAt = DateTime.now().add(const Duration(hours: 24));

      await FirebaseFirestore.instance
          .collection('chats')
          .doc(_chatId!)
          .collection('messages')
          .add({
            'senderUid': currentUid,
            'senderCode': _currentUserCode,
            'senderName': '', // Will be populated from user doc
            'message': messageText,
            'timestamp': Timestamp.now(),
            'expiresAt': Timestamp.fromDate(expiresAt),
          });
      Obs.logEvent('chat_message_sent', {'surface': 'friend_chat'});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error sending message: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Widget _buildFriendPortal(double size) {
    final portalSize = size + 36;
    return SizedBox(
      width: portalSize,
      height: portalSize,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Outer green ambient glow
          Container(
            width: portalSize,
            height: portalSize,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF00FF41).withValues(alpha: 0.12),
                  blurRadius: 24,
                  spreadRadius: 3,
                ),
              ],
            ),
          ),
          // Outer chrome ring
          Container(
            width: portalSize - 2,
            height: portalSize - 2,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: const Color(0xFF7A7A7A).withValues(alpha: 0.5),
                width: 1.2,
              ),
            ),
          ),
          // Green energy ring
          Container(
            width: portalSize - 12,
            height: portalSize - 12,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: const Color(0xFF00FF41).withValues(alpha: 0.2),
                width: 0.8,
              ),
            ),
          ),
          // Inner chrome ring
          Container(
            width: portalSize - 22,
            height: portalSize - 22,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: const Color(0xFF8A8A8A).withValues(alpha: 0.35),
                width: 1.2,
              ),
            ),
          ),
          // Green glow border around image
          Container(
            width: size + 4,
            height: size + 4,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: const Color(0xFF00FF41).withValues(alpha: 0.35),
                width: 1.2,
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF00FF41).withValues(alpha: 0.1),
                  blurRadius: 8,
                  spreadRadius: 1,
                ),
              ],
            ),
          ),
          // The actual profile image
          ClipOval(
            child: SizedBox(
              width: size,
              height: size,
              child:
                  widget.friendImageUrl != null &&
                      widget.friendImageUrl!.isNotEmpty
                  ? Image.network(
                      widget.friendImageUrl!,
                      width: size,
                      height: size,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) => Container(
                        width: size,
                        height: size,
                        color: Colors.grey[800],
                        child: const Icon(
                          Icons.person,
                          color: Colors.white30,
                          size: 36,
                        ),
                      ),
                    )
                  : Container(
                      width: size,
                      height: size,
                      color: Colors.grey[800],
                      child: const Icon(
                        Icons.person,
                        color: Colors.white30,
                        size: 36,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_chatId == null || _chatId!.isEmpty || _isCheckingBlockState) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          title: Text(widget.friendName),
        ),
        body: const Center(
          child: CircularProgressIndicator(color: Color(0xFF00FF41)),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        toolbarHeight: 160,
        leading: Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: IconButton(
              icon: const Icon(Icons.arrow_back, color: Color(0xFFB8B8C0)),
              onPressed: () => Navigator.pop(context),
            ),
          ),
        ),
        title: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildFriendPortal(80),
            const SizedBox(height: 6),
            Text(
              widget.friendName,
              style: const TextStyle(
                color: Color(0xFFB8B8C0),
                fontSize: 16,
                fontWeight: FontWeight.bold,
                letterSpacing: 1,
              ),
            ),
          ],
        ),
        centerTitle: true,
        actions: [
          Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.only(top: 4, right: 4),
              child: IconButton(
                tooltip: 'Relay XP',
                icon: const Icon(Icons.bolt_outlined, color: Color(0xFF00FF41)),
                onPressed: _isBlocked
                    ? null
                    : () {
                        HapticFeedback.lightImpact();
                        showDialog(
                          context: context,
                          barrierDismissible: true,
                          builder: (_) => _RelayPowerDialog(
                            recipientCode: widget.friendCode,
                            recipientName: widget.friendName,
                          ),
                        );
                      },
              ),
            ),
          ),
          Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: PopupMenuButton<String>(
                onSelected: (value) {
                  if (value == 'report') {
                    _showReportDialog();
                  } else if (value == 'block') {
                    _showBlockDialog();
                  }
                },
                itemBuilder: (BuildContext context) => [
                  const PopupMenuItem<String>(
                    value: 'report',
                    child: Text('Report User'),
                  ),
                  const PopupMenuItem<String>(
                    value: 'block',
                    child: Text('Block User'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_isBlocked)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.12),
                border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Text(
                'This conversation is blocked. Messaging is disabled until the user is unblocked.',
                style: TextStyle(color: Colors.white70),
              ),
            ),
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('chats')
                  .doc(_chatId!)
                  .collection('messages')
                  .orderBy('timestamp', descending: true)
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(
                    child: CircularProgressIndicator(color: Color(0xFF00FF41)),
                  );
                }

                if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                  return Center(
                    child: Text(
                      'CHANNEL OPEN — TRANSMIT',
                      style: TextStyle(color: Colors.white70),
                    ),
                  );
                }

                final messages = snapshot.data!.docs;

                // Filter out expired messages
                final activeMessages = messages.where((doc) {
                  final data = doc.data() as Map<String, dynamic>;
                  final expiresAt = (data['expiresAt'] as Timestamp?)?.toDate();
                  return expiresAt == null || expiresAt.isAfter(DateTime.now());
                }).toList();

                if (activeMessages.isEmpty) {
                  return Center(
                    child: Text(
                      'CHANNEL OPEN — TRANSMIT',
                      style: TextStyle(color: Colors.white70),
                    ),
                  );
                }

                return ListView.builder(
                  reverse: true,
                  itemCount: activeMessages.length,
                  itemBuilder: (context, index) {
                    final msgData =
                        activeMessages[index].data() as Map<String, dynamic>;
                    final currentUid = FirebaseAuth.instance.currentUser?.uid;
                    final isMe =
                        (currentUid != null &&
                            msgData['senderUid'] == currentUid) ||
                        msgData['senderCode'] == _currentUserCode;
                    final timestamp = (msgData['timestamp'] as Timestamp)
                        .toDate();
                    final timeStr = DateFormat('HH:mm').format(timestamp);

                    return Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Row(
                        mainAxisAlignment: isMe
                            ? MainAxisAlignment.end
                            : MainAxisAlignment.start,
                        children: [
                          Container(
                            constraints: BoxConstraints(
                              maxWidth: MediaQuery.of(context).size.width * 0.7,
                            ),
                            decoration: BoxDecoration(
                              color: isMe
                                  ? const Color(0xFF00FF41)
                                  : Colors.white.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if ((msgData['photoUrl'] as String? ?? '').isNotEmpty)
                                  GestureDetector(
                                    onTap: () => Navigator.push(
                                      context,
                                      cinematicRoute(_FullscreenImageView(url: msgData['photoUrl'] as String)),
                                    ),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: ConstrainedBox(
                                        constraints: const BoxConstraints(maxHeight: 240),
                                        child: FadeInNetImage(
                                          url: msgData['photoUrl'] as String,
                                          fit: BoxFit.cover,
                                        ),
                                      ),
                                    ),
                                  ),
                                if ((msgData['message'] as String? ?? '').isNotEmpty) ...[
                                  if ((msgData['photoUrl'] as String? ?? '').isNotEmpty)
                                    const SizedBox(height: 6),
                                  Text(
                                    msgData['message'] ?? '',
                                    style: TextStyle(
                                      color: isMe ? Colors.black : Colors.white,
                                      fontSize: 14,
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 4),
                                Text(
                                  timeStr,
                                  style: TextStyle(
                                    color: isMe
                                        ? Colors.black54
                                        : Colors.white54,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: Colors.white10)),
            ),
            child: Row(
              children: [
                GestureDetector(
                  onTap: _isBlocked || _sendingPhoto ? null : _sendPhotoMessage,
                  child: Container(
                    width: 40,
                    height: 40,
                    margin: const EdgeInsets.only(right: 8),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withValues(alpha: 0.08),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: _sendingPhoto
                        ? const Center(
                            child: SizedBox(
                              width: 16, height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF00FF41)),
                            ),
                          )
                        : const Icon(Icons.photo_camera, color: Color(0xFF00FF41), size: 20),
                  ),
                ),
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    enabled: !_isBlocked,
                    style: const TextStyle(color: Color(0xFFB8B8C0)),
                    maxLines: 1,
                    decoration: InputDecoration(
                      hintText: _isBlocked
                          ? 'Messaging disabled'
                          : 'Type a message...',
                      hintStyle: const TextStyle(color: Colors.white38),
                      filled: true,
                      fillColor: Colors.white.withValues(alpha: 0.05),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: const BorderSide(color: Colors.white24),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: const BorderSide(color: Colors.white24),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: const BorderSide(
                          color: Color(0xFF00FF41),
                          width: 2,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: _isBlocked ? null : _sendMessage,
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _isBlocked
                          ? Colors.white24
                          : const Color(0xFF00FF41),
                    ),
                    child: const Icon(
                      Icons.send,
                      color: Colors.black,
                      size: 18,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showReportDialog() {
    final reasonController = TextEditingController();
    String selectedCategory = _ugcReportCategories.first;
    showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (sbContext, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF1a1a1a),
          title: const Text(
            'Report User',
            style: TextStyle(color: Color(0xFFB8B8C0)),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Tell us why you are reporting ${widget.friendName}. We review reports within 24 hours.',
                  style: const TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.white24),
                  ),
                  child: DropdownButton<String>(
                    value: selectedCategory,
                    dropdownColor: const Color(0xFF1a1a1a),
                    isExpanded: true,
                    underline: const SizedBox.shrink(),
                    style: const TextStyle(color: Color(0xFFB8B8C0)),
                    items: _ugcReportCategories
                        .map(
                          (category) => DropdownMenuItem<String>(
                            value: category,
                            child: Text(category),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value == null) return;
                      setDialogState(() {
                        selectedCategory = value;
                      });
                    },
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: reasonController,
                  maxLines: 4,
                  style: const TextStyle(color: Color(0xFFB8B8C0)),
                  decoration: InputDecoration(
                    hintText: 'Add details that will help our moderation team.',
                    hintStyle: const TextStyle(color: Colors.white38),
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: 0.05),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: Colors.white24),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: Colors.white24),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: Color(0xFF00FF41)),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text(
                'Cancel',
                style: TextStyle(color: Colors.white54),
              ),
            ),
            TextButton(
              onPressed: () {
                final details = reasonController.text.trim();
                Navigator.pop(dialogContext);
                _submitReport(category: selectedCategory, details: details);
              },
              child: const Text('Report', style: TextStyle(color: Colors.red)),
            ),
          ],
        ),
      ),
    );
  }

  void _showBlockDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Color(0xFF1a1a1a),
        title: const Text(
          'Block User',
          style: TextStyle(color: Color(0xFFB8B8C0)),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Block ${widget.friendName}?',
              style: const TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 12),
            const Text(
              'You won\'t be able to message them and they won\'t be able to message you.',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              'Cancel',
              style: TextStyle(color: Colors.white54),
            ),
          ),
          TextButton(
            onPressed: () {
              _blockUser();
              Navigator.pop(context);
            },
            child: const Text('Block', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  Future<void> _submitReport({
    required String category,
    required String details,
  }) async {
    try {
      final currentUid = FirebaseAuth.instance.currentUser?.uid;
      if (currentUid == null) return;

      await FirebaseFirestore.instance.collection('moderation_reports').add({
        'reportedUserCode': widget.friendCode,
        'reportedUserName': widget.friendName,
        'reporterUid': currentUid,
        'reporterCode': _currentUserCode,
        'category': category,
        'details': details,
        'source': 'chat',
        'chatId': _chatId,
        'type': 'user',
        'timestamp': Timestamp.now(),
        'status': 'pending',
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Report submitted. Thank you!'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error submitting report: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _blockUser() async {
    try {
      if ((_currentUserCode ?? '').isEmpty) return;
      await _blockReferralCode(
        currentUserCode: _currentUserCode!,
        targetCode: widget.friendCode,
      );

      if (mounted) {
        setState(() {
          _isBlocked = true;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${widget.friendName} has been blocked.'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error blocking user: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
}

// ==================== MANAGE EVENTS SCREEN ====================
class ManageEventsScreen extends StatefulWidget {
  const ManageEventsScreen({super.key});

  @override
  State<ManageEventsScreen> createState() => _ManageEventsScreenState();
}

class _ManageEventsScreenState extends State<ManageEventsScreen> {
  Stream<QuerySnapshot> _eventsStream({required bool upcoming}) {
    final base = FirebaseFirestore.instance.collection('events');
    final now = Timestamp.now();
    if (upcoming) {
      return base
          .where('startAt', isGreaterThanOrEqualTo: now)
          .orderBy('startAt')
          .snapshots();
    }
    return base
        .where('startAt', isLessThan: now)
        .orderBy('startAt', descending: true)
        .snapshots();
  }

  Widget _buildEventsList(QuerySnapshot snapshot) {
    if (snapshot.docs.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.event_busy, size: 80, color: Colors.white30),
            const SizedBox(height: 16),
            Text(
              'No events found',
              style: TextStyle(color: Colors.white70, fontSize: 16),
            ),
          ],
        ),
      );
    }

    final events = snapshot.docs;

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: events.length,
      itemBuilder: (context, index) {
        final event = events[index];
        final eventData = event.data() as Map<String, dynamic>;
        final startAt = (eventData['startAt'] as Timestamp).toDate();
        final isPast = startAt.isBefore(DateTime.now());
        final ticketsSold = eventData['ticketsSold'] ?? 0;
        final capacity = eventData['capacity'] ?? 0;

        return Card(
          color: Colors.white.withValues(alpha: 0.05),
          margin: const EdgeInsets.only(bottom: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: isPast
                  ? Colors.white24
                  : const Color(0xFF00FF41).withValues(alpha: 0.3),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                // Event Image
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    color: Colors.white.withValues(alpha: 0.1),
                  ),
                  child:
                      eventData['imageUrl'] != null &&
                          eventData['imageUrl'].toString().isNotEmpty
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.network(
                            eventData['imageUrl'],
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) {
                              return const Icon(
                                Icons.event,
                                size: 40,
                                color: Colors.white30,
                              );
                            },
                          ),
                        )
                      : const Icon(
                          Icons.event,
                          size: 40,
                          color: Colors.white30,
                        ),
                ),
                const SizedBox(width: 12),
                // Event Info
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        eventData['title'] ?? 'Untitled Event',
                        style: const TextStyle(
                          color: Color(0xFFB8B8C0),
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        DateFormat('MMM d, y • HH:mm').format(startAt),
                        style: TextStyle(
                          color: isPast ? Colors.white38 : Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '$ticketsSold / $capacity tickets sold',
                        style: const TextStyle(
                          color: Color(0xFF00FF41),
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (isPast)
                        Container(
                          margin: const EdgeInsets.only(top: 4),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white24,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            'PAST',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                // Action Buttons
                Column(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.edit, color: Color(0xFF00FF41)),
                      onPressed: () => _editEvent(event.id, eventData),
                      tooltip: 'Edit',
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete, color: Colors.red),
                      onPressed: () =>
                          _confirmDelete(event.id, eventData['title']),
                      tooltip: 'Delete',
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          centerTitle: true,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: Color(0xFFB8B8C0)),
            onPressed: () => Navigator.pop(context),
          ),
          title: const Text(
            'MANAGE EVENTS',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Color(0xFFB8B8C0),
              letterSpacing: 1,
            ),
          ),
          bottom: const TabBar(
            indicatorColor: Color(0xFF00FF41),
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white70,
            tabs: [
              Tab(text: 'UPCOMING'),
              Tab(text: 'PAST'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            StreamBuilder<QuerySnapshot>(
              stream: _eventsStream(upcoming: true),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(
                    child: CircularProgressIndicator(color: Color(0xFF00FF41)),
                  );
                }
                if (!snapshot.hasData) {
                  return const Center(
                    child: Text(
                      'No events found',
                      style: TextStyle(color: Colors.white70),
                    ),
                  );
                }
                return _buildEventsList(snapshot.data!);
              },
            ),
            StreamBuilder<QuerySnapshot>(
              stream: _eventsStream(upcoming: false),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(
                    child: CircularProgressIndicator(color: Color(0xFF00FF41)),
                  );
                }
                if (!snapshot.hasData) {
                  return const Center(
                    child: Text(
                      'No events found',
                      style: TextStyle(color: Colors.white70),
                    ),
                  );
                }
                return _buildEventsList(snapshot.data!);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _editEvent(String eventId, Map<String, dynamic> eventData) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => EditEventScreen(eventId: eventId, eventData: eventData),
      ),
    );
  }

  void _confirmDelete(String eventId, String? title) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Color(0xFF1A1A1A).withValues(alpha: 0.85),
        title: const Text(
          'Delete Event',
          style: TextStyle(color: Color(0xFFB8B8C0)),
        ),
        content: Text(
          'Are you sure you want to delete "${title ?? 'this event'}"?\n\nThis will also delete all associated tickets.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              'Cancel',
              style: TextStyle(color: Colors.white70),
            ),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _deleteEvent(eventId);
            },
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteEvent(String eventId) async {
    try {
      // Delete all tickets for this event
      final ticketsSnapshot = await FirebaseFirestore.instance
          .collection('events')
          .doc(eventId)
          .collection('tickets')
          .get();

      final batch = FirebaseFirestore.instance.batch();
      for (final ticket in ticketsSnapshot.docs) {
        batch.delete(ticket.reference);
      }

      // Delete the event
      batch.delete(
        FirebaseFirestore.instance.collection('events').doc(eventId),
      );

      await batch.commit();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Event deleted successfully'),
            backgroundColor: Color(0xFF00FF41),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error deleting event: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
}

// ==================== EDIT EVENT SCREEN ====================
class EditEventScreen extends StatefulWidget {
  final String eventId;
  final Map<String, dynamic> eventData;

  const EditEventScreen({
    super.key,
    required this.eventId,
    required this.eventData,
  });

  @override
  State<EditEventScreen> createState() => _EditEventScreenState();
}

class _EditEventScreenState extends State<EditEventScreen> {
  late TextEditingController _titleCtrl;
  late TextEditingController _locationCtrl;
  late TextEditingController _priceCtrl;
  late TextEditingController _capacityCtrl;
  late TextEditingController _descriptionCtrl;
  DateTime? _startDate;
  File? _eventImage;
  String? _existingImageUrl;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController(text: widget.eventData['title']);
    _locationCtrl = TextEditingController(text: widget.eventData['location']);
    _priceCtrl = TextEditingController(
      text: widget.eventData['price']?.toString() ?? '0',
    );
    _capacityCtrl = TextEditingController(
      text: widget.eventData['capacity']?.toString() ?? '0',
    );
    _descriptionCtrl = TextEditingController(
      text: widget.eventData['description'],
    );
    _startDate = (widget.eventData['startAt'] as Timestamp).toDate();
    _existingImageUrl = widget.eventData['imageUrl'];
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _locationCtrl.dispose();
    _priceCtrl.dispose();
    _capacityCtrl.dispose();
    _descriptionCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Color(0xFFB8B8C0)),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'EDIT EVENT',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: Color(0xFFB8B8C0),
            letterSpacing: 1,
          ),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Image Section
            GestureDetector(
              onTap: _pickImage,
              child: Container(
                width: double.infinity,
                height: 200,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: const Color(0xFF00FF41).withValues(alpha: 0.3),
                  ),
                ),
                child: _eventImage != null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.file(_eventImage!, fit: BoxFit.cover),
                      )
                    : _existingImageUrl != null && _existingImageUrl!.isNotEmpty
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.network(
                          _existingImageUrl!,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) {
                            return const Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.add_photo_alternate,
                                  size: 50,
                                  color: Colors.white38,
                                ),
                                SizedBox(height: 8),
                                Text(
                                  'Tap to change image',
                                  style: TextStyle(
                                    color: Colors.white38,
                                    fontSize: 14,
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      )
                    : const Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.add_photo_alternate,
                            size: 50,
                            color: Colors.white38,
                          ),
                          SizedBox(height: 8),
                          Text(
                            'Tap to add image',
                            style: TextStyle(
                              color: Colors.white38,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
              ),
            ),
            const SizedBox(height: 16),
            _buildTextField(_titleCtrl, 'Title'),
            const SizedBox(height: 12),
            _buildTextField(_locationCtrl, 'Location'),
            const SizedBox(height: 12),
            _buildTextField(_priceCtrl, 'Ticket price'),
            const SizedBox(height: 12),
            _buildTextField(
              _capacityCtrl,
              'Capacity',
              keyboard: TextInputType.number,
            ),
            const SizedBox(height: 12),
            _buildTextField(_descriptionCtrl, 'Description', maxLines: 3),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _startDate != null
                        ? 'Date: ${DateFormat('MMM d, y • HH:mm').format(_startDate!)}'
                        : 'Pick date & time',
                    style: const TextStyle(color: Colors.white70),
                  ),
                ),
                TextButton(
                  onPressed: _pickDateTime,
                  child: const Text(
                    'Change',
                    style: TextStyle(color: Color(0xFF00FF41)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: _isLoading ? null : _updateEvent,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00FF41),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: _isLoading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          color: Colors.black,
                          strokeWidth: 2,
                        ),
                      )
                    : const Text(
                        'Update Event',
                        style: TextStyle(
                          color: Colors.black,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTextField(
    TextEditingController c,
    String hint, {
    int maxLines = 1,
    TextInputType keyboard = TextInputType.text,
  }) {
    return TextField(
      controller: c,
      maxLines: maxLines,
      keyboardType: keyboard,
      style: const TextStyle(color: Color(0xFFB8B8C0)),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: Colors.white38),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.05),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Colors.white24),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF00FF41), width: 2),
        ),
      ),
    );
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: ImageSource.gallery);
    if (pickedFile != null) {
      setState(() {
        _eventImage = File(pickedFile.path);
      });
    }
  }

  Future<void> _pickDateTime() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _startDate ?? DateTime.now(),
      firstDate: DateTime.now(),
      lastDate: DateTime(DateTime.now().year + 3),
    );
    if (date != null) {
      final time = await showTimePicker(
        context: context,
        initialTime: TimeOfDay.fromDateTime(_startDate ?? DateTime.now()),
      );
      if (time != null) {
        setState(() {
          _startDate = DateTime(
            date.year,
            date.month,
            date.day,
            time.hour,
            time.minute,
          );
        });
      }
    }
  }

  Future<void> _updateEvent() async {
    if (_titleCtrl.text.isEmpty || _startDate == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Title and date/time are required'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      final price = double.tryParse(_priceCtrl.text) ?? 0;
      final capacity = int.tryParse(_capacityCtrl.text) ?? 0;

      String imageUrl = _existingImageUrl ?? '';
      if (_eventImage != null) {
        final ref = FirebaseStorage.instance.ref(
          'event_images/${DateTime.now().millisecondsSinceEpoch}',
        );
        await ref.putFile(_eventImage!);
        imageUrl = await ref.getDownloadURL();
      }

      await FirebaseFirestore.instance
          .collection('events')
          .doc(widget.eventId)
          .update({
            'title': _titleCtrl.text.trim(),
            'location': _locationCtrl.text.trim(),
            'price': price,
            'capacity': capacity,
            'description': _descriptionCtrl.text.trim(),
            'imageUrl': imageUrl,
            'startAt': Timestamp.fromDate(_startDate!),
          });

      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Event updated successfully'),
            backgroundColor: Color(0xFF00FF41),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error updating event: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }
}

// ==================== USER PROFILE VIEW ====================
class UserProfileView extends StatefulWidget {
  final Map<String, dynamic> userData;

  const UserProfileView({super.key, required this.userData});

  @override
  State<UserProfileView> createState() => _UserProfileViewState();
}

class _UserProfileViewState extends State<UserProfileView> {
  bool _requestSent = false;
  bool _isLoading = false;
  String? _currentUserCode;
  bool _isFriend = false;
  bool _isBlocked = false;

  @override
  void initState() {
    super.initState();
    _loadCurrentUserCode();
    _checkIfRequestSent();
    _checkIfBlocked();
  }

  Future<void> _loadCurrentUserCode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Stored at login time under userReferralCode; keep fallback for older key
      final code =
          prefs.getString('userReferralCode') ??
          prefs.getString('referralCode');
      if (mounted) {
        setState(() {
          _currentUserCode = code;
        });
      }
      // After loading, check pending request, friendship and block status
      await _checkIfRequestSent();
      await _checkFriendshipStatus();
      await _checkIfBlocked();
    } catch (e) {
      print('Error loading current user code: $e');
    }
  }

  Future<void> _checkIfRequestSent() async {
    if (_currentUserCode == null) return;

    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('applications')
          .where('referralCode', isEqualTo: widget.userData['referralCode'])
          .limit(1)
          .get();

      if (snapshot.docs.isNotEmpty) {
        final userData = snapshot.docs.first.data();
        final requests =
            (userData['friendRequests'] as List?)?.cast<String>() ?? [];
        if (mounted) {
          setState(() {
            _requestSent = requests.contains(_currentUserCode);
          });
        }
      }
    } catch (e) {
      print('Error checking request status: $e');
    }
  }

  Future<void> _checkFriendshipStatus() async {
    try {
      if (_currentUserCode == null) return;

      // Load current user's friends list and see if it contains the target code
      final meSnapshot = await FirebaseFirestore.instance
          .collection('applications')
          .where('referralCode', isEqualTo: _currentUserCode)
          .limit(1)
          .get();

      if (meSnapshot.docs.isEmpty) return;

      final meData = meSnapshot.docs.first.data();
      final myFriends = (meData['friends'] as List?)?.cast<String>() ?? [];
      final targetCode = widget.userData['referralCode'] as String?;
      if (mounted) {
        setState(() {
          _isFriend = targetCode != null && myFriends.contains(targetCode);
        });
      }
    } catch (e) {
      print('Error checking friendship status: $e');
    }
  }

  Future<void> _checkIfBlocked() async {
    if (_currentUserCode == null) return;
    try {
      final targetCode = widget.userData['referralCode'] as String?;
      final isBlocked = await _areUsersBlocked(
        currentUserCode: _currentUserCode,
        targetCode: targetCode,
      );
      if (mounted) {
        setState(() {
          _isBlocked = targetCode != null && isBlocked;
        });
      }
    } catch (e) {
      print('Error checking blocked status: $e');
    }
  }

  Future<void> _blockUser() async {
    if (_currentUserCode == null) {
      AppUtils.showError(context, 'You need to log in to block users');
      return;
    }
    final targetCode = widget.userData['referralCode'] as String?;
    if (targetCode == null) return;
    if (targetCode == _currentUserCode) {
      AppUtils.showError(context, 'You cannot block yourself');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Color(0xFF1A1A1A).withValues(alpha: 0.85),
        title: Text('Block User', style: TextStyle(color: Color(0xFFB8B8C0))),
        content: Text(
          'Block ${widget.userData['name']}? Their content will be hidden from your feed.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Block', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _isLoading = true);
    try {
      await _blockReferralCode(
        currentUserCode: _currentUserCode!,
        targetCode: targetCode,
      );
      if (mounted) {
        setState(() {
          _isBlocked = true;
          _isLoading = false;
        });
        AppUtils.showSuccess(context, 'User blocked successfully');
      }
    } catch (e) {
      print('Error blocking user: $e');
      if (mounted) {
        AppUtils.showError(context, 'Error blocking user: $e');
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _reportUser() async {
    if (_currentUserCode == null) {
      AppUtils.showError(context, 'You need to log in to report users');
      return;
    }
    final targetCode = widget.userData['referralCode'] as String?;
    if (targetCode == null) return;
    if (targetCode == _currentUserCode) {
      AppUtils.showError(context, 'You cannot report yourself');
      return;
    }

    final reasonController = TextEditingController();
    final reported = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Color(0xFF1A1A1A).withValues(alpha: 0.85),
        title: Text('Report User', style: TextStyle(color: Color(0xFFB8B8C0))),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Why are you reporting ${widget.userData['name']}?',
                style: TextStyle(color: Colors.white70),
              ),
              SizedBox(height: 16),
              TextField(
                controller: reasonController,
                maxLines: 4,
                style: TextStyle(color: Color(0xFFB8B8C0)),
                decoration: InputDecoration(
                  hintText: 'Provide details...',
                  hintStyle: TextStyle(color: Colors.white38),
                  filled: true,
                  fillColor: Colors.white.withValues(alpha: 0.05),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: Colors.white24),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Report', style: TextStyle(color: Colors.orange)),
          ),
        ],
      ),
    );
    if (reported != true) {
      return;
    }

    if (mounted) setState(() => _isLoading = true);
    try {
      await FirebaseFirestore.instance.collection('moderation_reports').add({
        'reporterCode': _currentUserCode,
        'reporterUid': FirebaseAuth.instance.currentUser?.uid,
        'reportedUserCode': targetCode,
        'reportedUserName': widget.userData['name'],
        'category': 'Other',
        'details': reasonController.text.trim(),
        'source': 'profile',
        'type': 'user',
        'timestamp': Timestamp.now(),
        'status': 'pending',
      });
      if (mounted) {
        setState(() => _isLoading = false);
        AppUtils.showSuccess(
          context,
          'Report submitted. Our team will review it within 24 hours.',
        );
      }
    } catch (e) {
      print('Error reporting user: $e');
      if (mounted) {
        AppUtils.showError(context, 'Error submitting report: $e');
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _sendFriendRequest() async {
    if (_currentUserCode == null) {
      AppUtils.showError(context, 'You need to log in to send friend requests');
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      print(
        'DEBUG: Sending friend request from $_currentUserCode to ${widget.userData['referralCode']}',
      );

      // Get the target user document
      final targetUserSnapshot = await FirebaseFirestore.instance
          .collection('applications')
          .where('referralCode', isEqualTo: widget.userData['referralCode'])
          .limit(1)
          .get();

      if (targetUserSnapshot.docs.isEmpty) {
        throw Exception('User not found');
      }

      final targetUserDoc = targetUserSnapshot.docs.first;
      final targetUserData = targetUserDoc.data();
      print('DEBUG: Target user data: $targetUserData');

      List<String> requests =
          (targetUserData['friendRequests'] as List?)?.cast<String>() ?? [];
      print('DEBUG: Current requests: $requests');

      // Add current user to target user's friend requests
      if (_currentUserCode != null && !requests.contains(_currentUserCode)) {
        requests.add(_currentUserCode!);
        print(
          'DEBUG: Adding $_currentUserCode to requests. New list: $requests',
        );
        await targetUserDoc.reference.update({'friendRequests': requests});
        print('DEBUG: Updated Firestore with new requests');
      }

      setState(() {
        _requestSent = true;
        _isLoading = false;
      });

      AppUtils.showSuccess(
        context,
        'Friend request sent to ${widget.userData['name']}!',
      );
    } catch (e) {
      print('Error sending friend request: $e');
      AppUtils.showError(context, 'Error: ${e.toString()}');
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final referralCode = widget.userData['referralCode'] as String?;
    final stream = referralCode == null || referralCode.isEmpty
        ? null
        : FirebaseFirestore.instance
            .collection('applications')
            .where('referralCode', isEqualTo: referralCode)
            .limit(1)
            .snapshots();

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Color(0xFFB8B8C0)),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          widget.userData['name']?.toString().toUpperCase() ?? 'Profile',
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: Color(0xFFB8B8C0),
            letterSpacing: 1,
          ),
        ),
      ),
      backgroundColor: Colors.transparent,
      body: stream == null
          ? _buildPublicProfileBody(Map<String, dynamic>.from(widget.userData))
          : StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: stream,
              builder: (context, snapshot) {
                final live = (snapshot.hasData && snapshot.data!.docs.isNotEmpty)
                    ? <String, dynamic>{
                        ...widget.userData,
                        ...snapshot.data!.docs.first.data(),
                      }
                    : Map<String, dynamic>.from(widget.userData);
                return _buildPublicProfileBody(live);
              },
            ),
    );
  }

  Widget _buildPublicProfileBody(Map<String, dynamic> live) {
    final isSelf = live['referralCode'] == _currentUserCode;
    final xp = (live['xpPoints'] as num?)?.toInt() ?? 0;
    final level = (xp ~/ 100) + 1;
    final missions =
        (live['completedSidequests'] as List?)?.length ?? 0;
    final friendsCount = (live['friends'] as List?)?.length ?? 0;
    final next = _nextTekReward(xp);
    final current = _currentTekReward(xp);

    final prevThreshold = current?.xpRequired ?? 0;
    final nextThreshold = next?.xpRequired ?? (prevThreshold == 0 ? 200 : prevThreshold);
    final progress = next == null
        ? 1.0
        : ((xp - prevThreshold) / math.max(1, nextThreshold - prevThreshold))
            .clamp(0.0, 1.0)
            .toDouble();

    final imageUrl = live['profileImageUrl']?.toString() ?? '';
    final bio = live['bio']?.toString() ?? '';

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(height: 24),
          // Profile picture with neon-green ring
          Container(
            width: 150,
            height: 150,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xFF00FF41), width: 3),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF00FF41).withValues(alpha: 0.35),
                  blurRadius: 24,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: ClipOval(
              child: imageUrl.isNotEmpty
                  ? Image.network(
                      imageUrl,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        color: Colors.grey[800],
                        child: const Icon(Icons.person,
                            size: 60, color: Colors.white30),
                      ),
                    )
                  : Container(
                      color: Colors.grey[800],
                      child: const Icon(Icons.person,
                          size: 60, color: Colors.white30),
                    ),
            ),
          ),
          const SizedBox(height: 18),
          // Name
          Text(
            live['name']?.toString() ?? 'Unknown User',
            style: const TextStyle(
              color: Color(0xFFB8B8C0),
              fontSize: 22,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 4),
          if (isSelf)
            Text(
              '@${live['referralCode']}',
              style: const TextStyle(color: Colors.white54, fontSize: 13),
            ),
          const SizedBox(height: 22),
          // LEVEL banner with XP bar to next reward
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 18),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    const Color(0xFF00FF41).withValues(alpha: 0.18),
                    const Color(0xFF00FF41).withValues(alpha: 0.04),
                  ],
                ),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                    color: const Color(0xFF00FF41).withValues(alpha: 0.4)),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      const Icon(Icons.bolt,
                          color: Color(0xFF00FF41), size: 18),
                      const SizedBox(width: 6),
                      Text(
                        'LEVEL $level',
                        style: const TextStyle(
                          color: Color(0xFF00FF41),
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 2,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        '$xp XP',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 8,
                      backgroundColor: Colors.white12,
                      valueColor: const AlwaysStoppedAnimation<Color>(
                          Color(0xFF00FF41)),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        next == null
                            ? 'MAX TIER REACHED'
                            : '${nextThreshold - xp} XP TO ${next.name}',
                        style: TextStyle(
                          color: next == null
                              ? const Color(0xFFFFD700)
                              : Colors.white70,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.2,
                        ),
                      ),
                      if (next != null)
                        Icon(next.icon, size: 14, color: next.color),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),
          // Stat row
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                _StatCell(label: 'MISSIONS', value: '$missions'),
                _StatCell(label: 'FRIENDS', value: '$friendsCount'),
                _StatCell(label: 'XP', value: '$xp', animateTo: xp),
              ],
            ),
          ),
          const SizedBox(height: 24),
          // Friend / Report / Block — only when viewing someone else
          if (!isSelf)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                children: [
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton(
                      onPressed: _isLoading || _requestSent || _isFriend
                          ? null
                          : _sendFriendRequest,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: (_isFriend || _requestSent)
                            ? Colors.grey[700]
                            : const Color(0xFF00FF41),
                        disabledBackgroundColor: Colors.grey[700],
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      child: _isLoading
                          ? const SizedBox(
                              height: 24,
                              width: 24,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor:
                                    AlwaysStoppedAnimation(Colors.white),
                              ),
                            )
                          : Text(
                              _isFriend
                                  ? 'FRIENDS'
                                  : (_requestSent
                                      ? 'REQUEST SENT'
                                      : (_currentUserCode == null
                                          ? 'LOGIN TO SEND REQUEST'
                                          : 'SEND FRIEND REQUEST')),
                              style: TextStyle(
                                color: (_isFriend || _requestSent)
                                    ? Colors.white70
                                    : Colors.black,
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                                letterSpacing: 1,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 40,
                          child: OutlinedButton(
                            onPressed: _isLoading ? null : _reportUser,
                            style: OutlinedButton.styleFrom(
                              side: const BorderSide(
                                  color: Colors.orange, width: 1.5),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8)),
                            ),
                            child: const Text(
                              'REPORT',
                              style: TextStyle(
                                color: Colors.orange,
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: SizedBox(
                          height: 40,
                          child: OutlinedButton(
                            onPressed: _isLoading ? null : _blockUser,
                            style: OutlinedButton.styleFrom(
                              side: BorderSide(
                                color: _isBlocked ? Colors.grey : Colors.red,
                                width: 1.5,
                              ),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8)),
                            ),
                            child: Text(
                              _isBlocked ? 'BLOCKED' : 'BLOCK',
                              style: TextStyle(
                                color: _isBlocked ? Colors.grey : Colors.red,
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          const SizedBox(height: 24),
          // Bio
          if (bio.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'BIO',
                    style: TextStyle(
                      color: Color(0xFFB8B8C0),
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    bio,
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 14, height: 1.4),
                  ),
                ],
              ),
            ),
          if (bio.isNotEmpty) const SizedBox(height: 24),
          // Self-only contact info
          if (isSelf)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildInfoRow('Email', live['email'] ?? 'N/A'),
                  const SizedBox(height: 12),
                  _buildInfoRow('Phone', live['phone'] ?? 'N/A'),
                  const SizedBox(height: 12),
                  _buildInfoRow('Instagram', live['instagram'] ?? 'N/A'),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          // Badge wall (read-only)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 24),
                  child: Text(
                    'BADGES',
                    style: TextStyle(
                      color: Color(0xFFB8B8C0),
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.5,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: GridView.count(
                    crossAxisCount: 3,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                    childAspectRatio: 0.9,
                    children: _tekBadges
                        .map((b) =>
                            _BadgeTile(badge: b, earned: b.earned(live)))
                        .toList(),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$label: ',
          style: const TextStyle(
            color: Color(0xFFB8B8C0),
            fontSize: 12,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

// ==================== USER PROFILE MODAL ====================
class UserProfileModal extends StatefulWidget {
  final String name;
  final bool isFriend;
  final VoidCallback? onAddFriend;
  final VoidCallback? onRemoveFriend;

  const UserProfileModal({
    super.key,
    required this.name,
    this.isFriend = true,
    this.onAddFriend,
    this.onRemoveFriend,
  });

  @override
  State<UserProfileModal> createState() => _UserProfileModalState();
}

class _UserProfileModalState extends State<UserProfileModal> {
  late bool _isFriend;

  @override
  void initState() {
    super.initState();
    _isFriend = widget.isFriend;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SingleChildScrollView(
        child: Column(
          children: [
            SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                SizedBox(width: 40),
                Text(
                  widget.name.toUpperCase(),
                  style: TextStyle(
                    color: Color(0xFFB8B8C0),
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1,
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.close, color: Color(0xFFB8B8C0)),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            SizedBox(height: 20),
            _buildProfileCircle(200),
            SizedBox(height: 24),
            Text(
              'LEVEL 7',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 12,
                letterSpacing: 1,
              ),
            ),
            SizedBox(height: 12),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Text(
                    '24',
                    style: TextStyle(color: Color(0xFFB8B8C0), fontSize: 12),
                  ),
                  SizedBox(width: 8),
                  Icon(Icons.female, size: 12, color: Colors.white70),
                  SizedBox(width: 8),
                  Text(
                    'Female',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ],
              ),
            ),
            SizedBox(height: 16),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                '@mialove',
                style: TextStyle(color: Color(0xFFB8B8C0), fontSize: 12),
              ),
            ),
            SizedBox(height: 12),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'Clubbing enthusiast. Love to dance and always down for a good time! 🎉 Follow me on Instagram!',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
            ),
            SizedBox(height: 20),
            _buildImageGallery(),
            SizedBox(height: 20),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: _isFriend
                  ? Row(
                      children: [
                        Expanded(
                          child: ElevatedButton(
                            onPressed: () {},
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.transparent,
                              side: BorderSide(
                                color: Color(0xFFB8B8C0),
                                width: 1,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: Text(
                              'CHAT',
                              style: TextStyle(
                                color: Color(0xFFB8B8C0),
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                        SizedBox(width: 12),
                        Expanded(
                          child: ElevatedButton(
                            onPressed: () {
                              setState(() => _isFriend = false);
                              widget.onRemoveFriend?.call();
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('Removed from friends'),
                                  duration: Duration(seconds: 2),
                                  backgroundColor: Color(0xFF00FF41),
                                ),
                              );
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.transparent,
                              side: BorderSide(color: Colors.red, width: 1),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: Text(
                              'UNFRIEND',
                              style: TextStyle(
                                color: Colors.red,
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ],
                    )
                  : SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () {
                          setState(() => _isFriend = true);
                          widget.onAddFriend?.call();
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('${widget.name} added to friends!'),
                              duration: Duration(seconds: 2),
                              backgroundColor: Color(0xFF00FF41),
                            ),
                          );
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Color(
                            0xFF00FF41,
                          ).withValues(alpha: 0.2),
                          side: BorderSide(color: Color(0xFF00FF41), width: 2),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          padding: EdgeInsets.symmetric(vertical: 12),
                        ),
                        child: Text(
                          'ADD FRIEND',
                          style: TextStyle(
                            color: Color(0xFF00FF41),
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1,
                          ),
                        ),
                      ),
                    ),
            ),
            SizedBox(height: 30),
          ],
        ),
      ),
    );
  }

  Widget _buildProfileCircle(double size) {
    final portalSize = size + 60;
    return SizedBox(
      width: portalSize,
      height: portalSize,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Outer green ambient glow
          Container(
            width: portalSize,
            height: portalSize,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Color(0xFF00FF41).withValues(alpha: 0.15),
                  blurRadius: 40,
                  spreadRadius: 5,
                ),
              ],
            ),
          ),
          // Outer chrome ring
          Container(
            width: portalSize - 4,
            height: portalSize - 4,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: Color(0xFF7A7A7A).withValues(alpha: 0.5),
                width: 1.5,
              ),
            ),
          ),
          // Green energy ring
          Container(
            width: portalSize - 20,
            height: portalSize - 20,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: Color(0xFF00FF41).withValues(alpha: 0.2),
                width: 1,
              ),
            ),
          ),
          // Inner chrome ring
          Container(
            width: portalSize - 35,
            height: portalSize - 35,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: Color(0xFF8A8A8A).withValues(alpha: 0.35),
                width: 1.5,
              ),
            ),
          ),
          // Green glow border around image
          Container(
            width: size + 6,
            height: size + 6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: Color(0xFF00FF41).withValues(alpha: 0.35),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: Color(0xFF00FF41).withValues(alpha: 0.12),
                  blurRadius: 12,
                  spreadRadius: 1,
                ),
              ],
            ),
          ),
          // The actual profile image
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(shape: BoxShape.circle),
            child: ClipOval(child: Container(color: Colors.grey[800])),
          ),
        ],
      ),
    );
  }

  Widget _buildImageGallery() {
    return SizedBox(
      height: 120,
      child: PageView(
        children: [
          _buildGalleryItem(),
          _buildGalleryItem(),
          _buildGalleryItem(),
        ],
      ),
    );
  }

  Widget _buildGalleryItem() {
    return Container(
      margin: EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10),
        color: Colors.grey[800],
      ),
    );
  }
}

// ==================== SETTINGS SCREEN ====================
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        title: Text(
          'SETTINGS',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: Color(0xFFB8B8C0),
            letterSpacing: 2,
          ),
        ),
      ),
      body: ListView(
        children: [
          _buildSettingsItem(
            context,
            'Profile',
            Icons.person,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) =>
                      UserProfilePage(applicationData: _applicationData),
                ),
              );
            },
          ),
          _buildSettingsItem(
            context,
            'Invite Friends',
            Icons.person_add,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const InviteFriendsPage(),
                ),
              );
            },
          ),
          _buildSettingsItem(
            context,
            'My Tickets',
            Icons.confirmation_num,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const MyTicketsPage()),
              );
            },
          ),
          _buildSettingsItem(
            context,
            'Notifications',
            Icons.notifications,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => NotificationSettingsPage(),
                ),
              );
            },
          ),
          _buildSettingsItem(
            context,
            'Privacy',
            Icons.lock,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => PrivacySettingsPage()),
              );
            },
          ),
          _buildSettingsItem(
            context,
            'Blocked Users',
            Icons.block,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const ManageBlockedUsersPage(),
                ),
              );
            },
          ),
          _buildSettingsItem(
            context,
            'About',
            Icons.info,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => AboutPage()),
              );
            },
          ),
          _buildSettingsItem(
            context,
            'Delete Account',
            Icons.delete_forever,
            onTap: () async {
              // Double confirmation and loading indicator
              final confirm1 = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: Text('Delete Account'),
                  content: Text(
                    'Are you sure you want to permanently delete your account? This cannot be undone.',
                  ),
                  actions: [
                    TextButton(
                      child: Text('Cancel'),
                      onPressed: () => Navigator.of(ctx).pop(false),
                    ),
                    TextButton(
                      child: Text('Continue'),
                      onPressed: () => Navigator.of(ctx).pop(true),
                    ),
                  ],
                ),
              );
              if (confirm1 != true) return;

              final confirm2 = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: Text('Final Confirmation'),
                  content: Text(
                    'This will delete all your data and cannot be undone. Are you absolutely sure?',
                  ),
                  actions: [
                    TextButton(
                      child: Text('Cancel'),
                      onPressed: () => Navigator.of(ctx).pop(false),
                    ),
                    TextButton(
                      child: Text('Delete Forever'),
                      onPressed: () => Navigator.of(ctx).pop(true),
                    ),
                  ],
                ),
              );
              if (confirm2 != true) return;

              showDialog(
                context: context,
                barrierDismissible: false,
                builder: (ctx) => Center(child: CircularProgressIndicator()),
              );
              try {
                await deleteCurrentUserAccount();
                if (mounted) {
                  Navigator.of(context).pop(); // Remove loading dialog
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Account deleted successfully.'),
                      backgroundColor: Colors.green,
                    ),
                  );
                  Navigator.of(context).pushAndRemoveUntil(
                    MaterialPageRoute(builder: (_) => ReferralCodeScreen()),
                    (route) => false,
                  );
                }
              } catch (e) {
                if (mounted) {
                  Navigator.of(context).pop(); // Remove loading dialog
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Error deleting account: $e'),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              } finally {}
            },
          ),
          _buildSettingsItem(
            context,
            'Logout',
            Icons.logout,
            onTap: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  backgroundColor: Color(0xFF1A1A1A).withValues(alpha: 0.85),
                  title: Text(
                    'Logout',
                    style: TextStyle(color: Color(0xFFB8B8C0)),
                  ),
                  content: Text(
                    'Are you sure you want to logout?',
                    style: TextStyle(color: Colors.white70),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: Text(
                        'CANCEL',
                        style: TextStyle(color: Colors.white70),
                      ),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: Text(
                        'LOGOUT',
                        style: TextStyle(color: Color(0xFF00FF41)),
                      ),
                    ),
                  ],
                ),
              );

              if (confirmed == true) {
                await ReferralSessionManager.instance.stop();
                final prefs = await SharedPreferences.getInstance();
                await prefs.remove('userReferralCode');
                await prefs.remove('isAdmin');
                await prefs.remove(tekAdminModePrefsKey);
                await prefs.remove('tek_active_session_id');
                await prefs.remove('tek_active_session_app_id');

                try {
                  await FirebaseAuth.instance.signOut();
                } catch (_) {}
                _applicationData.clear();
                if (context.mounted) {
                  Navigator.pushAndRemoveUntil(
                    context,
                    MaterialPageRoute(
                      builder: (context) => ReferralCodeScreen(),
                    ),
                    (route) => false,
                  );
                }
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _buildSettingsItem(
    BuildContext context,
    String title,
    IconData icon, {
    VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: Colors.white10, width: 0.5)),
        ),
        child: Row(
          children: [
            Icon(icon, color: Colors.white70, size: 24),
            SizedBox(width: 16),
            Text(
              title,
              style: TextStyle(color: Color(0xFFB8B8C0), fontSize: 16),
            ),
            Spacer(),
            Icon(Icons.arrow_forward, color: Colors.white30, size: 20),
          ],
        ),
      ),
    );
  }
}

class ManageBlockedUsersPage extends StatefulWidget {
  const ManageBlockedUsersPage({super.key});

  @override
  State<ManageBlockedUsersPage> createState() => _ManageBlockedUsersPageState();
}

class _ManageBlockedUsersPageState extends State<ManageBlockedUsersPage> {
  late Future<List<Map<String, dynamic>>> _blockedUsersFuture;
  String? _currentUserCode;
  String? _pendingUnblockCode;

  @override
  void initState() {
    super.initState();
    _blockedUsersFuture = _loadBlockedUsers();
  }

  Future<List<Map<String, dynamic>>> _loadBlockedUsers() async {
    final prefs = await SharedPreferences.getInstance();
    _currentUserCode = prefs.getString('userReferralCode');
    final blockedCodes = await _getBlockedUsersForReferralCode(
      _currentUserCode,
    );
    if (blockedCodes.isEmpty) return <Map<String, dynamic>>[];

    final Map<String, Map<String, dynamic>> usersByCode = {
      for (final code in blockedCodes)
        code: <String, dynamic>{
          'referralCode': code,
          'name': code,
          'instagram': '',
          'profileImageUrl': null,
        },
    };

    for (final chunk in _chunkList<String>(blockedCodes, 10)) {
      final snapshot = await FirebaseFirestore.instance
          .collection('applications')
          .where('referralCode', whereIn: chunk)
          .get();
      for (final doc in snapshot.docs) {
        final data = doc.data();
        final code = (data['referralCode'] as String? ?? '').trim();
        if (code.isEmpty) continue;
        usersByCode[code] = <String, dynamic>{
          'referralCode': code,
          'name': data['name'] ?? code,
          'instagram': data['instagram'] ?? '',
          'profileImageUrl': data['profileImageUrl'],
        };
      }
    }

    return blockedCodes
        .map(
          (code) =>
              usersByCode[code] ??
              <String, dynamic>{'referralCode': code, 'name': code},
        )
        .toList();
  }

  Future<void> _unblockUser(String targetCode) async {
    final currentUserCode = _currentUserCode;
    if (currentUserCode == null || currentUserCode.isEmpty) return;

    setState(() {
      _pendingUnblockCode = targetCode;
    });

    try {
      await _unblockReferralCode(
        currentUserCode: currentUserCode,
        targetCode: targetCode,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('User unblocked successfully.'),
          backgroundColor: Colors.green,
        ),
      );
      setState(() {
        _blockedUsersFuture = _loadBlockedUsers();
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Unable to unblock user: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (!mounted) return;
      setState(() {
        _pendingUnblockCode = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        title: const Text(
          'BLOCKED USERS',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: Color(0xFFB8B8C0),
            letterSpacing: 2,
          ),
        ),
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _blockedUsersFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(
              child: CircularProgressIndicator(color: Color(0xFF00FF41)),
            );
          }

          final blockedUsers = snapshot.data ?? <Map<String, dynamic>>[];
          if (blockedUsers.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'You have not blocked anyone.',
                  style: TextStyle(color: Colors.white70, fontSize: 16),
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          return ListView.separated(
            itemCount: blockedUsers.length,
            separatorBuilder: (_, __) => const Divider(color: Colors.white10),
            itemBuilder: (context, index) {
              final user = blockedUsers[index];
              final referralCode = user['referralCode'] as String? ?? '';
              final isLoading = _pendingUnblockCode == referralCode;
              final instagram = (user['instagram'] as String? ?? '').trim();

              return ListTile(
                leading: CircleAvatar(
                  backgroundColor: Colors.white12,
                  backgroundImage: user['profileImageUrl'] != null
                      ? NetworkImage(user['profileImageUrl'] as String)
                      : null,
                  child: user['profileImageUrl'] == null
                      ? const Icon(Icons.person, color: Colors.white54)
                      : null,
                ),
                title: Text(
                  user['name'] as String? ?? referralCode,
                  style: const TextStyle(color: Color(0xFFB8B8C0)),
                ),
                subtitle: Text(
                  instagram.isEmpty
                      ? referralCode
                      : '@${instagram.replaceAll('@', '')}',
                  style: const TextStyle(color: Colors.white54),
                ),
                trailing: TextButton(
                  onPressed: isLoading
                      ? null
                      : () => _unblockUser(referralCode),
                  child: Text(
                    isLoading ? '...' : 'UNBLOCK',
                    style: const TextStyle(color: Color(0xFF00FF41)),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class MyTicketsPage extends StatefulWidget {
  const MyTicketsPage({super.key});

  @override
  State<MyTicketsPage> createState() => _MyTicketsPageState();
}

class _MyTicketsPageState extends State<MyTicketsPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  bool _backfilling = false;
  final Map<String, Future<_EventSummary?>> _eventSummaryFutures = {};

  List<_UserTicket> _dedupeOnePerEvent(List<_UserTicket> tickets) {
    final byEvent = <String, _UserTicket>{};
    for (final t in tickets) {
      final eventId = t.eventId.trim();
      if (eventId.isEmpty) continue;
      final existing = byEvent[eventId];
      if (existing == null) {
        byEvent[eventId] = t;
        continue;
      }

      final aAt = existing.purchasedAt?.millisecondsSinceEpoch ?? 0;
      final bAt = t.purchasedAt?.millisecondsSinceEpoch ?? 0;
      if (bAt != aAt) {
        if (bAt > aAt) byEvent[eventId] = t;
        continue;
      }

      // Stable tiebreaker: keep lexicographically larger id.
      if (t.id.compareTo(existing.id) > 0) {
        byEvent[eventId] = t;
      }
    }
    return byEvent.values.toList();
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Stream<QuerySnapshot> _ticketStream(String uid) {
    return FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('tickets')
        .orderBy('purchasedAt', descending: true)
        .snapshots();
  }

  Future<_EventSummary?> _getEventSummary(String eventId) {
    final trimmed = eventId.trim();
    if (trimmed.isEmpty) return Future.value(null);

    return _eventSummaryFutures.putIfAbsent(trimmed, () async {
      try {
        final snap = await FirebaseFirestore.instance
            .collection('events')
            .doc(trimmed)
            .get();
        if (!snap.exists) return null;
        final data = snap.data() ?? const {};
        return _EventSummary.fromMap(data);
      } catch (_) {
        return null;
      }
    });
  }

  Future<void> _backfillTicketsForUser(String uid) async {
    if (_backfilling) return;

    setState(() {
      _backfilling = true;
    });

    int? backfilled;
    String? backfillError;
    int? deletedTickets;
    int? dedupedEvents;
    int? deletedMirrors;
    String? dedupeError;

    try {
      final functions = FirebaseFunctions.instanceFor(region: 'us-central1');

      // Backfill (metadata repair) is helpful, but should never block dedupe.
      try {
        final callable = functions.httpsCallable('backfillMyTickets');
        final result = await callable.call(<String, dynamic>{'limit': 200});
        final data = result.data;
        backfilled = data is Map && data['backfilled'] is num
            ? (data['backfilled'] as num).toInt()
            : null;
      } on FirebaseFunctionsException catch (e) {
        backfillError = e.message?.isNotEmpty == true ? e.message : e.code;
      } catch (e) {
        backfillError = e.toString();
      }

      // Also clean up any historical duplicates (one ticket per user per event).
      try {
        final dedupeCallable = functions.httpsCallable('dedupeMyTickets');
        final dedupeResult = await dedupeCallable.call(<String, dynamic>{
          'limit': 500,
        });
        final dd = dedupeResult.data;
        if (dd is Map) {
          if (dd['deletedTickets'] is num) {
            deletedTickets = (dd['deletedTickets'] as num).toInt();
          }
          if (dd['deletedMirrors'] is num) {
            deletedMirrors = (dd['deletedMirrors'] as num).toInt();
          }
          if (dd['dedupedEvents'] is num) {
            dedupedEvents = (dd['dedupedEvents'] as num).toInt();
          }
        }
      } on FirebaseFunctionsException catch (e) {
        dedupeError = e.message?.isNotEmpty == true ? e.message : e.code;
      } catch (e) {
        dedupeError = e.toString();
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            (() {
              final didBackfill = backfillError == null;
              final didDedupe = dedupeError == null;

              final backfillText = didBackfill
                  ? (backfilled == null
                        ? 'Sync complete.'
                        : 'Sync complete: $backfilled ticket(s) updated.')
                  : 'Backfill failed: $backfillError';

              final dedupeText = didDedupe
                  ? (deletedTickets != null && deletedTickets > 0
                        ? (dedupedEvents != null && dedupedEvents > 0
                              ? (() {
                                  final mirrorText =
                                      (deletedMirrors != null &&
                                          deletedMirrors > 0)
                                      ? ' (+$deletedMirrors mirror)'
                                      : '';
                                  return '$deletedTickets duplicate ticket(s) removed across $dedupedEvents event(s)$mirrorText.';
                                })()
                              : (() {
                                  final mirrorText =
                                      (deletedMirrors != null &&
                                          deletedMirrors > 0)
                                      ? ' (+$deletedMirrors mirror)'
                                      : '';
                                  return '$deletedTickets duplicate ticket(s) removed$mirrorText.';
                                })())
                        : 'No duplicates found.')
                  : 'Dedupe failed: $dedupeError';

              if (didBackfill && didDedupe) {
                if (deletedTickets == null || deletedTickets == 0) {
                  return backfillText;
                }
                return '$backfillText $dedupeText';
              }
              if (!didBackfill && didDedupe) {
                return dedupeText;
              }
              if (didBackfill && !didDedupe) {
                return backfillText;
              }
              return 'Sync failed.';
            })(),
          ),
        ),
      );
    } finally {
      if (!mounted) return;
      setState(() {
        _backfilling = false;
      });
    }
  }

  Widget _buildTicketList({required bool upcoming, required String uid}) {
    final now = DateTime.now();

    return StreamBuilder<QuerySnapshot>(
      stream: _ticketStream(uid),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return AppUtils.buildLoadingIndicator(message: 'Loading tickets...');
        }
        if (snapshot.hasError) {
          return AppUtils.buildEmptyState(
            icon: Icons.error_outline,
            title: 'Could not load tickets',
            subtitle: snapshot.error.toString(),
          );
        }

        final allDocs = snapshot.data?.docs ?? const [];
        var tickets = allDocs
            .whereType<QueryDocumentSnapshot>()
            .map(_UserTicket.fromDoc)
            .where((t) => t.eventId.isNotEmpty)
            .where((t) {
              // If startAt isn't available yet, treat as upcoming so tickets don't disappear.
              if (t.startAt == null) return upcoming;
              return upcoming
                  ? t.startAt!.isAfter(now)
                  : t.startAt!.isBefore(now);
            })
            .toList();

        // Enforce the one-per-event UX even if historical data contains duplicates.
        tickets = _dedupeOnePerEvent(tickets);

        tickets.sort((a, b) {
          if (upcoming) {
            final aKey = a.startAt ?? DateTime(2100);
            final bKey = b.startAt ?? DateTime(2100);
            final byStart = aKey.compareTo(bKey);
            if (byStart != 0) return byStart;
          } else {
            final aKey = a.startAt ?? a.purchasedAt ?? DateTime(1970);
            final bKey = b.startAt ?? b.purchasedAt ?? DateTime(1970);
            final byStart = bKey.compareTo(aKey);
            if (byStart != 0) return byStart;
          }
          return (b.purchasedAt ?? DateTime(1970)).compareTo(
            a.purchasedAt ?? DateTime(1970),
          );
        });

        if (tickets.isEmpty) {
          return AppUtils.buildEmptyState(
            icon: Icons.confirmation_num_outlined,
            title: upcoming ? 'No upcoming tickets' : 'No previous tickets',
            subtitle: upcoming
                ? 'Buy a ticket to see it here.'
                : 'Your past tickets will appear here.',
          );
        }

        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: tickets.length,
          separatorBuilder: (_, __) => const SizedBox(height: 12),
          itemBuilder: (context, index) {
            final ticket = tickets[index];

            // Use mirrored metadata when present. If missing, fetch event doc once (cached)
            // so older tickets still show the correct event info.
            final needsEventFallback =
                ticket.eventTitle == null || ticket.startAt == null;

            Widget buildCard({_EventSummary? fallback}) {
              final title = (ticket.eventTitle?.trim().isNotEmpty == true)
                  ? ticket.eventTitle!.trim()
                  : (fallback?.title?.trim().isNotEmpty == true)
                  ? fallback!.title!.trim()
                  : 'TEK Event';
              final startAt = ticket.startAt ?? fallback?.startAt;
              final location = (ticket.location?.trim().isNotEmpty == true)
                  ? ticket.location!.trim()
                  : (fallback?.location?.trim().isNotEmpty == true)
                  ? fallback!.location!.trim()
                  : '';
              final imageUrl = (ticket.imageUrl?.trim().isNotEmpty == true)
                  ? ticket.imageUrl!.trim()
                  : (fallback?.imageUrl?.trim().isNotEmpty == true)
                  ? fallback!.imageUrl!.trim()
                  : null;

              return _TicketCard(
                title: title,
                startAt: startAt,
                location: location,
                imageUrl: imageUrl,
                code: ticket.ticketCode,
                quantity: ticket.quantity,
                amount: ticket.amount,
                currency: ticket.currency,
                onTap: () => AppUtils.showTicketPass(
                  context,
                  eventTitle: title,
                  ticketCode: ticket.ticketCode,
                  startAt: startAt,
                  location: location,
                ),
              );
            }

            if (!needsEventFallback) {
              return buildCard();
            }

            return FutureBuilder<_EventSummary?>(
              future: _getEventSummary(ticket.eventId),
              builder: (context, eventSnap) {
                return buildCard(fallback: eventSnap.data);
              },
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        title: const Text(
          'MY TICKETS',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: Color(0xFFB8B8C0),
            letterSpacing: 2,
          ),
        ),
        actions: [
          if (uid != null)
            IconButton(
              tooltip: 'Backfill tickets',
              onPressed: _backfilling
                  ? null
                  : () => _backfillTicketsForUser(uid),
              icon: _backfilling
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Color(0xFFB8B8C0),
                      ),
                    )
                  : const Icon(Icons.sync, color: Color(0xFFB8B8C0)),
            ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: const Color(0xFF00FF41),
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white70,
          labelStyle: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            letterSpacing: 1,
          ),
          tabs: const [
            Tab(text: 'UPCOMING'),
            Tab(text: 'PREVIOUS'),
          ],
        ),
      ),
      backgroundColor: Colors.transparent,
      body: uid == null
          ? AppUtils.buildEmptyState(
              icon: Icons.confirmation_num_outlined,
              title: 'Login to view your tickets',
            )
          : TabBarView(
              controller: _tabController,
              children: [
                _buildTicketList(upcoming: true, uid: uid),
                _buildTicketList(upcoming: false, uid: uid),
              ],
            ),
    );
  }
}

class _UserTicket {
  final String id;
  final String eventId;
  final String? eventTitle;
  final DateTime? startAt;
  final String? location;
  final String? imageUrl;
  final String ticketCode;
  final DateTime? purchasedAt;
  final int quantity;
  final int? amount;
  final String? currency;

  const _UserTicket({
    required this.id,
    required this.eventId,
    required this.eventTitle,
    required this.startAt,
    required this.location,
    required this.imageUrl,
    required this.ticketCode,
    required this.purchasedAt,
    required this.quantity,
    required this.amount,
    required this.currency,
  });

  static _UserTicket fromDoc(QueryDocumentSnapshot doc) {
    final data = (doc.data() as Map<String, dynamic>?) ?? const {};

    String eventId = (data['eventId'] is String)
        ? (data['eventId'] as String)
        : '';
    final eventTicketPath = (data['eventTicketPath'] is String)
        ? (data['eventTicketPath'] as String)
        : '';

    // Some older/backfilled docs may have a bad/missing eventId; recover from path:
    // events/{eventId}/tickets/{ticketId}
    if (eventId.trim().isEmpty && eventTicketPath.contains('/events/')) {
      final parts = eventTicketPath.split('/');
      final idx = parts.indexOf('events');
      if (idx != -1 && parts.length > idx + 1) {
        eventId = parts[idx + 1];
      }
    }

    DateTime? tsToDate(dynamic ts) {
      if (ts is Timestamp) return ts.toDate();
      return null;
    }

    final qtyRaw = data['quantity'];
    final quantity = qtyRaw is num ? qtyRaw.toInt() : 1;

    final amountRaw = data['amount'];
    final amount = amountRaw is num ? amountRaw.toInt() : null;

    final currency = (data['currency'] is String)
        ? (data['currency'] as String)
        : null;
    final eventTitle = (data['eventTitle'] is String)
        ? (data['eventTitle'] as String)
        : null;
    final location = (data['location'] is String)
        ? (data['location'] as String)
        : null;
    final imageUrl = (data['imageUrl'] is String)
        ? (data['imageUrl'] as String)
        : null;

    final startAt = tsToDate(data['startAt']);
    final purchasedAt = tsToDate(data['purchasedAt']);

    final ticketCode =
        (data['ticketCode'] is String &&
            (data['ticketCode'] as String).trim().isNotEmpty)
        ? (data['ticketCode'] as String).trim()
        : doc.id;

    return _UserTicket(
      id: doc.id,
      eventId: eventId.trim(),
      eventTitle: eventTitle,
      startAt: startAt,
      location: location,
      imageUrl: imageUrl,
      ticketCode: ticketCode,
      purchasedAt: purchasedAt,
      quantity: quantity <= 0 ? 1 : quantity,
      amount: amount,
      currency: currency,
    );
  }
}

class _EventSummary {
  final String? title;
  final DateTime? startAt;
  final String? location;
  final String? imageUrl;

  const _EventSummary({
    required this.title,
    required this.startAt,
    required this.location,
    required this.imageUrl,
  });

  static _EventSummary fromMap(Map<String, dynamic> data) {
    DateTime? tsToDate(dynamic ts) {
      if (ts is Timestamp) return ts.toDate();
      return null;
    }

    final title = (data['title'] is String) ? (data['title'] as String) : null;
    final startAt = tsToDate(data['startAt']);
    final location = (data['location'] is String)
        ? (data['location'] as String)
        : null;
    final imageUrl = (data['imageUrl'] is String)
        ? (data['imageUrl'] as String)
        : null;

    return _EventSummary(
      title: title,
      startAt: startAt,
      location: location,
      imageUrl: imageUrl,
    );
  }
}

class _TicketCard extends StatelessWidget {
  final String title;
  final DateTime? startAt;
  final String location;
  final String? imageUrl;
  final String code;
  final int quantity;
  final int? amount;
  final String? currency;
  final VoidCallback onTap;

  const _TicketCard({
    required this.title,
    required this.startAt,
    required this.location,
    required this.imageUrl,
    required this.code,
    required this.quantity,
    required this.amount,
    required this.currency,
    required this.onTap,
  });

  String _shortCode(String value) {
    final v = value.trim();
    if (v.length <= 12) return v;
    return '${v.substring(0, 6)}…${v.substring(v.length - 4)}';
  }

  String _formatMoney(int amountMinor, String? currency) {
    final cur = (currency ?? '').trim().toUpperCase();
    final value = (amountMinor / 100.0);
    final money = value.toStringAsFixed(2);
    return cur.isEmpty ? money : '$money $cur';
  }

  @override
  Widget build(BuildContext context) {
    final whenText = startAt != null
        ? DateFormat('EEE, MMM d · HH:mm').format(startAt!)
        : null;
    final paidText = (amount != null && amount! >= 0)
        ? _formatMoney(amount!, currency)
        : null;

    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white10),
          color: Colors.white.withValues(alpha: 0.05),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Container(
                width: 52,
                height: 52,
                color: Colors.white.withValues(alpha: 0.06),
                child: imageUrl != null
                    ? Image.network(
                        imageUrl!,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const Icon(
                          Icons.confirmation_num,
                          color: Color(0xFF00FF41),
                        ),
                      )
                    : const Icon(
                        Icons.confirmation_num,
                        color: Color(0xFF00FF41),
                      ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFFB8B8C0),
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 6),
                  if (whenText != null)
                    Text(
                      whenText,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                      ),
                    )
                  else
                    const Text(
                      'Date to be announced',
                      style: TextStyle(color: Colors.white54, fontSize: 13),
                    ),
                  if (location.trim().isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      location,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 13,
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: Colors.white12),
                          color: Colors.black.withValues(alpha: 0.25),
                        ),
                        child: Text(
                          'CODE  ${_shortCode(code)}',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (quantity > 1)
                        Text(
                          'x$quantity',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                          ),
                        ),
                      const Spacer(),
                      if (paidText != null)
                        Text(
                          paidText,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right, color: Colors.white30),
          ],
        ),
      ),
    );
  }
}

// Edit Profile Information Page
class EditProfileInfoPage extends StatefulWidget {
  final Map<String, dynamic> currentData;
  final Function(Map<String, dynamic>) onSave;

  const EditProfileInfoPage({
    super.key,
    required this.currentData,
    required this.onSave,
  });

  @override
  State<EditProfileInfoPage> createState() => _EditProfileInfoPageState();
}

class _EditProfileInfoPageState extends State<EditProfileInfoPage> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _nameController;
  late TextEditingController _emailController;
  late TextEditingController _phoneController;
  late TextEditingController _instagramController;
  late TextEditingController _bioController;
  File? _profileImage;
  final ImagePicker _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.currentData['name']);
    _emailController = TextEditingController(text: widget.currentData['email']);
    _phoneController = TextEditingController(text: widget.currentData['phone']);
    _instagramController = TextEditingController(
      text: widget.currentData['instagram'],
    );
    _bioController = TextEditingController(text: widget.currentData['bio']);
    _profileImage = widget.currentData['profileImage'];
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _instagramController.dispose();
    _bioController.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    final XFile? image = await _picker.pickImage(source: ImageSource.gallery);
    if (image != null) {
      setState(() {
        _profileImage = File(image.path);
      });
    }
  }

  void _saveChanges() {
    if (_formKey.currentState!.validate()) {
      if (containsProhibitedContent(_bioController.text.trim())) {
        AppUtils.showError(
          context,
          'Please remove abusive or explicit language from your bio before saving.',
        );
        return;
      }

      final updatedData = {
        'name': _nameController.text.trim(),
        'email': _emailController.text.trim(),
        'phone': _phoneController.text.trim(),
        'instagram': _instagramController.text.trim(),
        'bio': _bioController.text.trim(),
        'profileImage': _profileImage,
      };
      widget.onSave(updatedData);
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool isAdmin = widget.currentData['isAdmin'] == true;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: Color(0xFFB8B8C0)),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'EDIT INFORMATION',
          style: TextStyle(
            color: Color(0xFFB8B8C0),
            fontSize: 16,
            fontWeight: FontWeight.bold,
            letterSpacing: 1,
          ),
        ),
        actions: [
          TextButton(
            onPressed: _saveChanges,
            child: Text(
              'SAVE',
              style: TextStyle(
                color: Color(0xFF00FF41),
                fontSize: 14,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          color: Colors.black,
          border: Border(top: BorderSide(color: Colors.white10, width: 1)),
        ),
        child: BottomNavigationBar(
          backgroundColor: Colors.transparent,
          type: BottomNavigationBarType.fixed,
          currentIndex: 3,
          items: [
            const BottomNavigationBarItem(
              icon: Icon(Icons.group),
              label: 'SOCIAL',
            ),
            const BottomNavigationBarItem(
              icon: Icon(Icons.confirmation_num),
              label: 'TICKETS',
            ),
            const BottomNavigationBarItem(
              icon: Icon(Icons.calendar_today),
              label: 'EVENTS',
            ),
            const BottomNavigationBarItem(
              icon: Icon(Icons.settings),
              label: 'SETTINGS',
            ),
            if (isAdmin)
              const BottomNavigationBarItem(
                icon: Icon(Icons.admin_panel_settings),
                label: 'CONTROL',
              ),
          ],
          selectedItemColor: isAdmin
              ? const Color(0xFFFF0000)
              : const Color(0xFF00FF41),
          unselectedItemColor: Colors.white70,
          selectedLabelStyle: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
          ),
          unselectedLabelStyle: const TextStyle(
            fontSize: 11,
            letterSpacing: 0.5,
          ),
          onTap: (index) {
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(
                builder: (context) =>
                    MainApp(initialIndex: index, isAdmin: isAdmin),
              ),
            );
          },
        ),
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Profile Picture Section
              Center(
                child: Column(
                  children: [
                    GestureDetector(
                      onTap: _pickImage,
                      child: Container(
                        width: 120,
                        height: 120,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: Color(0xFF00FF41),
                            width: 3,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Color(0xFF00FF41).withOpacity(0.3),
                              blurRadius: 20,
                              spreadRadius: 2,
                            ),
                          ],
                        ),
                        child: ClipOval(
                          child: _profileImage != null
                              ? Image.file(_profileImage!, fit: BoxFit.cover)
                              : widget.currentData['profileImageUrl'] != null &&
                                    widget.currentData['profileImageUrl']
                                        .toString()
                                        .isNotEmpty
                              ? Image.network(
                                  widget.currentData['profileImageUrl'],
                                  fit: BoxFit.cover,
                                  errorBuilder: (context, error, stackTrace) {
                                    return Container(
                                      color: Colors.grey[800],
                                      child: Icon(
                                        Icons.person,
                                        size: 60,
                                        color: Colors.white30,
                                      ),
                                    );
                                  },
                                )
                              : Container(
                                  color: Colors.grey[800],
                                  child: Icon(
                                    Icons.person,
                                    size: 60,
                                    color: Colors.white30,
                                  ),
                                ),
                        ),
                      ),
                    ),
                    SizedBox(height: 12),
                    TextButton.icon(
                      onPressed: _pickImage,
                      icon: Icon(
                        Icons.camera_alt,
                        size: 16,
                        color: Color(0xFF00FF41),
                      ),
                      label: Text(
                        'CHANGE PHOTO',
                        style: TextStyle(
                          color: Color(0xFF00FF41),
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(height: 32),
              // Name Field
              Text(
                'NAME',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1,
                ),
              ),
              SizedBox(height: 8),
              TextFormField(
                controller: _nameController,
                style: TextStyle(color: Color(0xFFB8B8C0)),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: Colors.grey[900],
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.white10),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.white10),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Color(0xFF00FF41)),
                  ),
                ),
                validator: (value) =>
                    value?.isEmpty ?? true ? 'Name required' : null,
              ),
              SizedBox(height: 20),
              // Email Field
              Text(
                'EMAIL',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1,
                ),
              ),
              SizedBox(height: 8),
              TextFormField(
                controller: _emailController,
                style: TextStyle(color: Color(0xFFB8B8C0)),
                keyboardType: TextInputType.emailAddress,
                decoration: InputDecoration(
                  filled: true,
                  fillColor: Colors.grey[900],
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.white10),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.white10),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Color(0xFF00FF41)),
                  ),
                ),
                validator: (value) =>
                    value?.isEmpty ?? true ? 'Email required' : null,
              ),
              SizedBox(height: 20),
              // Phone Field
              Text(
                'PHONE',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1,
                ),
              ),
              SizedBox(height: 8),
              TextFormField(
                controller: _phoneController,
                style: TextStyle(color: Color(0xFFB8B8C0)),
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(
                  filled: true,
                  fillColor: Colors.grey[900],
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.white10),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.white10),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Color(0xFF00FF41)),
                  ),
                ),
                validator: (value) =>
                    value?.isEmpty ?? true ? 'Phone required' : null,
              ),
              SizedBox(height: 20),
              // Instagram Field
              Text(
                'INSTAGRAM',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1,
                ),
              ),
              SizedBox(height: 8),
              TextFormField(
                controller: _instagramController,
                style: TextStyle(color: Color(0xFFB8B8C0)),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: Colors.grey[900],
                  prefixText: '@',
                  prefixStyle: TextStyle(color: Colors.white70),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.white10),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.white10),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Color(0xFF00FF41)),
                  ),
                ),
                validator: (value) =>
                    value?.isEmpty ?? true ? 'Instagram required' : null,
              ),
              SizedBox(height: 20),
              // Bio Field
              Text(
                'BIO',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1,
                ),
              ),
              SizedBox(height: 8),
              TextFormField(
                controller: _bioController,
                style: TextStyle(color: Color(0xFFB8B8C0)),
                maxLines: 4,
                decoration: InputDecoration(
                  filled: true,
                  fillColor: Colors.grey[900],
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.white10),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.white10),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Color(0xFF00FF41)),
                  ),
                ),
                validator: (value) =>
                    value?.isEmpty ?? true ? 'Bio required' : null,
              ),
              SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}

// Notification Settings Page
class NotificationSettingsPage extends StatefulWidget {
  const NotificationSettingsPage({super.key});

  @override
  State<NotificationSettingsPage> createState() =>
      _NotificationSettingsPageState();
}

class _NotificationSettingsPageState extends State<NotificationSettingsPage> {
  // Notification preferences
  bool _allNotificationsEnabled = true;
  bool _pushNotifications = true;
  bool _emailNotifications = true;
  bool _smsNotifications = true;
  bool _inAppNotifications = true;

  // Notification types
  bool _eventUpdates = true;
  bool _membershipUpdates = true;
  bool _achievementNotifications = true;
  bool _promotionalNotifications = true;
  bool _socialNotifications = true;

  // Sound & Vibration
  bool _notificationSound = true;
  bool _vibration = true;

  // Do Not Disturb
  bool _doNotDisturb = false;
  String _dndStartTime = '22:00';
  String _dndEndTime = '08:00';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: Color(0xFFB8B8C0)),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'NOTIFICATIONS',
          style: TextStyle(
            color: Color(0xFF00FF41),
            fontSize: 18,
            fontWeight: FontWeight.bold,
            letterSpacing: 2,
          ),
        ),
        centerTitle: true,
      ),
      body: ListView(
        children: [
          // Master Toggle
          _buildSection('GENERAL', [
            _buildSwitchTile(
              'Enable All Notifications',
              'Turn on/off all notification types',
              _allNotificationsEnabled,
              (value) {
                setState(() {
                  _allNotificationsEnabled = value;
                  if (!value) {
                    _pushNotifications = false;
                    _emailNotifications = false;
                    _smsNotifications = false;
                    _inAppNotifications = false;
                  }
                });
              },
            ),
          ]),

          // Delivery Methods
          _buildSection('DELIVERY METHODS', [
            _buildSwitchTile(
              'Push Notifications',
              'Receive notifications on your device',
              _pushNotifications,
              (value) => setState(() => _pushNotifications = value),
              enabled: _allNotificationsEnabled,
            ),
            _buildSwitchTile(
              'Email Notifications',
              'Receive notifications via email',
              _emailNotifications,
              (value) => setState(() => _emailNotifications = value),
              enabled: _allNotificationsEnabled,
            ),
            _buildSwitchTile(
              'SMS Notifications',
              'Receive text messages for important updates',
              _smsNotifications,
              (value) => setState(() => _smsNotifications = value),
              enabled: _allNotificationsEnabled,
            ),
            _buildSwitchTile(
              'In-App Notifications',
              'Show notifications within the app',
              _inAppNotifications,
              (value) => setState(() => _inAppNotifications = value),
              enabled: _allNotificationsEnabled,
            ),
          ]),

          // Notification Types
          _buildSection('NOTIFICATION TYPES', [
            _buildSwitchTile(
              'Event Updates',
              'Upcoming events, cancellations, changes',
              _eventUpdates,
              (value) => setState(() => _eventUpdates = value),
              enabled: _allNotificationsEnabled,
            ),
            _buildSwitchTile(
              'Membership Updates',
              'Status changes, renewals, benefits',
              _membershipUpdates,
              (value) => setState(() => _membershipUpdates = value),
              enabled: _allNotificationsEnabled,
            ),
            _buildSwitchTile(
              'Achievements',
              'Level ups, rewards, milestones',
              _achievementNotifications,
              (value) => setState(() => _achievementNotifications = value),
              enabled: _allNotificationsEnabled,
            ),
            _buildSwitchTile(
              'Promotions & Offers',
              'Special deals and exclusive offers',
              _promotionalNotifications,
              (value) => setState(() => _promotionalNotifications = value),
              enabled: _allNotificationsEnabled,
            ),
            _buildSwitchTile(
              'Social',
              'Friend requests, messages, mentions',
              _socialNotifications,
              (value) => setState(() => _socialNotifications = value),
              enabled: _allNotificationsEnabled,
            ),
          ]),

          // Sound & Vibration
          _buildSection('SOUND & VIBRATION', [
            _buildSwitchTile(
              'Notification Sound',
              'Play sound for notifications',
              _notificationSound,
              (value) => setState(() => _notificationSound = value),
              enabled: _allNotificationsEnabled,
            ),
            _buildSwitchTile(
              'Vibration',
              'Vibrate on notification',
              _vibration,
              (value) => setState(() => _vibration = value),
              enabled: _allNotificationsEnabled,
            ),
          ]),

          // Do Not Disturb
          _buildSection('DO NOT DISTURB', [
            _buildSwitchTile(
              'Enable Do Not Disturb',
              'Silence notifications during specified hours',
              _doNotDisturb,
              (value) => setState(() => _doNotDisturb = value),
              enabled: _allNotificationsEnabled,
            ),
            if (_doNotDisturb && _allNotificationsEnabled)
              _buildTimePicker(
                'Start Time',
                _dndStartTime,
                (time) => setState(() => _dndStartTime = time),
              ),
            if (_doNotDisturb && _allNotificationsEnabled)
              _buildTimePicker(
                'End Time',
                _dndEndTime,
                (time) => setState(() => _dndEndTime = time),
              ),
          ]),

          SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildSection(String title, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(16, 24, 16, 12),
          child: Text(
            title,
            style: TextStyle(
              color: Color(0xFF00FF41),
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 2,
            ),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(color: Colors.white10, width: 0.5),
              bottom: BorderSide(color: Colors.white10, width: 0.5),
            ),
          ),
          child: Column(children: children),
        ),
      ],
    );
  }

  Widget _buildSwitchTile(
    String title,
    String subtitle,
    bool value,
    Function(bool) onChanged, {
    bool enabled = true,
  }) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.white10, width: 0.5)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: enabled ? Colors.white : Colors.white38,
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: enabled ? Colors.white54 : Colors.white24,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: enabled ? onChanged : null,
            activeThumbColor: Color(0xFF00FF41),
            inactiveThumbColor: Colors.white38,
            inactiveTrackColor: Colors.white10,
          ),
        ],
      ),
    );
  }

  Widget _buildTimePicker(
    String label,
    String time,
    Function(String) onTimeChanged,
  ) {
    return GestureDetector(
      onTap: () async {
        final TimeOfDay? picked = await showTimePicker(
          context: context,
          initialTime: TimeOfDay(
            hour: int.parse(time.split(':')[0]),
            minute: int.parse(time.split(':')[1]),
          ),
          builder: (context, child) {
            return Theme(
              data: ThemeData.dark().copyWith(
                colorScheme: ColorScheme.dark(
                  primary: Color(0xFF00FF41),
                  onPrimary: Colors.black,
                  surface: Color(0xFF1A1A1A).withValues(alpha: 0.85),
                  onSurface: Colors.white,
                ),
              ),
              child: child!,
            );
          },
        );
        if (picked != null) {
          final formattedTime =
              '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
          onTimeChanged(formattedTime);
        }
      },
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: Colors.white10, width: 0.5)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(color: Color(0xFFB8B8C0), fontSize: 16),
              ),
            ),
            Container(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white10,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Color(0xFF00FF41).withOpacity(0.3)),
              ),
              child: Row(
                children: [
                  Icon(Icons.access_time, color: Color(0xFF00FF41), size: 16),
                  SizedBox(width: 8),
                  Text(
                    time,
                    style: TextStyle(
                      color: Color(0xFF00FF41),
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Privacy Settings Page
class PrivacySettingsPage extends StatefulWidget {
  const PrivacySettingsPage({super.key});

  @override
  State<PrivacySettingsPage> createState() => _PrivacySettingsPageState();
}

class _PrivacySettingsPageState extends State<PrivacySettingsPage> {
  // Profile Privacy
  bool _profileVisible = true;
  bool _showEmail = false;
  bool _showPhone = false;
  bool _showInstagram = true;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: Color(0xFFB8B8C0)),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'PRIVACY',
          style: TextStyle(
            color: Color(0xFF00FF41),
            fontSize: 18,
            fontWeight: FontWeight.bold,
            letterSpacing: 2,
          ),
        ),
        centerTitle: true,
      ),
      body: ListView(
        children: [
          // Profile Privacy
          _buildSection('PROFILE VISIBILITY', [
            _buildSwitchTile(
              'Public Profile',
              'Allow others to view your profile',
              _profileVisible,
              (value) => setState(() => _profileVisible = value),
            ),
            _buildSwitchTile(
              'Show Email Address',
              'Display your email on your profile',
              _showEmail,
              (value) => setState(() => _showEmail = value),
              enabled: _profileVisible,
            ),
            _buildSwitchTile(
              'Show Phone Number',
              'Display your phone number on your profile',
              _showPhone,
              (value) => setState(() => _showPhone = value),
              enabled: _profileVisible,
            ),
            _buildSwitchTile(
              'Show Instagram',
              'Display your Instagram handle',
              _showInstagram,
              (value) => setState(() => _showInstagram = value),
              enabled: _profileVisible,
            ),
          ]),

          // Data Management
          _buildSection('DATA MANAGEMENT', [
            _buildActionTile(
              'Terminate My Account',
              'Permanently terminate your account and data',
              Icons.warning,
              () {
                _showDeleteAccountDialog(context);
              },
              isDestructive: true,
            ),
          ]),

          SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildSection(String title, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(16, 24, 16, 8),
          child: Text(
            title,
            style: TextStyle(
              color: Color(0xFF00FF41),
              fontSize: 13,
              fontWeight: FontWeight.bold,
              letterSpacing: 1,
            ),
          ),
        ),
        ...children,
      ],
    );
  }

  Widget _buildSwitchTile(
    String title,
    String subtitle,
    bool value,
    Function(bool) onChanged, {
    bool enabled = true,
  }) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.white10, width: 0.5)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: enabled ? Colors.white : Colors.white38,
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: enabled ? Colors.white54 : Colors.white24,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: enabled ? onChanged : null,
            activeThumbColor: Color(0xFF00FF41),
            inactiveThumbColor: Colors.white38,
            inactiveTrackColor: Colors.white10,
          ),
        ],
      ),
    );
  }

  Widget _buildActionTile(
    String title,
    String subtitle,
    IconData icon,
    VoidCallback onTap, {
    bool isDestructive = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: Colors.white10, width: 0.5)),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              color: isDestructive ? Colors.red : Color(0xFF00FF41),
              size: 24,
            ),
            SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: isDestructive ? Colors.red : Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(color: Colors.white54, fontSize: 13),
                  ),
                ],
              ),
            ),
            Icon(Icons.arrow_forward, color: Colors.white30, size: 20),
          ],
        ),
      ),
    );
  }

  void _showDeleteAccountDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Color(0xFF1A1A1A).withValues(alpha: 0.85),
        title: Text(
          'Terminate Account?',
          style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
        ),
        content: Text(
          'This action cannot be undone. All your data will be permanently terminated.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('CANCEL', style: TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Account termination request received'),
                  backgroundColor: Colors.red,
                ),
              );
            },
            child: Text('TERMINATE', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}

// About Page
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: Color(0xFFB8B8C0)),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'ABOUT',
          style: TextStyle(
            color: Color(0xFF00FF41),
            fontSize: 18,
            fontWeight: FontWeight.bold,
            letterSpacing: 2,
          ),
        ),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(height: 40),
            // Version
            Text(
              'Version 1.0.0',
              style: TextStyle(color: Colors.white70, fontSize: 16),
            ),
            SizedBox(height: 60),
            // Legal Links
            _buildLegalLink('Terms of Service'),
            SizedBox(height: 12),
            _buildLegalLink('Privacy Policy'),
            SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Widget _buildLegalLink(String text) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(vertical: 16, horizontal: 20),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.white.withOpacity(0.1)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(text, style: TextStyle(color: Color(0xFFB8B8C0), fontSize: 15)),
          Icon(Icons.arrow_forward, color: Colors.white30, size: 20),
        ],
      ),
    );
  }
}

// Admin Profile Page
class AdminProfilePage extends StatefulWidget {
  final Map<String, dynamic>? applicationData;

  const AdminProfilePage({super.key, this.applicationData});

  @override
  State<AdminProfilePage> createState() => _AdminProfilePageState();
}

class _AdminProfilePageState extends State<AdminProfilePage> {
  late Map<String, dynamic> profileData;
  int _userCount = 0;
  final int _eventCount = 0;
  final int _pendingCount = 0;
  bool _isLoading = true;

  Future<void> _showSendTestReferralEmailDialog() async {
    final toController = TextEditingController(text: 'linolyander@icloud.com');
    final nameController = TextEditingController(text: 'Admin');
    final codeController = TextEditingController();

    bool sending = false;

    await showDialog<void>(
      context: context,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (dialogCtx, setLocalState) {
            Future<void> send() async {
              final toEmail = toController.text.trim();
              final name = nameController.text.trim();
              final referralCode = codeController.text.trim().toUpperCase();

              bool didCloseDialog = false;

              if (toEmail.isEmpty || !toEmail.contains('@')) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Enter a valid recipient email'),
                    backgroundColor: Colors.red,
                  ),
                );
                return;
              }

              setLocalState(() => sending = true);
              try {
                final callable = FirebaseFunctions.instanceFor(
                  region: 'us-central1',
                ).httpsCallable('adminSendTestReferralCodeEmail');

                final res = await callable.call({
                  'toEmail': toEmail,
                  if (name.isNotEmpty) 'name': name,
                  if (referralCode.isNotEmpty) 'referralCode': referralCode,
                });

                final data = res.data;
                final usedCode = (data is Map && data['referralCode'] is String)
                    ? (data['referralCode'] as String)
                    : '';

                if (!mounted) return;

                // Close the dialog first. After pop, the dialog's StatefulBuilder is disposed,
                // so we must not call setLocalState in finally.
                didCloseDialog = true;
                if (dialogCtx.mounted) {
                  Navigator.of(dialogCtx).pop();
                }

                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      usedCode.isNotEmpty
                          ? 'Test email sent. Code: $usedCode'
                          : 'Test email sent.',
                    ),
                    backgroundColor: const Color(0xFF00FF41),
                    duration: const Duration(seconds: 5),
                  ),
                );
              } on FirebaseFunctionsException catch (e) {
                final msg = '${e.code}: ${e.message ?? ''}'.trim();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Failed to send test email ($msg)'),
                      backgroundColor: Colors.red,
                      duration: const Duration(seconds: 6),
                    ),
                  );
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Failed to send test email: $e'),
                      backgroundColor: Colors.red,
                      duration: const Duration(seconds: 6),
                    ),
                  );
                }
              } finally {
                if (!didCloseDialog && dialogCtx.mounted) {
                  setLocalState(() => sending = false);
                }
              }
            }

            return AlertDialog(
              backgroundColor: Colors.transparent,
              title: const Text(
                'Send test referral email',
                style: TextStyle(color: Color(0xFFB8B8C0)),
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: toController,
                      enabled: !sending,
                      style: const TextStyle(color: Color(0xFFB8B8C0)),
                      decoration: const InputDecoration(
                        labelText: 'To email',
                        labelStyle: TextStyle(color: Colors.white70),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: nameController,
                      enabled: !sending,
                      style: const TextStyle(color: Color(0xFFB8B8C0)),
                      decoration: const InputDecoration(
                        labelText: 'Name (optional)',
                        labelStyle: TextStyle(color: Colors.white70),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: codeController,
                      enabled: !sending,
                      style: const TextStyle(color: Color(0xFFB8B8C0)),
                      decoration: const InputDecoration(
                        labelText: 'Referral code (optional)',
                        labelStyle: TextStyle(color: Colors.white70),
                        helperText: 'Leave blank to generate a random code',
                        helperStyle: TextStyle(color: Colors.white38),
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'This sends a preview email only (no Firestore write).',
                      style: TextStyle(color: Colors.white38, fontSize: 12),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: sending
                      ? null
                      : () => Navigator.of(dialogCtx).pop(),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: sending ? null : send,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFF0000),
                  ),
                  child: Text(sending ? 'Sending…' : 'Send'),
                ),
              ],
            );
          },
        );
      },
    );

    toController.dispose();
    nameController.dispose();
    codeController.dispose();
  }

  @override
  void initState() {
    super.initState();
    profileData = widget.applicationData ?? {};
    _loadStats();
  }

  Future<void> _loadStats() async {
    try {
      final usersSnapshot =
          await FirebaseFirestore.instance.collection('applications').get();
      setState(() {
        _userCount = usersSnapshot.docs.length;
        _isLoading = false;
      });
    } catch (e) {
      print('Error loading stats: $e');
      setState(() => _isLoading = false);
    }
  }

  Future<void> _seedFestivalQuests(BuildContext ctx) async {
    final missions = [
      {
        'title': 'FIND THE SIGNAL',
        'description': 'The TEK QR code is hidden somewhere at the venue. Hunt it down, scan it, and claim your reward. Only the sharpest eyes survive.',
        'xpReward': 100,
        'verificationType': 'qr_code',
        'qrCodeValue': 'TEK_SIGNAL_2026',
      },
      {
        'title': 'WHISPER NETWORK',
        'description': 'Find a stranger at tonight\'s event and share the secret word "FREQUENCY" with them. Add them on TEK as proof of contact.',
        'xpReward': 75,
        'verificationType': 'friend_added',
        'requiredFriendCount': 1,
      },
      {
        'title': 'FREQUENCY FINDER',
        'description': 'Add 3 new TEK members you meet tonight at the event. The community grows through connection.',
        'xpReward': 50,
        'verificationType': 'friend_added',
        'requiredFriendCount': 3,
      },
      {
        'title': 'THE RITUAL',
        'description': 'Be present on the dance floor for both the opening and the closing track of the night. From first beat to last.',
        'xpReward': 75,
        'verificationType': 'honor',
      },
      {
        'title': 'GHOST PROTOCOL',
        'description': 'Disconnect. Stay off your phone for 60 minutes straight during the event. Trust the music. Trust the moment.',
        'xpReward': 100,
        'verificationType': 'timer',
        'timerMinutes': 60,
      },
      {
        'title': 'DECODE THE DROP',
        'description': 'The DJ will play a mystery track during peak hour. The secret code is hidden in plain sight at the venue. Find it and enter it here.',
        'xpReward': 75,
        'verificationType': 'code_entry',
        'secretCode': 'FREQUENCY',
      },
      {
        'title': 'UNDERGROUND SIGNAL',
        'description': 'Discover the hidden spot at the venue. A QR code marks the location. No hints. You\'ll know it when you feel it.',
        'xpReward': 50,
        'verificationType': 'qr_code',
        'qrCodeValue': 'TEK_UNDERGROUND_2026',
      },
      {
        'title': 'LOST FREQUENCY',
        'description': 'Find someone wearing green tonight and add them on TEK. Green is the colour of the signal.',
        'xpReward': 50,
        'verificationType': 'friend_added',
        'requiredFriendCount': 1,
      },
      {
        'title': 'MIRROR SIGNAL',
        'description': 'Find someone at the event dressed almost identically to you. Twin energy only. Add them on TEK as proof.',
        'xpReward': 50,
        'verificationType': 'friend_added',
        'requiredFriendCount': 1,
      },
      {
        'title': 'WATER MISSION',
        'description': 'Buy a stranger a bottle of water. No reason. No expectation. Just a human moment in the middle of the chaos.',
        'xpReward': 75,
        'verificationType': 'honor',
      },
      {
        'title': 'THE HANDSHAKE',
        'description': 'Create a unique secret handshake with someone you just met tonight. It must have at least 3 moves. Teach it. Remember it.',
        'xpReward': 50,
        'verificationType': 'honor',
      },
      {
        'title': 'REQUEST THE SIGNAL',
        'description': 'Get a track played or dedicated by the DJ tonight. Prove it happened. Legendary move.',
        'xpReward': 100,
        'verificationType': 'honor',
      },
      {
        'title': 'CLOSING TIME',
        'description': 'Be one of the last 20 people on the dance floor when the final track drops. Hold your ground until the very end.',
        'xpReward': 75,
        'verificationType': 'honor',
      },
      {
        'title': 'HUMAN COMPASS',
        'description': 'Find someone who is lost at the venue and successfully guide them to where they need to be. No map needed — just instinct.',
        'xpReward': 50,
        'verificationType': 'honor',
      },
      {
        'title': 'TWIN FREQUENCIES',
        'description': 'Find another TEK member somewhere in the crowd tonight — without using the app to locate them. Pure signal.',
        'xpReward': 75,
        'verificationType': 'friend_added',
        'requiredFriendCount': 1,
      },
      {
        'title': 'THE WITNESS',
        'description': 'Be physically present when another TEK member completes one of their missions tonight. Be the witness. Hold the frequency.',
        'xpReward': 50,
        'verificationType': 'honor',
      },
      {
        'title': 'SILENT PROTOCOL',
        'description': 'Communicate only through movement for 30 minutes straight. No words. No texts. Just the music and your body. Pure transmission.',
        'xpReward': 100,
        'verificationType': 'timer',
        'timerMinutes': 30,
      },
      {
        'title': 'FREQUENCY ARCHIVE',
        'description': 'Shazam 5 different tracks the DJ plays tonight and save them. The night lives forever in a playlist.',
        'xpReward': 75,
        'verificationType': 'honor',
      },
    ];

    int seeded = 0;
    int skipped = 0;
    try {
      final prefs = await SharedPreferences.getInstance();
      final adminCode = prefs.getString('userReferralCode') ?? 'admin';
      final col = FirebaseFirestore.instance.collection('sidequests');

      int updated = 0;
      for (final m in missions) {
        final existing = await col
            .where('title', isEqualTo: m['title'])
            .limit(1)
            .get();
        if (existing.docs.isNotEmpty) {
          // Patch verification fields onto existing docs that are missing them
          final existingData = existing.docs.first.data();
          if (!existingData.containsKey('verificationType')) {
            final patch = <String, dynamic>{};
            for (final key in ['verificationType', 'qrCodeValue', 'timerMinutes', 'requiredFriendCount', 'secretCode']) {
              if (m.containsKey(key)) patch[key] = m[key];
            }
            if (patch.isNotEmpty) {
              await existing.docs.first.reference.update(patch);
              updated++;
            } else {
              skipped++;
            }
          } else {
            skipped++;
          }
          continue;
        }
        await col.add({
          ...m,
          'active': true,
          'createdBy': adminCode,
          'createdAt': FieldValue.serverTimestamp(),
          'totalCompletions': 0,
        });
        seeded++;
      }

      if (!ctx.mounted) return;
      final parts = <String>[];
      if (seeded > 0) parts.add('$seeded seeded');
      if (updated > 0) parts.add('$updated updated');
      if (skipped > 0) parts.add('$skipped unchanged');
      ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
        content: Text('Missions: ${parts.join(', ')}'),
        backgroundColor: const Color(0xFF00FF41),
      ));
    } catch (e) {
      if (!ctx.mounted) return;
      ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
        content: Text('Seed failed: $e'),
        backgroundColor: Colors.red,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: Color(0xFFB8B8C0)),
          onPressed: () => Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (context) => MainApp(initialIndex: 5, isAdmin: true),
            ),
          ),
        ),
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.admin_panel_settings,
              color: Color(0xFFFF0000),
              size: 20,
            ),
            SizedBox(width: 8),
            Text(
              'ADMIN',
              style: TextStyle(
                color: Color(0xFFFF0000),
                fontSize: 18,
                fontWeight: FontWeight.bold,
                letterSpacing: 2,
              ),
            ),
          ],
        ),
        centerTitle: true,
        actions: [
          IconButton(
            icon: Icon(Icons.settings, color: Color(0xFFB8B8C0)),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => SettingsScreen()),
              );
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            SizedBox(height: 20),
            const _PushDiagnosticsPanel(),
            const _RedemptionScannerButton(),
            // Admin Profile Circle with Red Glow
            Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  width: 180,
                  height: 180,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Color(0xFFFF0000), width: 3),
                    boxShadow: [
                      BoxShadow(
                        color: Color(0xFFFF0000).withOpacity(0.5),
                        blurRadius: 30,
                        spreadRadius: 10,
                      ),
                    ],
                  ),
                ),
                Container(
                  width: 160,
                  height: 160,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.black,
                    border: Border.all(color: Color(0xFFFF0000), width: 2),
                  ),
                  child: Icon(
                    Icons.admin_panel_settings,
                    size: 80,
                    color: Color(0xFFFF0000),
                  ),
                ),
              ],
            ),
            SizedBox(height: 20),
            // Name
            Text(
              'ADMIN',
              style: TextStyle(
                color: Color(0xFFFF0000),
                fontSize: 28,
                fontWeight: FontWeight.bold,
                letterSpacing: 3,
              ),
            ),
            SizedBox(height: 8),
            Container(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              decoration: BoxDecoration(
                color: Color(0xFFFF0000).withOpacity(0.2),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Color(0xFFFF0000), width: 1),
              ),
              child: Text(
                'ADMINISTRATOR',
                style: TextStyle(
                  color: Color(0xFFFF0000),
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.5,
                ),
              ),
            ),
            SizedBox(height: 30),

            // Admin Stats
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _buildAdminStat(
                    'USERS',
                    _isLoading ? '...' : '$_userCount',
                    Icons.people,
                  ),
                  Container(width: 1, height: 40, color: Colors.white10),
                  _buildAdminStat('EVENTS', '$_eventCount', Icons.event),
                  Container(width: 1, height: 40, color: Colors.white10),
                  _buildAdminStat(
                    'PENDING',
                    '$_pendingCount',
                    Icons.pending_actions,
                  ),
                ],
              ),
            ),

            SizedBox(height: 30),
            Divider(color: Colors.white10, thickness: 1),

            // Admin Actions
            _buildAdminSection('USER MANAGEMENT', [
              _buildAdminAction(
                'Send XP to User',
                Icons.stars,
                () => _showSendXPDialog(),
              ),
              _buildAdminAction(
                'View All Users',
                Icons.people_outline,
                () => _showAllUsers(),
              ),
              _buildAdminAction(
                'Pending Applications',
                Icons.pending_outlined,
                () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Application management coming soon'),
                      backgroundColor: Color(0xFFFF0000),
                    ),
                  );
                },
              ),
              _buildAdminAction('Generate Referral Code', Icons.qr_code, () {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Code generation coming soon'),
                    backgroundColor: Color(0xFFFF0000),
                  ),
                );
              }),
            ]),

            _buildAdminSection('COMMUNICATIONS', [
              _buildAdminAction(
                'Send Notification to All Users',
                Icons.notifications_active,
                () => _showSendNotificationDialog(),
              ),
              _buildAdminAction(
                'Send Test Referral Email',
                Icons.email_outlined,
                () => _showSendTestReferralEmailDialog(),
              ),
            ]),

            _buildAdminSection('EVENT MANAGEMENT', [
              _buildAdminAction('Create Event', Icons.add_circle_outline, () {
                () async {
                  try {
                    final created = await Navigator.of(context).push<bool>(
                      MaterialPageRoute(
                        builder: (_) => const EventsScreenCreateModal(),
                      ),
                    );
                    if (!mounted) return;
                    if (created == true) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Event created successfully!'),
                          backgroundColor: Color(0xFF00FF41),
                        ),
                      );
                    }
                  } catch (_) {
                    // Ignore navigation errors if the route stack changes.
                  }
                }();
              }),
              _buildAdminAction('Manage Events', Icons.event_note, () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const ManageEventsScreen()),
                );
              }),
            ]),

            _buildAdminSection('QUESTS FEATURE FLAGS', const [
              _QuestFeatureFlagsPanel(key: ValueKey('quest_flags')),
            ]),

            ValueListenableBuilder<QuestsConfig>(
              valueListenable: questsConfig,
              builder: (context, cfg, _) {
                if (!cfg.enabled) return const SizedBox.shrink();
                return _buildAdminSection('SIDEQUESTS', [
                  _buildAdminAction(
                    'Manage Sidequests',
                    Icons.bolt,
                    () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const ManageSidequestsScreen(),
                      ),
                    ),
                  ),
                  _buildAdminAction(
                    'Seed Festival Missions',
                    Icons.auto_fix_high,
                    () => _seedFestivalQuests(context),
                  ),
                ]);
              },
            ),

            _buildAdminSection('ANALYTICS', [
              _buildAdminAction(
                'View Statistics',
                Icons.analytics_outlined,
                () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => StatisticsScreen()),
                  );
                },
              ),
              _buildAdminAction('Reports', Icons.assessment_outlined, () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => ReportsScreen()),
                );
              }),
            ]),

            SizedBox(height: 30),
          ],
        ),
      ),
    );
  }

  Future<void> _showSendXPDialog() async {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => SendXPToUsersScreen()),
    );
  }

  Future<List<Map<String, dynamic>>> _fetchUsers() async {
    try {
      final snapshot = await db.collection('applications').get();

      return snapshot.docs.map((doc) {
        final data = doc.data();
        data['docId'] = doc.id;
        return data;
      }).toList();
    } catch (e) {
      print('Error fetching users: $e');
      return [];
    }
  }

  Future<void> _showSendNotificationDialog() async {
    final users = await _fetchUsers();

    if (users.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('No users found in the system'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (context) => SendNotificationDialog(users: users),
    );
  }

  void _showAllUsers() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => AllUsersScreen()),
    );
  }

  Widget _buildAdminStat(String label, String value, IconData icon) {
    return Column(
      children: [
        Icon(icon, color: Color(0xFFFF0000), size: 24),
        SizedBox(height: 8),
        Text(
          value,
          style: TextStyle(
            color: Color(0xFFB8B8C0),
            fontSize: 24,
            fontWeight: FontWeight.bold,
          ),
        ),
        SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            color: Colors.white54,
            fontSize: 11,
            letterSpacing: 1,
          ),
        ),
      ],
    );
  }

  Widget _buildAdminSection(String title, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(24, 20, 24, 12),
          child: Text(
            title,
            style: TextStyle(
              color: Color(0xFFFF0000),
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 2,
            ),
          ),
        ),
        ...children,
        Divider(color: Colors.white10, thickness: 1),
      ],
    );
  }

  Widget _buildAdminAction(String title, IconData icon, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: Colors.white10, width: 0.5)),
        ),
        child: Row(
          children: [
            Container(
              padding: EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Color(0xFFFF0000).withOpacity(0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, color: Color(0xFFFF0000), size: 24),
            ),
            SizedBox(width: 16),
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  color: Color(0xFFB8B8C0),
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Icon(Icons.arrow_forward_ios, color: Colors.white30, size: 16),
          ],
        ),
      ),
    );
  }
}

// ==================== QUESTS V2: ADMIN FEATURE FLAGS PANEL ====================

class _QuestFeatureFlagsPanel extends StatelessWidget {
  const _QuestFeatureFlagsPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<QuestsConfig>(
      valueListenable: questsConfig,
      builder: (context, cfg, _) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
          child: Column(
            children: [
              _flagRow(
                icon: Icons.power_settings_new,
                label: 'QUESTS ENABLED',
                subtitle: 'Master switch — when off, the SIDEQUESTS tab shows offline.',
                value: cfg.enabled,
                onChanged: (v) => _writeFlag(context, 'enabled', v),
              ),
              _flagRow(
                icon: Icons.today,
                label: 'DAILY ROTATION',
                subtitle: 'Spawn fresh daily quests at 04:00 from templates.',
                value: cfg.dailyRotationEnabled,
                onChanged: cfg.enabled
                    ? (v) => _writeFlag(context, 'dailyRotationEnabled', v)
                    : null,
              ),
              _flagRow(
                icon: Icons.local_fire_department,
                label: 'STREAKS',
                subtitle: 'Track consecutive-day activity and award milestone XP.',
                value: cfg.streaksEnabled,
                onChanged: cfg.enabled
                    ? (v) => _writeFlag(context, 'streaksEnabled', v)
                    : null,
              ),
              _flagRow(
                icon: Icons.auto_awesome,
                label: 'AI QUEST DRAFTS',
                subtitle: 'Allow Claude-generated titles & descriptions in admin.',
                value: cfg.aiGenerationEnabled,
                onChanged: cfg.enabled
                    ? (v) => _writeFlag(context, 'aiGenerationEnabled', v)
                    : null,
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _flagRow({
    required IconData icon,
    required String label,
    required String subtitle,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) {
    final dimmed = onChanged == null;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.white10, width: 0.5)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFFFF0000).withOpacity(dimmed ? 0.05 : 0.2),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon,
                color: dimmed ? Colors.white24 : const Color(0xFFFF0000),
                size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: dimmed ? Colors.white30 : const Color(0xFFB8B8C0),
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: dimmed ? Colors.white24 : Colors.white54,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeColor: const Color(0xFF00FF41),
            activeTrackColor: const Color(0xFF00FF41).withOpacity(0.4),
            inactiveThumbColor: Colors.white38,
            inactiveTrackColor: Colors.white12,
          ),
        ],
      ),
    );
  }

  Future<void> _writeFlag(BuildContext context, String field, bool value) async {
    HapticFeedback.selectionClick();
    try {
      await QuestsConfigService.instance.updateFlags({field: value});
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to update: $e'),
          backgroundColor: const Color(0xFFFF0000),
        ),
      );
    }
  }
}

// All Users Screen
class AllUsersScreen extends StatefulWidget {
  const AllUsersScreen({super.key});

  @override
  State<AllUsersScreen> createState() => _AllUsersScreenState();
}

class _AllUsersScreenState extends State<AllUsersScreen> {
  List<Map<String, dynamic>> _users = [];
  List<Map<String, dynamic>> _filteredUsers = [];
  bool _isLoading = true;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _loadUsers();
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    setState(() {
      _searchQuery = _searchController.text.trim().toLowerCase();
      _applySearch();
    });
  }

  void _applySearch() {
    if (_searchQuery.isEmpty) {
      _filteredUsers = List.from(_users);
    } else {
      _filteredUsers = _users.where((user) {
        final name = (user['name'] ?? '').toString().toLowerCase();
        final email = (user['email'] ?? '').toString().toLowerCase();
        final phone = (user['phone'] ?? '').toString().toLowerCase();
        final instagram = (user['instagram'] ?? '').toString().toLowerCase();
        final referralCode = (user['referralCode'] ?? '').toString().toLowerCase();
        return name.contains(_searchQuery) ||
            email.contains(_searchQuery) ||
            phone.contains(_searchQuery) ||
            instagram.contains(_searchQuery) ||
            referralCode.contains(_searchQuery);
      }).toList();
    }
  }

  Future<void> _loadUsers() async {
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('applications')
          .orderBy('submittedAt', descending: true)
          .get();

      final loaded = snapshot.docs.map((doc) {
        final data = doc.data();
        data['docId'] = doc.id;
        return data;
      }).toList();
      setState(() {
        _users = loaded;
        _applySearch();
        _isLoading = false;
      });
    } catch (e) {
      print('Error loading users: $e');
      setState(() => _isLoading = false);
    }
  }

  Future<void> _deleteUser(Map<String, dynamic> user) async {
    final docId = user['docId'];
    if (docId == null) {
      AppUtils.showError(context, 'Cannot delete user: missing document ID');
      return;
    }

    // Show confirmation dialog
    final confirmed = await AppUtils.showConfirmDialog(
      context,
      title: 'Delete User?',
      message:
          'Are you sure you want to delete ${user['name'] ?? 'this user'}? This action cannot be undone.',
      confirmText: 'Delete',
      cancelText: 'Cancel',
      isDangerous: true,
    );

    if (!confirmed) return;

    try {
      // Show loading indicator
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => Center(
          child: Container(
            padding: EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Color(0xFFFF0000)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(
                  valueColor: AlwaysStoppedAnimation(Color(0xFFFF0000)),
                ),
                SizedBox(height: 16),
                Text(
                  'Deleting user...',
                  style: TextStyle(color: Color(0xFFB8B8C0)),
                ),
              ],
            ),
          ),
        ),
      );

      // Delete from Firestore
      await FirebaseFirestore.instance
          .collection('applications')
          .doc(docId)
          .delete();

      // Close loading dialog
      if (mounted) Navigator.pop(context);

      // Reload users list
      await _loadUsers();

      if (mounted) {
        AppUtils.showSuccess(
          context,
          'User ${user['name'] ?? 'deleted'} successfully',
        );
      }
    } catch (e) {
      // Close loading dialog if still open
      if (mounted) Navigator.pop(context);

      print('Error deleting user: $e');
      if (mounted) {
        AppUtils.showError(context, 'Failed to delete user: ${e.toString()}');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: Color(0xFFB8B8C0)),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'ALL USERS',
          style: TextStyle(
            color: Color(0xFFFF0000),
            fontSize: 16,
            fontWeight: FontWeight.bold,
            letterSpacing: 1,
          ),
        ),
        centerTitle: true,
      ),
      body: _isLoading
          ? Center(
              child: CircularProgressIndicator(
                valueColor: AlwaysStoppedAnimation(Color(0xFFFF0000)),
              ),
            )
          : _users.isEmpty
          ? AppUtils.buildEmptyState(
              icon: Icons.people_outline,
              title: 'No Users Found',
              subtitle: 'No registered users in the system yet',
            )
          : Column(
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: TextField(
                    controller: _searchController,
                    style: TextStyle(color: Colors.white, fontSize: 14),    
                    decoration: InputDecoration(
                      hintText: 'Search name, email, phone, IG...',
                      hintStyle: TextStyle(color: Colors.white38, fontSize: 13),
                      prefixIcon: Icon(Icons.search, color: Colors.white38, size: 20),
                      suffixIcon: _searchQuery.isNotEmpty
                          ? IconButton(
                              icon: Icon(Icons.close, color: Colors.white38, size: 18),
                              onPressed: () => _searchController.clear(),
                            )
                          : null,
                      filled: true,
                      fillColor: Color(0xFF1A1A1A).withOpacity(0.9),
                      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(color: Colors.white10),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(color: Colors.white10),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(color: Color(0xFFFF0000), width: 1),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _searchQuery.isEmpty
                          ? '${_users.length} users'
                          : '${_filteredUsers.length} of ${_users.length} users',
                      style: TextStyle(color: Colors.white38, fontSize: 11),
                    ),
                  ),
                ),
                Expanded(
                  child: _filteredUsers.isEmpty
                      ? Center(
                          child: Text(
                            'No users match "${_searchController.text}"',
                            style: TextStyle(color: Colors.white38, fontSize: 14),
                          ),
                        )
                      : ListView.builder(
                          padding: EdgeInsets.fromLTRB(16, 4, 16, 16),
                          itemCount: _filteredUsers.length,
                          itemBuilder: (context, index) {
                            final user = _filteredUsers[index];
                            return _buildUserCard(user);
                          },
                        ),
                ),
              ],
            ),
    );
  }

  Widget _buildUserCard(Map<String, dynamic> user) {
    final normalizedStatus = _normalizeUserStatus(user);
    return Container(
      margin: EdgeInsets.only(bottom: 12),
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Color(0xFF1A1A1A).withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 50,
                height: 50,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(0xFFFF0000).withOpacity(0.2),
                  border: Border.all(color: Color(0xFFFF0000), width: 2),
                ),
                child: Icon(Icons.person, color: Color(0xFFFF0000), size: 24),
              ),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            user['name'] ?? 'Unknown',
                            style: TextStyle(
                              color: Color(0xFFB8B8C0),
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        if (normalizedStatus.isNotEmpty) ...[
                          Container(
                            padding: EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: _getStatusColor(
                                normalizedStatus,
                              ).withOpacity(0.2),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: _getStatusColor(normalizedStatus),
                                width: 1,
                              ),
                            ),
                            child: Text(
                              _getStatusLabel(normalizedStatus),
                              style: TextStyle(
                                color: _getStatusColor(normalizedStatus),
                                fontSize: 9,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    SizedBox(height: 4),
                    Text(
                      user['email'] ?? 'No email',
                      style: TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                  ],
                ),
              ),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Color(0xFF00FF41).withOpacity(0.1),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Color(0xFF00FF41)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.stars, color: Color(0xFF00FF41), size: 14),
                    SizedBox(width: 4),
                    Text(
                      '${user['xpPoints'] ?? user['xp'] ?? 0} XP',
                      style: TextStyle(
                        color: Color(0xFF00FF41),
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: 12),
          Divider(color: Colors.white10, height: 1),
          SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _buildUserInfo(Icons.phone, user['phone'] ?? 'N/A'),
              ),
              Container(width: 1, height: 30, color: Colors.white10),
              Expanded(
                child: _buildUserInfo(
                  Icons.alternate_email,
                  user['instagram'] ?? 'N/A',
                ),
              ),
            ],
          ),
          if (user['referralCode'] != null) ...[
            SizedBox(height: 12),
            Row(
              children: [
                Icon(Icons.qr_code, color: Colors.white54, size: 16),
                SizedBox(width: 8),
                Text(
                  'Code: ',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
                Text(
                  user['referralCode'],
                  style: TextStyle(
                    color: Color(0xFFFF0000),
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Spacer(),
                if (user['submittedAt'] != null)
                  Text(
                    AppUtils.formatDate(user['submittedAt']),
                    style: TextStyle(color: Colors.white38, fontSize: 11),
                  ),
              ],
            ),
          ],
          SizedBox(height: 12),
          // Delete Button
          ElevatedButton.icon(
            onPressed: () => _deleteUser(user),
            icon: Icon(Icons.delete_forever, size: 16),
            label: Text(
              'DELETE USER',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 1,
              ),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: Color(0xFFFF0000).withOpacity(0.1),
              foregroundColor: Color(0xFFFF0000),
              side: BorderSide(color: Color(0xFFFF0000), width: 1),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              padding: EdgeInsets.symmetric(vertical: 10, horizontal: 16),
              minimumSize: Size(double.infinity, 40),
            ),
          ),
        ],
      ),
    );
  }

  String _normalizeUserStatus(Map<String, dynamic> user) {
    final rawStatus = (user['status'] ?? '').toString().trim().toLowerCase();
    final hasReferral = (user['referralCode'] ?? '')
        .toString()
        .trim()
        .isNotEmpty;

    if (rawStatus == 'approved') return 'approved';
    if (rawStatus == 'denied' || rawStatus == 'rejected') return 'denied';
    if (rawStatus == 'pending') {
      return hasReferral ? 'approved' : 'pending';
    }

    // Backward compatibility: older records without status
    if (hasReferral) return 'approved';
    return 'pending';
  }

  String _getStatusLabel(String status) {
    switch (status.toLowerCase()) {
      case 'approved':
        return 'APPROVED';
      case 'pending':
        return 'PENDING';
      case 'denied':
        return 'DENIED';
      default:
        return status.toUpperCase();
    }
  }

  Color _getStatusColor(String status) {
    switch (status.toLowerCase()) {
      case 'approved':
        return Color(0xFF00FF41);
      case 'pending':
        return Colors.orange;
      case 'denied':
        return Color(0xFFFF0000);
      default:
        return Colors.white54;
    }
  }

  Widget _buildUserInfo(IconData icon, String text) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, color: Colors.white54, size: 14),
        SizedBox(width: 6),
        Flexible(
          child: Text(
            text,
            style: TextStyle(color: Colors.white70, fontSize: 11),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

// Send XP Dialog
class SendXPDialog extends StatefulWidget {
  final List<Map<String, dynamic>> users;

  const SendXPDialog({super.key, required this.users});

  @override
  State<SendXPDialog> createState() => _SendXPDialogState();
}

// Screen for sending XP to users (Admin Only)
class SendXPToUsersScreen extends StatefulWidget {
  const SendXPToUsersScreen({super.key});

  @override
  _SendXPToUsersScreenState createState() => _SendXPToUsersScreenState();
}

class _SendXPToUsersScreenState extends State<SendXPToUsersScreen> {
  List<Map<String, dynamic>> _users = [];
  bool _isLoading = true;
  final Map<String, TextEditingController> _xpControllers = {};
  final Map<String, bool> _isSending = {};

  @override
  void initState() {
    super.initState();
    _loadUsers();
  }

  @override
  void dispose() {
    // Dispose all controllers
    for (var controller in _xpControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _loadUsers() async {
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('applications')
          .orderBy('submittedAt', descending: true)
          .get();

      setState(() {
        _users = snapshot.docs.map((doc) {
          return {'id': doc.id, ...doc.data()};
        }).toList();

        // Initialize controllers and sending states for each user
        for (var user in _users) {
          final userId = user['id'] as String;
          _xpControllers[userId] = TextEditingController();
          _isSending[userId] = false;
        }

        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
      AppUtils.showError(context, 'Failed to load users: $e');
    }
  }

  Future<void> _sendXP(String userId, String userName) async {
    final controller = _xpControllers[userId]!;
    final xpText = controller.text.trim();

    if (xpText.isEmpty) {
      AppUtils.showError(context, 'Please enter XP amount');
      return;
    }

    final xpAmount = int.tryParse(xpText);
    if (xpAmount == null || xpAmount <= 0) {
      AppUtils.showError(context, 'Please enter a valid positive number');
      return;
    }

    setState(() => _isSending[userId] = true);

    try {
      final docRef = FirebaseFirestore.instance
          .collection('applications')
          .doc(userId);
      final doc = await docRef.get();

      if (doc.exists) {
        final currentXPField = doc.data()?['xpPoints'];
        final currentXP = (currentXPField is num)
            ? currentXPField.toInt()
            : currentXPField ?? 0;
        final newXP = currentXP + xpAmount;

        await docRef.update({'xpPoints': newXP});

        // Log the transaction
        print(
          'DEBUG: Sent $xpAmount XP to $userName. Old: $currentXP, New: $newXP',
        );
        await FirebaseFirestore.instance.collection('xp_transactions').add({
          'adminName': 'Admin',
          'userId': userId,
          'userName': userName,
          'userEmail': doc.data()?['email'] ?? '',
          'amount': xpAmount,
          'previousXP': currentXP,
          'newXP': newXP,
          'timestamp': FieldValue.serverTimestamp(),
        });

        // Clear the input field
        controller.clear();

        // Reload users to show updated XP
        await _loadUsers();

        AppUtils.showSuccess(context, 'Sent $xpAmount XP to $userName');
      } else {
        AppUtils.showError(context, 'User not found');
      }
    } catch (e) {
      AppUtils.showError(context, 'Failed to send XP: $e');
    } finally {
      setState(() => _isSending[userId] = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[50],
      appBar: AppBar(
        title: Text(
          'Send XP to Users',
          style: TextStyle(color: Color(0xFFB8B8C0)),
        ),
        backgroundColor: Color(0xFFFF0000),
        iconTheme: IconThemeData(color: Color(0xFFB8B8C0)),
        elevation: 2,
      ),
      body: _isLoading
          ? AppUtils.buildLoadingIndicator(message: 'Loading users...')
          : _users.isEmpty
          ? AppUtils.buildEmptyState(
              icon: Icons.person_off,
              title: 'No Users Found',
              subtitle: 'No registered users to send XP to',
            )
          : ListView.builder(
              padding: EdgeInsets.all(16),
              itemCount: _users.length,
              itemBuilder: (context, index) {
                final user = _users[index];
                final userId = user['id'] as String;
                final name = user['name'] ?? 'Unknown';
                final email = user['email'] ?? 'No email';
                final currentXP = user['xp'] ?? 0;
                final controller = _xpControllers[userId]!;
                final isSending = _isSending[userId] ?? false;

                return Card(
                  margin: EdgeInsets.only(bottom: 12),
                  elevation: 2,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // User info header
                        Row(
                          children: [
                            CircleAvatar(
                              backgroundColor: Color(
                                0xFFFF0000,
                              ).withOpacity(0.1),
                              child: Icon(
                                Icons.person,
                                color: Color(0xFFFF0000),
                              ),
                            ),
                            SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    name,
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  SizedBox(height: 2),
                                  Text(
                                    email,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey[600],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            // Current XP badge
                            Container(
                              padding: EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.green,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                '${AppUtils.formatXP(currentXP)} XP',
                                style: TextStyle(
                                  color: Color(0xFFB8B8C0),
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),

                        SizedBox(height: 16),
                        Divider(),
                        SizedBox(height: 12),

                        // XP input and send button
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: controller,
                                keyboardType: TextInputType.number,
                                decoration: InputDecoration(
                                  labelText: 'XP Amount',
                                  hintText: 'Enter XP to send',
                                  prefixIcon: Icon(
                                    Icons.stars,
                                    color: Color(0xFFFF0000),
                                  ),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(8),
                                    borderSide: BorderSide(
                                      color: Colors.grey[300]!,
                                    ),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(8),
                                    borderSide: BorderSide(
                                      color: Color(0xFFFF0000),
                                      width: 2,
                                    ),
                                  ),
                                  contentPadding: EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 14,
                                  ),
                                ),
                                enabled: !isSending,
                              ),
                            ),
                            SizedBox(width: 12),
                            ElevatedButton(
                              onPressed: isSending
                                  ? null
                                  : () => _sendXP(userId, name),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Color(0xFFFF0000),
                                foregroundColor: Colors.white,
                                padding: EdgeInsets.symmetric(
                                  horizontal: 20,
                                  vertical: 14,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                              ),
                              child: isSending
                                  ? SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        valueColor:
                                            AlwaysStoppedAnimation<Color>(
                                              Colors.white,
                                            ),
                                      ),
                                    )
                                  : Row(
                                      children: [
                                        Icon(Icons.send, size: 18),
                                        SizedBox(width: 4),
                                        Text('Send'),
                                      ],
                                    ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}

// Statistics Screen (Admin Only)
class StatisticsScreen extends StatefulWidget {
  const StatisticsScreen({super.key});

  @override
  _StatisticsScreenState createState() => _StatisticsScreenState();
}

class _StatisticsScreenState extends State<StatisticsScreen> {
  bool _isLoading = true;
  int _totalUsers = 0;
  int _totalXP = 0;
  int _avgXP = 0;
  int _newUsersThisWeek = 0;
  List<Map<String, dynamic>> _topUsers = [];
  Map<String, int> _xpDistribution = {};

  @override
  void initState() {
    super.initState();
    _loadStatistics();
  }

  Future<void> _loadStatistics() async {
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('applications')
          .orderBy('submittedAt', descending: true)
          .get();

      final users = snapshot.docs;
      int totalXP = 0;
      int newUsersCount = 0;
      final weekAgo = DateTime.now().subtract(Duration(days: 7));

      // Calculate XP distribution buckets
      int xp0_100 = 0;
      int xp100_500 = 0;
      int xp500_1000 = 0;
      int xp1000plus = 0;

      for (var doc in users) {
        final data = doc.data();
        final xp = (data['xp'] ?? 0) as int;
        totalXP += xp;

        // Count new users this week
        final submittedAt = (data['submittedAt'] as Timestamp?)?.toDate();
        if (submittedAt != null && submittedAt.isAfter(weekAgo)) {
          newUsersCount++;
        }

        // XP distribution
        if (xp <= 100) {
          xp0_100++;
        } else if (xp <= 500) {
          xp100_500++;
        } else if (xp <= 1000) {
          xp500_1000++;
        } else {
          xp1000plus++;
        }
      }

      // Get top 10 users by XP
      final sortedUsers = users.map((doc) {
        final data = doc.data();
        return {
          'name': data['name'] ?? 'Unknown',
          'xp': (data['xp'] ?? 0) as int,
          'referralCode': data['referralCode'] ?? '',
        };
      }).toList();
      sortedUsers.sort((a, b) => (b['xp'] as int).compareTo(a['xp'] as int));
      final topUsers = sortedUsers.take(10).toList();

      setState(() {
        _totalUsers = users.length;
        _totalXP = totalXP;
        _avgXP = users.isEmpty ? 0 : (totalXP / users.length).round();
        _newUsersThisWeek = newUsersCount;
        _topUsers = topUsers;
        _xpDistribution = {
          '0-100 XP': xp0_100,
          '100-500 XP': xp100_500,
          '500-1K XP': xp500_1000,
          '1K+ XP': xp1000plus,
        };
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
      AppUtils.showError(context, 'Failed to load statistics: $e');
    }
  }

  Widget _buildStatCard(
    String title,
    String value,
    IconData icon,
    Color color,
  ) {
    return Card(
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Container(
        padding: EdgeInsets.all(12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          gradient: LinearGradient(
            colors: [color.withOpacity(0.8), color],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Color(0xFFB8B8C0), size: 28),
            SizedBox(height: 8),
            Flexible(
              child: Text(
                value,
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFFB8B8C0),
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            SizedBox(height: 2),
            Flexible(
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.white.withOpacity(0.9),
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDistributionBar(String label, int count, int maxCount) {
    final percentage = maxCount == 0 ? 0.0 : (count / maxCount);
    return Padding(
      padding: EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                label,
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
              ),
              Text(
                '$count users',
                style: TextStyle(fontSize: 14, color: Colors.grey[600]),
              ),
            ],
          ),
          SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: percentage,
              minHeight: 10,
              backgroundColor: Colors.grey[200],
              valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFFF0000)),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[50],
      appBar: AppBar(
        title: Text('Statistics', style: TextStyle(color: Color(0xFFB8B8C0))),
        backgroundColor: Color(0xFFFF0000),
        iconTheme: IconThemeData(color: Color(0xFFB8B8C0)),
        elevation: 2,
        actions: [
          IconButton(
            icon: Icon(Icons.refresh),
            onPressed: () {
              setState(() => _isLoading = true);
              _loadStatistics();
            },
          ),
        ],
      ),
      body: _isLoading
          ? AppUtils.buildLoadingIndicator(message: 'Loading statistics...')
          : RefreshIndicator(
              onRefresh: _loadStatistics,
              color: Color(0xFFFF0000),
              child: SingleChildScrollView(
                physics: AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Key Metrics Cards
                    Text(
                      'Key Metrics',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Colors.grey[800],
                      ),
                    ),
                    SizedBox(height: 12),
                    GridView.count(
                      shrinkWrap: true,
                      physics: NeverScrollableScrollPhysics(),
                      crossAxisCount: 2,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12,
                      childAspectRatio: 1.3,
                      children: [
                        _buildStatCard(
                          'Total Users',
                          '$_totalUsers',
                          Icons.people,
                          Color(0xFFFF0000),
                        ),
                        _buildStatCard(
                          'Total XP',
                          AppUtils.formatXP(_totalXP),
                          Icons.stars,
                          Colors.orange,
                        ),
                        _buildStatCard(
                          'Avg XP/User',
                          AppUtils.formatXP(_avgXP),
                          Icons.trending_up,
                          Colors.blue,
                        ),
                        _buildStatCard(
                          'New This Week',
                          '$_newUsersThisWeek',
                          Icons.person_add,
                          Colors.green,
                        ),
                      ],
                    ),
                    SizedBox(height: 32),

                    // XP Distribution
                    Text(
                      'XP Distribution',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Colors.grey[800],
                      ),
                    ),
                    SizedBox(height: 12),
                    Card(
                      elevation: 2,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: Column(
                          children: _xpDistribution.entries.map((entry) {
                            return _buildDistributionBar(
                              entry.key,
                              entry.value,
                              _totalUsers,
                            );
                          }).toList(),
                        ),
                      ),
                    ),
                    SizedBox(height: 32),

                    // Top Users Leaderboard
                    Text(
                      'Top Users by XP',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Colors.grey[800],
                      ),
                    ),
                    SizedBox(height: 12),
                    if (_topUsers.isEmpty)
                      AppUtils.buildEmptyState(
                        icon: Icons.emoji_events,
                        title: 'No Users Yet',
                        subtitle: 'Users will appear here as they earn XP',
                      )
                    else
                      Card(
                        elevation: 2,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: ListView.separated(
                          shrinkWrap: true,
                          physics: NeverScrollableScrollPhysics(),
                          itemCount: _topUsers.length,
                          separatorBuilder: (context, index) =>
                              Divider(height: 1),
                          itemBuilder: (context, index) {
                            final user = _topUsers[index];
                            final name = user['name'] as String;
                            final xp = user['xp'] as int;
                            final referralCode = user['referralCode'] as String;

                            // Medal colors for top 3
                            Color? medalColor;
                            IconData? medalIcon;
                            if (index == 0) {
                              medalColor = Color(0xFFFFD700); // Gold
                              medalIcon = Icons.emoji_events;
                            } else if (index == 1) {
                              medalColor = Color(0xFFC0C0C0); // Silver
                              medalIcon = Icons.emoji_events;
                            } else if (index == 2) {
                              medalColor = Color(0xFFCD7F32); // Bronze
                              medalIcon = Icons.emoji_events;
                            }

                            return ListTile(
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 8,
                              ),
                              leading: Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  color: medalColor ?? Colors.grey[200],
                                  shape: BoxShape.circle,
                                ),
                                child: Center(
                                  child: medalIcon != null
                                      ? Icon(
                                          medalIcon,
                                          color: Color(0xFFB8B8C0),
                                          size: 20,
                                        )
                                      : Text(
                                          '${index + 1}',
                                          style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 16,
                                            color: Colors.grey[700],
                                          ),
                                        ),
                                ),
                              ),
                              title: Text(
                                name,
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 16,
                                ),
                              ),
                              subtitle: Text(
                                referralCode.isEmpty
                                    ? 'No referral code'
                                    : 'Code: $referralCode',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey[600],
                                ),
                              ),
                              trailing: Container(
                                padding: EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  color: Color(0xFFFF0000),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  '${AppUtils.formatXP(xp)} XP',
                                  style: TextStyle(
                                    color: Color(0xFFB8B8C0),
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                  ],
                ),
              ),
            ),
    );
  }
}

// Reports Screen (Admin Only)
class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  _ReportsScreenState createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[50],
      appBar: AppBar(
        title: Text('Reports', style: TextStyle(color: Color(0xFFB8B8C0))),
        backgroundColor: Color(0xFFFF0000),
        iconTheme: IconThemeData(color: Color(0xFFB8B8C0)),
        elevation: 2,
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.white,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white70,
          tabs: [
            Tab(icon: Icon(Icons.swap_horiz), text: 'XP'),
            Tab(icon: Icon(Icons.timeline), text: 'Activity'),
            Tab(icon: Icon(Icons.people), text: 'Users'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [XPTransactionsTab(), UserActivityTab(), UserRegistryTab()],
      ),
    );
  }
}

// XP Transactions Tab
class XPTransactionsTab extends StatefulWidget {
  const XPTransactionsTab({super.key});

  @override
  _XPTransactionsTabState createState() => _XPTransactionsTabState();
}

class _XPTransactionsTabState extends State<XPTransactionsTab> {
  List<Map<String, dynamic>> _transactions = [];
  bool _isLoading = true;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _loadTransactions();
  }

  Future<void> _loadTransactions() async {
    setState(() => _isLoading = true);
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('xp_transactions')
          .orderBy('timestamp', descending: true)
          .limit(100)
          .get();

      setState(() {
        _transactions = snapshot.docs.map((doc) {
          return {'id': doc.id, ...doc.data()};
        }).toList();
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
      AppUtils.showError(context, 'Failed to load transactions: $e');
    }
  }

  List<Map<String, dynamic>> get _filteredTransactions {
    if (_searchQuery.isEmpty) return _transactions;
    return _transactions.where((t) {
      final userName = (t['userName'] ?? '').toString().toLowerCase();
      final userEmail = (t['userEmail'] ?? '').toString().toLowerCase();
      final query = _searchQuery.toLowerCase();
      return userName.contains(query) || userEmail.contains(query);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.all(16),
          child: TextField(
            decoration: InputDecoration(
              hintText: 'Search by name or email...',
              prefixIcon: Icon(Icons.search, color: Color(0xFFFF0000)),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Color(0xFFFF0000), width: 2),
              ),
            ),
            onChanged: (value) => setState(() => _searchQuery = value),
          ),
        ),
        Expanded(
          child: _isLoading
              ? AppUtils.buildLoadingIndicator(
                  message: 'Loading transactions...',
                )
              : _filteredTransactions.isEmpty
              ? AppUtils.buildEmptyState(
                  icon: Icons.receipt_long,
                  title: 'No Transactions',
                  subtitle: _searchQuery.isEmpty
                      ? 'XP transactions will appear here'
                      : 'No transactions match your search',
                )
              : RefreshIndicator(
                  onRefresh: _loadTransactions,
                  color: Color(0xFFFF0000),
                  child: ListView.builder(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    itemCount: _filteredTransactions.length,
                    itemBuilder: (context, index) {
                      final tx = _filteredTransactions[index];
                      final userName = tx['userName'] ?? 'Unknown';
                      final userEmail = tx['userEmail'] ?? '';
                      final amount = tx['amount'] ?? 0;
                      final previousXP = tx['previousXP'] ?? 0;
                      final newXP = tx['newXP'] ?? 0;
                      final timestamp = tx['timestamp'] as Timestamp?;

                      return Card(
                        margin: EdgeInsets.only(bottom: 12),
                        elevation: 2,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: ListTile(
                          contentPadding: EdgeInsets.all(16),
                          leading: CircleAvatar(
                            backgroundColor: Colors.green.withOpacity(0.1),
                            child: Icon(Icons.add, color: Colors.green),
                          ),
                          title: Text(
                            userName,
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(height: 4),
                              Text(
                                userEmail,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey[600],
                                ),
                              ),
                              SizedBox(height: 4),
                              Text(
                                '$previousXP XP → $newXP XP',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey[700],
                                ),
                              ),
                              if (timestamp != null)
                                Text(
                                  AppUtils.formatDate(timestamp.toDate()),
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.grey[500],
                                  ),
                                ),
                            ],
                          ),
                          trailing: Container(
                            padding: EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.green,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              '+$amount XP',
                              style: TextStyle(
                                color: Color(0xFFB8B8C0),
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }
}

// User Activity Tab
class UserActivityTab extends StatefulWidget {
  const UserActivityTab({super.key});

  @override
  _UserActivityTabState createState() => _UserActivityTabState();
}

class _UserActivityTabState extends State<UserActivityTab> {
  List<Map<String, dynamic>> _activities = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadActivity();
  }

  Future<void> _loadActivity() async {
    setState(() => _isLoading = true);
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('applications')
          .orderBy('submittedAt', descending: true)
          .limit(50)
          .get();

      setState(() {
        _activities = snapshot.docs.map((doc) {
          final data = doc.data();
          return {
            'type': 'registration',
            'name': data['name'] ?? 'Unknown',
            'email': data['email'] ?? '',
            'referralCode': data['referralCode'] ?? '',
            'timestamp': data['submittedAt'],
          };
        }).toList();
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
      AppUtils.showError(context, 'Failed to load activity: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return _isLoading
        ? AppUtils.buildLoadingIndicator(message: 'Loading activity...')
        : _activities.isEmpty
        ? AppUtils.buildEmptyState(
            icon: Icons.timeline,
            title: 'No Activity',
            subtitle: 'User activity will appear here',
          )
        : RefreshIndicator(
            onRefresh: _loadActivity,
            color: Color(0xFFFF0000),
            child: ListView.builder(
              padding: EdgeInsets.all(16),
              itemCount: _activities.length,
              itemBuilder: (context, index) {
                final activity = _activities[index];
                final name = activity['name'] ?? 'Unknown';
                final email = activity['email'] ?? '';
                final referralCode = activity['referralCode'] ?? '';
                final timestamp = activity['timestamp'] as Timestamp?;

                return Card(
                  margin: EdgeInsets.only(bottom: 12),
                  elevation: 2,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: ListTile(
                    contentPadding: EdgeInsets.all(16),
                    leading: CircleAvatar(
                      backgroundColor: Color(0xFFFF0000).withOpacity(0.1),
                      child: Icon(Icons.person_add, color: Color(0xFFFF0000)),
                    ),
                    title: Text(
                      'New Registration',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(height: 4),
                        Text(
                          name,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          email,
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[600],
                          ),
                        ),
                        if (referralCode.isNotEmpty)
                          Text(
                            'Code: $referralCode',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey[700],
                            ),
                          ),
                        if (timestamp != null)
                          Text(
                            AppUtils.timeAgo(timestamp.toDate()),
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.grey[500],
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          );
  }
}

// User Registry Tab with Export
class UserRegistryTab extends StatefulWidget {
  const UserRegistryTab({super.key});

  @override
  _UserRegistryTabState createState() => _UserRegistryTabState();
}

class _UserRegistryTabState extends State<UserRegistryTab> {
  List<Map<String, dynamic>> _users = [];
  bool _isLoading = true;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _loadUsers();
  }

  Future<void> _loadUsers() async {
    setState(() => _isLoading = true);
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('applications')
          .orderBy('submittedAt', descending: true)
          .get();

      setState(() {
        _users = snapshot.docs.map((doc) {
          return {'id': doc.id, ...doc.data()};
        }).toList();
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
      AppUtils.showError(context, 'Failed to load users: $e');
    }
  }

  List<Map<String, dynamic>> get _filteredUsers {
    if (_searchQuery.isEmpty) return _users;
    return _users.where((u) {
      final name = (u['name'] ?? '').toString().toLowerCase();
      final email = (u['email'] ?? '').toString().toLowerCase();
      final phone = (u['phone'] ?? '').toString().toLowerCase();
      final query = _searchQuery.toLowerCase();
      return name.contains(query) ||
          email.contains(query) ||
          phone.contains(query);
    }).toList();
  }

  void _exportToCSV() {
    final csv = StringBuffer();
    csv.writeln(
      'Name,Email,Phone,Instagram,XP,Referral Code,Registration Date',
    );

    for (var user in _filteredUsers) {
      final name = user['name'] ?? '';
      final email = user['email'] ?? '';
      final phone = user['phone'] ?? '';
      final instagram = user['instagram'] ?? '';
      final xp = user['xp'] ?? 0;
      final code = user['referralCode'] ?? '';
      final timestamp = user['submittedAt'] as Timestamp?;
      final date = timestamp != null
          ? AppUtils.formatDate(timestamp.toDate())
          : 'N/A';

      csv.writeln('"$name","$email","$phone","$instagram",$xp,"$code","$date"');
    }

    AppUtils.copyToClipboard(
      context,
      csv.toString(),
      message: 'CSV data copied! Paste in spreadsheet app',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  decoration: InputDecoration(
                    hintText: 'Search users...',
                    prefixIcon: Icon(Icons.search, color: Color(0xFFFF0000)),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(
                        color: Color(0xFFFF0000),
                        width: 2,
                      ),
                    ),
                  ),
                  onChanged: (value) => setState(() => _searchQuery = value),
                ),
              ),
              SizedBox(width: 12),
              ElevatedButton.icon(
                onPressed: _filteredUsers.isEmpty ? null : _exportToCSV,
                icon: Icon(Icons.download),
                label: Text('Export'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Color(0xFFFF0000),
                  foregroundColor: Colors.white,
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: _isLoading
              ? AppUtils.buildLoadingIndicator(message: 'Loading users...')
              : _filteredUsers.isEmpty
              ? AppUtils.buildEmptyState(
                  icon: Icons.people,
                  title: 'No Users',
                  subtitle: _searchQuery.isEmpty
                      ? 'Users will appear here'
                      : 'No users match your search',
                )
              : RefreshIndicator(
                  onRefresh: _loadUsers,
                  color: Color(0xFFFF0000),
                  child: ListView.builder(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    itemCount: _filteredUsers.length,
                    itemBuilder: (context, index) {
                      final user = _filteredUsers[index];
                      final name = user['name'] ?? 'Unknown';
                      final email = user['email'] ?? '';
                      final phone = user['phone'] ?? '';
                      final instagram = user['instagram'] ?? '';
                      final xp = user['xp'] ?? 0;
                      final code = user['referralCode'] ?? '';
                      final timestamp = user['submittedAt'] as Timestamp?;

                      return Card(
                        margin: EdgeInsets.only(bottom: 12),
                        elevation: 2,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: ExpansionTile(
                          leading: CircleAvatar(
                            backgroundColor: Color(0xFFFF0000).withOpacity(0.1),
                            child: Icon(Icons.person, color: Color(0xFFFF0000)),
                          ),
                          title: Text(
                            name,
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                          subtitle: Text(email, style: TextStyle(fontSize: 12)),
                          trailing: Container(
                            padding: EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.green,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              '${AppUtils.formatXP(xp)} XP',
                              style: TextStyle(
                                color: Color(0xFFB8B8C0),
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          children: [
                            Padding(
                              padding: EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _buildDetailRow(
                                    'Phone',
                                    phone.isEmpty ? 'N/A' : phone,
                                  ),
                                  _buildDetailRow(
                                    'Instagram',
                                    instagram.isEmpty ? 'N/A' : instagram,
                                  ),
                                  _buildDetailRow(
                                    'Referral Code',
                                    code.isEmpty ? 'N/A' : code,
                                  ),
                                  if (timestamp != null)
                                    _buildDetailRow(
                                      'Registered',
                                      AppUtils.formatDate(timestamp.toDate()),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: Colors.grey[700],
              ),
            ),
          ),
          Expanded(
            child: Text(value, style: TextStyle(color: Colors.grey[800])),
          ),
        ],
      ),
    );
  }
}

class _SendXPDialogState extends State<SendXPDialog> {
  String? selectedUserId;
  final TextEditingController _xpController = TextEditingController();
  bool _isSending = false;

  @override
  void dispose() {
    _xpController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Color(0xFF1A1A1A).withValues(alpha: 0.85),
      title: Row(
        children: [
          Icon(Icons.stars, color: Color(0xFFFF0000)),
          SizedBox(width: 8),
          Text(
            'Send XP to User',
            style: TextStyle(
              color: Color(0xFFB8B8C0),
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Select User',
              style: TextStyle(
                color: Color(0xFFFF0000),
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 1,
              ),
            ),
            SizedBox(height: 8),
            Container(
              padding: EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white10),
              ),
              child: DropdownButton<String>(
                value: selectedUserId,
                isExpanded: true,
                hint: Text(
                  'Choose a user...',
                  style: TextStyle(color: Colors.white54),
                ),
                dropdownColor: Color(0xFF1A1A1A).withValues(alpha: 0.85),
                underline: SizedBox(),
                style: TextStyle(color: Color(0xFFB8B8C0)),
                items: widget.users.map((user) {
                  return DropdownMenuItem<String>(
                    value: user['docId'],
                    child: Text(
                      '${user['name'] ?? 'Unknown'} (${user['email'] ?? 'No email'})',
                      style: TextStyle(color: Color(0xFFB8B8C0)),
                    ),
                  );
                }).toList(),
                onChanged: (value) {
                  setState(() {
                    selectedUserId = value;
                  });
                },
              ),
            ),
            SizedBox(height: 20),
            Text(
              'XP Amount',
              style: TextStyle(
                color: Color(0xFFFF0000),
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 1,
              ),
            ),
            SizedBox(height: 8),
            TextField(
              controller: _xpController,
              keyboardType: TextInputType.number,
              style: TextStyle(color: Color(0xFFB8B8C0)),
              decoration: InputDecoration(
                hintText: 'Enter XP amount',
                hintStyle: TextStyle(color: Colors.white30),
                filled: true,
                fillColor: Colors.black,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: Colors.white10),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: Colors.white10),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: Color(0xFFFF0000), width: 2),
                ),
                prefixIcon: Icon(Icons.add, color: Color(0xFFFF0000)),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSending ? null : () => Navigator.pop(context),
          child: Text('CANCEL', style: TextStyle(color: Colors.white54)),
        ),
        ElevatedButton(
          onPressed: _isSending ? null : _sendXP,
          style: ElevatedButton.styleFrom(
            backgroundColor: Color(0xFFFF0000),
            foregroundColor: Colors.white,
          ),
          child: _isSending
              ? SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(Colors.white),
                  ),
                )
              : Text('SEND XP'),
        ),
      ],
    );
  }

  Future<void> _sendXP() async {
    if (selectedUserId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Please select a user'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final xpAmount = int.tryParse(_xpController.text);
    if (xpAmount == null || xpAmount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Please enter a valid XP amount'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() => _isSending = true);

    try {
      // Get current user data
      final userDoc = await db
          .collection('applications')
          .doc(selectedUserId)
          .get();

      if (!userDoc.exists) {
        throw Exception('User not found');
      }

      final userData = userDoc.data()!;
      final currentXP = userData['xp'] ?? 0;
      final newXP = currentXP + xpAmount;

      // Update user's XP
      await db.collection('applications').doc(selectedUserId).update({
        'xp': newXP,
      });

      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Successfully sent $xpAmount XP to ${userData['name']}!',
            ),
            backgroundColor: Color(0xFF00FF41),
          ),
        );
      }
    } catch (e) {
      print('Error sending XP: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error sending XP: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSending = false);
      }
    }
  }
}

// Send Notification Dialog
class SendNotificationDialog extends StatefulWidget {
  final List<Map<String, dynamic>> users;

  const SendNotificationDialog({super.key, required this.users});

  @override
  State<SendNotificationDialog> createState() => _SendNotificationDialogState();
}

class _SendNotificationDialogState extends State<SendNotificationDialog> {
  final TextEditingController _messageController = TextEditingController();
  bool _sendSMS = false;
  bool _sendEmail = false;
  bool _sendInApp = true;
  bool _isSending = false;

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Color(0xFF1A1A1A).withValues(alpha: 0.85),
      title: Row(
        children: [
          Icon(Icons.notifications_active, color: Color(0xFFFF0000)),
          SizedBox(width: 8),
          Text(
            'Send Notification',
            style: TextStyle(
              color: Color(0xFFB8B8C0),
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'MESSAGE',
              style: TextStyle(
                color: Color(0xFFFF0000),
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 1,
              ),
            ),
            SizedBox(height: 8),
            TextField(
              controller: _messageController,
              maxLines: 4,
              style: TextStyle(color: Color(0xFFB8B8C0)),
              decoration: InputDecoration(
                hintText: 'Enter your message to all users...',
                hintStyle: TextStyle(color: Colors.white30),
                filled: true,
                fillColor: Colors.black,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: Colors.white10),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: Colors.white10),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: Color(0xFFFF0000), width: 2),
                ),
              ),
            ),
            SizedBox(height: 20),
            Text(
              'DELIVERY METHODS',
              style: TextStyle(
                color: Color(0xFFFF0000),
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 1,
              ),
            ),
            SizedBox(height: 8),
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white10),
              ),
              child: Column(
                children: [
                  CheckboxListTile(
                    title: Row(
                      children: [
                        Icon(
                          Icons.phone_android,
                          color: Color(0xFFFF0000),
                          size: 20,
                        ),
                        SizedBox(width: 8),
                        Text(
                          'SMS (Text Message)',
                          style: TextStyle(color: Color(0xFFB8B8C0)),
                        ),
                      ],
                    ),
                    value: _sendSMS,
                    onChanged: (value) =>
                        setState(() => _sendSMS = value ?? false),
                    activeColor: Color(0xFFFF0000),
                    checkColor: Colors.white,
                    contentPadding: EdgeInsets.zero,
                  ),
                  CheckboxListTile(
                    title: Row(
                      children: [
                        Icon(Icons.email, color: Color(0xFFFF0000), size: 20),
                        SizedBox(width: 8),
                        Text(
                          'Email',
                          style: TextStyle(color: Color(0xFFB8B8C0)),
                        ),
                      ],
                    ),
                    value: _sendEmail,
                    onChanged: (value) =>
                        setState(() => _sendEmail = value ?? false),
                    activeColor: Color(0xFFFF0000),
                    checkColor: Colors.white,
                    contentPadding: EdgeInsets.zero,
                  ),
                  CheckboxListTile(
                    title: Row(
                      children: [
                        Icon(
                          Icons.notifications,
                          color: Color(0xFFFF0000),
                          size: 20,
                        ),
                        SizedBox(width: 8),
                        Text(
                          'In-App Notification',
                          style: TextStyle(color: Color(0xFFB8B8C0)),
                        ),
                      ],
                    ),
                    value: _sendInApp,
                    onChanged: (value) =>
                        setState(() => _sendInApp = value ?? false),
                    activeColor: Color(0xFFFF0000),
                    checkColor: Colors.white,
                    contentPadding: EdgeInsets.zero,
                  ),
                ],
              ),
            ),
            SizedBox(height: 12),
            Text(
              'Sending to ${widget.users.length} user(s)',
              style: TextStyle(
                color: Colors.white54,
                fontSize: 12,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSending ? null : () => Navigator.pop(context),
          child: Text('CANCEL', style: TextStyle(color: Colors.white54)),
        ),
        ElevatedButton(
          onPressed: _isSending ? null : _sendNotifications,
          style: ElevatedButton.styleFrom(
            backgroundColor: Color(0xFFFF0000),
            foregroundColor: Colors.white,
          ),
          child: _isSending
              ? SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(Colors.white),
                  ),
                )
              : Text('SEND TO ALL'),
        ),
      ],
    );
  }

  Future<void> _sendNotifications() async {
    if (_messageController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Please enter a message'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    if (!_sendSMS && !_sendEmail && !_sendInApp) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Please select at least one delivery method'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() => _isSending = true);

    try {
      final message = _messageController.text.trim();

      // Create notification document in Firestore for in-app notifications
      if (_sendInApp) {
        for (var user in widget.users) {
          try {
            await db.collection('notifications').add({
              'userId': user['docId'],
              'userEmail': user['email'],
              'message': message,
              'timestamp': FieldValue.serverTimestamp(),
              'read': false,
              'type': 'admin_broadcast',
            });
          } catch (e) {
            print('Error sending in-app notification to ${user['email']}: $e');
          }
        }
      }

      // Send SMS (this would require Twilio or similar service integration)
      if (_sendSMS) {
        // TODO: Integrate with SMS service like Twilio
        // For now, just log
        print('SMS sending requested for ${widget.users.length} users');
        for (var user in widget.users) {
          print('Would send SMS to: ${user['phone']} - Message: $message');
        }
      }

      // Send Email (this would use your existing email function or service)
      if (_sendEmail) {
        try {
          // Call Cloud Function to send emails
          final HttpsCallable callable = FirebaseFunctions.instanceFor(
            region: 'us-central1',
          ).httpsCallable('sendBroadcastEmail');

          await callable.call({
            'users': widget.users
                .map((u) => {'email': u['email'], 'name': u['name']})
                .toList(),
            'message': message,
          });
        } catch (e) {
          print('Error sending emails: $e');
          // Continue even if email fails
        }
      }

      if (mounted) {
        Navigator.pop(context);

        List<String> deliveryMethods = [];
        if (_sendInApp) deliveryMethods.add('In-App');
        if (_sendEmail) deliveryMethods.add('Email');
        if (_sendSMS) deliveryMethods.add('SMS');

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Notification sent to ${widget.users.length} users via ${deliveryMethods.join(', ')}!',
            ),
            backgroundColor: Color(0xFF00FF41),
            duration: Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      print('Error sending notifications: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error sending notifications: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSending = false);
      }
    }
  }
}

// ==================== TERMS OF SERVICE SCREEN ====================
class TermsOfServiceScreen extends StatelessWidget {
  const TermsOfServiceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Color(0xFFB8B8C0)),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'Terms of Service',
          style: TextStyle(color: Color(0xFFB8B8C0), fontSize: 18),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Community Guidelines',
              style: TextStyle(
                color: Color(0xFF00FF41),
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'By using TEK, you agree to follow these community guidelines:',
              style: TextStyle(color: Colors.white70, height: 1.6),
            ),
            const SizedBox(height: 16),
            _buildGuidelineItem(
              '1. Be Respectful',
              'Treat all community members with respect. Harassment, bullying, or discrimination of any kind is strictly prohibited.',
            ),
            _buildGuidelineItem(
              '2. No Illegal Content',
              'Do not post, share, or promote any illegal activities, content, or services.',
            ),
            _buildGuidelineItem(
              '3. No Hate Speech',
              'Hateful language, slurs, or content targeting individuals or groups based on protected characteristics is not allowed.',
            ),
            _buildGuidelineItem(
              '4. No Spam',
              'Do not spam, scam, or engage in deceptive practices. Authentic interaction only.',
            ),
            _buildGuidelineItem(
              '5. Respect Privacy',
              'Do not share other users\' personal information without consent.',
            ),
            _buildGuidelineItem(
              '6. Report Violations',
              'Use the Report User button to report any violations. Our moderation team will review reports.',
            ),
            const SizedBox(height: 24),
            const Text(
              'Blocking & Safety',
              style: TextStyle(
                color: Color(0xFF00FF41),
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'You have full control over who can contact you. Use the Block User feature to prevent communication with any user.',
              style: TextStyle(color: Colors.white70, height: 1.6),
            ),
            const SizedBox(height: 24),
            const Text(
              'Content Moderation',
              style: TextStyle(
                color: Color(0xFF00FF41),
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'TEK has zero tolerance for objectionable content or abusive users. '
              'Our moderation team reviews all reports within 24 hours. '
              'Objectionable content will be removed and the offending user will be ejected from the platform. '
              'When you block a user, their content is instantly hidden from your feed and our team is notified for review.',
              style: TextStyle(color: Colors.white70, height: 1.6),
            ),
            const SizedBox(height: 24),
            const Text(
              '© 2026 TEK. All rights reserved.',
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _buildGuidelineItem(String title, String description) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: Color(0xFFB8B8C0),
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            description,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 13,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
// SIDEQUEST — user-facing screen
// ─────────────────────────────────────────────

class SidequestScreen extends StatefulWidget {
  const SidequestScreen({super.key});

  @override
  State<SidequestScreen> createState() => _SidequestScreenState();
}

class _SidequestScreenState extends State<SidequestScreen>
    with SingleTickerProviderStateMixin {
  String? _userCode;
  String? _appId;
  Set<String> _completedIds = {};
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadUserData();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadUserData() async {
    final prefs = await SharedPreferences.getInstance();
    final code = prefs.getString('userReferralCode');
    if (code == null || !mounted) return;
    final snap = await FirebaseFirestore.instance
        .collection('applications')
        .where('referralCode', isEqualTo: code)
        .limit(1)
        .get();
    if (snap.docs.isEmpty || !mounted) return;
    final doc = snap.docs.first;
    final data = doc.data();
    final completed =
        (data['completedSidequests'] as List?)?.cast<String>().toSet() ?? {};
    setState(() {
      _userCode = code;
      _appId = doc.id;
      _completedIds = completed;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<QuestsConfig>(
      valueListenable: questsConfig,
      builder: (context, cfg, _) {
        if (!cfg.enabled) {
          return Scaffold(
            backgroundColor: Colors.transparent,
            appBar: AppBar(
              backgroundColor: Colors.transparent,
              elevation: 0,
              automaticallyImplyLeading: false,
              title: const Text(
                'SIDEQUESTS',
                style: TextStyle(
                  color: Color(0xFF00FF41),
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 3,
                ),
              ),
              centerTitle: true,
            ),
            body: const _QuestsDisabledPlaceholder(),
          );
        }
        return Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            automaticallyImplyLeading: false,
            title: const Text(
              'SIDEQUESTS',
              style: TextStyle(
                color: Color(0xFF00FF41),
                fontSize: 20,
                fontWeight: FontWeight.bold,
                letterSpacing: 3,
              ),
            ),
            centerTitle: true,
            actions: [
              if (_userCode != null)
                _TekNotificationBell(userCode: _userCode!),
              const SizedBox(width: 8),
            ],
            bottom: TabBar(
              controller: _tabController,
              indicatorColor: const Color(0xFF00FF41),
              labelColor: const Color(0xFF00FF41),
              unselectedLabelColor: Colors.white38,
              labelStyle: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.5,
              ),
              tabs: const [
                Tab(text: 'MISSIONS'),
                Tab(text: 'CHALLENGES'),
                Tab(text: 'RANKS'),
              ],
            ),
          ),
          body: TabBarView(
            controller: _tabController,
            children: [
              _MissionsTab(
                userCode: _userCode,
                appId: _appId,
                completedIds: _completedIds,
                onClaimed: _loadUserData,
              ),
              _ChallengesTab(userCode: _userCode),
              _RanksTab(userCode: _userCode),
            ],
          ),
        );
      },
    );
  }
}

class _QuestsDisabledPlaceholder extends StatelessWidget {
  const _QuestsDisabledPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.power_settings_new, color: Color(0xFF00FF41), size: 48),
            SizedBox(height: 16),
            Text(
              'QUESTS OFFLINE',
              style: TextStyle(
                color: Color(0xFF00FF41),
                fontSize: 18,
                fontWeight: FontWeight.bold,
                letterSpacing: 3,
              ),
            ),
            SizedBox(height: 12),
            Text(
              'The mission system is temporarily disabled. Check back soon.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

class _MissionsTab extends StatelessWidget {
  final String? userCode;
  final String? appId;
  final Set<String> completedIds;
  final VoidCallback onClaimed;

  const _MissionsTab({
    required this.userCode,
    required this.appId,
    required this.completedIds,
    required this.onClaimed,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('sidequests')
          .where('active', isEqualTo: true)
          .orderBy('createdAt', descending: true)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'Error loading quests:\n${snapshot.error}',
                style: const TextStyle(color: Colors.red, fontSize: 13),
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const SkeletonList();
        }
        final docs = snapshot.data?.docs ?? [];
        if (docs.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: const [
                Icon(Icons.bolt, color: Color(0xFF00FF41), size: 48),
                SizedBox(height: 16),
                Text(
                  'AWAITING ASSIGNMENT',
                  style: TextStyle(
                    color: Color(0xFF00FF41),
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 2,
                  ),
                ),
                SizedBox(height: 8),
                Text(
                  'New transmissions inbound. Stand by, operator.',
                  style: TextStyle(color: Colors.white54, fontSize: 13),
                ),
              ],
            ),
          );
        }
        final hasHeader = appId != null;
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
          physics: const BouncingScrollPhysics(),
          itemCount: docs.length + (hasHeader ? 1 : 0),
          itemBuilder: (context, i) {
            if (hasHeader && i == 0) {
              return _MissionsHeader(appId: appId!);
            }
            final docIndex = hasHeader ? i - 1 : i;
            final doc = docs[docIndex];
            final data = doc.data() as Map<String, dynamic>;
            final completed = completedIds.contains(doc.id);
            return StaggeredItem(
              index: docIndex,
              child: _SidequestCard(
                questId: doc.id,
                data: data,
                completed: completed,
                userCode: userCode,
                appId: appId,
                onClaimed: onClaimed,
                completedIds: completedIds,
              ),
            );
          },
        );
      },
    );
  }
}

class _MissionsHeader extends StatelessWidget {
  final String appId;
  const _MissionsHeader({required this.appId});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _RewardProgressCard(appId: appId),
        _StreakBanner(appId: appId),
      ],
    );
  }
}

/// Shows current LEVEL + XP bar to the next reward in the TEK ladder.
/// Tap to open the full RewardsProgressPage. Streams the user's app doc.
class _RewardProgressCard extends StatelessWidget {
  final String appId;
  const _RewardProgressCard({required this.appId});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('applications')
          .doc(appId)
          .snapshots(),
      builder: (context, snap) {
        if (!snap.hasData || !snap.data!.exists) return const SizedBox.shrink();
        final data = snap.data!.data() ?? {};
        final xp = (data['xpPoints'] as num?)?.toInt() ?? 0;
        final level = (xp ~/ 100) + 1;
        final next = _nextTekReward(xp);
        final current = _currentTekReward(xp);
        final prev = current?.xpRequired ?? 0;
        final target = next?.xpRequired ?? math.max(prev, 200);
        final progress = next == null
            ? 1.0
            : ((xp - prev) / math.max(1, target - prev))
                .clamp(0.0, 1.0)
                .toDouble();

        return GestureDetector(
          onTap: () {
            HapticFeedback.lightImpact();
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => RewardsProgressPage(
                  currentLevel: level,
                  currentXP: xp,
                  maxXP: target,
                ),
              ),
            );
          },
          child: Container(
            margin: const EdgeInsets.only(bottom: 14),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  const Color(0xFF00FF41).withValues(alpha: 0.18),
                  const Color(0xFF00FF41).withValues(alpha: 0.04),
                ],
              ),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: const Color(0xFF00FF41).withValues(alpha: 0.45),
                  width: 1),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.bolt,
                        color: Color(0xFF00FF41), size: 18),
                    const SizedBox(width: 6),
                    Text(
                      'LEVEL $level',
                      style: const TextStyle(
                        color: Color(0xFF00FF41),
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 2,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '$xp XP',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1,
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Icon(Icons.chevron_right,
                        color: Colors.white38, size: 18),
                  ],
                ),
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 6,
                    backgroundColor: Colors.white12,
                    valueColor:
                        const AlwaysStoppedAnimation<Color>(Color(0xFF00FF41)),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    if (next != null) ...[
                      Icon(next.icon, size: 14, color: next.color),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'NEXT: ${next.name} — ${target - xp} XP',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1,
                          ),
                        ),
                      ),
                    ] else ...[
                      const Icon(Icons.workspace_premium,
                          size: 14, color: Color(0xFFFFD700)),
                      const SizedBox(width: 6),
                      const Expanded(
                        child: Text(
                          'ALL REWARDS UNLOCKED',
                          style: TextStyle(
                            color: Color(0xFFFFD700),
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _StreakBanner extends StatelessWidget {
  final String appId;
  const _StreakBanner({required this.appId});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<QuestsConfig>(
      valueListenable: questsConfig,
      builder: (context, cfg, _) {
        if (!cfg.streaksEnabled) return const SizedBox.shrink();
        return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: FirebaseFirestore.instance
              .collection('applications')
              .doc(appId)
              .snapshots(),
          builder: (context, snap) {
            if (!snap.hasData || !snap.data!.exists) return const SizedBox.shrink();
            final data = snap.data!.data() ?? {};
            final streak = (data['streak'] as Map?) ?? const {};
            final days = (streak['currentDays'] as num?)?.toInt() ?? 0;
            if (days < 1) return const SizedBox.shrink();
            return Container(
              margin: const EdgeInsets.only(bottom: 14),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: const Color(0xFFFF8800).withValues(alpha: 0.6),
                  width: 1,
                ),
              ),
              child: Row(
                children: [
                  const Icon(Icons.local_fire_department,
                      color: Color(0xFFFF8800), size: 24),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '$days-DAY STREAK',
                          style: const TextStyle(
                            color: Color(0xFFFF8800),
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 2,
                          ),
                        ),
                        const SizedBox(height: 2),
                        const Text(
                          'Stay active daily to bank milestone XP',
                          style: TextStyle(
                            color: Colors.white54,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _VerificationBadge extends StatelessWidget {
  final Map<String, dynamic> data;
  const _VerificationBadge({required this.data});

  @override
  Widget build(BuildContext context) {
    final vtype = data['verificationType'] as String? ?? 'honor';
    IconData? icon;
    String? label;
    Color color = Colors.white38;

    switch (vtype) {
      case 'qr_code':
        icon = Icons.qr_code_scanner;
        label = 'QR SCAN';
        color = const Color(0xFF00FF41);
        break;
      case 'timer':
        final mins = (data['timerMinutes'] as num?)?.toInt() ?? 60;
        icon = Icons.timer;
        label = '${mins}MIN';
        color = Colors.amber;
        break;
      case 'friend_added':
        final n = (data['requiredFriendCount'] as num?)?.toInt() ?? 1;
        icon = Icons.person_add;
        label = '+$n FRIEND${n > 1 ? 'S' : ''}';
        color = Colors.lightBlueAccent;
        break;
      case 'code_entry':
        icon = Icons.lock;
        label = 'CODE';
        color = Colors.white38;
        break;
      default:
        return const SizedBox.shrink();
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 10, color: color),
        const SizedBox(width: 3),
        Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 9,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
          ),
        ),
      ],
    );
  }
}

class _SidequestCard extends StatelessWidget {
  final String questId;
  final Map<String, dynamic> data;
  final bool completed;
  final String? userCode;
  final String? appId;
  final VoidCallback onClaimed;
  final Set<String> completedIds;

  static String _lootCountdown(DateTime? expiresAt) {
    if (expiresAt == null) return '';
    final diff = expiresAt.difference(DateTime.now());
    if (diff.isNegative) return 'EXPIRED';
    final mins = diff.inMinutes;
    final secs = diff.inSeconds.remainder(60);
    if (mins > 60) return '${diff.inHours}H';
    return '${mins}:${secs.toString().padLeft(2, '0')}';
  }

  const _SidequestCard({
    required this.questId,
    required this.data,
    required this.completed,
    required this.userCode,
    required this.appId,
    required this.onClaimed,
    required this.completedIds,
  });

  @override
  Widget build(BuildContext context) {
    final title = data['title'] as String? ?? '';
    final description = data['description'] as String? ?? '';
    final xpReward = (data['xpReward'] as num?)?.toInt() ?? 0;
    final prereqId = data['requiresQuestId'] as String?;
    final prereqTitle = data['requiresQuestTitle'] as String?;
    final chainLocked = prereqId != null && prereqId.isNotEmpty && !completedIds.contains(prereqId);
    final lootDrop = data['lootDrop'] == true;
    final lootExpires = (data['lootDropExpiresAt'] as Timestamp?)?.toDate();
    final lootActive = lootDrop && lootExpires != null && lootExpires.isAfter(DateTime.now());

    return GestureDetector(
      onTap: chainLocked ? null : () async {
        HapticFeedback.lightImpact();
        await Navigator.push(
          context,
          cinematicRoute(SidequestDetailPage(
              questId: questId,
              data: data,
              completed: completed,
              userCode: userCode,
            )),
        );
        onClaimed();
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 14),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: lootActive
                ? const Color(0xFFE63946)
                : chainLocked
                    ? Colors.white10
                    : completed
                        ? Colors.white12
                        : const Color(0xFF00FF41).withValues(alpha: 0.4),
            width: lootActive ? 1.5 : 1,
          ),
          boxShadow: lootActive
              ? [BoxShadow(color: const Color(0xFFE63946).withValues(alpha: 0.4), blurRadius: 18, spreadRadius: 1)]
              : null,
        ),
        child: Opacity(
          opacity: chainLocked ? 0.35 : completed ? 0.45 : 1.0,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (lootActive) ...[
                  Row(children: [
                    const Icon(Icons.bolt, color: Color(0xFFE63946), size: 12),
                    const SizedBox(width: 4),
                    const Text('LOOT DROP — TIME-LIMITED',
                        style: TextStyle(color: Color(0xFFE63946), fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 2)),
                    const Spacer(),
                    Text(_lootCountdown(lootExpires),
                        style: const TextStyle(color: Color(0xFFE63946), fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1, fontFamily: 'monospace')),
                  ]),
                  const SizedBox(height: 8),
                ],
                Row(
                  children: [
                    Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: chainLocked
                        ? Colors.white10
                        : completed
                            ? Colors.white12
                            : const Color(0xFF00FF41).withValues(alpha: 0.12),
                    border: Border.all(
                      color: chainLocked
                          ? Colors.white24
                          : completed
                              ? Colors.white24
                              : const Color(0xFF00FF41),
                      width: 1.5,
                    ),
                  ),
                  child: Icon(
                    chainLocked ? Icons.lock : completed ? Icons.check : Icons.bolt,
                    color: chainLocked ? Colors.white24 : completed ? Colors.white38 : const Color(0xFF00FF41),
                    size: 22,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          color: chainLocked
                              ? Colors.white24
                              : completed
                                  ? Colors.white38
                                  : const Color(0xFF00FF41),
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.2,
                        ),
                      ),
                      const SizedBox(height: 4),
                      if (chainLocked)
                        Text(
                          'COMPLETE ${(prereqTitle ?? 'PREVIOUS MISSION').toUpperCase()} FIRST',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white24, fontSize: 11, letterSpacing: 0.5),
                        )
                      else
                        Text(
                          description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 12,
                            height: 1.4,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: completed
                            ? Colors.white10
                            : const Color(0xFF00FF41).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: completed
                              ? Colors.white24
                              : const Color(0xFF00FF41),
                          width: 1,
                        ),
                      ),
                      child: Text(
                        '+$xpReward XP',
                        style: TextStyle(
                          color: completed
                              ? Colors.white38
                              : const Color(0xFF00FF41),
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                    if (!completed) ...[
                      const SizedBox(height: 6),
                      _VerificationBadge(data: data),
                    ],
                    if (completed) ...[
                      const SizedBox(height: 4),
                      const Text(
                        'DONE',
                        style: TextStyle(
                          color: Colors.white38,
                          fontSize: 10,
                          letterSpacing: 1,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
                ),
                if (!chainLocked && appId != null)
                  _QuestProgressBar(
                    appId: appId!,
                    questId: questId,
                    questData: data,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _QuestProgressBar extends StatelessWidget {
  final String appId;
  final String questId;
  final Map<String, dynamic> questData;

  const _QuestProgressBar({
    required this.appId,
    required this.questId,
    required this.questData,
  });

  @override
  Widget build(BuildContext context) {
    final qtype = questData['questType'] as String? ?? 'manual';
    if (qtype == 'manual') return const SizedBox.shrink();

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('applications')
          .doc(appId)
          .collection('questProgress')
          .doc(questId)
          .snapshots(),
      builder: (context, snap) {
        if (!snap.hasData || !snap.data!.exists) return const SizedBox.shrink();
        final p = snap.data!.data() ?? {};
        final progress = (p['progress'] as num?)?.toInt() ?? 0;
        final target =
            (p['target'] as num?)?.toInt() ?? (questData['target'] as num?)?.toInt() ?? 1;
        final completedAt = p['completedAt'];
        final claimedAt = p['claimedAt'];
        final ratio = target > 0 ? (progress / target).clamp(0.0, 1.0) : 0.0;
        final isReady = completedAt != null && claimedAt == null;

        return Padding(
          padding: const EdgeInsets.only(top: 12, left: 58),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    isReady ? 'READY TO CLAIM' : '$progress / $target',
                    style: TextStyle(
                      color: isReady
                          ? const Color(0xFF00FF41)
                          : Colors.white70,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.2,
                    ),
                  ),
                  if (isReady) ...[
                    const SizedBox(width: 6),
                    const Icon(Icons.bolt, size: 12, color: Color(0xFF00FF41)),
                  ],
                ],
              ),
              const SizedBox(height: 4),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: ratio,
                  minHeight: 4,
                  backgroundColor: Colors.white12,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    isReady ? const Color(0xFF00FF41) : Colors.white54,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────
// QR CODE SCANNER PAGE
// ─────────────────────────────────────────────

class _QRScannerPage extends StatefulWidget {
  final String expectedValue;
  const _QRScannerPage({required this.expectedValue});

  @override
  State<_QRScannerPage> createState() => _QRScannerPageState();
}

class _QRScannerPageState extends State<_QRScannerPage>
    with SingleTickerProviderStateMixin {
  late final MobileScannerController _controller;
  bool _matched = false;
  bool _wrongFlash = false;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();
    _controller = MobileScannerController(
      detectionSpeed: DetectionSpeed.normal,
      facing: CameraFacing.back,
    );
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.4, end: 1.0).animate(_pulseController);
  }

  @override
  void dispose() {
    _controller.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_matched) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue ?? '';
      if (raw.trim().toUpperCase() == widget.expectedValue.trim().toUpperCase()) {
        _matched = true;
        _controller.stop();
        if (mounted) Navigator.pop(context, raw);
        return;
      }
    }
    if (!_wrongFlash) {
      setState(() => _wrongFlash = true);
      Future.delayed(const Duration(milliseconds: 400), () {
        if (mounted) setState(() => _wrongFlash = false);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        iconTheme: const IconThemeData(color: Color(0xFF00FF41)),
        title: const Text('SCAN QR CODE',
            style: TextStyle(
                color: Color(0xFF00FF41),
                fontSize: 15,
                fontWeight: FontWeight.bold,
                letterSpacing: 2)),
        centerTitle: true,
      ),
      body: Stack(
        children: [
          MobileScanner(controller: _controller, onDetect: _onDetect),
          // Dark vignette overlay
          Container(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment.center,
                radius: 0.7,
                colors: [Colors.transparent, Colors.black.withValues(alpha: 0.55)],
              ),
            ),
          ),
          // Corner brackets overlay
          Center(
            child: SizedBox(
              width: 240,
              height: 240,
              child: CustomPaint(
                painter: _QRCornerPainter(
                  color: _wrongFlash ? Colors.red : const Color(0xFF00FF41),
                ),
              ),
            ),
          ),
          // Instructions
          Positioned(
            bottom: 80,
            left: 0,
            right: 0,
            child: Column(
              children: [
                FadeTransition(
                  opacity: _pulseAnim,
                  child: const Text('SCANNING...',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: Color(0xFF00FF41),
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 3)),
                ),
                const SizedBox(height: 8),
                Text(
                  _wrongFlash
                      ? 'WRONG QR — KEEP LOOKING'
                      : 'ALIGN QR CODE WITH FRAME',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: _wrongFlash ? Colors.red : Colors.white38,
                      fontSize: 12,
                      letterSpacing: 1.5),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _QRCornerPainter extends CustomPainter {
  final Color color;
  _QRCornerPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    const len = 32.0;
    final w = size.width;
    final h = size.height;
    // Top-left
    canvas.drawLine(Offset(0, len), Offset(0, 0), paint);
    canvas.drawLine(Offset(0, 0), Offset(len, 0), paint);
    // Top-right
    canvas.drawLine(Offset(w - len, 0), Offset(w, 0), paint);
    canvas.drawLine(Offset(w, 0), Offset(w, len), paint);
    // Bottom-left
    canvas.drawLine(Offset(0, h - len), Offset(0, h), paint);
    canvas.drawLine(Offset(0, h), Offset(len, h), paint);
    // Bottom-right
    canvas.drawLine(Offset(w - len, h), Offset(w, h), paint);
    canvas.drawLine(Offset(w, h - len), Offset(w, h), paint);
  }

  @override
  bool shouldRepaint(_QRCornerPainter old) => old.color != color;
}

// ─────────────────────────────────────────────
// SIDEQUEST — detail / claim page
// ─────────────────────────────────────────────

class SidequestDetailPage extends StatefulWidget {
  final String questId;
  final Map<String, dynamic> data;
  final bool completed;
  final String? userCode;

  const SidequestDetailPage({
    super.key,
    required this.questId,
    required this.data,
    required this.completed,
    required this.userCode,
  });

  @override
  State<SidequestDetailPage> createState() => _SidequestDetailPageState();
}

class _SidequestDetailPageState extends State<SidequestDetailPage> {
  bool _claiming = false;
  bool _done = false;
  bool _verified = false;

  // timer
  Timer? _countdownTimer;
  int _secondsRemaining = 0;
  bool _timerStarted = false;

  // friend count
  int _friendBase = -1;
  int _currentFriendCount = 0;
  Timer? _friendPollTimer;

  // code entry
  final TextEditingController _codeController = TextEditingController();
  bool _codeWrong = false;

  String get _vtype => widget.data['verificationType'] as String? ?? 'honor';

  @override
  void initState() {
    super.initState();
    _done = widget.completed;
    _verified = _done;
    if (!_done) {
      if (_vtype == 'timer') _initTimer();
      if (_vtype == 'friend_added') _initFriendCount();
    }
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _friendPollTimer?.cancel();
    _codeController.dispose();
    super.dispose();
  }

  // ── TIMER ──────────────────────────────────────────────────────────────────

  Future<void> _initTimer() async {
    final prefs = await SharedPreferences.getInstance();
    final key = 'timerstart_${widget.questId}';
    final totalSec = ((widget.data['timerMinutes'] as num?)?.toInt() ?? 60) * 60;
    final startStr = prefs.getString(key);
    if (startStr == null) {
      if (mounted) setState(() => _secondsRemaining = totalSec);
      return;
    }
    final elapsed = DateTime.now().difference(DateTime.parse(startStr)).inSeconds;
    final remaining = totalSec - elapsed;
    if (remaining <= 0) {
      if (mounted) setState(() { _secondsRemaining = 0; _verified = true; _timerStarted = true; });
      return;
    }
    if (mounted) setState(() { _secondsRemaining = remaining; _timerStarted = true; });
    _runCountdown();
  }

  Future<void> _startTimer() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('timerstart_${widget.questId}', DateTime.now().toIso8601String());
    final totalSec = ((widget.data['timerMinutes'] as num?)?.toInt() ?? 60) * 60;
    setState(() { _secondsRemaining = totalSec; _timerStarted = true; });
    _runCountdown();
  }

  void _runCountdown() {
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) { t.cancel(); return; }
      setState(() {
        if (_secondsRemaining > 0) {
          _secondsRemaining--;
        } else {
          t.cancel();
          _verified = true;
        }
      });
    });
  }

  String _fmt(int s) =>
      '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';

  // ── FRIEND COUNT ───────────────────────────────────────────────────────────

  Future<void> _initFriendCount() async {
    final userCode = widget.userCode;
    if (userCode == null) return;
    final prefs = await SharedPreferences.getInstance();
    final baseKey = 'friendbase_${widget.questId}';

    final snap = await FirebaseFirestore.instance
        .collection('applications')
        .where('referralCode', isEqualTo: userCode)
        .limit(1)
        .get();
    if (snap.docs.isEmpty || !mounted) return;

    final count = (snap.docs.first.data()['friends'] as List?)?.length ?? 0;
    int base = prefs.getInt(baseKey) ?? -1;
    if (base == -1) {
      base = count;
      await prefs.setInt(baseKey, base);
    }
    final required = (widget.data['requiredFriendCount'] as num?)?.toInt() ?? 1;
    if (mounted) {
      setState(() {
        _friendBase = base;
        _currentFriendCount = count;
        if (count >= base + required) _verified = true;
      });
    }
    if (!_verified) {
      _friendPollTimer = Timer.periodic(const Duration(seconds: 6), (_) async {
        if (!mounted) return;
        final s = await FirebaseFirestore.instance
            .collection('applications')
            .where('referralCode', isEqualTo: userCode)
            .limit(1)
            .get();
        if (s.docs.isEmpty || !mounted) return;
        final c = (s.docs.first.data()['friends'] as List?)?.length ?? 0;
        setState(() => _currentFriendCount = c);
        if (c >= _friendBase + required) {
          setState(() => _verified = true);
          _friendPollTimer?.cancel();
        }
      });
    }
  }



  // ── CODE ENTRY ─────────────────────────────────────────────────────────────

  void _submitCode() {
    final entered = _codeController.text.trim().toUpperCase();
    final expected = (widget.data['secretCode'] as String? ?? '').trim().toUpperCase();
    if (expected.isNotEmpty && entered == expected) {
      setState(() { _verified = true; _codeWrong = false; });
    } else {
      setState(() => _codeWrong = true);
    }
  }

  // ── CLAIM XP ───────────────────────────────────────────────────────────────

  Future<void> _showRewardUnlockedDialog(_TekReward reward) async {
    HapticFeedback.heavyImpact();
    Obs.logEvent('reward_unlocked', {
      'reward_id': reward.id,
      'reward_name': reward.name,
      'reward_level': reward.level,
      'xp_required': reward.xpRequired,
    });
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0D0D1A),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: reward.color, width: 1.5),
        ),
        contentPadding: const EdgeInsets.fromLTRB(24, 28, 24, 18),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: reward.color.withValues(alpha: 0.18),
                border: Border.all(color: reward.color, width: 2),
                boxShadow: [
                  BoxShadow(
                    color: reward.color.withValues(alpha: 0.5),
                    blurRadius: 28,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: Icon(reward.icon, color: reward.color, size: 44),
            ),
            const SizedBox(height: 18),
            Text(
              'REWARD UNLOCKED',
              style: TextStyle(
                color: reward.color,
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 3,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              reward.name,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.5,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              reward.description,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 13,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'LEVEL ${reward.level}  •  ${reward.xpRequired} XP',
              style: const TextStyle(
                color: Colors.white38,
                fontSize: 11,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.5,
              ),
            ),
          ],
        ),
        actions: [
          if (reward.id == 'inner_circle' || reward.id == 'black_card')
            TextButton(
              onPressed: () async {
                Navigator.of(ctx).pop();
                final loungeId = reward.id == 'black_card' ? 'black_card' : 'inner_circle';
                final lounge = _tierLounges.firstWhere((l) => l.id == loungeId);
                final prefs = await SharedPreferences.getInstance();
                final code = prefs.getString('userReferralCode');
                if (code != null && mounted) {
                  Navigator.push(context, cinematicRoute(
                      _TierLoungeChatScreen(lounge: lounge, userCode: code)));
                }
              },
              style: TextButton.styleFrom(
                foregroundColor: reward.color,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              ),
              child: const Text(
                'ENTER LOUNGE',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 2),
              ),
            ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            style: TextButton.styleFrom(
              foregroundColor: reward.color,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            ),
            child: const Text(
              'NICE',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                letterSpacing: 2,
              ),
            ),
          ),
        ],
        actionsAlignment: MainAxisAlignment.center,
      ),
    );
  }

  Future<void> _claimXP() async {
    if (_claiming || _done || !_verified) return;
    final userCode = widget.userCode;
    if (userCode == null) return;
    setState(() => _claiming = true);
    try {
      final xpReward = (widget.data['xpReward'] as num?)?.toInt() ?? 0;
      final questId = widget.questId;
      final callable = FirebaseFunctions.instanceFor(region: 'us-central1')
          .httpsCallable('claimQuestXP');
      final result = await callable.call(<String, dynamic>{
        'questId': questId,
        'userCode': userCode,
      });
      final payload = (result.data is Map)
          ? Map<String, dynamic>.from(result.data as Map)
          : <String, dynamic>{};
      final alreadyClaimed = payload['alreadyClaimed'] == true;
      final awarded = (payload['xpAwarded'] as num?)?.toInt() ?? xpReward;
      final previousXP = (payload['previousXP'] as num?)?.toInt() ?? 0;
      final newXP = (payload['newXP'] as num?)?.toInt() ?? (previousXP + awarded);

      if (!mounted) return;
      setState(() { _done = true; _claiming = false; });

      if (alreadyClaimed) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Already claimed.'),
            backgroundColor: Color(0xFF00FF41),
          ),
        );
      } else {
        Obs.logEvent('sidequest_claimed', {
          'quest_id': questId,
          'xp_awarded': awarded,
          'new_xp': newXP,
        });
        showXPToast(context,
            title: '+$awarded XP EARNED',
            subtitle: 'MISSION COMPLETE',
            icon: Icons.bolt);

        // Mission combo: complete 3 in 6h = +100 XP bonus
        try {
          final prefs = await SharedPreferences.getInstance();
          final firstMs = prefs.getInt('comboWindowStart') ?? 0;
          final count = prefs.getInt('comboCount') ?? 0;
          final nowMs = DateTime.now().millisecondsSinceEpoch;
          const windowMs = 6 * 60 * 60 * 1000;
          int newCount;
          int newWindow;
          if (firstMs == 0 || nowMs - firstMs > windowMs) {
            newCount = 1;
            newWindow = nowMs;
          } else {
            newCount = count + 1;
            newWindow = firstMs;
          }
          await prefs.setInt('comboCount', newCount);
          await prefs.setInt('comboWindowStart', newWindow);

          if (newCount >= 3) {
            // Award bonus once per window: track lastBonus
            final lastBonus = prefs.getInt('comboBonusForWindow') ?? 0;
            if (lastBonus != newWindow) {
              await prefs.setInt('comboBonusForWindow', newWindow);
              const bonusXp = 100;
              // Award bonus by writing to applications.xpPoints directly
              try {
                final code = prefs.getString('userReferralCode');
                if (code != null) {
                  final appSnap = await FirebaseFirestore.instance
                      .collection('applications')
                      .where('referralCode', isEqualTo: code)
                      .limit(1)
                      .get();
                  if (appSnap.docs.isNotEmpty) {
                    final cur = (appSnap.docs.first.data()['xpPoints'] as num?)?.toInt() ?? newXP;
                    await appSnap.docs.first.reference.update({'xpPoints': cur + bonusXp});
                    await FirebaseFirestore.instance.collection('xp_transactions').add({
                      'source': 'combo_bonus',
                      'comboCount': newCount,
                      'amount': bonusXp,
                      'previousXP': cur,
                      'newXP': cur + bonusXp,
                      'userId': FirebaseAuth.instance.currentUser?.uid ?? '',
                      'userName': appSnap.docs.first.data()['name'] ?? '',
                      'timestamp': FieldValue.serverTimestamp(),
                    });
                  }
                }
              } catch (_) {}
              if (mounted) {
                Future.delayed(const Duration(milliseconds: 1400), () {
                  if (!mounted) return;
                  showXPToast(context,
                      title: '+100 XP COMBO BONUS',
                      subtitle: '3-MISSION STREAK ENGAGED',
                      icon: Icons.local_fire_department);
                });
              }
            }
          }
        } catch (_) {}

        // If this claim crossed a reward threshold, celebrate.
        _TekReward? unlocked;
        for (final r in _tekRewards) {
          if (previousXP < r.xpRequired && newXP >= r.xpRequired) {
            unlocked = r;
            break;
          }
        }
        if (unlocked != null) {
          final reward = unlocked;
          // Let the XP toast play first, then surface the unlock dialog.
          Future.delayed(const Duration(milliseconds: 900), () {
            if (mounted) _showRewardUnlockedDialog(reward);
          });
        }
      }
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      setState(() => _claiming = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to claim XP: ${e.message ?? e.code}'),
          backgroundColor: Colors.red,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _claiming = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to claim XP: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  // ── BUILD ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final title = widget.data['title'] as String? ?? '';
    final description = widget.data['description'] as String? ?? '';
    final xpReward = (widget.data['xpReward'] as num?)?.toInt() ?? 0;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Color(0xFFB8B8C0)),
        title: const Text('MISSION BRIEF',
            style: TextStyle(color: Color(0xFF00FF41), fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 2)),
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const SizedBox(height: 20),
            Container(
              width: 80, height: 80,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFF00FF41), width: 2),
                color: const Color(0xFF00FF41).withValues(alpha: 0.08),
                boxShadow: [BoxShadow(color: const Color(0xFF00FF41).withValues(alpha: 0.25), blurRadius: 24, spreadRadius: 4)],
              ),
              child: const Icon(Icons.bolt, color: Color(0xFF00FF41), size: 40),
            ),
            const SizedBox(height: 24),
            Text(title, textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFF00FF41), fontSize: 22, fontWeight: FontWeight.bold, letterSpacing: 2)),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF00FF41).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(30),
                border: Border.all(color: const Color(0xFF00FF41), width: 1),
              ),
              child: Text('+$xpReward XP REWARD',
                  style: const TextStyle(color: Color(0xFF00FF41), fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
            ),
            const SizedBox(height: 32),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white10),
              ),
              child: Text(description, textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 15, height: 1.6)),
            ),
            const Spacer(),
            _buildVerificationSection(xpReward),
            const SizedBox(height: 12),
            if (!_done && widget.userCode != null)
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => showDialog(
                    context: context,
                    builder: (_) => ChallengeFriendDialog(
                      questId: widget.questId,
                      questTitle: widget.data['title'] as String? ?? '',
                      xpReward: (widget.data['xpReward'] as num?)?.toInt() ?? 0,
                      userCode: widget.userCode!,
                    ),
                  ),
                  icon: const Icon(Icons.person_add, color: Color(0xFF00FF41), size: 18),
                  label: const Text('CHALLENGE A FRIEND',
                      style: TextStyle(color: Color(0xFF00FF41), fontSize: 13, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Color(0xFF00FF41)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Widget _buildVerificationSection(int xpReward) {
    if (_done) {
      return SizedBox(
        width: double.infinity,
        child: ElevatedButton(
          onPressed: null,
          style: ElevatedButton.styleFrom(
            disabledBackgroundColor: Colors.white12,
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: const Text('MISSION COMPLETE',
              style: TextStyle(color: Colors.white38, fontSize: 15, fontWeight: FontWeight.bold, letterSpacing: 2)),
        ),
      );
    }

    if (_verified) {
      return PressScale(
        child: GlowPulse(
        child: SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _claiming ? null : () { HapticFeedback.mediumImpact(); _claimXP(); },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00FF41),
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: _claiming
                ? const SizedBox(height: 20, width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                : const Text('CLAIM XP',
                    style: TextStyle(color: Colors.black, fontSize: 15, fontWeight: FontWeight.bold, letterSpacing: 2)),
          ),
        ),
      ),
      );
    }

    switch (_vtype) {
      case 'qr_code':
        final expectedQR = (widget.data['qrCodeValue'] as String? ?? '').trim();
        return Column(children: [
          const Text('FIND THE HIDDEN QR CODE AND SCAN IT',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white38, fontSize: 12, letterSpacing: 1)),
          const SizedBox(height: 16),
          PressScale(
            child: GlowPulse(
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () async {
                  HapticFeedback.lightImpact();
                  final result = await Navigator.push<String>(
                    context,
                    cinematicRoute(_QRScannerPage(expectedValue: expectedQR)),
                  );
                  if (result != null && mounted) {
                    HapticFeedback.heavyImpact();
                    setState(() => _verified = true);
                  }
                },
                icon: const Icon(Icons.qr_code_scanner, color: Colors.black, size: 20),
                label: const Text('SCAN QR CODE',
                    style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, letterSpacing: 2)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00FF41),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
          ),
          ),
        ]);

      case 'timer':
        final timerMinutes = (widget.data['timerMinutes'] as num?)?.toInt() ?? 60;
        if (!_timerStarted) {
          return Column(children: [
            Text('COMPLETE THIS MISSION FOR $timerMinutes MINUTES',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white38, fontSize: 12, letterSpacing: 1)),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _startTimer,
                icon: const Icon(Icons.timer, color: Colors.black),
                label: const Text('START TIMER',
                    style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, letterSpacing: 2)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00FF41),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
          ]);
        }
        return Column(children: [
          const Text('STAY OFF YOUR PHONE. TIMER IS RUNNING.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white38, fontSize: 12, letterSpacing: 1)),
          const SizedBox(height: 16),
          Text(_fmt(_secondsRemaining),
              style: const TextStyle(
                  color: Color(0xFF00FF41), fontSize: 48, fontWeight: FontWeight.bold,
                  fontFamily: 'monospace', letterSpacing: 4)),
          const SizedBox(height: 8),
          const Text('remaining', style: TextStyle(color: Colors.white38, fontSize: 12)),
        ]);

      case 'friend_added':
        final required = (widget.data['requiredFriendCount'] as num?)?.toInt() ?? 1;
        final gained = _friendBase == -1 ? 0 : (_currentFriendCount - _friendBase).clamp(0, required);
        return Column(children: [
          Text('ADD $required NEW TEK MEMBER${required > 1 ? 'S' : ''} TO UNLOCK',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white38, fontSize: 12, letterSpacing: 1)),
          const SizedBox(height: 16),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            for (int i = 0; i < required; i++)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Icon(Icons.person,
                    size: 32,
                    color: i < gained ? const Color(0xFF00FF41) : Colors.white12),
              ),
          ]),
          const SizedBox(height: 8),
          Text('$gained / $required friends added',
              style: const TextStyle(color: Colors.white38, fontSize: 12)),
          const SizedBox(height: 8),
          const Text('Go to SOCIAL and add new members.',
              style: TextStyle(color: Colors.white24, fontSize: 11)),
        ]);

      case 'code_entry':
        return Column(children: [
          const Text('ENTER THE SECRET CODE TO UNLOCK',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white38, fontSize: 12, letterSpacing: 1)),
          const SizedBox(height: 12),
          TextField(
            controller: _codeController,
            textCapitalization: TextCapitalization.characters,
            style: const TextStyle(color: Colors.white, fontSize: 16, letterSpacing: 2),
            textAlign: TextAlign.center,
            decoration: InputDecoration(
              hintText: 'SECRET CODE',
              hintStyle: const TextStyle(color: Colors.white24, letterSpacing: 2),
              errorText: _codeWrong ? 'WRONG CODE — TRY AGAIN' : null,
              errorStyle: const TextStyle(color: Colors.red, letterSpacing: 1),
              enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Colors.white24)),
              focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Color(0xFF00FF41))),
              errorBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Colors.red)),
              focusedErrorBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Colors.red)),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _submitCode,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00FF41),
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('SUBMIT',
                  style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, letterSpacing: 2)),
            ),
          ),
        ]);

      default:
        return SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: null,
            style: ElevatedButton.styleFrom(
              disabledBackgroundColor: Colors.white10,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('MISSION LOCKED — CHECK BACK SOON',
                style: TextStyle(color: Colors.white38, fontSize: 13, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
          ),
        );
    }
  }
}


String _vtypeLabel(String vtype) {
  switch (vtype) {
    case 'qr_code': return 'QR';
    case 'timer': return 'TIMER';
    case 'friend_added': return 'FRIENDS';
    case 'code_entry': return 'CODE';
    default: return 'HONOR';
  }
}

// ─────────────────────────────────────────────
// SIDEQUEST — admin management screen
// ─────────────────────────────────────────────

class ManageSidequestsScreen extends StatelessWidget {
  const ManageSidequestsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Color(0xFFB8B8C0)),
        title: const Text(
          'MANAGE SIDEQUESTS',
          style: TextStyle(
            color: Color(0xFFFF0000),
            fontSize: 16,
            fontWeight: FontWeight.bold,
            letterSpacing: 2,
          ),
        ),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.auto_awesome, color: Color(0xFF00FF41)),
            tooltip: 'AI mission designer',
            onPressed: () => showModalBottomSheet(
              context: context,
              backgroundColor: Colors.transparent,
              isScrollControlled: true,
              builder: (_) => const _AiMissionDesignerSheet(),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.add, color: Color(0xFF00FF41)),
            tooltip: 'Create quest',
            onPressed: () => showDialog(
              context: context,
              builder: (_) => const CreateSidequestDialog(),
            ),
          ),
        ],
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('sidequests')
            .orderBy('createdAt', descending: true)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(
              child: CircularProgressIndicator(color: Color(0xFFFF0000)),
            );
          }
          final docs = snapshot.data?.docs ?? [];
          if (docs.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: const [
                  Icon(Icons.bolt, color: Colors.white24, size: 48),
                  SizedBox(height: 16),
                  Text(
                    'No sidequests yet.',
                    style: TextStyle(color: Colors.white54),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Tap + to create one.',
                    style: TextStyle(color: Colors.white38, fontSize: 13),
                  ),
                ],
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
            itemCount: docs.length,
            itemBuilder: (context, i) {
              final doc = docs[i];
              final data = doc.data() as Map<String, dynamic>;
              final active = data['active'] as bool? ?? false;
              final title = data['title'] as String? ?? '';
              final xpReward = (data['xpReward'] as num?)?.toInt() ?? 0;
              final completions =
                  (data['totalCompletions'] as num?)?.toInt() ?? 0;

              return Container(
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: active ? Colors.white24 : Colors.white10,
                    width: 1,
                  ),
                ),
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 8),
                  leading: Icon(
                    Icons.bolt,
                    color: active ? const Color(0xFF00FF41) : Colors.white24,
                  ),
                  title: Text(
                    title,
                    style: TextStyle(
                      color: active ? Colors.white : Colors.white38,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                      letterSpacing: 0.5,
                    ),
                  ),
                  subtitle: Text(
                    '+$xpReward XP  •  $completions completions  •  ${_vtypeLabel(data['verificationType'] as String? ?? 'honor')}',
                    style: const TextStyle(
                      color: Colors.white38,
                      fontSize: 12,
                    ),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Switch(
                        value: active,
                        activeThumbColor: const Color(0xFF00FF41),
                        activeTrackColor: const Color(0xFF00FF41).withValues(alpha: 0.4),
                        onChanged: (val) =>
                            doc.reference.update({'active': val}),
                      ),
                      if ((data['verificationType'] as String?) == 'qr_code' &&
                          (data['qrCodeValue'] as String? ?? '').isNotEmpty)
                        IconButton(
                          icon: const Icon(Icons.qr_code,
                              color: Color(0xFF00FF41), size: 20),
                          tooltip: 'View QR code',
                          onPressed: () => _showQRCode(
                              context, data['qrCodeValue'] as String, title),
                        ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline,
                            color: Colors.white38, size: 20),
                        onPressed: () => _confirmDelete(context, doc),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  void _showQRCode(BuildContext context, String value, String title) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF0D0D1A),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xFF00FF41)),
        ),
        title: Text(title,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xFF00FF41), fontSize: 14,
                fontWeight: FontWeight.bold, letterSpacing: 1)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              color: Colors.white,
              padding: const EdgeInsets.all(12),
              child: qr_flutter.QrImageView(data: value, size: 200),
            ),
            const SizedBox(height: 12),
            Text('Code: $value',
                style: const TextStyle(color: Colors.white54, fontSize: 12,
                    letterSpacing: 1)),
            const SizedBox(height: 4),
            const Text('Screenshot this to print and hide at the venue.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white38, fontSize: 11)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('CLOSE', style: TextStyle(color: Color(0xFF00FF41))),
          ),
        ],
      ),
    );
  }

  void _confirmDelete(BuildContext context, DocumentSnapshot doc) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: const Text(
          'Delete sidequest?',
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          'This will permanently delete the quest. Completion records are kept.',
          style: TextStyle(color: Colors.white54),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('CANCEL',
                style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () {
              doc.reference.delete();
              Navigator.pop(context);
            },
            child: const Text('DELETE', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
// AI MISSION DESIGNER (admin only)
// ─────────────────────────────────────────────

class _AiMissionDesignerSheet extends StatefulWidget {
  const _AiMissionDesignerSheet();

  @override
  State<_AiMissionDesignerSheet> createState() => _AiMissionDesignerSheetState();
}

class _AiMissionDesignerSheetState extends State<_AiMissionDesignerSheet> {
  final _themeController = TextEditingController();
  String _vtype = 'qr_code';
  int _xp = 50;
  bool _generating = false;
  String? _error;
  Map<String, dynamic>? _generated;

  @override
  void dispose() {
    _themeController.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    final theme = _themeController.text.trim();
    if (theme.isEmpty) return;
    setState(() { _generating = true; _error = null; _generated = null; });
    HapticFeedback.lightImpact();
    try {
      final callable = FirebaseFunctions.instanceFor(region: 'us-central1')
          .httpsCallable('generateQuestWithAI');
      final result = await callable.call({
        'theme': theme,
        'verificationType': _vtype,
        'xpReward': _xp,
      });
      final data = (result.data is Map) ? Map<String, dynamic>.from(result.data as Map) : <String, dynamic>{};
      setState(() => _generated = data);
      TekSounds.instance.transmission();
    } catch (e) {
      setState(() => _error = '${e.toString().replaceFirst('Exception: ', '').toUpperCase()}');
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  Color get _cardColor => Colors.black.withValues(alpha: 0.85);

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      maxChildSize: 0.92,
      minChildSize: 0.4,
      expand: false,
      builder: (context, scrollController) => FrostedGlass(
        sigma: 24,
        opacity: 0.85,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        child: ListView(
          controller: scrollController,
          padding: const EdgeInsets.all(20),
          physics: const BouncingScrollPhysics(),
          children: [
            const Row(children: [
              Icon(Icons.auto_awesome, color: Color(0xFF00FF41), size: 16),
              SizedBox(width: 8),
              Text('AI MISSION DESIGNER',
                  style: TextStyle(color: Color(0xFF00FF41), fontSize: 14, fontWeight: FontWeight.bold, letterSpacing: 3)),
            ]),
            const SizedBox(height: 4),
            const Text('Describe a mission concept. AI generates title + brief in TEK voice.',
                style: TextStyle(color: Colors.white54, fontSize: 11)),
            const SizedBox(height: 18),
            TextField(
              controller: _themeController,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              maxLines: 2,
              decoration: InputDecoration(
                labelText: 'THEME',
                labelStyle: const TextStyle(color: Color(0xFF00FF41), fontSize: 11, letterSpacing: 1.5),
                hintText: 'e.g. meeting strangers / photo at venue / dance battle',
                hintStyle: const TextStyle(color: Colors.white24, fontSize: 12),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Colors.white24)),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF00FF41))),
              ),
            ),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: _vtype,
                  dropdownColor: const Color(0xFF0D0D1A),
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                  decoration: InputDecoration(
                    labelText: 'VERIFICATION',
                    labelStyle: const TextStyle(color: Color(0xFF00FF41), fontSize: 10, letterSpacing: 1.5),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Colors.white24)),
                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF00FF41))),
                  ),
                  items: const [
                    DropdownMenuItem(value: 'qr_code', child: Text('QR CODE')),
                    DropdownMenuItem(value: 'timer', child: Text('TIMER')),
                    DropdownMenuItem(value: 'friend_added', child: Text('FRIEND')),
                    DropdownMenuItem(value: 'code_entry', child: Text('CODE')),
                  ],
                  onChanged: (v) => setState(() => _vtype = v ?? 'qr_code'),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 90,
                child: TextField(
                  keyboardType: TextInputType.number,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  controller: TextEditingController(text: '$_xp'),
                  decoration: InputDecoration(
                    labelText: 'XP',
                    labelStyle: const TextStyle(color: Color(0xFF00FF41), fontSize: 10, letterSpacing: 1.5),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Colors.white24)),
                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF00FF41))),
                  ),
                  onChanged: (v) {
                    final n = int.tryParse(v);
                    if (n != null) _xp = n;
                  },
                ),
              ),
            ]),
            const SizedBox(height: 20),
            PressScale(
              child: GlowPulse(
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _generating ? null : _generate,
                    icon: _generating
                        ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                        : const Icon(Icons.auto_awesome, color: Colors.black, size: 16),
                    label: Text(_generating ? 'GENERATING...' : 'GENERATE',
                        style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold, letterSpacing: 2)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00FF41),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 14),
              Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1)),
            ],
            if (_generated != null) ...[
              const SizedBox(height: 18),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: _cardColor,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFF00FF41).withValues(alpha: 0.5)),
                  boxShadow: [BoxShadow(color: const Color(0xFF00FF41).withValues(alpha: 0.2), blurRadius: 20)],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('GENERATED MISSION',
                        style: TextStyle(color: Color(0xFF00FF41), fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 2)),
                    const SizedBox(height: 8),
                    Text((_generated!['title'] ?? '').toString().toUpperCase(),
                        style: const TextStyle(color: Color(0xFF00FF41), fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 1)),
                    const SizedBox(height: 8),
                    Text((_generated!['description'] ?? '').toString(),
                        style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.4)),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: PressScale(
                    child: OutlinedButton(
                      onPressed: _generate,
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Colors.white38),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      child: const Text('REGENERATE',
                          style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold, letterSpacing: 1.5, fontSize: 11)),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: PressScale(
                    child: ElevatedButton(
                      onPressed: () {
                        Navigator.pop(context);
                        // Open create dialog with prefilled values
                        showDialog(context: context, builder: (_) => CreateSidequestDialog(
                          prefillTitle: (_generated!['title'] ?? '').toString().toUpperCase(),
                          prefillDescription: (_generated!['description'] ?? '').toString(),
                          prefillXp: _xp,
                          prefillVtype: _vtype,
                        ));
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00FF41),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      child: const Text('USE THIS',
                          style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, letterSpacing: 1.5, fontSize: 11)),
                    ),
                  ),
                ),
              ]),
            ],
            const SizedBox(height: 30),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// SIDEQUEST — admin create dialog
// ─────────────────────────────────────────────

class CreateSidequestDialog extends StatefulWidget {
  final String? prefillTitle;
  final String? prefillDescription;
  final int? prefillXp;
  final String? prefillVtype;
  const CreateSidequestDialog({
    super.key,
    this.prefillTitle,
    this.prefillDescription,
    this.prefillXp,
    this.prefillVtype,
  });

  @override
  State<CreateSidequestDialog> createState() => _CreateSidequestDialogState();
}

class _CreateSidequestDialogState extends State<CreateSidequestDialog> {
  final _titleController = TextEditingController();
  final _descController = TextEditingController();
  final _xpController = TextEditingController(text: '50');
  final _qrValueController = TextEditingController();
  final _timerMinController = TextEditingController(text: '60');
  final _friendCountController = TextEditingController(text: '1');
  final _secretCodeController = TextEditingController();
  String _vtype = 'qr_code';
  bool _saving = false;
  String? _selectedEventId;
  List<DocumentSnapshot> _events = [];
  String? _selectedPrereqId;
  String? _selectedPrereqTitle;
  List<DocumentSnapshot> _allQuests = [];
  bool _isLootDrop = false;
  final _lootDurationController = TextEditingController(text: '30');

  static const _vtypes = [
    ('qr_code', 'QR Code — scan hidden QR'),
    ('timer', 'Timer — stay active N minutes'),
    ('friend_added', 'Friends — add N new members'),
    ('code_entry', 'Code — enter secret word'),
  ];

  @override
  void initState() {
    super.initState();
    if (widget.prefillTitle != null) _titleController.text = widget.prefillTitle!;
    if (widget.prefillDescription != null) _descController.text = widget.prefillDescription!;
    if (widget.prefillXp != null) _xpController.text = '${widget.prefillXp}';
    if (widget.prefillVtype != null) _vtype = widget.prefillVtype!;
    _loadEvents();
    _loadQuests();
  }

  Future<void> _loadEvents() async {
    final snap = await FirebaseFirestore.instance
        .collection('events')
        .orderBy('startAt', descending: true)
        .limit(20)
        .get();
    if (mounted) setState(() => _events = snap.docs);
  }

  Future<void> _loadQuests() async {
    final snap = await FirebaseFirestore.instance
        .collection('sidequests')
        .orderBy('createdAt', descending: true)
        .limit(50)
        .get();
    if (mounted) setState(() => _allQuests = snap.docs);
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descController.dispose();
    _xpController.dispose();
    _qrValueController.dispose();
    _timerMinController.dispose();
    _friendCountController.dispose();
    _secretCodeController.dispose();
    super.dispose();
  }

  Future<void> _draftWithAI() async {
    final theme = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final ctrl = TextEditingController();
        return AlertDialog(
          backgroundColor: const Color(0xFF0D0D1A),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: Color(0xFF00FF41), width: 1),
          ),
          title: const Text(
            'AI DRAFT — THEME',
            style: TextStyle(
              color: Color(0xFF00FF41),
              fontSize: 14,
              fontWeight: FontWeight.bold,
              letterSpacing: 2,
            ),
          ),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            style: const TextStyle(color: Colors.white, fontSize: 14),
            decoration: const InputDecoration(
              hintText: 'e.g. midnight rave, halloween, recruitment night',
              hintStyle: TextStyle(color: Colors.white38, fontSize: 12),
            ),
            onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
              child: const Text(
                'GENERATE',
                style: TextStyle(color: Color(0xFF00FF41), fontWeight: FontWeight.bold),
              ),
            ),
          ],
        );
      },
    );
    if (theme == null || theme.isEmpty) return;

    setState(() => _saving = true);
    try {
      final callable = FirebaseFunctions.instanceFor(region: 'us-central1')
          .httpsCallable('generateQuestWithAI');
      final result = await callable.call(<String, dynamic>{
        'theme': theme,
        'verificationType': _vtype,
        'xpReward': int.tryParse(_xpController.text.trim()) ?? 50,
      });
      final data = (result.data is Map)
          ? Map<String, dynamic>.from(result.data as Map)
          : <String, dynamic>{};
      final title = (data['title'] as String? ?? '').trim();
      final desc = (data['description'] as String? ?? '').trim();
      final target = (data['suggestedTarget'] as num?)?.toInt() ?? 1;

      if (title.isNotEmpty) _titleController.text = title;
      if (desc.isNotEmpty) _descController.text = desc;
      if (_vtype == 'timer' && target > 0) _timerMinController.text = '$target';
      if (_vtype == 'friend_added' && target > 0) _friendCountController.text = '$target';

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('AI draft applied — review before saving'),
          backgroundColor: Color(0xFF00FF41),
        ),
      );
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('AI draft failed: ${e.message ?? e.code}'),
          backgroundColor: Colors.red,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('AI draft failed: $e'), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _draftBatchWithAI() async {
    final theme = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final ctrl = TextEditingController();
        return AlertDialog(
          backgroundColor: const Color(0xFF0D0D1A),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: Color(0xFF9F59FF), width: 1),
          ),
          title: const Text(
            'AI BATCH — THEME',
            style: TextStyle(
              color: Color(0xFF9F59FF),
              fontSize: 14,
              fontWeight: FontWeight.bold,
              letterSpacing: 2,
            ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Generate 5 distinct mission concepts. Pick one to use.',
                style: TextStyle(color: Colors.white54, fontSize: 11, height: 1.4),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: ctrl,
                autofocus: true,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                decoration: const InputDecoration(
                  hintText: 'e.g. tek004 launch night',
                  hintStyle: TextStyle(color: Colors.white38, fontSize: 12),
                ),
                onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
              child: const Text(
                'GENERATE 5',
                style: TextStyle(color: Color(0xFF9F59FF), fontWeight: FontWeight.bold),
              ),
            ),
          ],
        );
      },
    );
    if (theme == null || theme.isEmpty) return;

    setState(() => _saving = true);
    List<Map<String, dynamic>> quests = [];
    try {
      final callable = FirebaseFunctions.instanceFor(region: 'us-central1')
          .httpsCallable('generateQuestBatchWithAI');
      final result = await callable.call(<String, dynamic>{
        'theme': theme,
        'verificationType': _vtype,
        'xpReward': int.tryParse(_xpController.text.trim()) ?? 50,
        'count': 5,
      });
      final data = (result.data is Map)
          ? Map<String, dynamic>.from(result.data as Map)
          : <String, dynamic>{};
      final raw = data['quests'];
      if (raw is List) {
        for (final q in raw) {
          if (q is Map) {
            quests.add(Map<String, dynamic>.from(q));
          }
        }
      }
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Batch generate failed: ${e.message ?? e.code}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Batch generate failed: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }

    if (quests.isEmpty || !mounted) return;

    // Show the 5 concepts as a bottom sheet — user taps one to apply.
    final picked = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      backgroundColor: const Color(0xFF0D0D1A),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        side: BorderSide(color: Color(0xFF9F59FF), width: 1),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'AI BATCH — PICK ONE',
                style: TextStyle(
                  color: Color(0xFF9F59FF),
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 3,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Theme: "$theme"',
                style: const TextStyle(color: Colors.white54, fontSize: 11),
              ),
              const SizedBox(height: 16),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: quests.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (_, i) {
                    final q = quests[i];
                    final t = (q['title'] as String? ?? '').toUpperCase();
                    final d = q['description'] as String? ?? '';
                    return InkWell(
                      onTap: () {
                        HapticFeedback.lightImpact();
                        Navigator.of(ctx).pop(q);
                      },
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.04),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: const Color(0xFF9F59FF).withValues(alpha: 0.4),
                            width: 1,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  width: 22, height: 22,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF9F59FF).withValues(alpha: 0.18),
                                    shape: BoxShape.circle,
                                    border: Border.all(color: const Color(0xFF9F59FF), width: 1),
                                  ),
                                  child: Text(
                                    '${i + 1}',
                                    style: const TextStyle(
                                      color: Color(0xFF9F59FF),
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    t,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 14,
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: 1.2,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              d,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                                height: 1.45,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 10),
              Center(
                child: TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text(
                    'NONE OF THESE',
                    style: TextStyle(
                      color: Colors.white54,
                      fontSize: 11,
                      letterSpacing: 2,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (picked == null || !mounted) return;
    final title = (picked['title'] as String? ?? '').toUpperCase().trim();
    final desc = (picked['description'] as String? ?? '').trim();
    final target = (picked['suggestedTarget'] as num?)?.toInt() ?? 1;
    if (title.isNotEmpty) _titleController.text = title;
    if (desc.isNotEmpty) _descController.text = desc;
    if (_vtype == 'timer' && target > 0) _timerMinController.text = '$target';
    if (_vtype == 'friend_added' && target > 0) _friendCountController.text = '$target';
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Concept applied — review before saving'),
        backgroundColor: Color(0xFF9F59FF),
      ),
    );
  }

  Future<void> _save() async {
    final title = _titleController.text.trim().toUpperCase();
    final desc = _descController.text.trim();
    final xp = int.tryParse(_xpController.text.trim()) ?? 0;
    if (title.isEmpty || desc.isEmpty || xp <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Fill in all fields and set XP > 0'), backgroundColor: Colors.red));
      return;
    }
    setState(() => _saving = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final adminCode = prefs.getString('userReferralCode') ?? 'admin';
      final doc = <String, dynamic>{
        'title': title,
        'description': desc,
        'xpReward': xp,
        'active': true,
        'verificationType': _vtype,
        'createdBy': adminCode,
        'createdAt': FieldValue.serverTimestamp(),
        'totalCompletions': 0,
      };
      if (_vtype == 'qr_code') doc['qrCodeValue'] = _qrValueController.text.trim();
      if (_vtype == 'timer') doc['timerMinutes'] = int.tryParse(_timerMinController.text.trim()) ?? 60;
      if (_vtype == 'friend_added') doc['requiredFriendCount'] = int.tryParse(_friendCountController.text.trim()) ?? 1;
      if (_vtype == 'code_entry') doc['secretCode'] = _secretCodeController.text.trim().toUpperCase();
      if (_selectedEventId != null) doc['eventId'] = _selectedEventId;
      if (_selectedPrereqId != null) {
        doc['requiresQuestId'] = _selectedPrereqId;
        doc['requiresQuestTitle'] = _selectedPrereqTitle ?? '';
      }
      if (_isLootDrop) {
        doc['lootDrop'] = true;
        final mins = int.tryParse(_lootDurationController.text.trim()) ?? 30;
        doc['lootDropExpiresAt'] = Timestamp.fromDate(DateTime.now().add(Duration(minutes: mins)));
      }
      await FirebaseFirestore.instance.collection('sidequests').add(doc);
      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to create quest: $e'), backgroundColor: Colors.red));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF0D0D1A),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xFF00FF41), width: 1),
      ),
      title: const Text('CREATE SIDEQUEST',
          style: TextStyle(color: Color(0xFF00FF41), fontWeight: FontWeight.bold, fontSize: 16, letterSpacing: 2)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _field(_titleController, 'MISSION TITLE'),
            const SizedBox(height: 8),
            ValueListenableBuilder<QuestsConfig>(
              valueListenable: questsConfig,
              builder: (context, cfg, _) {
                if (!cfg.aiGenerationEnabled) return const SizedBox.shrink();
                return Row(
                  children: [
                    TextButton.icon(
                      onPressed: _saving ? null : _draftWithAI,
                      icon: const Icon(Icons.auto_awesome, size: 16, color: Color(0xFF00FF41)),
                      label: const Text(
                        'AI DRAFT',
                        style: TextStyle(
                          color: Color(0xFF00FF41),
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.5,
                        ),
                      ),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                    const SizedBox(width: 4),
                    TextButton.icon(
                      onPressed: _saving ? null : _draftBatchWithAI,
                      icon: const Icon(Icons.dashboard_customize, size: 16, color: Color(0xFF9F59FF)),
                      label: const Text(
                        'BATCH (5)',
                        style: TextStyle(
                          color: Color(0xFF9F59FF),
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.5,
                        ),
                      ),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 6),
            _field(_descController, 'DESCRIPTION', maxLines: 3),
            const SizedBox(height: 14),
            _field(_xpController, 'XP REWARD', keyboardType: TextInputType.number),
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              value: _vtype,
              dropdownColor: const Color(0xFF0D0D1A),
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: InputDecoration(
                labelText: 'VERIFICATION TYPE',
                labelStyle: const TextStyle(color: Color(0xFF00FF41), fontSize: 12, letterSpacing: 1),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Colors.white24)),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Color(0xFF00FF41))),
              ),
              items: _vtypes.map((t) => DropdownMenuItem(value: t.$1,
                  child: Text(t.$2, style: const TextStyle(fontSize: 13)))).toList(),
              onChanged: (v) => setState(() => _vtype = v ?? 'honor'),
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<String?>(
              value: _selectedEventId,
              dropdownColor: const Color(0xFF0D0D1A),
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: InputDecoration(
                labelText: 'LINK TO EVENT (optional)',
                labelStyle: const TextStyle(
                    color: Color(0xFF00FF41), fontSize: 12, letterSpacing: 1),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Colors.white24)),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Color(0xFF00FF41))),
              ),
              items: [
                const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('Global mission',
                        style: TextStyle(fontSize: 13))),
                ..._events.map((doc) {
                  final title =
                      (doc.data() as Map<String, dynamic>)['title'] as String? ??
                          doc.id;
                  return DropdownMenuItem<String?>(
                      value: doc.id,
                      child: Text(title,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13)));
                }),
              ],
              onChanged: (v) => setState(() => _selectedEventId = v),
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<String?>(
              value: _selectedPrereqId,
              dropdownColor: const Color(0xFF0D0D1A),
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: InputDecoration(
                labelText: 'REQUIRES MISSION FIRST (optional)',
                labelStyle: const TextStyle(color: Color(0xFF00FF41), fontSize: 12, letterSpacing: 1),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Colors.white24)),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Color(0xFF00FF41))),
              ),
              items: [
                const DropdownMenuItem<String?>(
                    value: null, child: Text('None', style: TextStyle(fontSize: 13))),
                ..._allQuests.map((doc) {
                  final t = (doc.data() as Map<String, dynamic>)['title'] as String? ?? doc.id;
                  return DropdownMenuItem<String?>(
                      value: doc.id,
                      child: Text(t, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)));
                }),
              ],
              onChanged: (v) {
                final t = v == null ? null : (_allQuests.firstWhere((d) => d.id == v, orElse: () => _allQuests.first).data() as Map<String, dynamic>)['title'] as String?;
                setState(() { _selectedPrereqId = v; _selectedPrereqTitle = t; });
              },
            ),
            const SizedBox(height: 14),
            Row(children: [
              Switch(
                value: _isLootDrop,
                activeThumbColor: const Color(0xFFE63946),
                onChanged: (v) => setState(() => _isLootDrop = v),
              ),
              const SizedBox(width: 4),
              const Text('LOOT DROP — TIME-LIMITED',
                  style: TextStyle(color: Color(0xFFE63946), fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
            ]),
            if (_isLootDrop) ...[
              const SizedBox(height: 8),
              _field(_lootDurationController, 'EXPIRES IN (minutes)', keyboardType: TextInputType.number),
            ],
            if (_vtype == 'qr_code') ...[
              const SizedBox(height: 14),
              _field(_qrValueController, 'QR CODE VALUE (what the QR encodes)'),
            ],
            if (_vtype == 'timer') ...[
              const SizedBox(height: 14),
              _field(_timerMinController, 'TIMER DURATION (minutes)', keyboardType: TextInputType.number),
            ],
            if (_vtype == 'friend_added') ...[
              const SizedBox(height: 14),
              _field(_friendCountController, 'FRIENDS REQUIRED', keyboardType: TextInputType.number),
            ],
            if (_vtype == 'code_entry') ...[
              const SizedBox(height: 14),
              _field(_secretCodeController, 'SECRET CODE (users must enter this)'),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('CANCEL', style: TextStyle(color: Colors.white38)),
        ),
        ElevatedButton(
          onPressed: _saving ? null : _save,
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF00FF41),
            foregroundColor: Colors.black,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          child: _saving
              ? const SizedBox(height: 16, width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
              : const Text('CREATE', style: TextStyle(fontWeight: FontWeight.bold)),
        ),
      ],
    );
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    int maxLines = 1,
    TextInputType keyboardType = TextInputType.text,
  }) {
    return TextField(
      controller: controller,
      maxLines: maxLines,
      keyboardType: keyboardType,
      style: const TextStyle(color: Colors.white, fontSize: 14),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(
          color: Color(0xFF00FF41),
          fontSize: 12,
          letterSpacing: 1,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Colors.white24),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFF00FF41), width: 1.5),
        ),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.04),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// SIDEQUEST — challenges tab
// ─────────────────────────────────────────────

class _ChallengesTab extends StatelessWidget {
  final String? userCode;
  const _ChallengesTab({required this.userCode});

  @override
  Widget build(BuildContext context) {
    if (userCode == null) {
      return const Center(
        child: Text('Log in to see challenges',
            style: TextStyle(color: Colors.white54)),
      );
    }

    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('challenges')
          .where('challengedCode', isEqualTo: userCode)
          .where('status', isEqualTo: 'pending')
          .orderBy('createdAt', descending: true)
          .snapshots(),
      builder: (context, inSnap) {
        return StreamBuilder<QuerySnapshot>(
          stream: FirebaseFirestore.instance
              .collection('challenges')
              .where('challengerCode', isEqualTo: userCode)
              .orderBy('createdAt', descending: true)
              .snapshots(),
          builder: (context, outSnap) {
            final incoming = inSnap.data?.docs ?? [];
            final outgoing = outSnap.data?.docs ?? [];

            if (incoming.isEmpty && outgoing.isEmpty) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    Icon(Icons.person_add, color: Colors.white24, size: 48),
                    SizedBox(height: 16),
                    Text('No challenges yet.',
                        style: TextStyle(color: Colors.white54, fontSize: 15)),
                    SizedBox(height: 8),
                    Text('Go to a mission and challenge a friend.',
                        style: TextStyle(color: Colors.white38, fontSize: 12)),
                  ],
                ),
              );
            }

            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
              children: [
                if (incoming.isNotEmpty) ...[
                  _sectionHeader('INCOMING'),
                  ...incoming.map((doc) => _ChallengeCard(
                        doc: doc,
                        isIncoming: true,
                        userCode: userCode!,
                      )),
                ],
                if (outgoing.isNotEmpty) ...[
                  _sectionHeader('SENT'),
                  ...outgoing.map((doc) => _ChallengeCard(
                        doc: doc,
                        isIncoming: false,
                        userCode: userCode!,
                      )),
                ],
              ],
            );
          },
        );
      },
    );
  }

  Widget _sectionHeader(String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, top: 4),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white38,
          fontSize: 11,
          letterSpacing: 2,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class _RanksTab extends StatelessWidget {
  final String? userCode;
  const _RanksTab({required this.userCode});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('applications')
          .orderBy('xpPoints', descending: true)
          .limit(50)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(
              child:
                  CircularProgressIndicator(color: Color(0xFF00FF41)));
        }
        final docs = snapshot.data?.docs ?? [];
        if (docs.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: const [
                Icon(Icons.emoji_events, color: Colors.white24, size: 48),
                SizedBox(height: 16),
                Text('No rankings yet.',
                    style:
                        TextStyle(color: Colors.white54, fontSize: 15)),
              ],
            ),
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
          itemCount: docs.length,
          itemBuilder: (context, i) {
            final data = docs[i].data() as Map<String, dynamic>;
            final name = data['name'] as String? ?? 'Anonymous';
            final xp = (data['xpPoints'] as num?)?.toInt() ?? 0;
            final level = (xp ~/ 100) + 1;
            final code = data['referralCode'] as String? ?? '';
            final isMe = code == userCode;
            final profileImageUrl = data['profileImageUrl'] as String?;
            final rank = i + 1;

            Color rankColor;
            IconData? medalIcon;
            if (rank == 1) {
              rankColor = const Color(0xFFFFD700);
              medalIcon = Icons.looks_one;
            } else if (rank == 2) {
              rankColor = const Color(0xFFC0C0C0);
              medalIcon = Icons.looks_two;
            } else if (rank == 3) {
              rankColor = const Color(0xFFCD7F32);
              medalIcon = Icons.looks_3;
            } else {
              rankColor = Colors.white38;
              medalIcon = null;
            }

            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: isMe
                    ? const Color(0xFF00FF41).withOpacity(0.08)
                    : Colors.white.withOpacity(0.04),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isMe
                      ? const Color(0xFF00FF41).withOpacity(0.4)
                      : (rank <= 3
                          ? rankColor.withOpacity(0.3)
                          : Colors.white10),
                ),
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 36,
                    child: rank <= 3
                        ? Icon(medalIcon, color: rankColor, size: 22)
                        : Text(
                            '#$rank',
                            style: TextStyle(
                              color: rankColor,
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                  ),
                  const SizedBox(width: 8),
                  CircleAvatar(
                    radius: 18,
                    backgroundColor: Colors.white10,
                    backgroundImage: profileImageUrl != null
                        ? NetworkImage(profileImageUrl)
                        : null,
                    child: profileImageUrl == null
                        ? const Icon(Icons.person,
                            color: Colors.white38, size: 18)
                        : null,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isMe ? '$name (YOU)' : name,
                          style: TextStyle(
                            color: isMe
                                ? const Color(0xFF00FF41)
                                : Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          'LVL $level',
                          style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 10,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: rankColor.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          color: rankColor.withOpacity(0.4)),
                    ),
                    child: Text(
                      '$xp XP',
                      style: TextStyle(
                        color: rankColor,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _ChallengeCard extends StatefulWidget {
  final DocumentSnapshot doc;
  final bool isIncoming;
  final String userCode;
  const _ChallengeCard(
      {required this.doc, required this.isIncoming, required this.userCode});

  @override
  State<_ChallengeCard> createState() => _ChallengeCardState();
}

class _ChallengeCardState extends State<_ChallengeCard> {
  bool _responding = false;

  Future<void> _respond(String status) async {
    setState(() => _responding = true);
    try {
      await widget.doc.reference.update({'status': status});

      final data = widget.doc.data() as Map<String, dynamic>;
      final challengerCode = data['challengerCode'] as String? ?? '';
      final challengedName = data['challengedName'] as String? ?? 'Someone';
      final questTitle = data['questTitle'] as String? ?? 'a mission';

      if (challengerCode.isNotEmpty) {
        await FirebaseFirestore.instance.collection('tek_notifications').add({
          'recipientCode': challengerCode,
          'type': status == 'accepted'
              ? 'challenge_accepted'
              : 'challenge_denied',
          'title': status == 'accepted'
              ? 'CHALLENGE ACCEPTED'
              : 'CHALLENGE DENIED',
          'body': status == 'accepted'
              ? '$challengedName accepted your challenge on "$questTitle". Game on.'
              : '$challengedName denied your challenge on "$questTitle".',
          'read': false,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _responding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.doc.data() as Map<String, dynamic>;
    final questTitle = data['questTitle'] as String? ?? '';
    final xpReward = (data['xpReward'] as num?)?.toInt() ?? 0;
    final status = data['status'] as String? ?? 'pending';
    final otherName = widget.isIncoming
        ? (data['challengerName'] as String? ?? 'Someone')
        : (data['challengedName'] as String? ?? 'Someone');

    Color statusColor;
    String statusLabel;
    switch (status) {
      case 'accepted':
        statusColor = const Color(0xFF00FF41);
        statusLabel = 'ACCEPTED';
        break;
      case 'denied':
        statusColor = Colors.red;
        statusLabel = 'DENIED';
        break;
      default:
        statusColor = Colors.amber;
        statusLabel = 'PENDING';
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: widget.isIncoming && status == 'pending'
              ? const Color(0xFF00FF41).withValues(alpha: 0.5)
              : Colors.white12,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.bolt,
                  color: const Color(0xFF00FF41), size: 16),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  questTitle,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: statusColor, width: 0.8),
                ),
                child: Text(
                  statusLabel,
                  style: TextStyle(
                      color: statusColor,
                      fontSize: 10,
                      fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            widget.isIncoming
                ? '$otherName challenged you  •  +$xpReward XP'
                : 'You challenged $otherName  •  +$xpReward XP',
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
          if (widget.isIncoming && status == 'pending') ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _responding ? null : () => _respond('denied'),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.red),
                      foregroundColor: Colors.red,
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                    child: const Text('DENY',
                        style: TextStyle(
                            fontSize: 12, fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _responding ? null : () => _respond('accepted'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00FF41),
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                    child: _responding
                        ? const SizedBox(
                            height: 16,
                            width: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.black))
                        : const Text('ACCEPT',
                            style: TextStyle(
                                fontSize: 12, fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
// SIDEQUEST — challenge a friend dialog
// ─────────────────────────────────────────────

class ChallengeFriendDialog extends StatefulWidget {
  final String questId;
  final String questTitle;
  final int xpReward;
  final String userCode;

  const ChallengeFriendDialog({
    super.key,
    required this.questId,
    required this.questTitle,
    required this.xpReward,
    required this.userCode,
  });

  @override
  State<ChallengeFriendDialog> createState() => _ChallengeFriendDialogState();
}

class _ChallengeFriendDialogState extends State<ChallengeFriendDialog> {
  List<Map<String, dynamic>> _friends = [];
  bool _loading = true;
  String? _sendingTo;

  @override
  void initState() {
    super.initState();
    _loadFriends();
  }

  Future<void> _loadFriends() async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('applications')
          .where('referralCode', isEqualTo: widget.userCode)
          .limit(1)
          .get();
      if (snap.docs.isEmpty) return;
      final friendCodes =
          (snap.docs.first.data()['friends'] as List?)?.cast<String>() ?? [];
      if (friendCodes.isEmpty) {
        setState(() => _loading = false);
        return;
      }

      final chunks = <List<String>>[];
      for (var i = 0; i < friendCodes.length; i += 10) {
        chunks.add(friendCodes.sublist(
            i, i + 10 > friendCodes.length ? friendCodes.length : i + 10));
      }

      final friends = <Map<String, dynamic>>[];
      for (final chunk in chunks) {
        final res = await FirebaseFirestore.instance
            .collection('applications')
            .where('referralCode', whereIn: chunk)
            .get();
        for (final d in res.docs) {
          friends.add(d.data());
        }
      }

      setState(() {
        _friends = friends;
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
    }
  }

  Future<void> _sendChallenge(Map<String, dynamic> friend) async {
    final targetCode = friend['referralCode'] as String? ?? '';
    if (targetCode.isEmpty) return;

    setState(() => _sendingTo = targetCode);
    try {
      final mySnap = await FirebaseFirestore.instance
          .collection('applications')
          .where('referralCode', isEqualTo: widget.userCode)
          .limit(1)
          .get();
      final myName =
          mySnap.docs.isNotEmpty ? (mySnap.docs.first.data()['name'] ?? '') : '';
      final targetName = friend['name'] as String? ?? 'Someone';

      await FirebaseFirestore.instance.collection('challenges').add({
        'questId': widget.questId,
        'questTitle': widget.questTitle,
        'xpReward': widget.xpReward,
        'challengerCode': widget.userCode,
        'challengerName': myName,
        'challengedCode': targetCode,
        'challengedName': targetName,
        'status': 'pending',
        'createdAt': FieldValue.serverTimestamp(),
      });

      await FirebaseFirestore.instance.collection('tek_notifications').add({
        'recipientCode': targetCode,
        'type': 'challenge_received',
        'title': 'CHALLENGE INCOMING',
        'body':
            '$myName challenged you to "${widget.questTitle}". Accept or deny in SIDEQUESTS.',
        'read': false,
        'createdAt': FieldValue.serverTimestamp(),
      });

      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Challenge sent to $targetName'),
          backgroundColor: const Color(0xFF00FF41),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('Failed: $e'), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _sendingTo = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF0D0D1A),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xFF00FF41), width: 1),
      ),
      title: const Text(
        'CHALLENGE A FRIEND',
        style: TextStyle(
          color: Color(0xFF00FF41),
          fontWeight: FontWeight.bold,
          fontSize: 15,
          letterSpacing: 2,
        ),
      ),
      content: SizedBox(
        width: double.maxFinite,
        height: 320,
        child: _loading
            ? const Center(
                child:
                    CircularProgressIndicator(color: Color(0xFF00FF41)))
            : _friends.isEmpty
                ? const Center(
                    child: Text(
                      'Add friends first to challenge them.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white54, fontSize: 13),
                    ),
                  )
                : ListView.builder(
                    itemCount: _friends.length,
                    itemBuilder: (context, i) {
                      final f = _friends[i];
                      final code = f['referralCode'] as String? ?? '';
                      final name = f['name'] as String? ?? 'Unknown';
                      final isSending = _sendingTo == code;
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor:
                              const Color(0xFF00FF41).withValues(alpha: 0.15),
                          child: Text(
                            name.isNotEmpty ? name[0].toUpperCase() : '?',
                            style: const TextStyle(
                                color: Color(0xFF00FF41),
                                fontWeight: FontWeight.bold),
                          ),
                        ),
                        title: Text(name,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 14)),
                        subtitle: Text(code,
                            style: const TextStyle(
                                color: Colors.white38, fontSize: 11)),
                        trailing: isSending
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Color(0xFF00FF41)))
                            : const Icon(Icons.send,
                                color: Color(0xFF00FF41), size: 20),
                        onTap: isSending ? null : () => _sendChallenge(f),
                      );
                    },
                  ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('CANCEL',
              style: TextStyle(color: Colors.white38)),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────
// SIDEQUEST — notification bell widget
// ─────────────────────────────────────────────

class _TekNotificationBell extends StatelessWidget {
  final String userCode;
  const _TekNotificationBell({required this.userCode});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('tek_notifications')
          .where('recipientCode', isEqualTo: userCode)
          .where('read', isEqualTo: false)
          .snapshots(),
      builder: (context, snap) {
        final count = snap.data?.docs.length ?? 0;
        return IconButton(
          icon: Stack(
            clipBehavior: Clip.none,
            children: [
              const Icon(Icons.notifications_outlined,
                  color: Color(0xFFB8B8C0)),
              if (count > 0)
                Positioned(
                  top: -4,
                  right: -4,
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: const BoxDecoration(
                      color: Color(0xFF00FF41),
                      shape: BoxShape.circle,
                    ),
                    constraints:
                        const BoxConstraints(minWidth: 16, minHeight: 16),
                    child: Text(
                      count > 9 ? '9+' : '$count',
                      style: const TextStyle(
                        color: Colors.black,
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
            ],
          ),
          onPressed: () => showModalBottomSheet(
            context: context,
            backgroundColor: Colors.transparent,
            isScrollControlled: true,
            builder: (_) => _NotificationsSheet(userCode: userCode),
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────
// SIDEQUEST — notifications bottom sheet
// ─────────────────────────────────────────────

class _NotificationsSheet extends StatelessWidget {
  final String userCode;
  const _NotificationsSheet({required this.userCode});

  Future<void> _markAllRead(List<DocumentSnapshot> docs) async {
    final batch = FirebaseFirestore.instance.batch();
    for (final d in docs) {
      batch.update(d.reference, {'read': true});
    }
    await batch.commit();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.65,
      decoration: const BoxDecoration(
        color: Color(0xFF0D0D1A),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        border: Border(
            top: BorderSide(color: Color(0xFF00FF41), width: 1)),
      ),
      child: Column(
        children: [
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'NOTIFICATIONS',
                  style: TextStyle(
                    color: Color(0xFF00FF41),
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 2,
                  ),
                ),
                TextButton(
                  onPressed: () async {
                    final snap = await FirebaseFirestore.instance
                        .collection('tek_notifications')
                        .where('recipientCode', isEqualTo: userCode)
                        .where('read', isEqualTo: false)
                        .get();
                    await _markAllRead(snap.docs);
                  },
                  child: const Text('MARK ALL READ',
                      style: TextStyle(
                          color: Colors.white38,
                          fontSize: 11,
                          letterSpacing: 1)),
                ),
              ],
            ),
          ),
          const Divider(color: Colors.white10, height: 1),
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('tek_notifications')
                  .where('recipientCode', isEqualTo: userCode)
                  .orderBy('createdAt', descending: true)
                  .limit(30)
                  .snapshots(),
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(
                      child: CircularProgressIndicator(
                          color: Color(0xFF00FF41)));
                }
                final docs = snap.data?.docs ?? [];
                if (docs.isEmpty) {
                  return const Center(
                    child: Text('NO TRANSMISSIONS YET',
                        style:
                            TextStyle(color: Colors.white38, fontSize: 13)),
                  );
                }
                return ListView.builder(
                  itemCount: docs.length,
                  itemBuilder: (context, i) {
                    final d = docs[i].data() as Map<String, dynamic>;
                    final read = d['read'] as bool? ?? false;
                    final title = d['title'] as String? ?? '';
                    final body = d['body'] as String? ?? '';
                    final type = d['type'] as String? ?? '';

                    IconData icon;
                    Color iconColor;
                    switch (type) {
                      case 'challenge_received':
                        icon = Icons.person_add;
                        iconColor = const Color(0xFF00FF41);
                        break;
                      case 'challenge_accepted':
                        icon = Icons.check_circle_outline;
                        iconColor = const Color(0xFF00FF41);
                        break;
                      case 'challenge_denied':
                        icon = Icons.cancel_outlined;
                        iconColor = Colors.red;
                        break;
                      case 'chat':
                        icon = Icons.chat_bubble_outline;
                        iconColor = const Color(0xFF00FF41);
                        break;
                      case 'friend_request':
                        icon = Icons.person_add_alt;
                        iconColor = Colors.lightBlueAccent;
                        break;
                      case 'friend_accepted':
                        icon = Icons.handshake;
                        iconColor = const Color(0xFF00FF41);
                        break;
                      case 'new_quest':
                        icon = Icons.bolt;
                        iconColor = const Color(0xFF00FF41);
                        break;
                      default:
                        icon = Icons.bolt;
                        iconColor = const Color(0xFF00FF41);
                    }

                    return InkWell(
                      onTap: () =>
                          docs[i].reference.update({'read': true}),
                      child: Container(
                        color: read
                            ? Colors.transparent
                            : const Color(0xFF00FF41).withValues(alpha: 0.05),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 14),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(icon, color: iconColor, size: 20),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    title,
                                    style: TextStyle(
                                      color: read
                                          ? Colors.white54
                                          : Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                      letterSpacing: 0.5,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    body,
                                    style: const TextStyle(
                                        color: Colors.white38,
                                        fontSize: 12,
                                        height: 1.4),
                                  ),
                                ],
                              ),
                            ),
                            if (!read)
                              Container(
                                width: 8,
                                height: 8,
                                margin: const EdgeInsets.only(top: 4, left: 8),
                                decoration: const BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Color(0xFF00FF41),
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
