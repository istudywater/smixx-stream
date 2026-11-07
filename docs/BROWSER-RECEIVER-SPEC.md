# Smixx browser receiver

## Purpose

Build a shared, receive-only web app at `https://stream.smixx.org` for live presentations from Smixx Stream and WinDeck/PDFDeck. A presenter starts a session from a Mac, copies a link, and opens it on a second computer connected to the room projector and sound system. The same link can serve remote viewers. LiveKit Cloud carries the live media. The Smixx web app handles links, access, and playback.

The first milestone is one Mac sending clean Program video **and** Program audio to a browser on a second computer. Scope ends at live, one-way delivery. Two-way conferencing, synchronized performance, recording, and large-event capacity are outside this milestone.

## Viewer experience

1. The presenter starts **Send to browser** in the Mac app and copies the generated watch link.
2. The viewer opens `/watch/<invite>` in a supported desktop browser and sees **Waiting for presenter** or **Play with sound**. Playback starts with a user gesture. If the browser blocks sound, keep an explicit retry control visible.
3. The viewer can mute, adjust volume, and enter or exit fullscreen. Fit the whole presentation into the viewport, preserving aspect ratio. Use the computer's selected audio output, including HDMI when selected by the operator.
4. Show **Reconnecting** during temporary connection loss. Resume playback when possible and offer a retry when needed. If the publisher briefly disappears, keep the session open and show **Waiting for presenter**.
5. An explicitly ended or expired session shows **Presentation ended**. Invalid links show a generic unavailable page. The viewer never requests microphone, camera, or screen capture permission.

The root page explains that a presenter provides the watch link. It needs no viewer login or room directory for the pilot. Anyone holding a valid link can watch and listen, so the presenter should share it only with intended viewers.

## Web app and service

Deploy the viewer and a small HTTPS session API under the same hostname. Keep provider secrets server-side. Use the LiveKit browser SDK to subscribe to the session's authorized presenter and attach that presenter's Program video and audio tracks. Let the SDK handle media transport and reconnection. The service stores session state in persistent storage shared across deployments.

| Operation | Contract |
| --- | --- |
| `POST /api/v1/sessions` | Authenticated presenter creates a session. Return a session ID, expiration time, watch URL, LiveKit server URL, and presenter token. Use an opaque, cryptographically random watch invite distinct from the room name. |
| `POST /api/v1/watch/<invite>/join` | Exchange a valid invite for the LiveKit server URL, a short-lived room-scoped viewer token with a unique participant identity, and the session expiration time. Return an unavailable response for invalid links and a terminal response for ended or expired sessions. Allow a valid viewer to request fresh credentials after an unrecoverable disconnect. |
| `POST /api/v1/sessions/<id>/publisher-token` | An authenticated session owner can refresh publisher credentials for an active session. Retain the session's designated publisher identity. |
| `DELETE /api/v1/sessions/<id>` | The authenticated session owner ends the session. Reject future token requests and close the LiveKit room to disconnect active participants. Make retries safe. |

- Use a scoped, revocable pilot credential per presenter, provisioned outside the app binary. Store it in the macOS Keychain when a native client is integrated. The API must enforce session ownership. Defer public account onboarding until after the pilot.
- Permit one designated publisher per room. Publisher tokens grant publish access for the Program tracks. Viewer tokens grant subscribe access only, with media and data publishing disabled.
- Default sessions to four hours and join tokens to five minutes for the pilot. Treat these as configurable starting values. Enforce session expiry server-side and close expired rooms through scheduled cleanup. Token expiry alone does not end a connected session.
- Persist the session owner, room identity, invite digest, expiration, and lifecycle state. Mark sessions ended before room teardown and retry teardown after provider failure. A previously minted token can remain usable until it expires, so room closure and short token lifetimes both matter.
- Rate-limit session creation and invite exchange. Keep watch invites and credentials out of analytics, referrers, and access logs where configurable. Return credentials with `Cache-Control: no-store` and use `Referrer-Policy: no-referrer` on the watch page.

## Mac publisher contract

Each sender joins as the designated publisher and publishes one video track containing the clean presentation and one audio track containing its intended Program output. Agree on stable track names, `program-video` and `program-audio`. Use a common timing basis for both tracks and keep them published through ordinary source switches. When paused, the sender provides its pause visual and silence. When the presenter ends the session, the app stops publishing and calls the end endpoint.

For Smixx Stream, the sources are the clean Program picture and Program mix. Keep Monitor and conference return out of that mix. The current app has a clean window and a Program audio bus. Native publishing and timestamp-aligned output require sender integration. WinDeck/PDFDeck should use the same API and track contract, with its own clean picture and chosen presentation audio.

## Build order and acceptance

1. Build the watch page and session API against a development LiveKit project. Include a development-only way to publish an audio/video test clip so the web app can be exercised independently of the Mac integration. Keep test publishing out of the production viewer.
2. Verify that two browser tabs can subscribe independently and that viewer credentials cannot publish. Verify invalid, expired, and ended links, including disconnection of active viewers after an explicit end. Exercise temporary loss of the publisher and a viewer network interruption.
3. Connect one native Mac sender. On a second computer, test desktop Chrome and Safari with fullscreen and audible playback. Run a clip with a clear visual and audio cue, switch to a slide with small text, and verify that the slide remains readable and clip audio stops when intended. Confirm the receiver plays the intended mix, measure observed audio/video offset, and record the device, browser, and network used. A test publisher validates the web app, while the native test validates the end-to-end milestone.

Before deploying to `stream.smixx.org`, configure DNS and HTTPS for the chosen host, LiveKit project credentials, persistent session storage, and expiry cleanup. Keep the web host and database selection open for the implementation handoff.
