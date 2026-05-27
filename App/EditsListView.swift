// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Razvan Cremenescu

import SwiftUI

/// One "logical" edit row — the operations grouped into atomic reverts.
struct EditEntry: Identifiable {
    let id: String
    let label: String
    let detail: String
    let revert: () -> Void
}

struct EditsListView: View {
    @ObservedObject var doc: OpenImage

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Editari aplicate")
                    .font(.headline)
                Spacer()
                Button("Reseteaza tot") {
                    revertAll()
                }
                .disabled(doc.stack.isNeutral)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider()

            let entries = makeEntries()
            if entries.isEmpty {
                VStack {
                    Text("Niciuna")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 16)
                }
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(entries) { entry in
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(entry.label)
                                        .font(.callout)
                                    Text(entry.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                                Spacer()
                                Button {
                                    entry.revert()
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 15))
                                        .foregroundStyle(Color.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Revert acest pas")
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 320)
            }

            Text("Editarile sunt aplicate live; reverturile sunt undoable.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
    }

    // MARK: - Build entries from current stack

    private func makeEntries() -> [EditEntry] {
        var out: [EditEntry] = []
        let s = doc.stack

        if let crop = s.crop {
            let xPct = Int(crop.x * 100)
            let yPct = Int(crop.y * 100)
            let wPct = Int(crop.width * 100)
            let hPct = Int(crop.height * 100)
            out.append(EditEntry(
                id: "crop",
                label: "Decupare",
                detail: "\(xPct)% \(yPct)%  •  \(wPct)% × \(hPct)%",
                revert: { doc.commitChange { doc.stack.crop = nil } }
            ))
        }
        if abs(s.rotateDegrees) > 0.0001 {
            out.append(EditEntry(
                id: "rotate",
                label: "Rotire",
                detail: String(format: "%.2f°", s.rotateDegrees),
                revert: { doc.commitChange { doc.stack.rotateDegrees = 0 } }
            ))
        }
        if s.flipHorizontal {
            out.append(EditEntry(
                id: "flipH",
                label: "Flip orizontal",
                detail: "Activ",
                revert: { doc.commitChange { doc.stack.flipHorizontal = false } }
            ))
        }
        if s.flipVertical {
            out.append(EditEntry(
                id: "flipV",
                label: "Flip vertical",
                detail: "Activ",
                revert: { doc.commitChange { doc.stack.flipVertical = false } }
            ))
        }
        if s.adjustments.brightness != 0 {
            out.append(EditEntry(
                id: "brightness",
                label: "Luminozitate",
                detail: signed(s.adjustments.brightness * 100),
                revert: { doc.commitChange { doc.stack.adjustments.brightness = 0 } }
            ))
        }
        if s.adjustments.contrast != 0 {
            out.append(EditEntry(
                id: "contrast",
                label: "Contrast",
                detail: signed(s.adjustments.contrast * 100),
                revert: { doc.commitChange { doc.stack.adjustments.contrast = 0 } }
            ))
        }
        if s.adjustments.saturation != 0 {
            out.append(EditEntry(
                id: "saturation",
                label: "Saturatie",
                detail: signed(s.adjustments.saturation * 100),
                revert: { doc.commitChange { doc.stack.adjustments.saturation = 0 } }
            ))
        }
        if s.adjustments.exposure != 0 {
            out.append(EditEntry(
                id: "exposure",
                label: "Expunere",
                detail: String(format: "%+.2f EV", s.adjustments.exposure),
                revert: { doc.commitChange { doc.stack.adjustments.exposure = 0 } }
            ))
        }
        return out
    }

    private func signed(_ v: Double) -> String {
        String(format: "%+d", Int(v.rounded()))
    }

    private func revertAll() {
        doc.commitChange {
            doc.stack = EditStack()
        }
    }
}
