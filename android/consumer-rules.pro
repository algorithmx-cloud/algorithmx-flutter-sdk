# Campaign HTML calls EngageBridge.postMessage(...) by reflection. Preserve the
# annotated JavaScript interface method in release builds with code shrinking.
-keepclassmembers class * {
    @android.webkit.JavascriptInterface <methods>;
}
