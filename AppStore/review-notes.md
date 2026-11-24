# Notes for App Review (paste into “App Review Information → Notes”)

Raskladushka is a typing aid for people who write in two languages (for example Russian and English).
It fixes a frequent mistake: a word typed while the wrong keyboard layout is active (“ghbdtn” instead of “привет”).

ABOUT THE PERMISSION (previous review: guideline 2.4.5)
The permission is OPTIONAL. Without it the app still converts selected text through the system Services menu
(test A below). It is requested only if the user wants words corrected automatically while typing, and only
after the user clicks “Allow…”; the welcome window can be continued without granting it.
What the permission is used for: posting keyboard events (CGEvent.post) to retype the mistyped word in the app
the user is typing in. macOS lists this capability under Privacy & Security → Accessibility; there is no other
macOS API for it. The app does NOT read or control other apps’ user interface: it makes no AXUIElement calls
(only AXIsProcessTrusted, to see whether permission was granted). Key-downs are observed with a LISTEN-ONLY
CGEventTap, which cannot modify or block events.
Who it helps: retyping a whole word is costly for people with motor impairments, and a person who is blind or
has low vision cannot see that the wrong layout is active. Version 1.3 adds, on the “Accessibility” tab:
- spoken corrections (uses the VoiceOver voice and rate when VoiceOver is on);
- an on-screen hint with adjustable size and high contrast; Increase Contrast, Reduce Transparency and
  Reduce Motion are respected;
- a shortcut made of a double press of ONE key (Shift, Shift) for people who cannot hold several keys;
- VoiceOver labels on the icon-only controls.

HOW TO TEST
Add a second layout first: System Settings → Keyboard → Input Sources → add “Russian”. Launch the app once;
a welcome window opens (it can be closed or continued without the permission).
A. No permission needed. In TextEdit type ghbdtn, select it, choose TextEdit → Services → “Convert Keyboard
   Layout” (or right-click → Services). The selection becomes “привет”.
B. In the welcome window (or menu-bar icon → Settings…) click “Allow…” and enable Raskladushka in
   System Settings → Privacy & Security → Accessibility.
C. In TextEdit, with the “ABC”/“U.S.” layout active, type ghbdtn and Space: the word becomes “привет” and the
   layout switches to Russian. Command-Z or Backspace right after it restores the typed word.
D. Type text, select it, press Control-Shift-Space: the selection is converted.
E. Menu-bar icon → Settings… → “Accessibility” tab: set “Speak corrections” to “Always”, repeat step C.

HOW IT WORKS
- Listen-only CGEventTap to know which keys formed the current word; CGEvent.post to send Backspace and the
  corrected text. For a selection: Command-C, convert, Command-V, then the clipboard is restored.
- Right after a correction the app registers Command-Z (and Shift-Command-Z after an undo) as a global hot key
  (RegisterEventHotKey) so the correction can be undone; the hot key is released on the next key press.

PRIVACY
- No network entitlement, no network connections. Sandboxed, no extra entitlements. No ads, no analytics.
- Keystrokes never leave the process. The key codes of the current word and up to 60 previous words are kept
  in memory only, and are discarded on a mouse click, arrow key, Return, Tab or app switch.
- Secure input fields (passwords) are not visible to the app; it stops processing while secure input is on.
- Words are validated with the system spell checker (NSSpellChecker). Speech uses the on-device synthesizer.
- Stored in UserDefaults: settings, the shortcut, lists of excluded apps and words, correction counters
  (numbers only), and words the user converted manually with the shortcut (to learn them; can be turned off).

No account or sign-in is required.
