# Preserve source file & line numbers for readable stack traces
-keepattributes SourceFile,LineNumberTable
-keepattributes *Annotation*

# Keep Android entrypoints referenced from XML/Manifest safely
-keepclassmembers class * extends android.app.Activity {
    public void *(android.view.View);
}
