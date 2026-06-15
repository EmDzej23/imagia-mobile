# App Store Review — demo notes & App Privacy answers

Submission content for App Store Connect. Keep in sync with `ios/Runner/PrivacyInfo.xcprivacy` and the release checklist in `../PROGRESS.md`. Last updated: 2026-06-15.

> Context: the app currently ships as a **free app** (mosaic generation is free in the mobile apps via the launch bridge — no in-app digital purchases). Prints are an optional **physical** product paid via external web checkout (Creem), which is allowed. IAP for tokens is gated off until the Apple Organization account + Paid Apps agreement are live (`AppConfig.freeRenders`).

---

## 1) App Review notes

Paste into App Store Connect → app version → **App Review Information → Notes**. Create a dedicated review account (email/password — reviewers can't easily use Google/Apple sign-in) and fill the password; seed it with a couple of sample mosaics/projects so screens aren't empty.

```
SIGN-IN (required — the app is login-gated)
Demo account:
  Email:    review@imagiastore.com
  Password: <set-a-password>
Use "Sign in" with the email/password above (Google and Apple sign-in are also
offered but the demo account uses email/password).

HOW TO TEST THE CORE FEATURE (no purchase needed)
1. Tap "New Mosaic" → choose a base photo from the library.
2. On the Tile Library step, tap "Free sample photos" to add a ready-made set
   (so you don't need to pick many photos manually), then "Continue".
3. Open the Studio: adjust density/variety; the preview updates live.
4. Tap "Export full quality" to render the full-resolution mosaic and save it to
   Photos. Creating and exporting mosaics is FREE in the app — there are no
   in-app purchases for digital content.

PERMISSIONS
- Photos: used to pick the base image + tiles and to save the finished mosaic.
- Notifications: used to alert the user when a render finishes or a print order
  ships. (Optional; the app works without granting it.)

WALL-ART PRINTS (optional physical product)
- "Order as wall art" creates a physical print, fulfilled by a third-party
  print provider (Prodigi) and paid via an external web checkout (Creem). This
  is a physical good shipped to the customer, not digital content.
- Prints ship to US / UK / EU only, so the option appears based on region.
- You can review the flow up to the payment step; completing payment charges a
  real card, so we don't recommend placing a live order during review.

ACCOUNT DELETION
- Account → "Delete account" permanently deletes the account and all associated
  data (in-app, as required).

NOTE: We do not track users across apps or websites, and show no ads.
```

---

## 2) App Privacy answers (App Store Connect → App Privacy)

**"Do you or your third-party partners collect data from this app?"** → **Yes.**

For every type below: **Linked to the user = Yes**, **Used for tracking = No**, **Purpose = App Functionality.** (Mirrors `PrivacyInfo.xcprivacy` — keep in sync.)

| Apple category | Data type | Why |
|---|---|---|
| Contact Info | **Email Address** | Account / sign-in |
| Contact Info | **Name** | Account + print shipping |
| Contact Info | **Phone Number** | Print shipping (optional) |
| Contact Info | **Physical Address** | Print shipping |
| User Content | **Photos or Videos** | The photos used to build the mosaic + the result |
| Identifiers | **User ID** | Account identity |
| Identifiers | **Device ID** | Push notifications (Firebase Cloud Messaging token) |
| Purchases | **Purchase History** | Order history (prints / tokens) |

**Tracking section** → **"No, we do not use data to track."** (No ATT prompt, no ad/analytics SDKs.)

**Explicitly DO NOT declare** (not collected):
- **Payment Info / card numbers** — handled entirely by Creem/Apple; the app never receives card data.
- **Location** — region/locale is used to gate prints, which uses **no location permission**, so it's not "Location" data.
- Health, Financial info, Contacts, Browsing/Search history, Audio, Sensitive info, Diagnostics/Crash data (no crash-reporting SDK).

---

## Related required fields / reminders
- **Privacy Policy URL** — required separately in App Store Connect (the in-app native Privacy screen isn't enough); ensure a **public hosted URL** (e.g. `https://studio.imagiastore.com/privacy`) is reachable.
- **Add `ios/Runner/PrivacyInfo.xcprivacy` to the Runner target** in Xcode (target membership) or it won't be bundled.
- Keep this file, the nutrition label, and `PrivacyInfo.xcprivacy` consistent if data collection changes (e.g. if analytics/crash reporting is added later).
- Third parties involved (for your reference; the in-app SDK that collects is Firebase/FCM → Device ID): Firebase (push), Creem (payments — physical), Prodigi (print fulfilment), Vercel (hosting/blob), Resend (email).

---

## 3) Store listing copy (drafts — edit freely)

| Field | Limit | Draft |
|---|---|---|
| App Name | 30 | `Imagia — Photo Mosaics` |
| Subtitle | 30 | `Turn photos into mosaics` |
| Promotional Text | 170 | `Create stunning photo mosaics from your own pictures — tune them live, export in high resolution, and order them as framed wall art.` |
| Keywords | 100 (comma-separated, no spaces) | `mosaic,photo mosaic,collage,picture,wall art,canvas print,photo collage,art,maker,poster` |
| Primary Category | — | Photo & Video |
| Secondary Category | — | Graphics & Design (optional) |
| Copyright | — | `2026 <D.O.O. legal name>` |
| Support URL | — | `https://studio.imagiastore.com/contact` (must be reachable) |
| Marketing URL | — | `https://studio.imagiastore.com` (optional) |
| Privacy Policy URL | — | `https://studio.imagiastore.com/privacy` (required, public) |

### Description (≤ 4000 chars)

```
Turn your favorite photos into stunning mosaics made of hundreds of your own pictures. Imagia rebuilds one image out of many — a portrait made of memories, a landscape made of moments.

HOW IT WORKS
• Pick a base photo — the picture your mosaic will form.
• Add your tile photos, or load a ready-made sample set to start instantly.
• Tune it live — density, variety, and color blend — and watch the mosaic update in real time.
• Export a full-resolution mosaic and save it straight to your Photos.

POWERFUL, BUT SIMPLE
• Real-time preview with pinch-to-zoom and a magnifying loupe to inspect every tile.
• Smart tile matching places each photo where its colors fit best.
• Create animated mosaic videos to share.
• Your projects are saved, so you can come back and refine them anytime.

ORDER IT AS WALL ART
Love how it looks? Order your mosaic as a premium physical print — framed print, gallery canvas, or metal — shipped to your door. (Available in the US, UK, and EU.)

FREE TO CREATE
Designing, previewing, exporting, and saving your mosaics is free.

Made of moments. Create yours with Imagia.
```

---

## 4) Screenshots & build metadata checklist

**Device family decision:** ship **iPhone-only** for v1 (set the device family to iPhone in Xcode) — avoids iPad screenshots + iPad-layout review. Go universal later if desired.

### Screenshots
- **iPhone 6.9"** (16/15 Pro Max): **1320 × 2868 px** portrait — required; ASC scales it to smaller iPhones. (6.7" = 1290 × 2796 also accepted.)
- **iPad 13"**: 2064 × 2752 px — only if you support iPad.
- 1–10 per size; aim for 3–5 (Studio with a mosaic, loupe/zoom, finished export, wall-art mockup, video).
- PNG or JPEG, **RGB, flattened (no alpha)**, exact pixel size.

### App icon
- **1024 × 1024 PNG**, RGB, **no alpha, no transparency, square** (Apple rounds corners). In-app icon set already in the Flutter asset catalog.

### Questionnaires / toggles
- **Age Rating:** all "none" → **4+** (personal photos; no public UGC sharing).
- **Sign-in required:** Yes → demo account (section 1).
- **Export Compliance:** standard HTTPS only → `ITSAppUsesNonExemptEncryption = false` in Info.plist (confirm value) → answers "No" to the encryption question.
- **Content Rights:** uses the user's own photos → you have the rights / no third-party content.
- **App Review Contact:** name, phone, email.
- **Version / Build** numbers set.

### Compliance notes for review
- **Prints via Creem (external web checkout) are allowed and required to be non-IAP** — Guideline 3.1.3(e)/3.1.5(a): physical goods consumed outside the app must NOT use IAP. The review notes state prints are physical to preempt a reviewer false-positive. (If ever challenged: cite 3.1.3(e); last-resort fallback is opening the Creem checkout in Safari instead of the in-app webview.)
- **Digital tokens must use IAP** (not Creem) — which is why generation is currently FREE in the app (launch bridge) until Apple IAP is live.

### Optional (skip v1)
- App Preview video, promotional artwork, "What's New" (updates only).
