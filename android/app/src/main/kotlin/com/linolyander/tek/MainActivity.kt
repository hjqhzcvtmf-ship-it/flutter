package com.linolyander.tek

import io.flutter.embedding.android.FlutterFragmentActivity

// Stripe SDK on Android requires FlutterFragmentActivity (not FlutterActivity)
// for the payment sheet's modal lifecycle.
class MainActivity : FlutterFragmentActivity()
