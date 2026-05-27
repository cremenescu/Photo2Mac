// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Razvan Cremenescu

import SwiftUI

enum EditorTool: String, CaseIterable, Identifiable {
    case move, crop, rotate, text, arrow, rect, blur
    var id: String { rawValue }
    var systemImage: String {
        switch self {
        case .move: return "hand.point.up.left"
        case .crop: return "crop"
        case .rotate: return "rotate.right"
        case .text: return "textformat"
        case .arrow: return "arrow.up.right"
        case .rect: return "rectangle"
        case .blur: return "drop.halffull"
        }
    }
    var label: String {
        switch self {
        case .move: return "Mutare"
        case .crop: return "Decupare"
        case .rotate: return "Rotire"
        case .text: return "Text"
        case .arrow: return "Sageata"
        case .rect: return "Dreptunghi"
        case .blur: return "Blur"
        }
    }
}

struct ContentView: View {
    @Binding var document: PhotoDocument
    @State private var tool: EditorTool = .move
    @State private var zoom: CGFloat = 1.0
    @State private var showInspector: Bool = true

    var body: some View {
        HSplitView {
            ImageCanvasView(image: document.image, zoom: $zoom)
                .frame(minWidth: 500, minHeight: 400)
                .layoutPriority(1)

            if showInspector {
                InspectorView(document: document, tool: tool)
                    .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                ForEach(EditorTool.allCases) { t in
                    Button {
                        tool = t
                    } label: {
                        Image(systemName: t.systemImage)
                            .symbolVariant(tool == t ? .fill : .none)
                    }
                    .help(t.label)
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    zoom = max(0.1, zoom / 1.25)
                } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Micsoreaza")

                Text("\(Int(zoom * 100))%")
                    .frame(width: 48)
                    .monospacedDigit()

                Button {
                    zoom = min(16, zoom * 1.25)
                } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Mareste")

                Button {
                    zoom = 1.0
                } label: { Image(systemName: "1.magnifyingglass") }
                .help("Marime reala")

                Toggle(isOn: $showInspector) {
                    Image(systemName: "sidebar.trailing")
                }
                .help("Inspector")
            }
        }
    }
}

struct InspectorView: View {
    @ObservedObject var document: PhotoDocument
    let tool: EditorTool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tool.label)
                .font(.headline)

            Divider()

            switch tool {
            case .move:
                Text("Selecteaza un tool pentru a edita.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            default:
                Text("Parametri \(tool.label) — in dezvoltare")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

            Spacer()

            if let img = document.image {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Dimensiune")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(Int(img.size.width)) x \(Int(img.size.height)) px")
                        .font(.callout)
                        .monospacedDigit()
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct SettingsView: View {
    var body: some View {
        Form {
            Section("General") {
                Text("Setari in dezvoltare.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
