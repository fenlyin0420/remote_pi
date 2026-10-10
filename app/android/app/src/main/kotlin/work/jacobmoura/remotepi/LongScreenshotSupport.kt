package work.jacobmoura.remotepi

import android.app.Activity
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.ScrollView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Makes the ROM's long-screenshot (长截屏 / scroll capture) work in this
 * Flutter app.
 *
 * How the ROM does it (verified against Xianyu's MIUI adaptation write-up
 * and the fit_system_screenshot plugin): the capture feature finds a
 * scrollable view in the focused window (width > screenWidth/3, height >
 * screenHeight/2, VISIBLE), then drives it with SYNTHETIC POINTER EVENTS of
 * a non-finger tool type — it does not call scrollBy. So the overlay below
 * must accept those events (and only those: real finger touches fall
 * through to the Flutter surface so the app stays interactive), let the
 * ScrollView scroll itself, and mirror every offset change to the Dart
 * side, which moves the real chat transcript. The Dart side keeps the
 * overlay's SCROLLABLE RANGE equal to the transcript's maxScrollExtent
 * (child height = range + the overlay's own height), so the ROM's loop
 * ends exactly where the transcript ends.
 *
 * The overlay is added/removed by the Dart side (`attach`/`detach`) while a
 * chat transcript is on top, so the button only lights up where capturing
 * makes sense.
 */
object LongScreenshotSupport {
    private const val TAG = "LongScreenshot"

    /** Channel name; must match [LongScreenshotAdapter.channelName] in Dart. */
    const val CHANNEL = "work.jacobmoura.remotepi/longscreenshot"

    /**
     * Which [FlutterEngine] owns the channel wiring for each activity, so an
     * engine re-creation cannot stack handlers.
     */
    private val installedEngines = java.util.WeakHashMap<Activity, FlutterEngine>()

    /**
     * The scrollable surface the ROM's synthetic gestures drive.
     *
     * Finger touches are rejected at [dispatchTouchEvent] so they fall
     * through to the Flutter surface below; everything else (the ROM's
     * injected capture gestures) scrolls this view, and each offset change
     * is pushed to the Dart side as `onScrollChanged {top: <physical px>}`.
     */
    private class LongScreenshotControlView(
        context: android.content.Context,
        private val channel: MethodChannel,
    ) : ScrollView(context) {
        private val child =
            View(context).apply {
                layoutParams = LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0)
            }

        // The transcript's maxScrollExtent in physical px. The child is
        // sized to range + this view's own height, so this view's
        // scrollable range equals the transcript's — the ROM's loop then
        // ends exactly where the transcript does, whatever chrome the
        // transcript's viewport leaves out of the full window.
        private var rangePx = 0

        private var firstSynthetic = true
        private var firstScroll = true

        init {
            addView(child)
            setWillNotDraw(true)
            isFocusable = false
            isFocusableInTouchMode = false
            setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO)
            overScrollMode = View.OVER_SCROLL_NEVER
            isVerticalScrollBarEnabled = false
        }

        override fun dispatchTouchEvent(ev: MotionEvent): Boolean {
            // A real finger must keep operating the Flutter app; the ROM's
            // synthetic capture gestures (non-finger tool type) scroll us.
            if (ev.getToolType(0) == MotionEvent.TOOL_TYPE_FINGER) {
                return false
            }
            if (firstSynthetic) {
                firstSynthetic = false
                // One-shot: proves on logcat that the ROM's injected events
                // do land here, and with which tool type/source.
                android.util.Log.d(
                    TAG,
                    "synthetic ev: tool=${ev.getToolType(0)} " +
                        "source=0x${ev.getSource().toString(16)} " +
                        "action=${ev.action}",
                )
            }
            return super.dispatchTouchEvent(ev)
        }

        override fun onScrollChanged(
            l: Int,
            t: Int,
            oldl: Int,
            oldt: Int,
        ) {
            super.onScrollChanged(l, t, oldl, oldt)
            if (syncing) return
            // A real (ROM-driven) scroll means the offset is no longer ours
            // to re-apply: a pending attach offset that survived this long
            // would otherwise snap the view back mid-capture.
            pendingPositionPx = null
            if (firstScroll) {
                firstScroll = false
                android.util.Log.d(TAG, "overlay scrolled to $t")
            }
            channel.invokeMethod("onScrollChanged", mapOf("top" to t))
        }

        override fun onSizeChanged(
            w: Int,
            h: Int,
            oldw: Int,
            oldh: Int,
        ) {
            super.onSizeChanged(w, h, oldw, oldh)
            if (h > 0 && h != oldh) applyRange()
        }

        /**
         * Moves the offset without telling Dart ([syncing] suppresses the
         * callback) — used to keep this view's offset aligned with the
         * transcript's position. Until this view has been laid out, a
         * [ScrollView.scrollTo] is clamped to zero, so the request is
         * deferred to [onLayout] instead of being silently dropped.
         */
        private var syncing = false
        private var pendingPositionPx: Int? = null

        fun syncTo(positionPx: Int) {
            if (positionPx == scrollY) return
            if (child.height > 0 && height > 0) {
                syncScroll(positionPx)
            } else {
                pendingPositionPx = positionPx
            }
        }

        private fun syncScroll(positionPx: Int) {
            syncing = true
            try {
                scrollTo(0, positionPx)
            } finally {
                syncing = false
            }
        }

        override fun onLayout(
            changed: Boolean,
            l: Int,
            t: Int,
            r: Int,
            b: Int,
        ) {
            super.onLayout(changed, l, t, r, b)
            // NOT gated on [changed]: the pass that gives the child its real
            // height comes after the pass that grows this view's frame, and
            // it reports changed == false. The pending offset is cleared
            // only once it was actually applied.
            val pending = pendingPositionPx ?: return
            if (child.height <= 0) return
            pendingPositionPx = null
            if (pending != scrollY) syncScroll(pending)
        }

        /**
         * Sets the transcript's scrollable range (physical px) and resizes
         * the child so this view's range matches it.
         */
        fun setScrollLength(newRangePx: Int) {
            if (newRangePx == rangePx) return
            rangePx = newRangePx
            applyRange()
        }

        private fun applyRange() {
            if (height <= 0) return
            val h = rangePx + height
            if (h == child.minimumHeight) return
            // A ScrollView measures its direct child with an UNSPECIFIED
            // height spec (which is why android:fillViewport exists), so
            // the spacer's height must come from its suggested minimum,
            // not from its LayoutParams.
            child.minimumHeight = h
        }
    }

    private fun installOn(
        activity: Activity,
        flutterEngine: FlutterEngine,
    ) {
        val content = activity.findViewById<ViewGroup>(android.R.id.content)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        var view: LongScreenshotControlView? = null

        channel.setMethodCallHandler { call, result ->
            val args = call.arguments as? Map<*, *>
            when (call.method) {
                "attach" -> {
                    val existing =
                        (0 until content.childCount)
                            .mapNotNull { index -> content.getChildAt(index) }
                            .filterIsInstance<LongScreenshotControlView>()
                    existing.forEach { old -> content.removeView(old) }
                    val fresh = LongScreenshotControlView(activity, channel)
                    // Last child of the content frame, i.e. above the
                    // Flutter surface.
                    content.addView(fresh)
                    view = fresh
                    fresh.setScrollLength((args?.get("length") as? Number ?: 0).toInt())
                    fresh.syncTo((args?.get("position") as? Number ?: 0).toInt())
                    result.success(null)
                }

                "detach" -> {
                    (0 until content.childCount)
                        .mapNotNull { index -> content.getChildAt(index) }
                        .filterIsInstance<LongScreenshotControlView>()
                        .forEach { old -> content.removeView(old) }
                    view = null
                    result.success(null)
                }

                "setScrollLength" -> {
                    view?.setScrollLength((args?.get("length") as? Number ?: 0).toInt())
                    result.success(null)
                }

                "setScrollPosition" -> {
                    view?.syncTo((args?.get("position") as? Number ?: 0).toInt())
                    result.success(null)
                }

                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    /**
     * Wires the channel for this [FlutterEngine]; idempotent per engine.
     * The overlay view itself is added/removed by the Dart side on
     * `attach`/`detach`.
     */
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
