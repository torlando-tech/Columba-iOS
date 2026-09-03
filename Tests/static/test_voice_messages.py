#!/usr/bin/env python3
"""Static contract: iOS voice-message parity (issue #168).

Pins, at the grep level, the load-bearing pieces of the port so a wording
drift, a lost dual-write, a lost retry rehydration, or an unregistered
`Voice/` source file fails CI before it ships:

  1. Every Section-3 picker/panel/bubble string is present in
     `Sources/ColumbaApp/Resources/Localizable.xcstrings` with the EXACT
     Android `strings.xml` value (assert the literal, so a wording drift
     fails). The two parameterized keys use the iOS `%@` form (the plan's
     deterministic-key rule).
  2. The composer mic button exists with a11y id `voice_message_button` and
     the exact label "Record a voice message" in `MessageInputBar.swift`.
  3. The outbound path writes field 7 (FIELD_AUDIO) into BOTH the local
     `LXMessage.fields` (so reload preserves the audio) AND the typed
     `OutboundSendRequest.audioAttachment` (the wire), in
     `MessagingViewModel.swift` (the plan's dual-write guard). The plan's
     "extraFields" slot is the typed `RnsAudio` parameter here, because the
     app's `[UInt8: Data]` extraFields cannot carry the `[mode_int, bytes]`
     shape; the guard checks both write sites.
  4. The retry path rehydrates the audio attachment (plan Section 4.5):
     `retryMessage` passes `failedMessage.audioAttachment` into
     `sendMessage`.
  5. Every new `Sources/ColumbaApp/Voice/*.swift` file is registered in
     `Columba.xcodeproj` (PBXFileReference + the two app targets' Sources
     phases). An unregistered file compiles into nothing (hand-maintained
     pbxproj, no folder sync), so disk presence is not build presence.
"""

import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

XCSTRINGS = ROOT / "Sources/ColumbaApp/Resources/Localizable.xcstrings"
INPUT_BAR = ROOT / "Sources/ColumbaApp/Views/Messaging/MessageInputBar.swift"
VIEW_MODEL = ROOT / "Sources/ColumbaApp/ViewModels/MessagingViewModel.swift"
PBXPROJ = ROOT / "Columba.xcodeproj/project.pbxproj"
VOICE_DIR = ROOT / "Sources/ColumbaApp/Voice"

FIELD_AUDIO = "FIELD_AUDIO"

# Section 3 of the parity plan - EXACT Android values (the two parameterized
# keys in their iOS %@ form).
SECTION3_STRINGS = [
    # Picker (the "exact same text" strings)
    "Select Voice Message Quality",
    "Choose the recording format and bandwidth",
    "Record",
    "Codec2 1200",
    "Very low bandwidth voice",
    "Codec2 2400",
    "Low bandwidth voice",
    "Codec2 3200",
    "Clearer speech at low bandwidth",
    "Medium Quality",
    "Opus 8 kbps mono - good balance of quality and bandwidth",
    "High Quality",
    "Opus 16 kbps mono - higher fidelity audio",
    "Maximum Quality",
    "Opus 32 kbps stereo - best audio, requires more bandwidth",
    # Composer / panel
    "Voice",
    "Record a voice message",
    "Voice message",
    "Start recording",
    "Stop recording",
    "Cancel recording",
    "Remove recording",
    "Microphone permission is required to record a voice message.",
    "Voice messages are not supported on this device.",
    "Recording",
    "Finalizing",
    "Selected voice message",
    "Recording error: %@",
    "Ready to record a voice message",
    "Grant microphone access",
    "Microphone access is disabled. Enable it in app settings.",
    "Open settings",
    "Voice recording is unavailable during a call.",
    # Bubble / player
    "Play voice message",
    "Pause voice message",
    "Loading voice message",
    "Voice message unavailable",
    "Unsupported voice message",
    "%@ of %@",
    "Unable to play voice message",
]


def _catalog() -> dict:
    data = json.loads(XCSTRINGS.read_text(encoding="utf-8"))
    return data["strings"]


class VoiceStringsContract(unittest.TestCase):
    def test_section3_strings_present_with_exact_values(self):
        strings = _catalog()
        missing = [s for s in SECTION3_STRINGS if s not in strings]
        self.assertEqual(
            missing, [],
            f"missing Section-3 strings in Localizable.xcstrings: {missing}",
        )
        for s in SECTION3_STRINGS:
            entry = strings[s]
            en = entry["localizations"]["en"]["stringUnit"]
            self.assertEqual(
                en["value"], s,
                f"catalog value drifted for {s!r}: {en['value']!r}",
            )


class MicButtonContract(unittest.TestCase):
    def test_mic_button_a11y_id_and_label(self):
        src = INPUT_BAR.read_text(encoding="utf-8")
        self.assertIn('accessibilityIdentifier("voice_message_button")', src)
        self.assertIn('String(localized: "Record a voice message")', src)


class DualWriteContract(unittest.TestCase):
    """Field 7 must be written into BOTH the local LXMessage.fields (reload)
    and the typed OutboundSendRequest.audioAttachment (wire)."""

    def setUp(self):
        self.src = VIEW_MODEL.read_text(encoding="utf-8")

    def test_local_fields_field_audio_write(self):
        # `fields[LXMessage.FIELD_AUDIO] = ...` inside sendMessage, sourced
        # from the audio attachment (the [mode_int, bytes] wire shape).
        self.assertRegex(
            self.src,
            r"fields\[LXMessage\.FIELD_AUDIO\]\s*=\s*audioAttachment\.fieldValue",
            "field 7 is not written into the local LXMessage.fields",
        )

    def test_outbound_request_audio_attachment(self):
        # The typed wire param: OutboundSendRequest.audioAttachment is built
        # from the attachment as RnsAudio(mode:, bytes:) at both send sites
        # (direct + relay-retry).
        hits = re.findall(
            r"audioAttachment:\s*audioAttachment\.map\s*\{\s*RnsAudio\(mode:\s*Int\(\$0\.mode\.rawValue\),\s*bytes:\s*\$0\.bytes\)\s*\}",
            self.src,
        )
        self.assertGreaterEqual(
            len(hits), 2,
            "OutboundSendRequest must carry the audioAttachment (RnsAudio) at "
            f"the direct and relay-retry send sites; found {len(hits)}",
        )

    def test_sendoutbound_threads_audio_to_backend(self):
        self.assertRegex(
            self.src,
            r"audioAttachment:\s*request\.audioAttachment",
            "sendOutbound does not thread audioAttachment into sendLxmfMessage",
        )

    def test_optimistic_and_failed_messages_carry_audio(self):
        # Both the optimistic bubble and the failed-row reconstruction must
        # carry the attachment so in-memory retry rehydrates field 7.
        hits = re.findall(
            r"audioAttachment:\s*audioAttachment\s*,\s*\n\s*replyToId:\s*replyToId",
            self.src,
        )
        self.assertGreaterEqual(
            len(hits), 2,
            "the Message(...) optimistic + failed-row constructions must carry "
            f"audioAttachment; found {len(hits)}",
        )


class RetryRehydrationContract(unittest.TestCase):
    def test_retry_passes_audio_attachment(self):
        src = VIEW_MODEL.read_text(encoding="utf-8")
        # retryMessage calls sendMessage twice (staged-recovery path +
        # direct path); both must pass failedMessage.audioAttachment.
        hits = re.findall(
            r"audioAttachment:\s*failedMessage\.audioAttachment", src
        )
        self.assertGreaterEqual(
            len(hits), 2,
            f"retryMessage must rehydrate audioAttachment in both sendMessage "
            f"calls; found {len(hits)}",
        )


class PbxprojRegistrationContract(unittest.TestCase):
    def test_all_voice_files_registered(self):
        files = sorted(p.name for p in VOICE_DIR.glob("*.swift"))
        self.assertGreaterEqual(len(files), 12, f"expected >=12 Voice files, got {len(files)}")
        src = PBXPROJ.read_text(encoding="utf-8")
        problems = []
        for name in files:
            refs = len(re.findall(
                r"isa = PBXFileReference; lastKnownFileType = sourcecode\.swift; path = "
                + re.escape(name) + r";", src))
            builds = len(re.findall(
                r"/\* " + re.escape(name) + r" in Sources \*/ = \{isa = PBXBuildFile", src))
            phases = len(re.findall(
                r"\t\t\t\t[0-9A-Za-z]+ /\* " + re.escape(name) + r" in Sources \*/,$",
                src, re.M))
            if refs != 1:
                problems.append(f"{name}: file references = {refs} (want 1)")
            if builds != 2:
                problems.append(f"{name}: build files = {builds} (want 2, one per app target)")
            if phases != 2:
                problems.append(f"{name}: phase entries = {phases} (want 2, one per app target)")
        self.assertEqual(
            problems, [],
            "unregistered Voice/ files would compile into nothing:\n  "
            + "\n  ".join(problems),
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
