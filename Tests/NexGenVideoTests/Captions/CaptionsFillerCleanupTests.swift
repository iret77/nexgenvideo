import Testing
@testable import NexGenVideo

@MainActor
struct CaptionsFillerCleanupTests {
    @Test func removesTheFillersCommaInsteadOfLeavingLeadingPunctuation() {
        for (input, expected) in [
            ("um, hello", "hello"),
            ("UM, hello!", "hello!"),
            ("Well, um, hello.", "Well, hello."),
            ("Um, uh, you know, hello?", "hello?"),
            ("\n um,\t hello \n", "\n hello \n")
        ] {
            #expect(EditorViewModel.stripFillerWords(input) == expected)
        }
    }

    @Test func preservesRetainedWordsPunctuationAndInternalWhitespace() {
        for (input, expected) in [
            ("Hello,\n\tum, world!", "Hello,\n\tworld!"),
            ("Hello\tum, world.", "Hello\tworld."),
            ("um, First  phrase;\n\tsecond phrase!", "First  phrase;\n\tsecond phrase!"),
            ("\nFirst  phrase;\n\tsecond phrase!\n", "\nFirst  phrase;\n\tsecond phrase!\n"),
            ("number umbrella likeable", "number umbrella likeable")
        ] {
            #expect(EditorViewModel.stripFillerWords(input) == expected)
        }
    }

    @Test func attachesSentencePunctuationToTheRetainedWords() {
        for (input, expected) in [
            ("Okay, um.", "Okay."),
            ("I said um.", "I said."),
            ("I said um uh.", "I said."),
            ("Okay, um, uh!", "Okay!"),
            ("Really\tuh ?", "Really?"),
            ("A list um:", "A list:"),
            ("Wait, um; next.", "Wait; next."),
            ("🙂 I said um.", "🙂 I said."),
            ("Okay, um, , uh.", "Okay.")
        ] {
            #expect(EditorViewModel.stripFillerWords(input) == expected)
        }
    }

    @Test func preservesWhitespaceOutsideTheRemovedFillerSpan() {
        for (input, expected) in [
            (" \nHello um world\n\t ", " \nHello world\n\t "),
            ("\tOkay, um.  \n", "\tOkay.  \n"),
            ("  um, Hello  world! \n", "  Hello  world! \n"),
            ("One\n\tuh, two  words.\n", "One\n\ttwo  words.\n"),
            ("\tNo filler here. \n", "\tNo filler here. \n"),
            ("number umbrella likeable\r\n", "number umbrella likeable\r\n")
        ] {
            #expect(EditorViewModel.stripFillerWords(input) == expected)
        }
    }

    @Test func removesOnlyTheTerminatorsBelongingToAnEmptyFillerSentence() {
        for (input, expected) in [
            ("Okay. Um. Next.", "Okay. Next."),
            ("Um... so", "so"),
            ("Okay. Um... Next.", "Okay. Next."),
            ("Okay. Um?! Next.", "Okay. Next."),
            ("Um?!", ""),
            ("Okay? Um!", "Okay?"),
            ("Um. Hello.", "Hello."),
            ("Hello\num.", "Hello\n"),
            ("Hello\r\num.\r\nNext.", "Hello\r\n\r\nNext."),
            ("Okay um. Next.", "Okay. Next."),
            ("Okay um... Next.", "Okay... Next."),
            ("Okay. um, , uh. Next.", "Okay. Next."),
            ("  Um. Hello.", "  Hello."),
            ("Okay?! Next.\n", "Okay?! Next.\n")
        ] {
            #expect(EditorViewModel.stripFillerWords(input) == expected)
        }
    }
}
