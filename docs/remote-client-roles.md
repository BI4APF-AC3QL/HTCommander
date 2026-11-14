# Client roles and session revocation

Windows: Settings → Servers → Phone remote control settings. Enable default read-only and host approval when each visitor should first request control. The live client list shows role, ownership and queue position.

- Toggle a connection between read-only and permission to request control. This does not grant TX/APRS/position scopes.
- Grant one connection exclusive control; granting also makes that connection eligible. Same-login sibling sockets stay read-only.
- Downgrading a holder releases control immediately. Windows can recall every remote holder.
- Revoke login disconnects every socket sharing that login session. Independent sessions keep working. The revoked pages retry, then return to login; a new login uses the configured default role.
- Emergency stop disables grants until Windows explicitly resumes.

Roles are connection-scoped, not named accounts; password login is shared. Revocation does not prevent someone who still knows the password from signing in again. Change the remote password if access must be removed persistently.

## Acceptance

Thirteen targeted Flutter tests cover the narrow host editor, server authentication/roles/revocation and ownership. A real 390px browser used three production HTTP/WebSocket connections: one login at 127.0.0.1, its second tab, and an independent login at localhost. Default controls disabled; request queued; host grant enabled only the selected connection; its volume action generated exactly one simulated SetVolumeLevel event. Downgrade disabled it and released ownership. Revocation returned both same-login tabs to login while the independent login stayed connected. Browser console had no errors. Tests used a simulated radio and zero RF/PTT requests.
