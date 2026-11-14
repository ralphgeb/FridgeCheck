package com.ralphgeb.halo

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import com.ralphgeb.halo.data.HaloStore
import com.ralphgeb.halo.ui.HaloApp

class MainActivity : ComponentActivity() {
    private val store: HaloStore by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent { HaloApp(store) }
    }
}
