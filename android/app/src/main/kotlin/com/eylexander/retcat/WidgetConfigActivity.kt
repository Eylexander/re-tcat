package com.eylexander.retcat

import io.flutter.embedding.android.FlutterActivity

/**
 * A widget's setup: the launcher opens it when a widget is added or reconfigured (android:configure in
 * the res/xml widget infos), and an Android widget without a stop opens it when tapped. It runs the app's Dart, which
 * sees the configure intent and shows lib/setup.dart instead of the app, then finishes it.
 */
class WidgetConfigActivity : FlutterActivity()
