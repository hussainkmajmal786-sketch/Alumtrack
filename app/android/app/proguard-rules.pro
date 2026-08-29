# R8 is enabled for release builds. Flutter's own rules are applied by the
# Flutter Gradle plugin; these cover the plugins this app uses.

# Google Sign-In and the Play Services auth stack reflect over these.
-keep class com.google.android.gms.auth.** { *; }
-keep class com.google.android.gms.common.** { *; }

# Geolocator's background/foreground service is referenced from the manifest,
# so R8 cannot see the usage.
-keep class com.baseflow.geolocator.** { *; }

# Keep annotations used for reflective lookups in the plugins above.
-keepattributes *Annotation*, Signature, InnerClasses, EnclosingMethod
