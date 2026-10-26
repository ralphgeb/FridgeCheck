// Halo's Whoop sign-in service.
//
// Whoop needs the app's client secret whenever a sign-in code or refresh token is swapped for an
// access token. The secret lives here (as a Worker secret), never in the app:
//
//   GET  /login?state=…   → sends you to Whoop's sign-in page
//   GET  /callback        → Whoop comes back here; hands the code to the app (halo://whoop?code=…)
//   POST /token           → {"code": …} or {"refresh_token": …} → Whoop's token response
//
// The worker stores nothing: tokens go straight back to the app, which keeps them in the Keychain.

const AUTH_URL = "https://api.prod.whoop.com/oauth/oauth2/auth";
const TOKEN_URL = "https://api.prod.whoop.com/oauth/oauth2/token";
const SCOPES = "offline read:recovery read:cycles read:sleep read:workout read:profile read:body_measurement";

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const redirectURI = `${url.origin}/callback`;

    if (url.pathname === "/login") {
      const state = url.searchParams.get("state") || "";
      if (state.length < 8) return new Response("Missing state", { status: 400 });
      const to = new URL(AUTH_URL);
      to.search = new URLSearchParams({
        client_id: env.WHOOP_CLIENT_ID,
        redirect_uri: redirectURI,
        response_type: "code",
        scope: SCOPES,
        state,
      }).toString();
      return redirect(to.toString());
    }

    if (url.pathname === "/callback") {
      const back = new URL("halo://whoop");
      for (const key of ["code", "state", "error", "error_description"]) {
        const value = url.searchParams.get(key);
        if (value) back.searchParams.set(key, value);
      }
      return redirect(back.toString());
    }

    if (url.pathname === "/token" && request.method === "POST") {
      const body = await request.json().catch(() => ({}));
      const form = new URLSearchParams({
        client_id: env.WHOOP_CLIENT_ID,
        client_secret: env.WHOOP_CLIENT_SECRET,
      });
      if (typeof body.code === "string") {
        form.set("grant_type", "authorization_code");
        form.set("code", body.code);
        form.set("redirect_uri", redirectURI);
      } else if (typeof body.refresh_token === "string") {
        form.set("grant_type", "refresh_token");
        form.set("refresh_token", body.refresh_token);
        form.set("scope", "offline");
      } else {
        return Response.json({ error: "invalid_request" }, { status: 400 });
      }
      const response = await fetch(TOKEN_URL, {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: form,
      });
      return new Response(await response.text(), {
        status: response.status,
        headers: { "Content-Type": "application/json" },
      });
    }

    return new Response("Halo · Whoop sign-in", { status: 404 });
  },
};

function redirect(location) {
  return new Response(null, { status: 302, headers: { Location: location } });
}
