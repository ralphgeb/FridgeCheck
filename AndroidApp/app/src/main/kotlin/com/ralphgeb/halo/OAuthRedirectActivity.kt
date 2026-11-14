package com.ralphgeb.halo

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import com.ralphgeb.halo.data.GoogleAuth

/** Where Google's sign-in page sends you back: hands the answer over and returns to Halo. */
class OAuthRedirectActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        GoogleAuth.init(this)
        intent?.data?.let { GoogleAuth.complete(it) } ?: GoogleAuth.cancelled()
        // back to Halo, closing the sign-in tab above it
        startActivity(Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP))
        finish()
    }
}
