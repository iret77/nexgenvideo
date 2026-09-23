# FCPXML DTD provenance

These are Apple's Final Cut Pro XML DTDs for versions 1.10 through 1.14, with their original
Apple copyright headers intact. Apple publishes 1.10 on its
[Document Type Definition](https://developer.apple.com/documentation/professional-video-applications/document-type-definition)
page; newer schemas ship in Final Cut Pro's `Interchange.framework` resources.

The exact copies here were retrieved from the
[OpenFCPXMLKit archive](https://github.com/TheAcharya/OpenFCPXMLKit/tree/bfc95f8e9631453643762e6b97470ccf164468e2/Sources/OpenFCPXMLKit/Resources/DTDs)
at commit `bfc95f8e9631453643762e6b97470ccf164468e2`. The archived 1.10 declaration was checked
against Apple's published 1.10 text; only formatting differs. Runtime validation checks every
vendored file against its pinned SHA-256 in `FCPXMLInterop.swift` before using it.
