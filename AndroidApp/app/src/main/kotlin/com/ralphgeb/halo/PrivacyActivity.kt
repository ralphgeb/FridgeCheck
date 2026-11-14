package com.ralphgeb.halo

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import com.ralphgeb.halo.ui.PrivacyScreen

/** Why Halo asks for health data: Health Connect shows this from its permission screens. */
class PrivacyActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        com.ralphgeb.halo.ui.Looks.load(this)
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent { PrivacyScreen(onClose = { finish() }) }
    }
}
