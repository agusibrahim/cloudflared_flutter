# Cloudflared Tunnel Plugin ProGuard Rules

# Keep all gomobile generated classes
-keep class go.** { *; }
-keep class mobile.** { *; }

# Keep gomobile Seq class (critical for JNI)
-keep class go.Seq { *; }
-keep class go.Seq$Ref { *; }
-keep class go.Seq$RefMap { *; }

# Keep all native methods
-keepclasseswithmembernames class * {
    native <methods>;
}

# Keep gomobile interfaces and implementations
-keep interface mobile.TunnelCallback { *; }
-keep interface mobile.ServerCallback { *; }
-keep class * implements mobile.TunnelCallback { *; }
-keep class * implements mobile.ServerCallback { *; }

# Keep Mobile class methods
-keep class mobile.Mobile { *; }

# Don't warn about gomobile internal classes
-dontwarn go.**
-dontwarn mobile.**

# Keep class names for reflection
-keepnames class go.** { *; }
-keepnames class mobile.** { *; }
