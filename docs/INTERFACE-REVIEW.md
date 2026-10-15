# WAI Remote interface review

12–13 October 2026. Native app on macOS 27.0.1, built with SDK 27; browser viewer inspected in the Codex in-app browser. Candidate 43 contains the principal visual revision. Candidate 45 includes the follow-up native fixes and is installed on the MacBook.

The remote screen is the main content. Its native unified toolbar contains drawing and disconnect actions; drawing adds Undo. The redundant header, persistent input footer, clipboard activity labels and duplicated fullscreen control are removed. A subtitle appears only when the user needs to know about interrupted access, a pause, view-only permission or an individual shared window. Standard AppKit and SwiftUI controls supply the system material and accessibility behavior, rather than simulated translucent cards.

The home window has two actions: connect or share. Saved computers open directly. The sharing flow presents one primary action at a time: open access, copy an invitation, or approve a pending request. Permission instructions appear when needed. Clipboard visibility and the limitation of a shared clipboard during separate-window work remain explicit at the point where access is granted.

| Surface | Inspected states |
| --- | --- |
| Native home | Saved computer, closed/open sharing, missing permissions, pending request, connected guest |
| Native viewer | Active, view only, drawing, interrupted, disconnected, explicit paste failure |
| Settings | Updates and collapsed diagnostics, light/dark |
| Window sizes | Home at 640×600 and 560×480; resizable viewer |
| Browser connection | Desktop dark, 390 px dark, 320 px light/high contrast/reduced transparency; invalid invitation |

Native screenshots were captured through computer use in an isolated fixture using the production views and toolbar. They establish layout and text, not a working connection. The installed build-43 MacBook viewer was separately reconnected to our Mini. Browser screenshots and console inspection were performed on the actual Vite page; no console errors were observed. Local screenshots are in `.runtime/ui43/`; private remote desktop screenshots are not release artwork.

Follow-up review found that a guest allowed to draw but not control could not finish drawing. The client now returns to viewing without requesting control, matching the host's existing permission checks. A regression test failed before the change and passes after it, including rejection of a subsequent pointer event. The browser labels this state “Смотреть” and hides input controls. Repeated reconnect advice was removed; underlying system errors are recorded as diagnostic domain/code instead of exposing untranslated errors in the product. These changes are included in candidate 45; permission-specific drawing still needs final inspection on two Macs.

Candidate 45 returns an application reopen event to the existing connected or connecting viewer, restores a minimized viewer, and opens Home only when no session is active. The explicit “Подключение и доступ…” command remains available in the app and Window menus. Native Hide, Hide Others, Minimize and Settings shortcuts stay on the local Mac. Five window lifecycle regressions and a shortcut regression failed before the changes and pass afterwards.

The installed MacBook build was opened from Finder while connected to Mini, including after the native Hide command and a minimize action. The visible result was the existing “Mac Mini” viewer, not Home. The process remained PID 26235. During the subsequent observation the transport disconnected and was manually reconnected twice; the window checks are not evidence of sustained transport stability. The native menu's “Скрыть WAI Remote” command and Russian AppKit labels were inspected through computer use. Sparkle's post-update localization and the complete OpenRamble-to-Mini insertion remain separate device checks.

References: Apple's [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass) and [system toolbar guidance](https://developer.apple.com/documentation/swiftui/landmarks-refining-the-system-provided-glass-effect-in-toolbars). Browser CSS follows the same hierarchy and system colors without claiming to provide a native macOS material.
