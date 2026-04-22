---
name: Workday OAuth refresh tokens are scope-bound
description: Changing API client scopes in Workday does NOT update existing refresh tokens — must regenerate. Cost us hours of 403 debugging.
type: feedback
originSessionId: 600d8b8d-a9d5-4ab7-936a-e343e6ded197
---
Workday OAuth refresh tokens are bound to the functional area scopes that existed when the token was generated. Changing scopes on the API client (e.g. adding System, enabling "Include Workday Owned Scope") does NOT retroactively update existing tokens. The token exchange will return 200 (valid token) but API calls will return 403 S22 because the access token inherits the old scopes.

**Why:** Discovered 2026-04-21 after hours of debugging. Domain security policies were all correctly configured and activated, but WQL calls kept returning 403. The JWT decoded fine, the token endpoint returned 200, everything looked correct. Root cause was the refresh token predating the scope changes.

**How to apply:** Whenever Workday API client scopes change, always regenerate the refresh token ("Generate Refresh Token for Integrations" task) and update Secrets Manager. Do not assume the existing token will pick up new scopes. Check this first when debugging 403/S22 errors.
