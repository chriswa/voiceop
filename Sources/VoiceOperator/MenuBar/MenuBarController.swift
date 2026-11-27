import AppKit
import Carbon

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate, NSMenuItemValidation {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let status = NSMenuItem(title: "Idle", action: nil, keyEquivalent: "")
    /// Shown only while some app holds secure event input — see `update(secureInputHolder:)`.
    private let secureInputWarning = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    /// Shown only while Parakeet is failing — see `update(streamHealth:)`.
    private let streamWarning = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    /// Claude Code voice mode: what it is attached to, and a way out. Hidden while detached.
    private let voiceMode = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let voiceModeDetach = NSMenuItem(title: "Turn Off Claude Hands-Free", action: #selector(detachVoiceMode), keyEquivalent: "")
    private let mute = NSMenuItem(title: "Mute Speech", action: #selector(toggleMute), keyEquivalent: "")
    private let tapToToggle = NSMenuItem(title: "Tap to Toggle Dictation", action: #selector(toggleTapToToggle), keyEquivalent: "")
    private let wordOverlay = NSMenuItem(title: "Word Overlay", action: nil, keyEquivalent: "")
    private let muteSystemAudio = NSMenuItem(title: "Mute System Audio While Dictating", action: #selector(toggleMuteSystemAudio), keyEquivalent: "")
    private let typeInsteadOfPaste = NSMenuItem(title: "Type Text Instead of Pasting", action: #selector(toggleTypeInsteadOfPaste), keyEquivalent: "")
    private let retypeClipboard = NSMenuItem(title: "Use Clipboard for Next Re-type", action: #selector(toggleRetypeClipboard), keyEquivalent: "")
    private let keepMicOpen = NSMenuItem(title: "Keep Microphone Always On", action: #selector(toggleKeepMicOpen), keyEquivalent: "")
    private let keepMicOpenForWireless = NSMenuItem(title: "Only When Using AirPods (Bluetooth)", action: #selector(toggleKeepMicOpenForWireless), keyEquivalent: "")
    private let macMicrophoneWithHeadsets = NSMenuItem(title: "Use the Mac's Microphone with AirPods (Bluetooth)", action: #selector(toggleMacMicrophoneWithHeadsets), keyEquivalent: "")
    /// How long hands-free keeps listening without the trigger word once everyone is quiet.
    private let conversationTimeout = NSMenuItem(title: "Hands-Free Listening Timeout", action: nil, keyEquivalent: "")
    private let echoExperiment = NSMenuItem(title: "Echo Cancellation on Speakers (Experimental)", action: #selector(toggleEchoExperiment), keyEquivalent: "")
    private let stt = NSMenuItem(title: "Recent Dictations", action: nil, keyEquivalent: "")
    private let commands = NSMenuItem(title: "Recent Commands", action: nil, keyEquivalent: "")
    private let cleanupToggle = NSMenuItem(title: "Clean Up Transcripts (Fluid-1 Mini)", action: #selector(toggleCleanup), keyEquivalent: "")
    private let cleanupStatus = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let cleanupInstructions = NSMenuItem(title: "Clean-Up Setup Instructions…", action: #selector(showCleanupInstructions), keyEquivalent: "")
    private let cleanupDelete = NSMenuItem(title: "Delete Clean-Up Model (1.6 GB)", action: #selector(deleteCleanupModel), keyEquivalent: "")
    private let playbackSpeed = NSMenuItem(title: "Playback Speed: 1.0×", action: nil, keyEquivalent: "")
    private let fasterSpeech = NSMenuItem(title: "Faster Speech", action: #selector(faster), keyEquivalent: ".")
    private let slowerSpeech = NSMenuItem(title: "Slower Speech", action: #selector(slower), keyEquivalent: ",")
    private let rewindSpeech = NSMenuItem(title: "Rewind 3 Seconds", action: #selector(rewind), keyEquivalent: String(UnicodeScalar(NSLeftArrowFunctionKey)!))
    private let forwardSpeech = NSMenuItem(title: "Skip Ahead 3 Seconds", action: #selector(forward), keyEquivalent: String(UnicodeScalar(NSRightArrowFunctionKey)!))
    var onFasterSpeech: (() -> Void)?
    var onSlowerSpeech: (() -> Void)?
    var onRewindSpeech: (() -> Void)?
    var onForwardSpeech: (() -> Void)?
    private var canAdjustSpeech = false
    private var canRewindSpeech = false
    /// The Text to Speech submenu: the local Kokoro service's status and its
    /// install/restart/uninstall (see `KokoroService`).
    private let textToSpeech = NSMenuItem(title: "Text to Speech", action: nil, keyEquivalent: "")
    private let ttsStatus = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let ttsMemory = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let ttsInstall = NSMenuItem(title: "Install Kokoro…", action: #selector(installKokoro), keyEquivalent: "")
    private let ttsUpdate = NSMenuItem(title: "Update Kokoro", action: #selector(updateKokoro), keyEquivalent: "")
    private let ttsRestart = NSMenuItem(title: "Restart Kokoro", action: #selector(restartKokoro), keyEquivalent: "")
    private let ttsUninstall = NSMenuItem(title: "Uninstall Kokoro…", action: #selector(uninstallKokoro), keyEquivalent: "")
    private let ttsLog = NSMenuItem(title: "Show Kokoro Log", action: #selector(showKokoroLog), keyEquivalent: "")
    var ttsMenuState: (() -> TTSMenuState)?
    /// The menu opened: time to ask the local server how it is.
    var onTTSMenuOpened: (() -> Void)?
    var onInstallKokoro: (() -> Void)?
    var onCancelKokoroInstall: (() -> Void)?
    var onUpdateKokoro: (() -> Void)?
    var onRestartKokoro: (() -> Void)?
    var onUninstallKokoro: (() -> Void)?
    var onShowKokoroLog: (() -> Void)?
    private var ttsActionsEnabled = true
    var onMuteSpeech: ((Bool) -> Void)?
    var onSpeakClipboard: (() -> Void)?
    var onSummarizeClipboard: (() -> Void)?
    var onRestart: (() -> Void)?
    var launchAtLoginState: (() -> Bool)?
    var onToggleLaunchAtLogin: (() -> Bool)?
    /// Reads and flips the tap-to-toggle trigger preference. The flip closure
    /// returns the state afterwards so the checkmark can follow it.
    var tapToToggleState: (() -> Bool)?
    var onToggleTapToToggle: (() -> Bool)?
    /// Reads and sets the word overlay's placement — from its submenu, or the
    /// next one in the cycle on ⌘⌃/.
    var wordOverlayPlacement: (() -> OverlayPlacement)?
    var onSetWordOverlay: ((OverlayPlacement) -> Void)?
    /// Reads and flips whether a transcript is typed a character at a time rather
    /// than pasted. Same shape as the other preference toggles: the flip closure
    /// returns the state afterwards so the checkmark follows it.
    var typeInsteadOfPasteState: (() -> Bool)?
    var onToggleTypeInsteadOfPaste: (() -> Bool)?
    /// Reads and flips the one-shot that makes the next ⌘⌃⇧V type the clipboard
    /// instead of the last transcript. The re-type clears it once it fires.
    var retypeClipboardState: (() -> Bool)?
    var onToggleRetypeClipboard: (() -> Bool)?
    /// Reads and flips whether a dictation hardware-mutes the system output for
    /// its duration. Same shape as the other preference toggles: the flip closure
    /// returns the state afterwards so the checkmark follows it.
    var muteSystemAudioState: (() -> Bool)?
    var onToggleMuteSystemAudio: (() -> Bool)?
    /// Reads and flips whether the microphone is held open between dictations.
    /// `keepMicOpenState` reports the state the recorder is *actually* in, which
    /// while the AirPods rule is on is the rule's answer rather than the manual
    /// one — the checkmark has to follow the hardware, not the stored choice.
    var keepMicOpenState: (() -> Bool)?
    var onToggleKeepMicOpen: (() -> Bool)?
    var keepMicOpenForWirelessState: (() -> Bool)?
    /// Reads and flips recording from the Mac's own microphone while a headset plays.
    var macMicrophoneWithHeadsetsState: (() -> Bool)?
    var onToggleMacMicrophoneWithHeadsets: (() -> Bool)?
    var onToggleKeepMicOpenForWireless: (() -> Bool)?
    /// Reads and flips hands-free's echo experiment (`EchoExperiment`). Off is
    /// how hands-free has always behaved; the flip returns the state afterwards.
    var echoExperimentState: (() -> Bool)?
    /// Reads and sets the conversation window's timeout (`HandsFreePreferences`).
    var conversationTimeoutState: (() -> ConversationTimeout)?
    var onSetConversationTimeout: ((ConversationTimeout) -> Void)?
    var onToggleEchoExperiment: (() -> Bool)?
    var sttHistoryProvider: (() -> [STTHistoryEntry])?
    var commandHistoryProvider: (() -> [CommandHistoryEntry])?
    var onRetrySTT: ((UUID) -> Void)?
    var onCopySTT: ((UUID) -> Void)?
    var onRetryCommand: ((UUID) -> Void)?
    var onCopyCommand: ((UUID) -> Void)?
    var onCopyRawSTT: ((UUID) -> Void)?
    var onCopyRawCommand: ((UUID) -> Void)?
    /// The on-device clean-up pass: its checkbox, status line and delete item.
    var cleanupMenuState: (() -> CleanupMenuState)?
    var onToggleCleanup: (() -> Void)?
    var onDeleteCleanupModel: (() -> Void)?
    var onShowCleanupInstructions: (() -> Void)?
    /// The menu opened (true) or closed (false). Its items carry the same ⌘⌃
    /// shortcuts the global tap watches for, and AppKit fires them itself while
    /// the menu is open, so the tap must stand down for exactly that window.
    var onMenuOpenChanged: ((Bool) -> Void)?
    var onDetachVoiceMode: (() -> Void)?
    private var muted = false
    private var currentStatus: OperatorStatus = .idle
    private var currentStyle: TranscriptStyle = .normal
    private var streamHealth: StreamHealth = .unverified
    private var handsFree: HandsFreeLook?

    override init() {
        super.init(); menu.delegate = self; status.isEnabled = false; menu.addItem(status)
        secureInputWarning.isEnabled = false; secureInputWarning.isHidden = true
        menu.addItem(secureInputWarning)
        streamWarning.isEnabled = false; streamWarning.isHidden = true
        menu.addItem(streamWarning)
        voiceMode.isEnabled = false; voiceMode.isHidden = true; menu.addItem(voiceMode)
        voiceModeDetach.target = self; voiceModeDetach.indentationLevel = 1; voiceModeDetach.isHidden = true
        menu.addItem(voiceModeDetach)
        mute.keyEquivalent = "b"; mute.keyEquivalentModifierMask = [.command, .control]
        mute.target = self; menu.addItem(mute)
        menu.addItem(.separator())
        stt.submenu = NSMenu(); commands.submenu = NSMenu(); menu.addItem(stt); menu.addItem(commands)
        cleanupToggle.target = self; menu.addItem(cleanupToggle)
        cleanupStatus.isEnabled = false; cleanupStatus.indentationLevel = 1; menu.addItem(cleanupStatus)
        for item in [cleanupInstructions, cleanupDelete] {
            item.target = self; item.indentationLevel = 1; menu.addItem(item)
        }
        for item in [cleanupStatus, cleanupInstructions, cleanupDelete] { item.isHidden = true }
        menu.addItem(.separator())
        // Real key equivalents, so each item shows its shortcut right-aligned the
        // way every other menu does. While the menu is open AppKit fires these
        // itself, so the tap's copy of the same chord is muted for that window
        // (see `onMenuOpenChanged` and `HotkeyMonitor.chordsSuppressed`) — without
        // that, opening the menu and pressing ⌘⌃S would speak the clipboard twice.
        let speak = NSMenuItem(title: "Speak Clipboard", action: #selector(speakClipboard), keyEquivalent: "s")
        speak.keyEquivalentModifierMask = [.command, .control]
        speak.target = self; menu.addItem(speak)
        let summarize = NSMenuItem(title: "Summarize Clipboard", action: #selector(summarizeClipboard), keyEquivalent: "a")
        summarize.keyEquivalentModifierMask = [.command, .control]
        summarize.target = self; menu.addItem(summarize)
        menu.addItem(.separator())
        playbackSpeed.isEnabled = false; menu.addItem(playbackSpeed)
        for item in [fasterSpeech, slowerSpeech, rewindSpeech, forwardSpeech] {
            item.target = self
            item.keyEquivalentModifierMask = [.command, .control]
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let tts = NSMenu()
        ttsStatus.isEnabled = false; ttsMemory.isEnabled = false
        tts.addItem(ttsStatus); tts.addItem(ttsMemory); tts.addItem(.separator())
        for item in [ttsInstall, ttsUpdate, ttsRestart, ttsUninstall, ttsLog] { item.target = self; tts.addItem(item) }
        textToSpeech.submenu = tts; menu.addItem(textToSpeech)
        menu.addItem(.separator())
        tapToToggle.target = self; menu.addItem(tapToToggle)
        // One radio item per placement, then the cycle with its chord shown.
        let placements = NSMenu()
        for placement in OverlayPlacement.allCases {
            let item = NSMenuItem(title: placement.title, action: #selector(chooseWordOverlay(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = placement.rawValue; placements.addItem(item)
        }
        placements.addItem(.separator())
        let cycle = NSMenuItem(title: "Next Placement", action: #selector(cycleWordOverlayItem), keyEquivalent: "/")
        cycle.keyEquivalentModifierMask = [.command, .control]
        cycle.target = self; placements.addItem(cycle)
        wordOverlay.submenu = placements; menu.addItem(wordOverlay)
        muteSystemAudio.target = self; menu.addItem(muteSystemAudio)
        typeInsteadOfPaste.target = self; menu.addItem(typeInsteadOfPaste)
        // Reminders only: disabled, with no action, so they show their shortcut but
        // never fire. The tap handles both chords whatever the checkbox says.
        for (title, modifiers) in [("Re-paste Last (Clipboard)", [.command, .control]),
                                   ("Re-type Last (Keystrokes)", [.command, .control, .shift])] as [(String, NSEvent.ModifierFlags)] {
            let hint = NSMenuItem(title: title, action: nil, keyEquivalent: "v")
            hint.keyEquivalentModifierMask = modifiers
            hint.isEnabled = false; hint.indentationLevel = 1; menu.addItem(hint)
        }
        retypeClipboard.indentationLevel = 2
        retypeClipboard.target = self; menu.addItem(retypeClipboard)
        keepMicOpen.target = self; menu.addItem(keepMicOpen)
        // Indented under the checkbox it takes over, the way System Settings nests
        // a rule under the switch it drives.
        keepMicOpenForWireless.indentationLevel = 1
        keepMicOpenForWireless.target = self; menu.addItem(keepMicOpenForWireless)
        macMicrophoneWithHeadsets.toolTip = "Listen on AirPods or another Bluetooth headset, but record from the Mac's "
            + "own microphone: the headset never switches into its call mode, so the music never drops."
        macMicrophoneWithHeadsets.target = self; menu.addItem(macMicrophoneWithHeadsets)
        let timeouts = NSMenu()
        for timeout in ConversationTimeout.allCases {
            let item = NSMenuItem(title: timeout.title, action: #selector(chooseConversationTimeout(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = timeout.rawValue; timeouts.addItem(item)
        }
        conversationTimeout.toolTip = "After the trigger word or a reply, hands-free takes speech without the trigger word "
            + "until both sides have been quiet this long."
        conversationTimeout.submenu = timeouts; menu.addItem(conversationTimeout)
        echoExperiment.toolTip = "Off: hands-free does not listen while our voice plays on a speaker the microphone hears. "
            + "On: it listens through echo cancellation, and only \"Control\" cuts in. Headsets are never affected."
        echoExperiment.target = self; menu.addItem(echoExperiment)
        let copyPath = NSMenuItem(title: "Copy Log Path", action: #selector(copyLogPath), keyEquivalent: "")
        copyPath.target = self; menu.addItem(copyPath)
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self; menu.addItem(login)
        // Which build is running, right next to the item that restarts it: the
        // version changing is how you know the restart picked up the last build
        // (see BuildInfo).
        let version = NSMenuItem(title: BuildInfo.menuLabel, action: nil, keyEquivalent: "")
        version.isEnabled = false; menu.addItem(version)
        let restart = NSMenuItem(title: "Restart Voice Operator", action: #selector(restart), keyEquivalent: "")
        restart.target = self; menu.addItem(restart)
        menu.addItem(NSMenuItem(title: "Quit Voice Operator", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        statusItem.menu = menu; update(status: .idle)
    }
    func update(status state: OperatorStatus) {
        currentStatus = state
        status.title = state.accessibilityLabel.replacingOccurrences(of: "Voice Operator — ", with: "")
        refreshIcon()
    }
    func updatePlayback(rate: Float, canAdjust: Bool, canRewind: Bool) {
        playbackSpeed.title = String(format: "Playback Speed: %.1f×", rate)
        canAdjustSpeech = canAdjust
        canRewindSpeech = canRewind
        fasterSpeech.isEnabled = canAdjust && rate < 5
        slowerSpeech.isEnabled = canAdjust && rate > 0.5
        rewindSpeech.isEnabled = canRewind
        forwardSpeech.isEnabled = canAdjust
    }
    /// The transcript style of the dictation being recorded, shown as badges on
    /// the icon. Only visible while capturing, which is where the key that cycles
    /// it does anything (see `AudioArbiter.cycleTranscriptStyle`).
    func update(style: TranscriptStyle) {
        guard style != currentStyle else { return }
        currentStyle = style
        refreshIcon()
    }
    /// Name the app holding secure event input, or nil when it is off. While it is
    /// on the ⌘⌃ shortcuts get no key events at all (see `SecureInput`), so the
    /// menu says which app to turn it off in rather than leaving them dead and
    /// unexplained. Dictation is unaffected, so the rest of the menu stays normal.
    func update(secureInputHolder: String?) {
        guard let holder = secureInputHolder else { secureInputWarning.isHidden = true; return }
        secureInputWarning.title = "⚠︎ Secure Keyboard Entry is on in \(holder) — ⌘⌃ shortcuts disabled"
        secureInputWarning.isHidden = false
    }
    /// Whether dictation is working. While it is failing the menu carries a
    /// warning line naming the reason, and the icon wears an amber badge in
    /// every state — including idle, so it is seen *before* the next dictation.
    func update(streamHealth health: StreamHealth) {
        guard health != streamHealth else { return }
        streamHealth = health
        if let warning = health.menuWarning {
            streamWarning.title = warning; streamWarning.isHidden = false
        } else {
            streamWarning.isHidden = true
        }
        refreshIcon()
    }
    /// Claude Code voice mode attached (its line), or not (nil).
    func update(voiceMode title: String?) {
        voiceMode.title = title ?? ""
        voiceMode.isHidden = title == nil
        voiceModeDetach.isHidden = title == nil
    }
    @objc private func detachVoiceMode() { onDetachVoiceMode?() }
    /// Hands-free on the Mac's microphone, or nil while it is off: the icon's
    /// colour whenever the status itself has none.
    func update(handsFree look: HandsFreeLook?) {
        guard look != handsFree else { return }
        handsFree = look
        refreshIcon()
    }
    func refreshHistory() { }
    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        onMenuOpenChanged?(true)
        tapToToggle.state = (tapToToggleState?() ?? false) ? .on : .off
        let current = (wordOverlayPlacement?() ?? .bottom).rawValue
        for item in wordOverlay.submenu!.items where item.representedObject != nil {
            item.state = item.representedObject as? String == current ? .on : .off
        }
        muteSystemAudio.state = (muteSystemAudioState?() ?? true) ? .on : .off
        typeInsteadOfPaste.state = (typeInsteadOfPasteState?() ?? false) ? .on : .off
        retypeClipboard.state = (retypeClipboardState?() ?? false) ? .on : .off
        keepMicOpen.state = (keepMicOpenState?() ?? false) ? .on : .off
        keepMicOpenForWireless.state = (keepMicOpenForWirelessState?() ?? false) ? .on : .off
        macMicrophoneWithHeadsets.state = (macMicrophoneWithHeadsetsState?() ?? false) ? .on : .off
        echoExperiment.state = (echoExperimentState?() ?? false) ? .on : .off
        let timeout = (conversationTimeoutState?() ?? .s15).rawValue
        for item in conversationTimeout.submenu!.items {
            item.state = item.representedObject as? Int == timeout ? .on : .off
        }
        rebuild(stt.submenu!, entries: sttHistoryProvider?() ?? [], retry: onRetrySTT, copy: onCopySTT,
                copyRaw: onCopyRawSTT)
        rebuild(commands.submenu!, entries: commandHistoryProvider?() ?? [], retry: onRetryCommand, copy: onCopyCommand,
                copyRaw: onCopyRawCommand)
        refreshCleanupMenu()
        refreshTTSMenu()
        onTTSMenuOpened?()
    }
    /// Re-render the Text to Speech submenu. Safe while the menu is open: the
    /// health probe started on open lands here and fills in the memory line.
    func refreshTTSMenu() {
        guard let state = ttsMenuState?() else { return }
        textToSpeech.title = state.isWarning ? "⚠︎ Text to Speech" : "Text to Speech"
        ttsStatus.title = state.status
        ttsMemory.title = state.memory ?? ""
        ttsMemory.isHidden = state.memory == nil
        ttsInstall.isHidden = state.install == .hidden
        ttsInstall.title = state.install == .cancel ? "Cancel Install" : "Install Kokoro…"
        ttsUpdate.isHidden = !state.showUpdate
        ttsRestart.isHidden = !state.showRestart
        ttsUninstall.isHidden = !state.showUninstall
        ttsActionsEnabled = state.actionsEnabled
    }
    func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        onMenuOpenChanged?(false)
    }
    private func rebuild<T>(_ menu: NSMenu, entries: [T], retry: ((UUID) -> Void)?, copy: ((UUID) -> Void)?,
                            copyRaw: ((UUID) -> Void)?) {
        menu.removeAllItems()
        if entries.isEmpty { menu.addItem(NSMenuItem(title: "None yet", action: nil, keyEquivalent: "")); return }
        for e in entries.prefix(10) {
            let id: UUID; let title: String; let raw: String?
            if let x = e as? STTHistoryEntry { id = x.id; title = x.menuTitle; raw = x.raw }
            else if let x = e as? CommandHistoryEntry { id = x.id; title = x.menuTitle; raw = x.raw }
            else { continue }
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let sub = NSMenu(); let retryItem = NSMenuItem(title: "Retry", action: #selector(runRetry(_:)), keyEquivalent: "")
            retryItem.target = self; retryItem.representedObject = Action(id: id, handler: retry); sub.addItem(retryItem)
            let copyItem = NSMenuItem(title: "Copy transcription", action: #selector(runCopy(_:)), keyEquivalent: "")
            copyItem.target = self; copyItem.representedObject = Action(id: id, handler: copy); sub.addItem(copyItem)
            if raw != nil {
                let copyRawItem = NSMenuItem(title: "Copy raw transcription (before clean-up)", action: #selector(runCopy(_:)), keyEquivalent: "")
                copyRawItem.target = self; copyRawItem.representedObject = Action(id: id, handler: copyRaw)
                sub.addItem(copyRawItem)
            }
            item.submenu = sub; menu.addItem(item)
        }
    }
    /// The clean-up checkbox and the lines under it, re-read whenever the menu
    /// opens and whenever the server's state changes (it may be open).
    func refreshCleanupMenu() {
        guard let state = cleanupMenuState?() else { return }
        cleanupToggle.state = state.enabled ? .on : .off
        cleanupStatus.title = state.status ?? ""
        cleanupStatus.isHidden = state.status == nil
        cleanupInstructions.isHidden = !state.showInstructions
        cleanupDelete.isHidden = !state.showDelete
    }
    @objc private func toggleCleanup() { onToggleCleanup?() }
    @objc private func deleteCleanupModel() { onDeleteCleanupModel?() }
    @objc private func showCleanupInstructions() { onShowCleanupInstructions?() }
    private final class Action: NSObject { let id: UUID; let handler: ((UUID) -> Void)?; init(id: UUID, handler: ((UUID) -> Void)?) { self.id = id; self.handler = handler } }
    @objc private func runRetry(_ sender: NSMenuItem) { (sender.representedObject as? Action)?.handler?((sender.representedObject as! Action).id) }
    @objc private func runCopy(_ sender: NSMenuItem) { (sender.representedObject as? Action)?.handler?((sender.representedObject as! Action).id) }
    @objc private func toggleMute() { muted.toggle(); mute.title = muted ? "Unmute Speech" : "Mute Speech"; refreshIcon(); onMuteSpeech?(muted) }
    /// Toggle narration mute from outside the menu — the global ⌘⌃B chord. Goes
    /// through the menu item's own action so the title, the icon and the mute
    /// listener stay in step however it was triggered.
    func toggleNarrationMute() { toggleMute() }
    @objc private func speakClipboard() { onSpeakClipboard?() }
    @objc private func faster() { onFasterSpeech?() }
    @objc private func slower() { onSlowerSpeech?() }
    @objc private func rewind() { onRewindSpeech?() }
    @objc private func forward() { onForwardSpeech?() }
    @objc private func summarizeClipboard() { onSummarizeClipboard?() }
    @objc private func restart() { onRestart?() }
    @objc private func installKokoro() {
        if ttsInstall.title == "Cancel Install" { onCancelKokoroInstall?() } else { onInstallKokoro?() }
    }
    @objc private func updateKokoro() { onUpdateKokoro?() }
    @objc private func restartKokoro() { onRestartKokoro?() }
    @objc private func uninstallKokoro() { onUninstallKokoro?() }
    @objc private func showKokoroLog() { onShowKokoroLog?() }
    @objc private func toggleLogin() { _ = onToggleLaunchAtLogin?() }
    @objc private func toggleTapToToggle() { tapToToggle.state = (onToggleTapToToggle?() ?? false) ? .on : .off }
    @objc private func cycleWordOverlayItem() { cycleWordOverlay() }
    /// Advance the overlay placement, from the submenu's "Next Placement" or the
    /// global ⌘⌃/ chord. The checkmarks are re-read when the menu next opens.
    func cycleWordOverlay() {
        onSetWordOverlay?((wordOverlayPlacement?() ?? .bottom).next)
    }
    @objc private func chooseWordOverlay(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let placement = OverlayPlacement(rawValue: raw) else { return }
        onSetWordOverlay?(placement)
    }
    @objc private func toggleMuteSystemAudio() { muteSystemAudio.state = (onToggleMuteSystemAudio?() ?? true) ? .on : .off }
    @objc private func toggleTypeInsteadOfPaste() { typeInsteadOfPaste.state = (onToggleTypeInsteadOfPaste?() ?? false) ? .on : .off }
    @objc private func toggleRetypeClipboard() { retypeClipboard.state = (onToggleRetypeClipboard?() ?? false) ? .on : .off }
    @objc private func toggleKeepMicOpen() { keepMicOpen.state = (onToggleKeepMicOpen?() ?? false) ? .on : .off }
    @objc private func toggleEchoExperiment() {
        echoExperiment.state = (onToggleEchoExperiment?() ?? false) ? .on : .off
    }
    @objc private func chooseConversationTimeout(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? Int, let timeout = ConversationTimeout(rawValue: raw) else { return }
        onSetConversationTimeout?(timeout)
    }

    @objc private func toggleMacMicrophoneWithHeadsets() {
        macMicrophoneWithHeadsets.state = (onToggleMacMicrophoneWithHeadsets?() ?? false) ? .on : .off
    }

    @objc private func toggleKeepMicOpenForWireless() {
        keepMicOpenForWireless.state = (onToggleKeepMicOpenForWireless?() ?? false) ? .on : .off
        // The rule just took the manual checkbox over (or handed it back), so the
        // tick above has to be re-read rather than left where the rule found it.
        keepMicOpen.state = (keepMicOpenState?() ?? false) ? .on : .off
    }

    /// AppKit's automatic validation, which matters for exactly one item: while
    /// the AirPods rule is on, the manual "Keep Microphone Always On" checkbox is
    /// no longer what decides, so it is shown greyed at whatever the rule has
    /// currently made true. Everything else validates as it always did.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item === fasterSpeech || item === slowerSpeech { return canAdjustSpeech && item.isEnabled }
        if item === rewindSpeech { return canRewindSpeech }
        if item === forwardSpeech { return canAdjustSpeech }
        // One Kokoro action at a time; Cancel Install stays live while one runs.
        if item === ttsUpdate || item === ttsRestart || item === ttsUninstall { return ttsActionsEnabled }
        if item === ttsInstall { return ttsActionsEnabled || item.title == "Cancel Install" }
        guard item === keepMicOpen else { return true }
        return !(keepMicOpenForWirelessState?() ?? false)
    }
    @objc private func copyLogPath() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(Log.fileURL.path, forType: .string) }

    private func refreshIcon() {
        guard let button = statusItem.button else { return }
        button.image = Self.icon(status: currentStatus, muted: muted, style: currentStyle,
                                 degraded: streamHealth.isDegraded, handsFree: handsFree)
        let showsHandsFree = currentStatus.tint == nil && handsFree != nil
        button.image?.accessibilityDescription = currentStatus.accessibilityLabel
            + (showsHandsFree ? " — \(handsFree?.accessibilityLabel ?? "")" : "")
            + (Self.badgesVisible(status: currentStatus, style: currentStyle)
               ? " (\(currentStyle.accessibilityLabel))" : "")
            + (streamHealth.isDegraded ? " — dictation is failing" : "")
    }

    /// Preserve the original megaphone and its red/magenta/yellow/cyan/green
    /// status palette. Idle remains a template image so macOS adapts it to the
    /// menu-bar appearance. A discarded dictation swaps the megaphone for a
    /// trash can.
    ///
    /// Hands-free (`handsFree`) colours the icon only while the status has no
    /// colour of its own — so speech (green) and a Fn dictation win over it.
    /// Listening, it is a rainbow: vivid in the conversation window, washed out
    /// while the trigger word is needed.
    static func icon(status: OperatorStatus, muted: Bool, style: TranscriptStyle = .normal,
                     degraded: Bool = false, handsFree: HandsFreeLook? = nil) -> NSImage {
        let showsDiscard = style.discard && (status == .listening || status == .commandListening)
        let name = showsDiscard ? "trash.fill" : "megaphone.fill"
        let base = NSImage(systemSymbolName: name, accessibilityDescription: "Voice Operator")
        let symbol = base?.withSymbolConfiguration(.init(pointSize: showsDiscard ? 18 : 15,
                                                          weight: showsDiscard ? .bold : .regular))
            ?? NSImage(size: NSSize(width: 18, height: 18))
        // A degraded icon is badged in colour, so like the muted ring it cannot
        // be a template image even at idle.
        let look = status.tint == nil ? handsFree : nil
        let tint = status.tint ?? look?.tint
        let rainbow = look != nil && tint == nil ? rainbowGradient(pastel: look == .waiting) : nil
        let template = tint == nil && rainbow == nil && !muted && !degraded
        let color = tint ?? .labelColor
        let badges = badgesVisible(status: status, style: style)
        let image = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            if let rainbow {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current?.compositingOperation = .sourceAtop
                rainbow.draw(in: rect, angle: 0)
                NSGraphicsContext.restoreGraphicsState()
            } else if !template { color.set(); rect.fill(using: .sourceAtop) }
            if muted {
                color.setStroke()
                let path = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)); path.lineWidth = 1.5; path.stroke()
                let slash = NSBezierPath(); slash.move(to: NSPoint(x: rect.minX + 2, y: rect.maxY - 2)); slash.line(to: NSPoint(x: rect.maxX - 2, y: rect.minY + 2)); slash.lineWidth = 1.5; slash.stroke()
            }
            // After the tint fill, or `sourceAtop` would repaint the badges in the
            // status colour and they would vanish into the silhouette.
            if badges && !showsDiscard { drawStyleBadges(style, in: rect) }
            if degraded { drawDegradedBadge(in: rect) }
            return true
        }
        // A badged icon is no longer monochrome, so it must not be a template
        // image even when the status itself would have been.
        image.isTemplate = template && !badges
        return image
    }

    /// Red to violet, left to right; `pastel` washed 42% of the way to white — any further and it vanishes on a light menu bar.
    private nonisolated static func rainbowGradient(pastel: Bool) -> NSGradient? {
        // Full: saturated primaries in Display P3, past what sRGB can show, on the screens that can.
        let hues: [(CGFloat, CGFloat, CGFloat)] = [(1, 0, 0.1), (1, 0.45, 0), (1, 0.9, 0), (0, 0.9, 0.2),
                                                   (0, 0.4, 1), (0.6, 0, 1)]
        guard pastel else {
            return NSGradient(colors: hues.map { r, g, b in NSColor(displayP3Red: r, green: g, blue: b, alpha: 1) })
        }
        let wash: CGFloat = 0.42
        return NSGradient(colors: hues.map { r, g, b in
            NSColor(srgbRed: r + (1 - r) * wash, green: g + (1 - g) * wash, blue: b + (1 - b) * wash, alpha: 1)
        })
    }

    /// The badges describe the dictation being recorded, so they show only while
    /// it is — the same instants the icon is red (or magenta for a command).
    private static func badgesVisible(status: OperatorStatus, style: TranscriptStyle) -> Bool {
        !style.isNormal && (status == .listening || status == .commandListening)
    }

    /// Amber, not another red: it has to sit on a red silhouette and still be
    /// picked out, without competing with "recording" for attention. Computed
    /// rather than stored so it stays outside the main actor — it is read from
    /// inside `NSImage`'s drawing handler.
    private nonisolated static var badgeColor: NSColor {
        NSColor(srgbRed: 1.0, green: 0.62, blue: 0.11, alpha: 1)
    }

    /// The slow-path mark: a filled amber dot in the top-right corner, ringed in
    /// the label colour (black on a light menu bar, white on a dark one) so it
    /// separates from the silhouette whatever the status tint — amber on the
    /// yellow "transcribing" icon has almost no contrast on its own. Top-right
    /// keeps it clear of the style badges, which own the bottom edge, and of the
    /// mute slash, which runs corner to corner.
    private nonisolated static func drawDegradedBadge(in rect: NSRect) {
        let diameter = round(rect.height * 0.38)
        // Inset by the ring width so the ring is not clipped at the image edge.
        let dot = NSRect(x: rect.maxX - diameter - 1, y: rect.maxY - diameter - 1, width: diameter, height: diameter)
        NSColor.labelColor.setFill(); NSBezierPath(ovalIn: dot.insetBy(dx: -1, dy: -1)).fill()
        badgeColor.setFill(); NSBezierPath(ovalIn: dot).fill()
    }

    /// Draw the style flags as large, transparent bottom-edge badges: `a` for a
    /// lowercased first word always occupies the left half, and a struck-through
    /// comma for stripped end punctuation always occupies the right half. This
    /// makes the positions stable as flags are enabled and disabled.
    private nonisolated static func drawStyleBadges(_ style: TranscriptStyle, in rect: NSRect) {
        let badges: [(character: String, slot: Int)] = [
            style.lowercaseFirst ? ("a", 0) : nil,
            style.trimTrailingPunctuation ? ("trimPunctuation", 1) : nil,
        ].compactMap { $0 }
        guard !badges.isEmpty else { return }

        let badgeHeight = round(rect.height * 0.5)
        let badgeWidth = rect.width / 2
        let baselineLift = round(rect.height * 0.17)
        // Use a heavy monospaced face so `a` and `x` both use their full
        // half-width slots instead of leaving a conspicuous gap between them.
        // The font's visible ink is smaller than its point size, so it is allowed
        // to be taller than half the icon for legibility at menu-bar scale.
        let font = NSFont.monospacedSystemFont(ofSize: round(rect.height * 0.9), weight: .heavy)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: badgeColor,
            // A negative stroke width fills and strokes the glyph. The heavy
            // outline makes the transparent badge readable over either the
            // coloured megaphone or the menu-bar background.
            .strokeColor: NSColor.black.withAlphaComponent(0.9),
            .strokeWidth: -5.0,
        ]

        for badge in badges {
            let badgeRect = NSRect(x: rect.minX + CGFloat(badge.slot) * badgeWidth,
                                   y: rect.minY,
                                   width: badgeWidth,
                                   height: badgeHeight)
            if badge.character == "trimPunctuation" {
                drawTrimPunctuationBadge(in: badgeRect, verticallyCenteredAt: badgeRect.midY + baselineLift)
                continue
            }
            let glyph = NSAttributedString(string: badge.character, attributes: attrs)
            let size = glyph.size()
            glyph.draw(at: NSPoint(x: badgeRect.midX - size.width / 2,
                                   y: badgeRect.midY - size.height / 2 + baselineLift))
        }
    }

    /// The terminal-punctuation marker is a purpose-drawn SVG rather than text:
    /// a thick comma struck through with an X stays legible at menu-bar scale.
    private nonisolated static func drawTrimPunctuationBadge(in rect: NSRect, verticallyCenteredAt y: CGFloat) {
        // AppKit does not reliably decode SVGs into `NSImage` outside a full
        // asset catalogue, so the checked-in PNG is the faithful raster export
        // of `Resources/trim-punctuation.svg` used at runtime.
        let sourceAsset = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/trim-punctuation.png")
        let workingDirectoryAsset = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/trim-punctuation.png")
        let candidates = [
            Bundle.main.url(forResource: "trim-punctuation", withExtension: "png"),
            sourceAsset,
            workingDirectoryAsset,
        ].compactMap { $0 }
        guard let image = candidates.lazy.compactMap(NSImage.init(contentsOf:)).first else { return }
        let frame = NSRect(x: rect.minX,
                           y: y - rect.height * 0.72,
                           width: rect.width,
                           height: rect.height * 1.44)
        image.draw(in: frame)
    }
}
