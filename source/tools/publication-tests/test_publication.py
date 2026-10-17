# SPDX-License-Identifier: GPL-3.0-or-later
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

TOOLS = Path(__file__).resolve().parents[1]


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, TOOLS / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


publication = load("publication", "publication.py")
initialization = load("initialization", "initialize-data.py")


class PublicationTests(unittest.TestCase):
    def fixture(self, root):
        (root / "docs").mkdir()
        (root / "README.md").write_text("Public project\n")
        (root / publication.MANIFEST).write_text(json.dumps({"files": ["README.md", publication.MANIFEST]}))

    def test_export_ignores_private_history_and_unlisted_data(self):
        with tempfile.TemporaryDirectory() as parent:
            root = Path(parent).resolve() / "source"; root.mkdir(); self.fixture(root)
            (root / ".git").mkdir(); (root / ".git/private").write_text("private history")
            (root / "profiles").mkdir(); (root / "profiles/local.json").write_text("private record")
            target = Path(parent).resolve() / "public"
            publication.export(root, target)
            self.assertEqual(set(p.relative_to(target).as_posix() for p in target.rglob("*") if p.is_file()),
                             {"README.md", publication.MANIFEST})
            with self.assertRaises(ValueError): publication.export(root, target)

    def test_export_rejects_symlinked_input_and_manifest_traversal(self):
        with tempfile.TemporaryDirectory() as parent:
            root = Path(parent).resolve() / "source"; root.mkdir(); self.fixture(root)
            (root / "README.md").unlink()
            outside = Path(parent).resolve() / "private"; outside.write_text("private")
            (root / "README.md").symlink_to(outside)
            with self.assertRaises(ValueError): publication.check(root)
            (root / publication.MANIFEST).write_text(json.dumps({"files": ["../private", publication.MANIFEST]}))
            with self.assertRaises(ValueError): publication.allowed_files(root)

    def test_private_data_cannot_be_allowlisted(self):
        with tempfile.TemporaryDirectory() as parent:
            root = Path(parent).resolve(); self.fixture(root)
            for name in ["prefixes/account.json", "manifests/storage.json", "source/credential.pem"]:
                (root / publication.MANIFEST).write_text(json.dumps({"files": [name, publication.MANIFEST]}))
                with self.assertRaises(ValueError): publication.allowed_files(root)

    def test_secret_detection_never_echoes_the_matched_value(self):
        with tempfile.TemporaryDirectory() as parent:
            root = Path(parent).resolve(); self.fixture(root)
            token = "ghp_" + "a" * 36
            (root / "README.md").write_text(token)
            with self.assertRaises(ValueError) as failure: publication.check(root)
            self.assertIn("github-token", str(failure.exception))
            self.assertNotIn(token, str(failure.exception))

    def test_export_rejects_local_markers_and_unexpected_files(self):
        with tempfile.TemporaryDirectory() as parent:
            root = Path(parent).resolve(); self.fixture(root)
            (root / "README.md").write_text("fixture-local-identity")
            with self.assertRaises(ValueError): publication.check(root, markers={"fixture-local-identity"})
            (root / "README.md").write_text("Public")
            (root / "unlisted").write_text("private")
            with self.assertRaises(ValueError): publication.check(root, strict=True)

    def test_initialize_preserves_existing_files_and_rejects_links(self):
        with tempfile.TemporaryDirectory() as parent:
            root = Path(parent).resolve()
            for name in ["profiles", "manifests"]:
                (root / "examples" / name).mkdir(parents=True)
                (root / "examples" / name / "example.json").write_text('{"example": true}')
            self.assertEqual(initialization.initialize(root), 2)
            private = root / "profiles/example.json"; private.write_text('{"private": true}')
            self.assertEqual(initialization.initialize(root), 0)
            self.assertEqual(json.loads(private.read_text()), {"private": True})
            private.unlink(); private.symlink_to(root / "manifests/example.json")
            with self.assertRaises(ValueError): initialization.initialize(root)


if __name__ == "__main__":
    unittest.main()
