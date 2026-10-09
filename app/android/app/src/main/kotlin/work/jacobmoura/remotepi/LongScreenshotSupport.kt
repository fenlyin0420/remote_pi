package work.jacobmoura.remotepi

import android.app.Activity
import android.view.View
import android.view.ViewGroup
import android.widget.ScrollView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Makes the ROM's long-screenshot (长截屏 / scroll capture) find a scrollable
 * view inside this Flutter window.
 *
 * A ROM's long-screenshot works by finding a scrollable view in the focused
 * window (MIUI/HyperOS: width > screenWidth/3, height > screenHeight/2,
 * VISIBLE) and driving it with scrollBy() until canScrollVertically(1)
 * turns false, capturing a frame per step and stitching them. A Flutter
 * window holds one drawing surface and no scrollable views, so the button
 * stays grey.
 *
 * [install] therefore lays a transparent scrollable control view on top of
 * the Flutter surface: the ROM finds and scrolls IT, it mirrors every scroll
 * step to the Dart side (the [LongScreenshotAdapter] moves the real
 * transcript) and answers canScroll*() from the snapshot Dart reports.
 *
 * The view is touch-transparent and non-focusable, so normal operation is
 * unaffected — taps pass through to the Flutter surface, and it stays out of
 * the accessibility tree.
 */
object LongScreenshotSupport {
    private const val TAG = "LongScreenshot"

    /** Channel name; must match [LongScreenshotAdapter.channelName] in Dart. */
    const val CHANNEL = "work.jacobmoura.remotepi/longscreenshot"

    /**
     * Which [FlutterEngine] owns the installed control view for each
     * activity, so an engine re-creation cannot stack a second view.
     */
    private val installedEngines = java.util.WeakHashMap<Activity, FlutterEngine>()

    /**
     * Consecutive scrollBy() steps without a fresh setScrollState after
     * which the cache is declared stale: a dead Dart side must not let the
     * ROM loop forever on a stale snapshot (e.g. engine re-created while
     * the last report said active). The valve trips grey, and the next
     * fresh report re-enables it.
     */
    private const val MAX_UNACKNOWLEDGED_SCROLLS = 8

    /**
     * The control surface the ROM scrolls. The child is tall enough that
     * [scrollBy] (delegated to [ScrollView]) can advance the view's own
     * offset on every step — a capture loop that reads the view's offset
     * progression would see a view that clamps early as one that ended,
     * and stop.
     */
    private class LongScreenshotControlView(
        context: android.content.Context,
        private val channel: MethodChannel,
    ) : ScrollView(context) {
        private val child =
            View(context).apply {
                layoutParams = LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 200_000)
            }

        init {
            addView(child)
            setWillNotDraw(true)
            isFocusable = false
            isFocusableInTouchMode = false
            setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO)
            overScrollMode = View.OVER_SCROLL_NEVER
            isVerticalScrollBarEnabled = false
        }

        override fun onInterceptTouchEvent(ev: android.view.MotionEvent): Boolean = false

        override fun onTouchEvent(ev: android.view.MotionEvent): Boolean = false

        /**
         * The Android contract is ±1 (1 = down, -1 = up); some ROM code
         * passes the FOCUS_* constants instead — answer both. (`View`
         * alone has no ±1 constants, hence the literal branch.)
         */
        override fun canScrollVertically(direction: Int): Boolean = when (direction) {
            View.FOCUS_UP -> active && canScrollUp
            View.FOCUS_DOWN -> active && canScrollDown
            else -> active && if (direction < 0) canScrollUp else canScrollDown
        }

        override fun scrollBy(
            x: Int,
            y: Int,
        ) {
            if (y == 0) return
            // Advance the view's own offset so a loop that reads
            // getScrollY()/computeVerticalScrollOffset() sees real motion;
            // the answer to canScroll*() comes from the Dart report, not
            // from these bounds.
            super.scrollBy(x, y)
            unacknowledgedScrolls++
            if (unacknowledgedScrolls > MAX_UNACKNOWLEDGED_SCROLLS) {
                // Stale cache: the Dart side has not answered any recent
                // step. Say not scrollable so the ROM stops; the next
                // fresh report flips it back.
                active = false
                canScrollUp = false
                canScrollDown = false
                unacknowledgedScrolls = 0
            }
            channel.invokeMethod("scrollBy", mapOf("dy" to y))
        }

        /** True while the Dart side says its list is mounted and its route is on top. */
        @Volatile var active = false

        @Volatile var canScrollUp = false

        @Volatile var canScrollDown = false

        private var unacknowledgedScrolls = 0

        fun acknowledge() {
            unacknowledgedScrolls = 0
        }
    }

    private fun installOn(
        activity: Activity,
        flutterEngine: FlutterEngine,
    ) {
        val content = activity.findViewById<ViewGroup>(android.R.id.content)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        // The ROM probes canScrollVertically() on every step, off the
        // channel. The last state Dart reported is cached here and only
        // refreshed when Dart reports again.
        val view =
            LongScreenshotControlView(activity, channel).also {
                // An engine re-creation leaves the old view dead: drop it
                // before laying the new one down.
                (0 until content.childCount)
                    .mapNotNull { index -> content.getChildAt(index) }
                    .filterIsInstance<LongScreenshotControlView>()
                    .forEach { old -> content.removeView(old) }
                // Last child of the content frame, i.e. above the Flutter
                // surface, so the ROM's hit scan finds it first.
                content.addView(it)
            }
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "setScrollState" -> {
                    val args = call.arguments as? Map<*, *> ?: return@setMethodCallHandler
                    view.active = args["active"] as? Boolean ?: false
                    view.canScrollUp = view.active && (args["canUp"] as? Boolean ?: false)
                    view.canScrollDown = view.active && (args["canDown"] as? Boolean ?: false)
                    view.acknowledge()
                    result.success(null)
                }

                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    /** Installs the control view for this [FlutterEngine]; idempotent per engine. */
    fun install(
        activity: Activity,
        flutterEngine: FlutterEngine,
    ) {
        if (installedEngines[activity] === flutterEngine) return
        installedEngines[activity] = flutterEngine
        activity.window.decorView.post {
            try {
                installOn(activity, flutterEngine)
            } catch (t: Throwable) {
                android.util.Log.w(TAG, "install failed", t)
            }
        }
    }
}
