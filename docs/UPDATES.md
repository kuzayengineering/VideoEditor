# Getting updates automatically

Every time new work lands on the main branch, GitHub builds the app and
publishes a **Release** (version 0.1.1, 0.1.2, …). Each release includes:

- `VideoEditor-<version>-android-arm64.apk` (the Android app)
- `VideoEditor-<version>-windows-x64.zip` (the Windows program)

Releases are listed at
<https://github.com/kuzayengineering/VideoEditor/releases>.

## One-time setup 1: the signing key (GitHub)

Android only installs an update if it's signed with the same digital key as
the version already on the phone. The key is kept as two hidden **secrets**
in the repository settings, never in the code.

1. Open the repository on github.com → **Settings** → **Secrets and
   variables** → **Actions**.
2. Click **New repository secret** and add `ANDROID_KEYSTORE_PASSWORD` with
   the value from the key file you were given.
3. Add a second secret, `ANDROID_KEYSTORE_BASE64`, with the long line of text
   from the same file.
4. **Keep a backup of that key file** (password manager or encrypted folder).
   If the key is ever lost, updates can't install over the existing app.

Until the secrets exist, builds still run (and the files can be downloaded
from each run's *Artifacts* section) but no release is published.

## One-time setup 2: Obtainium (Android)

The repository is **private**, so Obtainium needs a read-only access token to
see the releases.

1. On github.com, open your profile picture → **Settings** → **Developer
   settings** → **Personal access tokens** → **Fine-grained tokens** →
   **Generate new token**.
   - Name: `Obtainium`
   - Expiration: the longest allowed (you'll need to make a new one when it
     expires)
   - Repository access: **Only select repositories** → `VideoEditor`
   - Permissions → Repository permissions → **Contents: Read-only**
   - Click **Generate token** and copy it.
2. In Obtainium: **Settings** → find the **GitHub** section → paste the token
   into the personal access token field.
3. In Obtainium: **Add App** → URL
   `https://github.com/kuzayengineering/VideoEditor` → **Add**.
4. Tap **Install**. Android will ask you to allow installs from Obtainium the
   first time.

From then on Obtainium checks for new releases and offers each update.

> If you'd rather not deal with tokens, the repository can be made public
> instead (Settings → General → Danger Zone → Change visibility). Then step 1
> and 2 aren't needed. That also makes the source code visible to everyone.

## Windows

For now: open the Releases page, download the newest `.zip`, unzip it and run
`video_editor.exe`. Windows SmartScreen may warn about an "unrecognized app"
the first time. Click **More info → Run anyway**.

### FFmpeg (the Windows video engine)

FFmpeg, which the Windows version uses to read and export video, now comes
inside the download (in the `ffmpeg` folder next to `video_editor.exe`). If
you installed it separately earlier, that copy is no longer needed.

Planned: the Windows app checks for new releases itself and offers a one-click
update.
