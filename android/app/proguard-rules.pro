# Picked up by Flutter's Gradle plugin for release builds.
# shared_preferences_android 2.5.0 calls its Kotlin API from Dart through JNI (Pigeon JNI) and ships no keep rules:
# R8 renames what JNI looks up by name (kotlin.coroutines.Continuation in SharedPreferencesApiRegistrar.getAll) and
# the app hangs on the splash screen. Classes from `grep -rohE 'kotlin/[A-Za-z/$]+' lib` in the plugin and package:jni.
# Drop this once upstream ships consumer rules.
-keep class io.flutter.plugins.sharedpreferences.** { *; }
-keep class kotlin.coroutines.Continuation { *; }
-keep class kotlin.coroutines.intrinsics.CoroutineSingletons { *; }
-keep class kotlin.coroutines.intrinsics.IntrinsicsKt { *; }
-keep class kotlin.enums.EnumEntries { *; }
-keep class kotlin.jvm.internal.DefaultConstructorMarker { *; }
-keep class kotlin.Result { *; }
-keep class kotlin.Result$Failure { *; }
-keep class kotlin.Unit { *; }
