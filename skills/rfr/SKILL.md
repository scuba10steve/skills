---
name: rfr
description: Draft "RFR: <pr/mr-link>" in Slack or copy it to the clipboard for Microsoft Teams. Use when the user invokes /rfr or asks to request review of the current PR/MR in chat.
---

# Request For Review (RFR)

Create an "RFR: <link>" message for the current branch's pull request or merge request. The message is always printed first. Slack creates a draft the user sends manually; Teams copies the message to the clipboard for the user to paste.

## Steps

1. **Detect code platform:**

   ```bash
   origin="$(git remote get-url origin 2>/dev/null)"
   if [[ "$origin" == *"gitlab"* ]]; then
     platform="gitlab"
     noun="MR"
   else
     platform="github"
     noun="PR"
   fi
   ```

   Announce the detected platform and noun, e.g. `Detected GitHub repo → using PR nomenclature.`
   If no remote URL is available, warn the user (`No remote URL detected; defaulting to GitHub.`) and proceed.

2. **Resolve the PR/MR URL:**

   - **GitHub:**
     ```bash
     gh pr view --json url,number,title
     ```
   - **GitLab:**
     ```bash
     glab mr view -F json --jq '.web_url,.iid,.title'
     ```

   If no PR/MR exists for this branch, tell the user and stop.
   Display the title and URL so the user can confirm it's correct, using the detected noun (e.g. "Found PR #123: Fix login bug" or "Found MR #456: Fix login bug").

3. **Print the message:**

   Always print the final message on its own line first, so it is available whatever happens next:

   ```
   RFR: <url>
   ```

4. **Ask where to send it:** Slack, Teams, or neither. If the user picks neither, stop; the printed message is the result.

5. **Slack path** (if Slack was selected):

   Requires a Slack integration in the current harness that can search channels and create a message draft. If there is none, or a call to it fails, say so and stop; the printed message is the result.

   1. Ask which Slack channel to draft the RFR message in.
   2. Search for the channel with the integration.
      - Multiple matches → ask the user to pick the right one.
      - No match → ask the user to try a different channel name.
   3. Create a draft `RFR: <url>` in the selected channel.
   4. Confirm that the draft was created, showing the channel name, PR/MR link, and the draft link returned by the integration (if any) so the user can open Slack and send it.

6. **Teams path** (if Teams was selected):

   Copy `RFR: <url>` to the clipboard for the user to paste into Teams themselves.

   1. Resolve a clipboard command once, rather than assuming `pbcopy`:

      ```bash
      if command -v pbcopy >/dev/null 2>&1; then
        clip="pbcopy"                      # macOS
      elif command -v wl-copy >/dev/null 2>&1; then
        clip="wl-copy"                     # Linux / Wayland
      elif command -v xclip >/dev/null 2>&1; then
        clip="xclip -selection clipboard"  # Linux / X11
      else
        clip=""
      fi
      ```

   2. If `clip` is non-empty, copy the message (`printf '%s'` avoids a trailing newline):

      ```bash
      printf '%s' "RFR: $url" | $clip
      ```

      Confirm what was copied, e.g. `Copied to clipboard: RFR: <url> — paste it into your Teams channel.`

   3. If no clipboard command is available, say the printed message is the result. Do not treat this as a failure.

   **Note:** This path does no channel targeting; the user pastes and sends the message themselves.
