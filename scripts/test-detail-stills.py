#!/usr/bin/env python3
"""Source-contract regression checks; not a substitute for SwiftUI/device tests.

Run from any directory: python3 scripts/test-detail-stills.py
These guard the two visibility conditions and the independent extras section.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
DETAIL = ROOT / "Packages/VelaKit/Sources/VelaFeatures/Detail"


class DetailStillsContracts(unittest.TestCase):
    def test_gallery_is_not_gated_by_layout_or_extras(self):
        source = (DETAIL / "ItemDetailView.swift").read_text()
        self.assertRegex(source, r"if let client \{\s*StillsShelf\(images: client\.stillImages\(for: item, screenshotTags: model\.details\?\.screenshotImageTags \?\? \[\]\)\)\s*\}")

    def test_single_image_is_visible_and_empty_gallery_is_hidden(self):
        source = (DETAIL / "DetailStills.swift").read_text().split("struct StillsShelf: View {", 1)[1]
        self.assertRegex(source, r"var body: some View \{\s*if !images\.isEmpty \{")
        self.assertNotIn("images.count > 1", source.split("private struct StillPreview", 1)[0])

    def test_stills_and_video_extras_are_independent_siblings(self):
        source = (DETAIL / "ItemDetailView.swift").read_text()
        self.assertRegex(source, r"StillsShelf\(images: client\.stillImages\(for: item, screenshotTags: model\.details\?\.screenshotImageTags \?\? \[\]\)\)\s*\}\s*ExtrasShelf\(trailers: model\.trailers, remoteTrailers: model\.details\?\.remoteTrailers \?\? \[\], features: model\.specialFeatures\)")

    def test_static_images_do_not_become_video_play_buttons(self):
        stills = (DETAIL / "DetailStills.swift").read_text().split("struct StillsShelf: View {", 1)[1]
        self.assertIn('RemoteArtwork(url: image.thumbnailURL, placeholderSymbol: "photo")', stills)
        self.assertNotIn("playMedia", stills)
        extras = (DETAIL / "DetailSections.swift").read_text().split("struct ExtrasShelf: View {", 1)[1].split("// MARK: - 章节", 1)[0]
        self.assertIn('ForEach(features) { card($0, badge: "花絮") }', extras)
        self.assertIn("Button { playMedia(.item(item)) }", extras)


if __name__ == "__main__":
    unittest.main()
