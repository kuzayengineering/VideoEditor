# Keep real class and method names in the release app (it is still shrunk),
# so error details copied from the app can be read without a code map.
-dontobfuscate

# MediaPipe (Eye color, Outfit) reaches its Java classes from native code and
# reads its settings with protobuf: shrinking must not remove or rename them.
-keep class com.google.mediapipe.** { *; }
-keep class com.google.protobuf.** { *; }
-dontwarn com.google.mediapipe.**
-dontwarn com.google.protobuf.**
# LiteRT (Recolor, Cutout) likewise.
-keep class org.tensorflow.lite.** { *; }
-keep class com.google.ai.edge.litert.** { *; }
-dontwarn org.tensorflow.lite.**
