# Stripe SDK ProGuard rules
-keep class com.stripe.android.** { *; }
-keep class com.reactnativestripesdk.** { *; }
-keep class com.stripe.android.pushProvisioning.** { *; }

# Firebase
-keep class com.google.firebase.** { *; }
-keep class com.google.android.gms.** { *; }

# Flutter and Dart
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class io.flutter.embedding.** { *; }

# Google Play Services
-keep class com.google.android.gms.** { *; }
-dontwarn com.google.android.gms.**

# Google Play Core Library - required for split installs
-keep class com.google.android.play.core.** { *; }
-dontwarn com.google.android.play.core.**

# All Google packages
-keep class com.google.** { *; }
-dontwarn com.google.**

# Keep all native methods
-keepclasseswithmembernames class * {
    native <methods>;
}

# Keep enum values which are used in Switch statements
-keepclassmembers enum * {
    public static **[] values();
    public static ** valueOf(java.lang.String);
}

# Keep custom application classes
-keep public class * extends android.app.Activity
-keep public class * extends android.app.Service
-keep public class * extends android.content.BroadcastReceiver
-keep public class * extends android.content.ContentProvider
-keep public class * extends android.app.Fragment
-keep public class * extends androidx.fragment.app.Fragment

# Suppress warnings for missing classes from optional dependencies
-dontwarn com.stripe.android.pushProvisioning.**
-dontwarn com.reactnativestripesdk.pushProvisioning.**
