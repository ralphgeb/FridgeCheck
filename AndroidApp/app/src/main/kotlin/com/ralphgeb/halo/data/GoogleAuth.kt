package com.ralphgeb.halo.data

import android.content.Context
import android.net.Uri
import androidx.browser.customtabs.CustomTabsIntent
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.security.MessageDigest
import java.security.SecureRandom
import android.util.Base64

/**
 * Signs in to your Fitbit account (Google owns Fitbit data now) with OAuth 2.0 and PKCE, in a
 * browser tab, and keeps a fresh access token for the Google Health API. The same sign-in as the
 * iPhone app; the tokens stay in this app's private storage on the phone.
 */
object GoogleAuth {
    /** Google's OAuth client for Halo (public, not a secret). */
    const val CLIENT_ID = "94050104553-876cam76fuffpsgne8a9o6gh8r12tlv8.apps.googleusercontent.com"
    val REDIRECT_SCHEME = "com.googleusercontent.apps." + CLIENT_ID.removeSuffix(".apps.googleusercontent.com")
    val REDIRECT_URI = "$REDIRECT_SCHEME:/oauth2redirect"

    private val SCOPES = listOf(
        "https://www.googleapis.com/auth/googlehealth.activity_and_fitness.readonly",
        "https://www.googleapis.com/auth/googlehealth.health_metrics_and_measurements.readonly",
        "https://www.googleapis.com/auth/googlehealth.sleep.readonly",
    )

    /** Your devices (for the band's battery). Asked for on its own, added to the sign-in you have, so the main sign-in never depends on it. */
    const val DEVICES_SCOPE = "https://www.googleapis.com/auth/googlehealth.settings.readonly"
    private const val AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"
    private const val TOKEN_URL = "https://oauth2.googleapis.com/token"
    private const val PREFS = "halo_google"

    data class State(val connected: Boolean = false, val busy: Boolean = false, val error: String? = null)

    private val _state = MutableStateFlow(State())
    val state: StateFlow<State> = _state.asStateFlow()

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val refreshLock = Mutex()
    @Volatile private var exchanging = false
    private lateinit var app: Context

    fun init(context: Context) {
        app = context.applicationContext
        _state.update { it.copy(connected = prefs().getString("refresh", null) != null) }
    }

    private fun prefs() = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    val isConnected: Boolean get() = _state.value.connected

    /** Opens Google's sign-in in a browser tab. The answer comes back to [OAuthRedirectActivity]. */
    fun connect(context: Context, scopes: List<String> = SCOPES) {
        val verifier = random(64)
        val st = random(24)
        prefs().edit().putString("verifier", verifier).putString("state", st).apply()
        val url = Uri.parse(AUTH_URL).buildUpon()
            .appendQueryParameter("client_id", CLIENT_ID)
            .appendQueryParameter("redirect_uri", REDIRECT_URI)
            .appendQueryParameter("response_type", "code")
            .appendQueryParameter("scope", scopes.joinToString(" "))
            .appendQueryParameter("code_challenge", challenge(verifier))
            .appendQueryParameter("code_challenge_method", "S256")
            .appendQueryParameter("state", st)
            .appendQueryParameter("prompt", "consent")
            .appendQueryParameter("include_granted_scopes", "true")
            .build()
        _state.update { it.copy(busy = true, error = null) }
        try {
            CustomTabsIntent.Builder().setShowTitle(true).build().launchUrl(context, url)
        } catch (e: Exception) {
            _state.update { it.copy(busy = false, error = "Couldn't open the browser to sign in.") }
        }
    }

    /** The browser came back: swap the code for tokens. */
    fun complete(uri: Uri) {
        val p = prefs()
        val code = uri.getQueryParameter("code")
        val st = uri.getQueryParameter("state")
        val verifier = p.getString("verifier", null)
        if (code == null || st != p.getString("state", null) || verifier == null) {
            val why = uri.getQueryParameter("error")
            _state.update { it.copy(busy = false, error = if (why == "access_denied") "Sign-in was cancelled." else "Google didn't return a sign-in code.") }
            return
        }
        exchanging = true
        scope.launch {
            try {
                exchange(
                    mapOf(
                        "client_id" to CLIENT_ID, "code" to code, "code_verifier" to verifier,
                        "grant_type" to "authorization_code", "redirect_uri" to REDIRECT_URI,
                    )
                )
                p.edit().remove("verifier").remove("state").apply()
                _state.update { State(connected = prefs().getString("refresh", null) != null) }
            } catch (e: Exception) {
                _state.update { it.copy(busy = false, error = e.message ?: "Google sign-in failed.") }
            } finally {
                exchanging = false
            }
        }
    }

    /** Back in Halo: if the sign-in tab was closed without signing in, stop waiting for it. */
    fun onResume() {
        if (!_state.value.busy) return
        scope.launch {
            kotlinx.coroutines.delay(1500)
            if (!exchanging && !_state.value.connected) _state.update { it.copy(busy = false) }
        }
    }

    /** The sign-in tab was closed without an answer. */
    fun cancelled() = _state.update { it.copy(busy = false) }

    fun disconnect() {
        val token = prefs().getString("refresh", null) ?: prefs().getString("access", null)
        prefs().edit().clear().apply()
        _state.update { State() }
        if (token != null) scope.launch {
            runCatching {
                val c = URL("https://oauth2.googleapis.com/revoke?token=" + URLEncoder.encode(token, "UTF-8")).openConnection() as HttpURLConnection
                c.requestMethod = "POST"
                c.responseCode
                c.disconnect()
            }
        }
    }

    /** A valid access token, refreshed when it has under a minute left. */
    suspend fun accessToken(): String = refreshLock.withLock {
        val p = prefs()
        val access = p.getString("access", null)
        if (access != null && p.getLong("expiry", 0) - System.currentTimeMillis() > 60_000) return access
        val refresh = p.getString("refresh", null) ?: throw IllegalStateException("Sign in to your Fitbit account in Settings.")
        exchange(mapOf("client_id" to CLIENT_ID, "refresh_token" to refresh, "grant_type" to "refresh_token"))
        return p.getString("access", null) ?: throw IllegalStateException("Sign in to your Fitbit account in Settings.")
    }

    private suspend fun exchange(form: Map<String, String>) = withContext(Dispatchers.IO) {
        val c = URL(TOKEN_URL).openConnection() as HttpURLConnection
        c.requestMethod = "POST"
        c.doOutput = true
        c.connectTimeout = 20_000
        c.readTimeout = 30_000
        c.setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
        val body = form.entries.joinToString("&") { "${it.key}=${URLEncoder.encode(it.value, "UTF-8")}" }
        c.outputStream.use { it.write(body.toByteArray()) }
        val status = c.responseCode
        val text = (if (status in 200..299) c.inputStream else c.errorStream)?.bufferedReader()?.use { it.readText() } ?: ""
        c.disconnect()
        val json = runCatching { JSONObject(text) }.getOrDefault(JSONObject())
        val access = json.optString("access_token", "")
        if (status != 200 || access.isEmpty()) {
            if (json.optString("error") == "invalid_grant") {
                // refresh token revoked or expired: sign in again
                prefs().edit().clear().apply()
                _state.update { State(error = "Your Fitbit sign-in expired. Connect again.") }
            }
            throw IllegalStateException("Google sign-in failed: " + (json.optString("error_description").ifEmpty { json.optString("error").ifEmpty { "error $status" } }))
        }
        val e = prefs().edit()
            .putString("access", access)
            .putLong("expiry", System.currentTimeMillis() + json.optLong("expires_in", 3600) * 1000)
        json.optString("refresh_token", "").takeIf { it.isNotEmpty() }?.let { e.putString("refresh", it) }
        e.apply()
    }

    private fun random(length: Int): String {
        val chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        val rng = SecureRandom()
        return (1..length).map { chars[rng.nextInt(chars.length)] }.joinToString("")
    }

    private fun challenge(verifier: String): String {
        val hash = MessageDigest.getInstance("SHA-256").digest(verifier.toByteArray())
        return Base64.encodeToString(hash, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)
    }
}
