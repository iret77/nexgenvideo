import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class AudioRuntimeWiringTests(unittest.TestCase):
    def test_production_and_fixture_use_shared_runtime_configuration(self):
        consumers = [
            ("Sources/NexGenVideo/Agent/Tools/ToolExecutor+Workflow.swift",
             "configureAudioAnalysis(registry)", 1),
            ("Sources/NexGenVideo/App/ExampleAudioAnalysisSelfTest.swift",
             "AudioAnalysisRuntime.configure(registry)", 1),
            ("Sources/NexGenVideo/Agent/Tools/ToolExecutor.swift",
             "configureAudioAnalysis: @escaping AudioAnalysisConfiguration = { AudioAnalysisRuntime.configure($0) }", 2),
            ("Sources/NexGenVideo/App/MusicvideoHostFlowAcceptance.swift",
             "configureAudioAnalysis: @escaping ToolExecutor.AudioAnalysisConfiguration = { AudioAnalysisRuntime.configure($0) }", 1),
        ]
        direct_registration = (
            "registerAudioDecoder(",
            "registerTranscriber(",
            "registerStemSeparator(",
            "registerBeatDetector(",
            "registerChordRecognizer(",
            "registerMusicUnderstandingAnalyzer(",
        )
        for relative, configure, count in consumers:
            path = ROOT / relative
            text = path.read_text(encoding="utf-8")
            self.assertEqual(text.count(configure), count, path)
            for call in direct_registration:
                self.assertNotIn(call, text, f"{path} bypasses shared audio runtime with {call}")
        executor = (ROOT / "Sources/NexGenVideo/Agent/Tools/ToolExecutor.swift").read_text(encoding="utf-8")
        self.assertEqual(executor.count("self.configureAudioAnalysis = configureAudioAnalysis"), 2)
        workflow = (ROOT / "Sources/NexGenVideo/Agent/Tools/ToolExecutor+Workflow.swift").read_text(encoding="utf-8")
        self.assertNotIn("AudioAnalysisRuntime.configure(", workflow)

    def test_only_acceptance_can_override_audio_configuration(self):
        allowed = {
            "Sources/NexGenVideo/Agent/Tools/ToolExecutor.swift",
            "Sources/NexGenVideo/App/MusicvideoHostFlowAcceptance.swift",
            "Sources/NexGenVideo/App/AnalysisRemeasurementOwnerAcceptance.swift",
        }
        for path in (ROOT / "Sources").rglob("*.swift"):
            text = path.read_text(encoding="utf-8")
            if re.search(r"\bconfigureAudioAnalysis\s*:", text):
                self.assertIn(path.relative_to(ROOT).as_posix(), allowed)


if __name__ == "__main__":
    unittest.main()
