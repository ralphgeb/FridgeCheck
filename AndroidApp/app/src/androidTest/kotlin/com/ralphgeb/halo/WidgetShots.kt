package com.ralphgeb.halo

import android.appwidget.AppWidgetHost
import android.appwidget.AppWidgetHostView
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.Bundle
import android.util.SizeF
import android.view.View
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.ralphgeb.halo.core.Snapshot
import com.ralphgeb.halo.ui.Looks
import com.ralphgeb.halo.widget.ScoreWidgetReceiver
import com.ralphgeb.halo.widget.ScoresWidgetReceiver
import com.ralphgeb.halo.widget.SleepWidgetReceiver
import com.ralphgeb.halo.widget.VitalsWidgetReceiver
import com.ralphgeb.halo.widget.Widgets
import kotlinx.coroutines.runBlocking
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/**
 * Puts each Halo widget on a real widget host (as a launcher would), lets it draw, and saves a
 * picture of it, so the widgets can be checked without a phone. Run by the emulator workflow.
 */
@RunWith(AndroidJUnit4::class)
class WidgetShots {
    private data class Shot(val name: String, val receiver: Class<*>, val widthDp: Int, val heightDp: Int)

    @Test
    fun drawWidgets() {
        val inst = InstrumentationRegistry.getInstrumentation()
        val ctx = inst.targetContext
        Looks.load(ctx)
        runBlocking { Widgets.save(ctx, Snapshot.sample()) }
        val out = File(ctx.getExternalFilesDir(null), "widgets").apply { deleteRecursively(); mkdirs() }
        val manager = AppWidgetManager.getInstance(ctx)
        val host = AppWidgetHost(ctx, 7001)
        inst.runOnMainSync { host.startListening() }
        val density = ctx.resources.displayMetrics.density
        val report = StringBuilder()
        val shots = listOf(
            Shot("scores-4x2", ScoresWidgetReceiver::class.java, 320, 165),
            Shot("score-2x2", ScoreWidgetReceiver::class.java, 165, 165),
            Shot("sleep-4x2", SleepWidgetReceiver::class.java, 320, 165),
            Shot("sleep-2x2", SleepWidgetReceiver::class.java, 165, 165),
            Shot("vitals-4x2", VitalsWidgetReceiver::class.java, 320, 165),
            Shot("vitals-4x1", VitalsWidgetReceiver::class.java, 320, 75),
        )
        for (s in shots) {
            try {
                val id = host.allocateAppWidgetId()
                val component = ComponentName(ctx, s.receiver)
                val options = Bundle().apply {
                    putInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, s.widthDp)
                    putInt(AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH, s.widthDp)
                    putInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, s.heightDp)
                    putInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT, s.heightDp)
                    putParcelableArrayList(AppWidgetManager.OPTION_APPWIDGET_SIZES, arrayListOf(SizeF(s.widthDp.toFloat(), s.heightDp.toFloat())))
                }
                val bound = manager.bindAppWidgetIdIfAllowed(id, component, options)
                report.append("${s.name}: bound=$bound\n")
                if (!bound) continue
                val info = manager.getAppWidgetInfo(id)
                var view: AppWidgetHostView? = null
                inst.runOnMainSync { view = host.createView(ctx, id, info) }
                val w = (s.widthDp * density).toInt()
                val h = (s.heightDp * density).toInt()
                // sized first, as on a home screen, so a widget with several layouts picks the right one
                inst.runOnMainSync {
                    view!!.measure(View.MeasureSpec.makeMeasureSpec(w, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(h, View.MeasureSpec.EXACTLY))
                    view!!.layout(0, 0, w, h)
                }
                ctx.sendBroadcast(Intent(AppWidgetManager.ACTION_APPWIDGET_UPDATE).setComponent(component)
                    .putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, intArrayOf(id)))
                Thread.sleep(7000)
                inst.runOnMainSync {
                    val v = view!!
                    v.measure(View.MeasureSpec.makeMeasureSpec(w, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(h, View.MeasureSpec.EXACTLY))
                    v.layout(0, 0, w, h)
                    val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                    val canvas = Canvas(bmp)
                    canvas.drawColor(0xFF2E3440.toInt())
                    v.draw(canvas)
                    File(out, "${s.name}.png").outputStream().use { bmp.compress(Bitmap.CompressFormat.PNG, 100, it) }
                    report.append("  drew ${w}x$h, children=${(v as? android.view.ViewGroup)?.childCount}\n")
                }
            } catch (e: Throwable) {
                report.append("${s.name}: FAILED ${e}\n${e.stackTraceToString().take(1500)}\n")
            }
        }
        inst.runOnMainSync { host.stopListening() }
        File(out, "report.txt").writeText(report.toString())
    }
}
