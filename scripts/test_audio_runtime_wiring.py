import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class AudioRuntimeWiringTests(unittest.TestCase):
    def test_production_and_fixture_use_shared_runtime_configuration(self):
        consumers = [
            ROOT / "Sources/NexGenVideo/Agent/Tools/ToolExecutor+Workflow.swift",
            ROOT / "Sources/NexGenVideo/App/ExampleAudioAnalysisSelfTest.swift",
        ]
        direct_registration = (
            "registerAudioDecoder(",
            "registerTranscriber(",
            "registerStemSeparator(",
            "registerBeatDetector(",
            "registerChordRecognizer(",
            "registerMusicUnderstandingAnalyzer(",
        )
        for path in consumers:
            text = path.read_text(encoding="utf-8")
            self.assertEqual(text.count("AudioAnalysisRuntime.configure(registry)"), 1, path)
            for call in direct_registration:
                self.assertNotIn(call, text, f"{path} bypasses shared audio runtime with {call}")


if __name__ == "__main__":
    unittest.main()
