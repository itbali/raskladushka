# Notes for App Review (paste into “App Review Information → Notes”)

Raskladushka is a menu-bar utility for people who type in two languages (for example Russian and English).
It fixes a very common mistake: typing a word while the wrong keyboard layout is active
(“ghbdtn” instead of “привет”).

HOW TO TEST
1. Add a second keyboard layout: System Settings → Keyboard → Input Sources → add “Russian”.
2. Launch the app. A keyboard icon appears in the menu bar and the Settings window opens.
3. Click “Allow…” next to “Keyboard control” and enable Raskladushka in
   System Settings → Privacy & Security → Accessibility.
4. Open TextEdit. With the “ABC”/“U.S.” layout active type: ghbdtn followed by Space.
   The word is replaced with “привет” and the layout switches to Russian.
5. Type some text, select it, press Control-Shift-Space: the selection is converted to the other layout.
6. The menu-bar menu has switches for both features, “Launch at login”, and Quit.

WHY THE PERMISSION IS NEEDED
The app’s only function is to replace a mistyped word in the app the user is typing in. To do that it
(a) observes key-down events with a listen-only CGEventTap to know which keys formed the current word, and
(b) posts Backspace and text key events with CGEvent.post to retype the word.
For a selection it posts Command-C, converts the copied text, posts Command-V and restores the clipboard.
The app does not use the Accessibility (AXUIElement) API and does not read or control other apps’ UI.
macOS gates this behind the user’s explicit consent in Privacy & Security. The permission is requested only
after the user clicks “Allow…”, and the Settings window explains the purpose in plain language.
If macOS additionally requires Input Monitoring for the listen-only tap, the app shows a second row
explaining that and asks only then.

PRIVACY
- The app has no network entitlement and makes no network connections. It is sandboxed with no extra entitlements.
- Keystrokes are never written to disk and never leave the process. Only the key codes of the word being
  typed (and up to 60 preceding words, to allow undo and re-conversion) are kept in memory and are discarded on any mouse click,
  arrow key, Return, Tab, app switch or layout change.
- Secure input fields (passwords) are not visible to the app; it also stops processing while
  secure input is active.
- Words are validated with the system spell checker (NSSpellChecker). No dictionaries are bundled.
- Stored settings (UserDefaults): feature switches, the shortcut, the list of excluded apps and the list of
  words the user chose not to correct.

No account or sign-in is required.
