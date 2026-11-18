package com.ralphgeb.halo

import android.content.Intent
import android.content.res.Configuration
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.runtime.mutableStateOf
import com.ralphgeb.halo.data.HaloStore
import com.ralphgeb.halo.ui.HaloApp
import com.ralphgeb.halo.ui.Looks

class MainActivity : ComponentActivity() {
    private val store: HaloStore by viewModels()
    /** A tab a widget asked for. */
    private val openTab = mutableStateOf<Int?>(null)
    /** A metric's graphs a widget asked for. */
    private val openMetric = mutableStateOf<String?>(null)

    companion object {
        const val EXTRA_TAB = "tab"
        const val EXTRA_METRIC = "metric"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        Looks.load(this)
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        readTab(intent)
        // the hourly check with the app closed: the morning and evening notes, fresh widgets
        com.ralphgeb.halo.notify.SyncWorker.schedule(this)
        setContent { HaloApp(store, openTab, openMetric) }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        readTab(intent)
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        Looks.systemDark = Looks.systemDark(this)
    }

    private fun readTab(intent: Intent?) {
        // test builds only: the emulator screenshots skip the setup pages
        val debuggable = (applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0
        if (debuggable && intent?.getBooleanExtra("haloSkipSetup", false) == true) store.finishOnboarding()
        val tab = intent?.getIntExtra(EXTRA_TAB, -1) ?: -1
        if (tab >= 0) openTab.value = tab
        intent?.getStringExtra(EXTRA_METRIC)?.let { openMetric.value = it }
        intent?.removeExtra(EXTRA_TAB)
        intent?.removeExtra(EXTRA_METRIC)
    }

    override fun onStop() {
        super.onStop()
        // leaving Halo: the widgets show the latest look and numbers
        com.ralphgeb.halo.widget.Widgets.refresh(this)
    }
}
