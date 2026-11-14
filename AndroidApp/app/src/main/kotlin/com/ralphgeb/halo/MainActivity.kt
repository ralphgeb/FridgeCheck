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

    companion object {
        const val EXTRA_TAB = "tab"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        Looks.load(this)
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        readTab(intent)
        setContent { HaloApp(store, openTab) }
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
        val tab = intent?.getIntExtra(EXTRA_TAB, -1) ?: -1
        if (tab >= 0) openTab.value = tab
    }
}
