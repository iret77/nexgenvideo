import copy
import hashlib
import io
import json
from pathlib import Path
import unittest
import zipfile

from bpy_source_companions import (
    EVIDENCE_PATH, NOTICE_PREFIX, bind_dependencies, companion_sources,
    load_companions, validate_archived_companions,
)


ROOT = Path(__file__).resolve().parents[1]


class Archive:
    def __init__(self, files):
        self.files = files

    def read(self, name):
        return self.files.get(name)

    def digest(self, name, algorithms):
        data = self.read(name)
        return None if data is None else {key: hashlib.new(key, data).hexdigest() for key in algorithms}

    def size(self, name):
        data = self.read(name)
        return None if data is None else len(data)


class SourceCompanionTests(unittest.TestCase):
    def setUp(self):
        self.lock = json.loads((ROOT / "Runtime/bpy/runtime-lock.json").read_text())
        self.companions = copy.deepcopy(load_companions(self.lock, ROOT))
        item = self.companions[0]
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w") as archive:
            for pin in item["dependency"]["binaryMembers"]:
                data = ("unit fixture for " + pin["path"]).encode()
                pin.update(sha256=hashlib.sha256(data).hexdigest(), size=len(data))
                archive.writestr(pin["path"], data)
        binary = buffer.getvalue()
        item["dependency"].update(sha256=hashlib.sha256(binary).hexdigest(), size=len(binary))
        source = b"unit source archive bytes"
        item["source"].update(sha256=hashlib.sha256(source).hexdigest(), size=len(source))
        metadata = json.dumps({"companions": self.companions}).encode()
        self.lock["sourceCompanions"]["sha256"] = hashlib.sha256(metadata).hexdigest()
        self.files = {EVIDENCE_PATH: metadata, "sources/companion.tar.gz": source, "sources/FLEXBISON.zip": binary}
        for pin in item["notices"]:
            self.files[NOTICE_PREFIX + Path(pin["path"]).name] = (ROOT / pin["path"]).read_bytes()
        row = companion_sources(self.companions)[item["component"]]
        self.manifest = {"sourceCompanionsEvidence": EVIDENCE_PATH, "sources": [
            {"component": item["component"], **row, "archivePath": "sources/companion.tar.gz"},
            {"component": item["dependency"]["component"], "archivePath": "sources/FLEXBISON.zip"}]}

    def check(self):
        validate_archived_companions(Archive(self.files), self.manifest, self.lock, self.companions)

    def test_bound_binary_source_and_original_notices_are_accepted(self):
        self.check()

    def test_source_cannot_be_omitted_changed_or_substituted(self):
        for replacement in (None, b"different source"):
            with self.subTest(replacement=replacement):
                original = self.files.pop("sources/companion.tar.gz")
                if replacement is not None:
                    self.files["sources/companion.tar.gz"] = replacement
                with self.assertRaisesRegex(ValueError, "source archive is absent or changed"):
                    self.check()
                self.files["sources/companion.tar.gz"] = original
        self.manifest["sources"].pop(0)
        with self.assertRaisesRegex(ValueError, "metadata is missing or changed"):
            self.check()

    def test_repacked_binary_cannot_change_its_bound_executable(self):
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w") as archive:
            for pin in self.companions[0]["dependency"]["binaryMembers"]:
                archive.writestr(pin["path"], b"changed executable")
        data = buffer.getvalue()
        self.files["sources/FLEXBISON.zip"] = data
        self.companions[0]["dependency"].update(sha256=hashlib.sha256(data).hexdigest(), size=len(data))
        with self.assertRaisesRegex(ValueError, "binary member changed"):
            self.check()

    def test_companion_must_bind_original_dependency_version_url_and_hash(self):
        item = self.companions[0]["dependency"]
        dependency = {"key": "FLEXBISON", **{key: item[key] for key in ("version", "url", "upstreamHash", "upstreamHashType")}}
        bind_dependencies(self.companions, [dependency])
        for key in ("version", "url", "upstreamHash", "upstreamHashType"):
            changed = dict(dependency, **{key: "changed"})
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, "original release dependency"):
                bind_dependencies(self.companions, [changed])

    def test_missing_or_rewritten_notice_and_metadata_are_rejected(self):
        for path in [EVIDENCE_PATH] + [name for name in self.files if name.startswith(NOTICE_PREFIX)]:
            original = self.files.pop(path)
            with self.subTest(path=path), self.assertRaisesRegex(ValueError, "evidence is absent|notice is absent"):
                self.check()
            self.files[path] = b"rewritten text"
            with self.subTest(path=path), self.assertRaisesRegex(ValueError, "evidence is absent|notice is absent"):
                self.check()
            self.files[path] = original


if __name__ == "__main__":
    unittest.main()
