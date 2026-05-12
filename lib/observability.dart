import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';

/// Thin wrapper so the rest of the app never has to touch the SDK directly.
/// Failures here must never reach the user — analytics is best-effort.
class Obs {
  static FirebaseAnalytics get analytics => FirebaseAnalytics.instance;
  static FirebaseCrashlytics get crash => FirebaseCrashlytics.instance;

  static Future<void> logEvent(String name, [Map<String, Object?>? params]) async {
    try {
      final clean = <String, Object>{};
      params?.forEach((k, v) {
        if (v != null) clean[k] = v;
      });
      await analytics.logEvent(name: name, parameters: clean.isEmpty ? null : clean);
    } catch (_) {}
  }

  static Future<void> setUser(String? uid, {String? referralCode, int? level}) async {
    try {
      await analytics.setUserId(id: uid);
      await crash.setUserIdentifier(uid ?? '');
      if (referralCode != null) {
        await analytics.setUserProperty(name: 'referral_code', value: referralCode);
      }
      if (level != null) {
        await analytics.setUserProperty(name: 'tier_level', value: level.toString());
      }
    } catch (_) {}
  }
}
