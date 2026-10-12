package com.meshcentral.htcommander

import android.content.Context
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/** Shares one application-owned engine with the foreground radio/server service. */
class MainActivity : FlutterActivity() {
    override fun provideFlutterEngine(context: Context): FlutterEngine =
        (application as HTCommanderApplication).provideFlutterEngine(context)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        (application as HTCommanderApplication).configureFlutterEngine(flutterEngine, this)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        // The application owns this engine. Detaching the Activity must leave its
        // Dart web server, Bluetooth streams and enabled location stream running.
        (application as HTCommanderApplication).detachActivity(this)
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
