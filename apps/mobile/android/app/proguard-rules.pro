# R8 rules for the Leopard release build.
#
# The Flutter Gradle plugin and the plugins used by the app (local_auth,
# flutter_secure_storage, mobile_scanner / ML Kit, CameraX) ship their own
# consumer rules, so nothing has to be kept by hand here. Add a rule only for
# a concrete R8 failure, with a comment saying which class needed it.

# Keep stack traces useful without revealing source file names.
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile
