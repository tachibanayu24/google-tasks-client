# Security

Please report vulnerabilities privately through [GitHub's security advisories](https://github.com/tachibanayu24/google-tasks-client/security/advisories/new), not in public issues.

## What the app handles

- Your OAuth client and refresh token, stored in the login keychain.
- A cache of your task lists, in `~/Library/Application Support/com.tachibanayu24.GoogleTasksClient/cache.json`. It is readable only by your user and removed when you sign out.
- A local server on `127.0.0.1` during sign-in only. It accepts just the one redirect that carries the expected `state`, and it exchanges the code using PKCE.

The only network traffic is to Google: `accounts.google.com`, `oauth2.googleapis.com` and `tasks.googleapis.com`.
